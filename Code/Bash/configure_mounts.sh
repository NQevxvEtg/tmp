#!/usr/bin/env bash

#
# =================================================================================
# configure_live_mounts.sh (v7 - Robust Error Handling)
# -----------------------------------------------------
# This script automates Phase 3 of the LVM setup on a LIVE, SELinux-enabled system.
#
# CRITICAL FIXES in v7:
# - Correctly handles fstab by ensuring the file ends with a newline before appending.
# - Uses `umount -l` (lazy unmount) to prevent "device is busy" errors.
# - Excludes volatile directories (`/var/run`, `/var/lock`) during rsync to prevent
#   "partial transfer" (exit 23) errors.
#
# HOW TO USE:
# 1. Save script as 'configure_live_mounts.sh'.
# 2. Make it executable: `chmod +x configure_live_mounts.sh`
# 3. Run with sudo: `sudo ./configure_live_mounts.sh`
# 4. After success, REBOOT. The first boot will be MUCH LONGER. This is normal.
#
# =================================================================================
#

# --- Safety First: Exit immediately if a command exits with a non-zero status.
set -e
set -o pipefail

# --- Check if running as root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "!!! This script must be run as root or with sudo. !!!" >&2
  exit 1
fi

# --- Configuration
MIGRATION_ROOT="/mnt/migration_root"
FSTAB_FILE="/etc/fstab"

declare -A LV_CONFIG
LV_CONFIG["home"]="nodev"; LV_CONFIG["tmp"]="noexec,nosuid,nodev"
LV_CONFIG["var"]="nosuid,nodev"; LV_CONFIG["varTmp"]="noexec,nosuid,nodev"
LV_CONFIG["varLog"]="noexec,nosuid,nodev"; LV_CONFIG["varLogAudit"]="noexec,nosuid,nodev"
LV_CONFIG["opt"]="nodev"; LV_CONFIG["optMcAfee"]="nodev"

declare -A LV_PATHS
LV_PATHS["home"]="/home"; LV_PATHS["tmp"]="/tmp"; LV_PATHS["var"]="/var"
LV_PATHS["varTmp"]="/var/tmp"; LV_PATHS["varLog"]="/var/log"; LV_PATHS["varLogAudit"]="/var/log/audit"
LV_PATHS["opt"]="/opt"; LV_PATHS["optMcAfee"]="/opt/McAfee"

MOUNT_ORDER=("home" "tmp" "opt" "var" "varTmp" "optMcAfee" "varLog" "varLogAudit")
SERVICES_TO_STOP=(
    rsyslog crond atd httpd nginx mariadb mysqld postgresql postfix sendmail
)

# --- 1. Stop Services & Disable Auditing
echo ">>> Phase 3.0: Automatically stopping services & disabling auditing..."
if systemctl is-active --quiet auditd; then echo "    - Disabling audit rule generation with 'auditctl -e 0'"; auditctl -e 0; fi
if command -v journalctl &> /dev/null; then echo "    - Flushing journald logs..."; journalctl --flush || true; fi
for service in "${SERVICES_TO_STOP[@]}"; do
    if systemctl is-active --quiet "$service"; then
        echo "    - Stopping active service: $service"; systemctl stop "$service"
    else
        echo "    - Service not active, skipping: $service"
    fi
done
echo "    - Service stop phase complete."

# --- 2. Data Migration with SELinux Contexts
echo ">>> Phase 3.1: Migrating data to new LVs..."
mkdir -p "$MIGRATION_ROOT"
for lv_name in "${MOUNT_ORDER[@]}"; do
    temp_mount_point="${MIGRATION_ROOT}${LV_PATHS[$lv_name]}"; lv_device="/dev/ocivolume/${lv_name}"
    echo "    - Mounting ${lv_device} at ${temp_mount_point}"; mkdir -p "$temp_mount_point"; mount "$lv_device" "$temp_mount_point"
done

echo "    - rsync'ing /home/, /tmp/, /opt/ with SELinux contexts..."
rsync -axvX /home/ "${MIGRATION_ROOT}/home/"
rsync -axvX /tmp/ "${MIGRATION_ROOT}/tmp/"
rsync -axvX /opt/ "${MIGRATION_ROOT}/opt/"

