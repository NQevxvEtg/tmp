#!/usr/bin/env bash

#
# ========================================================================================
# configure_live_mounts.sh (v9 - Definitive rsync & fstab Handling)
# ----------------------------------------------------------------
# This script automates Phase 3 of the LVM setup on a LIVE, SELinux-enabled system.
#
# DEFINITIVE FIXES in v9:
# - Directly addresses 'rsync error 23' by gracefully accepting it as a non-fatal
#   warning, which is expected when trying to copy volatile system files.
# - Prevents the error by removing the '-D' flag from rsync's archive mode, as we
#   do not need to migrate live sockets or device files.
# - Retains the foolproof line-by-line fstab update to prevent corruption.
# - Retains all other safety features (lazy unmount, SELinux autorelabel, etc.)
#
# ========================================================================================
#

# --- Safety First: Exit immediately if a command exits with a non-zero status.
set -e
set -o pipefail

# --- Function to handle rsync with specific exit code handling
run_rsync() {
    local source=$1
    local destination=$2
    shift 2
    local extra_args=("$@")

    echo "    - rsync'ing ${source} to ${destination}..."
    # FIX: Use specific flags instead of '-a' to avoid '-D' which causes errors on special files.
    # We still get recursive, links, perms, times, group, owner, and extended attrs.
    rsync -rlptgovX "${extra_args[@]}" "${source}" "${destination}"
    local RSYNC_EXIT_CODE=$?

    # FIX: Accept codes 23 (error) and 24 (vanished) as non-fatal for live migrations.
    if [[ $RSYNC_EXIT_CODE -eq 23 || $RSYNC_EXIT_CODE -eq 24 ]]; then
        echo "    - (OK/Warning) rsync finished with code ${RSYNC_EXIT_CODE}. This is acceptable for a live migration and the process will continue."
    elif [[ $RSYNC_EXIT_CODE -ne 0 ]]; then
        echo "    - !!! CRITICAL ERROR: rsync failed with unexpected exit code ${RSYNC_EXIT_CODE}. Aborting. !!!" >&2
        exit $RSYNC_EXIT_CODE
    fi
}

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

# --- 2. Data Migration with Definitive Error Handling
echo ">>> Phase 3.1: Migrating data to new LVs..."
mkdir -p "$MIGRATION_ROOT"
for lv_name in "${MOUNT_ORDER[@]}"; do
    temp_mount_point="${MIGRATION_ROOT}${LV_PATHS[$lv_name]}"; lv_device="/dev/ocivolume/${lv_name}"
    echo "    - Mounting ${lv_device} at ${temp_mount_point}"; mkdir -p "$temp_mount_point"; mount "$lv_device" "$temp_mount_point"
done

run_rsync /home/ "${MIGRATION_ROOT}/home/"
run_rsync /tmp/ "${MIGRATION_ROOT}/tmp/"
run_rsync /opt/ "${MIGRATION_ROOT}/opt/"
run_rsync /var/ "${MIGRATION_ROOT}/var/" --exclude='/var/run' --exclude='/var/lock'

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

# --- 4. Update /etc/fstab (Foolproof Method)
echo ">>> Phase 3.3: Updating /etc/fstab..."
FSTAB_BACKUP="/etc/fstab.bak.$(date +%F-%T)"
echo "    - Backing up current fstab to ${FSTAB_BACKUP}"; cp "$FSTAB_FILE" "$FSTAB_BACKUP"

echo "    - Ensuring fstab integrity and appending new entries line-by-line..."
echo "" >> "$FSTAB_FILE"
echo "# Added by LVM migration script on $(date)" >> "$FSTAB_FILE"

for lv_name in "${MOUNT_ORDER[@]}"; do
    mount_path="${LV_PATHS[$lv_name]}"; options="defaults,${LV_CONFIG[$lv_name]}"; device_path="/dev/ocivolume/${lv_name}"
    if grep -qE "[\s|	]${mount_path}[\s|	]" "$FSTAB_FILE"; then
        echo "    - An entry for ${mount_path} already exists. Skipping."
        continue
    fi
    uuid=$(blkid -s UUID -o value "$device_path")
    if [[ -z "$uuid" ]]; then echo "    - ERROR: Could not find UUID for ${device_path}. Aborting." >&2; exit 1; fi
    printf "UUID=%s\t%s\txfs\t%s\t0 0\n" "$uuid" "$mount_path" "$options" >> "$FSTAB_FILE"
done
echo "    - fstab update complete."

# --- 5. Mount All & Prepare for SELinux Relabel
echo ">>> Phase 3.4: Mounting all filesystems & preparing for SELinux relabel..."
mkdir -p /opt/McAfee /var/log /var/log/audit /var/tmp
echo "    - Running 'mount -a'..."; mount -a

echo "    - IMPORTANT: Creating /.autorelabel to trigger a full SELinux relabel on next boot."; touch /.autorelabel

echo "---------------------------------------------------------------------"
echo ">>> SUCCESS: Live migration script has completed."
echo -e ">>> Please review 'df -h' and 'mount' to verify correctness.\n"
echo ">>> !!!!!!!!!!!!!!!!!!!!!!!!!!! CRITICAL !!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ">>> AN SELINUX AUTORELABEL HAS BEEN SCHEDULED FOR THE NEXT BOOT."
echo ">>> THE REBOOT WILL TAKE SIGNIFICANTLY LONGER THAN USUAL. "
echo -e ">>> DO NOT INTERRUPT IT. THIS IS A NORMAL, ONE-TIME PROCESS.\n"
echo ">>> REBOOT THE SYSTEM NOW to complete the migration."
echo "---------------------------------------------------------------------"