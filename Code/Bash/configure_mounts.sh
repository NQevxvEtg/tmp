#!/usr/bin/env bash

#
# =================================================================================
# configure_live_mounts.sh (v3)
# -----------------------------
# This script automates Phase 3 of the LVM setup on a LIVE system.
#
# NEW FEATURES:
# - Uses custom CamelCase LV names (e.g., 'varLog') as requested.
# - Automatically stops a predefined list of services to ensure a safer migration.
#
# WHAT IT DOES:
# 1. Stops common services that write to the target filesystems.
# 2. Backs up /etc/fstab.
# 3. Creates a temporary mount structure to mirror the final filesystem layout.
# 4. Copies data from old directories using rsync.
# 5. Moves old directories to *.old backups and creates new mount points.
# 6. Automatically finds UUIDs and adds new entries to /etc/fstab.
# 7. Mounts all new filesystems.
#
# HOW TO USE:
# 1. Review the SERVICES_TO_STOP list below. Add any other services you use.
# 2. Save script as 'configure_live_mounts.sh'.
# 3. Make it executable: `chmod +x configure_live_mounts.sh`
# 4. Run with sudo: `sudo ./configure_live_mounts.sh`
# 5. After success, REBOOT the system.
#
# =================================================================================
#

# --- Safety First: Exit immediately if a command exits with a non-zero status.
set -e
set -o pipefail

# --- Check if running as root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "!!! This script must be run as root or with sudo. Please run 'sudo ./configure_live_mounts.sh' !!!" >&2
  exit 1
fi

# --- Configuration
MIGRATION_ROOT="/mnt/migration_root"
FSTAB_FILE="/etc/fstab"

# Define your exact LV names and their mount points / options
declare -A LV_CONFIG
LV_CONFIG["home"]="nodev"
LV_CONFIG["tmp"]="noexec,nosuid,nodev"
LV_CONFIG["opt"]="nodev"
LV_CONFIG["optMcAfee"]="nodev"
LV_CONFIG["var"]="nosuid,nodev"
LV_CONFIG["varLog"]="noexec,nosuid,nodev"
LV_CONFIG["varLogAudit"]="noexec,nosuid,nodev"

# Define mount paths for each LV
declare -A LV_PATHS
LV_PATHS["home"]="/home"
LV_PATHS["tmp"]="/tmp"
LV_PATHS["opt"]="/opt"
LV_PATHS["optMcAfee"]="/opt/McAfee"
LV_PATHS["var"]="/var"
LV_PATHS["varLog"]="/var/log"
LV_PATHS["varLogAudit"]="/var/log/audit"

# Define the order for mounting (parents before children)
MOUNT_ORDER=("home" "tmp" "opt" "var" "optMcAfee" "varLog" "varLogAudit")

# Define services to stop. Add any others specific to your system.
SERVICES_TO_STOP=(
    rsyslog
    auditd
    crond
    atd
    httpd
    nginx
    mariadb
    mysqld
    postgresql
    postfix
    sendmail
)

# --- 1. Stop Services
echo ">>> Phase 3.0: Automatically stopping services..."
echo ">>> This is critical for data integrity on a live migration."

# Be safe: Flush systemd journal to disk before stopping logging
if command -v journalctl &> /dev/null; then
    echo "    - Flushing journald logs to disk..."
    journalctl --flush || echo "    - (Warning) Failed to flush journald, continuing."
fi

for service in "${SERVICES_TO_STOP[@]}"; do
    # Check if the service is active before trying to stop it
    if systemctl is-active --quiet "$service"; then
        echo "    - Stopping active service: $service"
        systemctl stop "$service"
    else
        echo "    - Service not active, skipping: $service"
    fi
done
echo "    - Service stop phase complete."


# --- 2. Data Migration via Temporary Mounts
echo ">>> Phase 3.1: Migrating data to new LVs via temporary mounts..."
mkdir -p "$MIGRATION_ROOT"

# Mount all LVs in the correct hierarchical order
for lv_name in "${MOUNT_ORDER[@]}"; do
    mount_path_suffix="${LV_PATHS[$lv_name]}"
    temp_mount_point="${MIGRATION_ROOT}${mount_path_suffix}"
    lv_device="/dev/ocivolume/${lv_name}"

    echo "    - Mounting ${lv_device} at ${temp_mount_point}"
    mkdir -p "$temp_mount_point"
    mount "$lv_device" "$temp_mount_point"
