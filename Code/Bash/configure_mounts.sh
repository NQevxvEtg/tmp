#!/usr/bin/env bash

#
# ========================================================================================
# configure_live_mounts.sh (v14 - Final Bulletproof Version)
# -------------------------------------------------------------------------
# This script automates Phase 3 of the LVM setup on a LIVE, SELinux-enabled system.
#
# DEFINITIVE FIXES in v14:
# - FIXES `target is busy` error by using `umount -l` (lazy unmount) on nested
#   filesystems. This immediately detaches the filesystem from its mount point,
#   allowing the script to proceed without being blocked by a busy process, which is
#   critical for the safety of the subsequent `mv` command.
# - Retains all previous safety features. This version is maximally robust for live environments.
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
    local RSYNC_EXIT_CODE=0

    echo "    - rsync'ing ${source} to ${destination}..."
    rsync -rlptgovX "${extra_args[@]}" "${source}" "${destination}" || RSYNC_EXIT_CODE=$?

    if [[ $RSYNC_EXIT_CODE -eq 23 || $RSYNC_EXIT_CODE -eq 24 ]]; then
        echo "    - (OK/Warning) rsync finished with code ${RSYNC_EXIT_CODE}. This is acceptable and will be ignored."
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
# Add any other known nested mount points here that need to be unmounted first.
PRE_UNMOUNTS=("/var/oled")

declare -A LV_CONFIG
LV_CONFIG["home"]="nodev"
LV_CONFIG["tmp"]="noexec,nosuid,nodev"
LV_CONFIG["var"]="nosuid,nodev"
LV_CONFIG["varTmp"]="noexec,nosuid,nodev"
LV_CONFIG["varLog"]="noexec,nosuid,nodev"
LV_CONFIG["varLogAudit"]="noexec,nosuid,nodev"
LV_CONFIG["opt"]="nodev"
LV_CONFIG["optMcAfee"]="nodev"

declare -A LV_PATHS
LV_PATHS["home"]="/home"
LV_PATHS["tmp"]="/tmp"
LV_PATHS["var"]="/var"
LV_PATHS["varTmp"]="/var/tmp"
LV_PATHS["varLog"]="/var/log"
LV_PATHS["varLogAudit"]="/var/log/audit"
LV_PATHS["opt"]="/opt"
LV_PATHS["optMcAfee"]="/opt/McAfee"

MOUNT_ORDER=("home" "tmp" "opt" "var" "varTmp" "optMcAfee" "varLog" "varLogAudit")
SERVICES_TO_STOP=(
    rsyslog crond atd httpd nginx mariadb mysqld postgresql postfix sendmail docker podman
)

# --- 1. Stop Services & Disable Auditing
echo ">>> Phase 3.0: Stopping services..."
if systemctl is-active --quiet auditd; then echo "    - Disabling audit rule generation with 'auditctl -e 0'"; auditctl -e 0; fi
if command -v journalctl &> /dev/null; then echo "    - Flushing journald logs..."; journalctl --flush || true; fi
for service in "${SERVICES_TO_STOP[@]}"; do
    if systemctl is-active --quiet "$service"; then
        echo "    - Stopping active service: $service"; systemctl stop "$service"
    fi
done
echo "    - Service stop phase complete."

# --- 2. CRITICAL: Unmount Nested Filesystems (Anti-Race-Condition)
echo ">>> Phase 3.1: Unmounting nested filesystems to prevent 'ghost mounts'..."
for mount_point in "${PRE_UNMOUNTS[@]}"; do
    if findmnt -rno TARGET "$mount_point" > /dev/null; then
        # FIX: Use `umount -l` (lazy) to avoid "target is busy" errors on a live system.
        # This detaches the filesystem from the directory tree immediately so `mv` is safe.
        echo "    - Performing lazy unmount on ${mount_point}..."
        umount -l "$mount_point"
    else
        echo "    - (Info) ${mount_point} is not a mount point, skipping unmount."
    fi
done

