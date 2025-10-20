#!/bin/bash

# Configuration for iostat
IOSTAT_INTERVAL=1
IOSTAT_COUNT=1

# --- 1. Generate the Device-to-Mount Mapping (No Changes Needed Here) ---
generate_mapping() {
    MAPPING_DATA=$(lsblk -P -o KNAME,MOUNTPOINT,TYPE)
    
    declare -A IOSTAT_MAP

    echo "$MAPPING_DATA" | while IFS=$'\n' read -r line; do
        KNAME=$(echo "$line" | grep -oE "KNAME=\"[^\"]*\"" | cut -d'"' -f2)
        MOUNTPOINT=$(echo "$line" | grep -oE "MOUNTPOINT=\"[^\"]*\"" | cut -d'"' -f2)
        TYPE=$(echo "$line" | grep -oE "TYPE=\"[^\"]*\"" | cut -d'"' -f2)

        if [[ -n "$MOUNTPOINT" && ("$TYPE" == "disk" || "$TYPE" == "part" || "$TYPE" == "lvm" || "$TYPE" == "crypt") ]]; then
            IOSTAT_MAP["$KNAME"]="$MOUNTPOINT"
        elif [[ -z "$MOUNTPOINT" && "$TYPE" == "lvm" ]]; then
            LV_NAME=$(echo "$line" | grep -oE "NAME=\"[^\"]*\"" | cut -d'"' -f2)
            IOSTAT_MAP["$KNAME"]="/dev/mapper/$LV_NAME"
        fi
    done

    for k in "${!IOSTAT_MAP[@]}"; do 
        echo "$k:${IOSTAT_MAP[$k]}"
    done
}

MAP_SOURCE=$(generate_mapping)
declare -A REPLACEMENT_MAP

while IFS=: read -r KNAME MPOINT; do
    REPLACEMENT_MAP["$KNAME"]="$MPOINT"
done <<< "$MAP_SOURCE"

# --- 2. Function to Process iostat Output (Minimal Changes) ---
process_iostat_output() {
    local line=$1
    local output=""
    
    # Check if the line starts with a block device name (e.g., sda, dm-0)
    if [[ "$line" =~ ^(sd|hd|dm|md)[a-z0-9-]* ]]; then
        local device_name=$(echo "$line" | awk '{print $1}')
        local replacement="${REPLACEMENT_MAP[$device_name]}"
        
        if [[ -n "$replacement" ]]; then
            # Found a mapping: Replace the device name with the mount point
            # Use printf for precise column formatting based on the original data
            
            # The device column in iostat -k is usually 17 characters wide.
            local formatted_replacement=$(printf "%-17s" "$replacement")
            
            # Print the replacement followed by the rest of the line (starting from the second field)
            local rest_of_line=$(echo "$line" | awk '{$1=""; print $0}')
            
            output="${formatted_replacement}${rest_of_line}"
            
        else
            # No mapping found, print original line
            output="$line"
        fi
    else
        # Not a device line, print original line
        output="$line"
    fi
    
    echo "$output"
}

# --- 3. Run iostat and Process Stream ---

# Use iostat -k -N (basic historical rates) instead of -dxk (extended stats)
# -k: Reports in kilobytes (matching your desired output)
# -N: Uses LVM names where possible, although we override this with mount points.
iostat -k -N $IOSTAT_INTERVAL $IOSTAT_COUNT | while IFS=$'\n' read -r original_line; do
    
    # Check if the line is the Device header line
    if [[ "$original_line" =~ ^Device ]]; then
        # Replace "Device" with "Mount" and adjust spacing/tabs
        # Original header is "Device             tps ..." (19 characters wide)
        # We replace "Device" with "Mount" and pad it out.
        echo "Mount              $(echo "$original_line" | awk '{$1=""; print $0}')"
    else
        process_iostat_output "$original_line"
    fi
    
done
