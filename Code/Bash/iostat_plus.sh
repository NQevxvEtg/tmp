#!/bin/bash

# Configuration for iostat
IOSTAT_INTERVAL=2
IOSTAT_COUNT=5 

# Check for 'script' availability
if ! command -v script &> /dev/null; then
    echo "Error: 'script' command (part of util-linux) not found." >&2
    echo "This command is required to force iostat to output color codes." >&2
    exit 1
fi

# --- 1. Generate the Device-to-Mount Mapping for AWK ---
generate_awk_mapping() {
    lsblk -P -o KNAME,MOUNTPOINT,TYPE,NAME | awk '
        /KNAME/ {
            kname = $0; gsub(/.*KNAME="|" .*/, "", kname);
            mount = $0; gsub(/.*MOUNTPOINT="|" .*/, "", mount);
            type = $0; gsub(/.*TYPE="|" .*/, "", type);
            name = $0; gsub(/.*NAME="|" .*/, "", name);

            if (kname != "" && mount != "") {
                printf "map[\"%s\"] = \"%s\";\n", kname, mount;
            } else if (kname != "" && (type == "lvm" || type == "crypt")) {
                printf "map[\"%s\"] = \"/dev/mapper/%s\";\n", kname, name;
            }
        }
    '
}

AWK_MAP_CODE=$(generate_awk_mapping)


# --- 2. Capture Colored iostat Output to a Temporary File via PTY ---

TEMP_FILE=$(mktemp)
# $TEMP_FILE

# Use 'script -qc' (quiet/command) to execute iostat within a PTY
# We use the full command path for iostat and specify a shell
# Note: Since iostat runs multiple times, we only capture the output of the final run
script -q -c "iostat -k -N $IOSTAT_INTERVAL $IOSTAT_COUNT" $TEMP_FILE

# The output from 'script' may include carriage returns and null characters.
# We process the raw file using tr and sed before piping to awk.
# tr -d '\r\0' removes carriage returns and nulls
# sed 's/\x1b\[[0-9;]*m//g' # Optional: Can be used to strip colors for debugging line length

# --- 3. Run awk on the Cleaned, Colored Stream ---

tr -d '\r\0' < "$TEMP_FILE" | awk '

BEGIN {
    # Execute the map generation code
    '"$AWK_MAP_CODE"'
    
    # Initialize calculated width variable
    WIDTH_LIMIT = 0;
}

# --- Function to strip ANSI codes for length counting ---
function strip_ansi(str) {
    # Remove all ANSI escape sequences
    gsub(/\x1b\[[0-9;]*m/, "", str);
    return str;
}


{
    LINE = $0;
    
    # 3a. HEADER PROCESSING: Determine the dynamic width
    if (LINE ~ /^Device:/ || LINE ~ /Device\s+tps/) { 
        # Check for the header line pattern.
        
        # 1. Clean the header line for length calculation
        stripped_header = strip_ansi(LINE);

        # 2. Find the index of the second word
        idx = index(stripped_header, $2);
        
        # This is the width we use for all mount points
        WIDTH_LIMIT = idx - 1; 

        # 3. Replace the text "Device" with "Mount"
        
        # We need to preserve color codes around "Device" if they exist.
        # Find exactly where "Device" starts and ends in the raw string.
        # This uses simple string replacement, assuming 'Device' appears only once.
        # We replace the text, but the AWK 'print' function maintains existing color codes.
        
        # Calculate padding needed: WIDTH_LIMIT - length("Mount")
        padding_needed = WIDTH_LIMIT - 5; # 5 is the length of "Mount"

        replacement_text = "Mount"
        for (i=1; i<=padding_needed; i++) {
            replacement_text = replacement_text " " 
        }

        # Substitute the "Device" word block with the padded "Mount"
        sub(/^Device: */, replacement_text, LINE);
        sub(/^Device */, replacement_text, LINE);


    # 3b. DEVICE LINE PROCESSING
    } else if (map[strip_ansi($1)] != "") { 
        # Use strip_ansi($1) as the key might have color codes attached
        device_name_clean = strip_ansi($1);
        mount_point = map[device_name_clean];
        
        # Global width must have been set by the header line, check for safety
        if (WIDTH_LIMIT == 0) {
            # Fallback if header line was missed, use a safe default width
            WIDTH_LIMIT = 18; 
        }
        
        # Truncate mount point if it exceeds the determined column width
        if (length(mount_point) > WIDTH_LIMIT) {
            # Truncate and add a tilde (~) for visual truncation indicator
            mount_point = substr(mount_point, 1, WIDTH_LIMIT - 1) "~";
        }
        
        # Print the new mount point, left-aligned to the determined width
        printf "%-*s", WIDTH_LIMIT, mount_point;
        
        # Print the rest of the fields starting from the second one
        # $2 already contains the first metric (tps)
        for (i = 2; i <= NF; i++) {
            # We use $i directly, preserving any existing color codes on the numbers
            printf " %s", $i; 
        }
        printf "\n";
        
        # Skip printing the original line
        next;
    }
    
    # Print all other lines (processed header, Avg-CPU, blank lines, unmapped devices)
    print LINE;
}
'

# --- 4. Cleanup ---
rm -f "$TEMP_FILE"