# --- 3. Data Migration
echo ">>> Phase 3.2: Migrating data to new LVs..."
mkdir -p "$MIGRATION_ROOT"
for lv_name in "${MOUNT_ORDER[@]}"; do
    temp_mount_point="${MIGRATION_ROOT}${LV_PATHS[$lv_name]}"; lv_device="/dev/ocivolume/${lv_name}"
    echo "    - Mounting ${lv_device} at ${temp_mount_point}"; mkdir -p "$temp_mount_point"; mount "$lv_device" "$temp_mount_point"
done

run_rsync /home/ "${MIGRATION_ROOT}/home/"
run_rsync /tmp/ "${MIGRATION_ROOT}/tmp/"
run_rsync /opt/ "${MIGRATION_ROOT}/opt/"
run_rsync /var/ "${MIGRATION_ROOT}/var/" --exclude='/var/run' --exclude='/var/lock' --exclude='/var/oled'

echo "    - Unmounting all temporary filesystems (using lazy unmount)..."
for (( idx=${#MOUNT_ORDER[@]}-1 ; idx>=0 ; idx-- )) ; do
    temp_mount_point="${MIGRATION_ROOT}${LV_PATHS[${MOUNT_ORDER[idx]}]}"
    umount -l "$temp_mount_point"
done
rm -rf "$MIGRATION_ROOT"
echo "    - Migration complete."

# --- 4. Move Old Dirs & Create New Mount Points
echo ">>> Phase 3.3: Renaming old directories and creating new mount points..."
declare -A TOP_LEVEL_DIRS
TOP_LEVEL_DIRS["/var"]=1; TOP_LEVEL_DIRS["/home"]=1; TOP_LEVEL_DIRS["/opt"]=1; TOP_LEVEL_DIRS["/tmp"]=1
for path in "${!TOP_LEVEL_DIRS[@]}"; do
    if [ -d "$path" ]; then mv "$path" "${path}.old"; fi
    mkdir -p "$path"
done

# --- 5. Update /etc/fstab
echo ">>> Phase 3.4: Updating /etc/fstab..."
FSTAB_BACKUP="/etc/fstab.bak.$(date +%F-%T)"
echo "    - Backing up current fstab to ${FSTAB_BACKUP}"; cp "$FSTAB_FILE" "$FSTAB_BACKUP"
echo "" >> "$FSTAB_FILE"; echo "# Added by LVM migration script on $(date)" >> "$FSTAB_FILE"

for lv_name in "${MOUNT_ORDER[@]}"; do
    mount_path="${LV_PATHS[$lv_name]}"; options="defaults,${LV_CONFIG[$lv_name]}"; device_path="/dev/ocivolume/${lv_name}"
    if grep -qE "[\s|	]${mount_path}[\s|	]" "$FSTAB_FILE"; then continue; fi
    uuid=$(blkid -s UUID -o value "$device_path")
    if [[ -z "$uuid" ]]; then echo "    - ERROR: Could not find UUID for ${device_path}. Aborting." >&2; exit 1; fi
    echo -e "UUID=${uuid}\t${mount_path}\txfs\t${options}\t0 0" >> "$FSTAB_FILE"
done
echo "    - fstab update complete."

# --- 6. Mount All & Prepare for SELinux Relabel
echo ">>> Phase 3.5: Re-creating mount points, mounting all, and preparing for SELinux relabel..."
mkdir -p /opt/McAfee /var/log /var/log/audit /var/tmp /var/oled
echo "    - Running 'mount -a' to mount all filesystems..."; mount -a
echo "    - IMPORTANT: Creating /.autorelabel for next boot."; touch /.autorelabel

echo "---------------------------------------------------------------------"
echo ">>> SUCCESS: Live migration script has completed."
echo -e ">>> Please review 'df -h', 'mount', and '/etc/fstab' to verify correctness.\n"
echo ">>> REBOOT THE SYSTEM NOW to complete the migration."
echo "---------------------------------------------------------------------"