done

# Perform rsync for the top-level directories
echo "    - rsync'ing /home/, /tmp/, /opt/, /var/..."
# The trailing slashes are important!
rsync -axv /home/ "${MIGRATION_ROOT}/home/"
rsync -axv /tmp/ "${MIGRATION_ROOT}/tmp/"
rsync -axv /opt/ "${MIGRATION_ROOT}/opt/"
rsync -axv /var/ "${MIGRATION_ROOT}/var/"

# Unmount all temporary mounts in reverse order
echo "    - Unmounting all temporary filesystems..."
for (( idx=${#MOUNT_ORDER[@]}-1 ; idx>=0 ; idx-- )) ; do
    lv_name="${MOUNT_ORDER[idx]}"
    mount_path_suffix="${LV_PATHS[$lv_name]}"
    temp_mount_point="${MIGRATION_ROOT}${mount_path_suffix}"
    umount "$temp_mount_point" || echo "    - (Warning) Could not unmount $temp_mount_point. Continuing."
done

rm -rf "$MIGRATION_ROOT"
echo "    - Migration complete."

# --- 3. Move Old Dirs & Create New Mount Points
echo ">>> Phase 3.2: Renaming old directories and creating new mount points..."
declare -A TOP_LEVEL_DIRS
TOP_LEVEL_DIRS["/var"]=1
TOP_LEVEL_DIRS["/home"]=1
TOP_LEVEL_DIRS["/opt"]=1
TOP_LEVEL_DIRS["/tmp"]=1

for path in "${!TOP_LEVEL_DIRS[@]}"; do
    if [ -d "$path" ]; then
        echo "    - Moving ${path} to ${path}.old"
        mv "$path" "${path}.old"
    fi
    echo "    - Creating new empty mount point at ${path}"
    mkdir -p "$path"
done

# --- 4. Update /etc/fstab
echo ">>> Phase 3.3: Updating /etc/fstab..."
FSTAB_BACKUP="/etc/fstab.bak.$(date +%F-%T)"
echo "    - Backing up current fstab to ${FSTAB_BACKUP}"
cp "$FSTAB_FILE" "$FSTAB_BACKUP"

FSTAB_ADDITIONS=""
for lv_name in "${MOUNT_ORDER[@]}"; do
    mount_path="${LV_PATHS[$lv_name]}"
    options="defaults,${LV_CONFIG[$lv_name]}"
    device_path="/dev/ocivolume/${lv_name}"

    if grep -qE "[\s|	]${mount_path}[\s|	]" "$FSTAB_FILE"; then
        echo "    - WARNING: An entry for ${mount_path} already exists in fstab. Skipping."
        continue
    fi

    uuid=$(blkid -s UUID -o value "$device_path")
    if [[ -z "$uuid" ]]; then
        echo "    - ERROR: Could not find UUID for ${device_path}. Aborting." >&2
        exit 1
    fi
    
    FSTAB_ADDITIONS+=$(printf "UUID=%s\t%s\txfs\t%s\t0 0\n" "$uuid" "$mount_path" "$options")
done

echo "    - Appending new entries to fstab..."
echo -e "\n# Added by LVM migration script on $(date)\n${FSTAB_ADDITIONS}" >> "$FSTAB_FILE"
echo "    - fstab update complete."

# --- 5. Mount All
echo ">>> Phase 3.4: Mounting all filesystems..."
# We must create the nested mountpoint directories before 'mount -a' can succeed
mkdir -p /opt/McAfee
mkdir -p /var/log
mkdir -p /var/log/audit

echo "    - Running 'mount -a'..."
mount -a

echo "--------------------------------------------------------"
echo ">>> SUCCESS: Live migration script has completed."
echo ">>> Services were stopped and will not restart until a reboot."
echo ">>> Please review 'df -h' and 'mount' to verify."
echo ">>> If everything is correct, REBOOT THE SYSTEM NOW."
echo "--------------------------------------------------------"