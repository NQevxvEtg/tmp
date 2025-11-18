#!/bin/bash

# 1. Define the destination directory for your mirror
MIRROR_DIR="/var/www/html/yum"

# 2. Define the array of Repo IDs to sync
# (You can find these IDs by running 'dnf repolist all')
REPOS=(
    "ol9_baseos_latest"
    "ol9_appstream"
    "ol9_uek_latest"
    "ol8_baseos_latest"
    "ol8_appstream"
)

# 3. Start the Loop
echo "Starting Mirror Sync at $(date)"

for REPO_ID in "${REPOS[@]}"; do
    echo "-------------------------------------------------"
    echo "Processing repository: $REPO_ID"
    
    # Create the specific directory so the structure is clean
    # (Optional: reposync usually creates the dir, but this is safer)
    mkdir -p "$MIRROR_DIR"

    # 4. Run dnf reposync
    # --delete: Remove local packages that no longer exist upstream
    # --newest-only: Don't download old versions (saves huge disk space)
    # --download-metadata: Required for the client to see repodata

    dnf reposync \
        --repoid="$REPO_ID" \
        --download-path="$MIRROR_DIR" \
        --newest-only \
        --download-metadata \
        --delete

    if [ $? -eq 0 ]; then
        echo "Basic sync for $REPO_ID - SUCCESS"
    else
        echo "Basic sync for $REPO_ID - FAILED"
    fi
done

echo "-------------------------------------------------"
echo "All sync jobs completed at $(date)"