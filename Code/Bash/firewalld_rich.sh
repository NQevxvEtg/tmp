#!/bin/bash

# Function to convert port arrays to firewalld rich rules for predefined networks
# Arguments:
#   $1 - Name of the firewalld zone to apply rules to (e.g., "public", "trusted", or a custom zone)
#   $2 - Comma-separated string of TCP ports (e.g., "80,443,22")
#   $3 - Comma-separated string of UDP ports (e.g., "53,123")
#   $4 - Comma-separated string of allowed network sources (e.g., "192.168.1.0/24,10.0.0.0/16")
function create_port_rich_rules {
    local ZONE_NAME="$1"
    local TCP_PORTS_STR="$2"
    local UDP_PORTS_STR="$3"
    local NETWORK_SOURCES_STR="$4"

    # Ensure firewalld is running
    if ! systemctl is-active firewalld >/dev/null 2>&1; then
        echo "Error: firewalld is not running. Please start firewalld before running this function."
        return 1
    fi

    echo "--- Generating firewalld rich rules for zone: ${ZONE_NAME} ---"
    echo "  TCP Ports: ${TCP_PORTS_STR}"
    echo "  UDP Ports: ${UDP_PORTS_STR}"
    echo "  Network Sources: ${NETWORK_SOURCES_STR}"

    # Split network sources string into an array
    IFS=',' read -r -a NETWORK_SOURCES_ARRAY <<< "$NETWORK_SOURCES_STR"

    # Process TCP ports
    if [ -n "$TCP_PORTS_STR" ]; then
        IFS=',' read -r -a TCP_PORTS_ARRAY <<< "$TCP_PORTS_STR"
        echo "  Adding TCP port rules..."
        for port in "${TCP_PORTS_ARRAY[@]}"; do
            for network in "${NETWORK_SOURCES_ARRAY[@]}"; do
                local family="ipv4"
                if [[ "$network" == *:* ]]; then # Basic check for IPv6
                    family="ipv6"
                fi
                echo "    Adding permanent rich rule: allow TCP/$port from $network (family: $family)"
                firewall-cmd --permanent --zone="$ZONE_NAME" --add-rich-rule="rule family='$family' source address='$network' port protocol='tcp' port='$port' accept"
                if [ $? -ne 0 ]; then
                    echo "      Warning: Failed to add rule for TCP port $port from $network. Check the network address format."
                fi
            done
        done
    fi

    # Process UDP ports
    if [ -n "$UDP_PORTS_STR" ]; then
        IFS=',' read -r -a UDP_PORTS_ARRAY <<< "$UDP_PORTS_STR"
        echo "  Adding UDP port rules..."
        for port in "${UDP_PORTS_ARRAY[@]}"; do
            for network in "${NETWORK_SOURCES_ARRAY[@]}"; do
                local family="ipv4"
                if [[ "$network" == *:* ]]; then # Basic check for IPv6
                    family="ipv6"
                fi
                echo "    Adding permanent rich rule: allow UDP/$port from $network (family: $family)"
                firewall-cmd --permanent --zone="$ZONE_NAME" --add-rich-rule="rule family='$family' source address='$network' port protocol='udp' port='$port' accept"
                if [ $? -ne 0 ]; then
                    echo "      Warning: Failed to add rule for UDP port $port from $network. Check the network address format."
                fi
            done
        done
    fi

    # Reload firewalld to apply permanent changes
    echo "Reloading firewalld to apply new rules..."
    firewall-cmd --reload
    if [ $? -ne 0 ]; then
        echo "Error: Failed to reload firewalld. Check firewalld logs for issues."
        return 1
    else
        echo "Firewalld reloaded. Rules applied successfully."
    fi

    return 0
}

# --- Example Usage ---
# Define your TCP and UDP ports
TCP_PORTS="80,443,22,8080"
UDP_PORTS="53,123,161"

# Define the networks you want to allow access from
# These can be individual IPs or CIDR blocks
# Ensure to include both IPv4 and IPv6 if needed
ALLOWED_NETWORKS="192.168.1.0/24,10.0.0.10,2001:db8::/32"

# Define the firewalld zone where you want to add these rules
# Common zones: public, trusted, home, work, internal, external, dmz, drop, block.
# You can also create a custom zone, as shown in your example code.
TARGET_ZONE="public" # Or choose a custom zone if you created one like "drop"

echo "--- Starting rich rule creation process ---"

# Call the function
create_port_rich_rules "$TARGET_ZONE" "$TCP_PORTS" "$UDP_PORTS" "$ALLOWED_NETWORKS"

# Check the exit status of the function
if [ $? -eq 0 ]; then
    echo "Rich rules successfully added and firewalld reloaded."
    echo "You can verify with: firewall-cmd --zone=${TARGET_ZONE} --list-rich-rules"
else
    echo "Failed to add rich rules. Please review the output above for errors."
fi

echo "--- Process complete ---"