# FIX: For /var, exclude volatile run/lock directories to prevent rsync error 23
echo "    - rsync'ing /var/ (excluding /var/run and /var/lock)..."
rsync -axvX --exclude='/var/run' --exclude='/var/lock' /var/ "${MIGRATION_ROOT}/var/"

# FIX: Use "lazy" unmount (-l) to avoid "device is busy" errors.
echo "    - Unmounting all temporary filesystems (using lazy unmount)..."
for (( idx=${#MOUNT_ORDER[@]}-1 ; idx>=0 ; idx-- )) ; do
    temp_mount_point="${MIGRATION_ROOT}${LV_PATHS[${MOUNT_ORDER[idx]}]}"
    umount -l "$temp_mount_point"
done
rm -rf "$MIGRATION_ROOT"
echo "    - Migration complete."

# --- 3. Move Old Dirs & Create New Mount Points
echo ">>> Phase 3.2: Renaming old directories and creating new mount points..."
declare -A TOP_LEVEL_DIRS
TOP_LEVEL_DIRS["/var"]=1; TOP_LEVEL_DIRS["/home"]=1; TOP_LEVEL_DIRS["/opt"]=1; TOP_LEVEL_DIRS["/tmp"]=1
for path in "${!TOP_LEVEL_DIRS[@]}"; do
    if [ -d "$path" ]; then mv "$path" "${path}.old"; fi
    mkdir -p "$path"
done

# --- 4. Update /etc/fstab (Safely)
echo ">>> Phase 3.3: Updating /etc/fstab..."
FSTAB_BACKUP="/etc/fstab.bak.$(date +%F-%T)"
echo "    - Backing up current fstab to ${FSTAB_BACKUP}"; cp "$FSTAB_FILE" "$FSTAB_BACKUP"

# FIX: Ensure fstab ends with a newline before we append to it.
if [[ "$(tail -c1 "$FSTAB_FILE")" != "" ]]; then
    echo "    - Adding missing newline to end of fstab to prevent corruption."
    echo >> "$FSTAB_FILE"
fi

FSTAB_ADDITIONS=""
for lv_name in "${MOUNT_ORDER[@]}"; do
    mount_path="${LV_PATHS[$lv_name]}"; options="defaults,${LV_CONFIG[$lv_name]}"; device_path="/dev/ocivolume/${lv_name}"
    if grep -qE "[\s|	]${mount_path}[\s|	]" "$FSTAB_FILE"; then continue; fi
    uuid=$(blkid -s UUID -o value "$device_path")
    if [[ -z "$uuid" ]]; then echo "    - ERROR: Could not find UUID for ${device_path}. Aborting." >&2; exit 1; fi
    FSTAB_ADDITIONS+=$(printf "UUID=%s\t%s\txfs\t%s\t0 0\n" "$uuid" "$mount_path" "$options")
done
echo "    - Appending new entries to fstab...";
echo -e "\n# Added by LVM migration script on $(date)\n${FSTAB_ADDITIONS}" >> "$FSTAB_FILE"
echo "    - fstab update complete."

# --- 5. Mount All & Prepare for SELinux Relabel
echo ">>> Phase 3.4: Mounting all filesystems & preparing for SELinux relabel..."
mkdir -p /opt/McAfee /var/log /var/log/audit /var/tmp
echo "    - Running 'mount -a'..."; mount -a

echo "    - IMPORTANT: Creating /.autorelabel to trigger a full SELinux relabel on next boot."; touch /.autorelabel

echo "---------------------------------------------------------------------"
echo ">>> SUCCESS: Live migration script has completed."
echo ">>> Please review 'df -h' and 'mount' to verify correctness."
echo ">>> "
echo ">>> !!!!!!!!!!!!!!!!!!!!!!!!!!! CRITICAL !!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ">>> AN SELINUX AUTORELABEL HAS BEEN SCHEDULED FOR THE NEXT BOOT."
echo ">>> THE REBOOT WILL TAKE SIGNIFICANTLY LONGER THAN USUAL. "
echo ">>> DO NOT INTERRUPT IT. THIS IS A NORMAL, ONE-TIME PROCESS."
echo ">>> "
echo ">>> REBOOT THE SYSTEM NOW to complete the migration."
echo "---------------------------------------------------------------------"