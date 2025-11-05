#!/bin/bash

# Function to check if firewalld is running
function check_firewalld_status {
    if ! systemctl is-active firewalld >/dev/null 2>&1; then
        echo "Error: firewalld is not running. Please start firewalld before running this function."
        return 1
    fi
    return 0
}

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

    if ! check_firewalld_status; then
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

    return 0 # Do not reload here, reload once at the end
}

# Function to add firewalld services to a zone for predefined networks
# Arguments:
#   $1 - Name of the firewalld zone to apply rules to (e.g., "public")
#   $2 - Comma-separated string of service names (e.g., "http,https,ssh")
#   $3 - Comma-separated string of allowed network sources (e.g., "192.168.1.0/24")
function create_service_rich_rules {
    local ZONE_NAME="$1"
    local SERVICES_STR="$2"
    local NETWORK_SOURCES_STR="$3"

    if ! check_firewalld_status; then
        return 1
    fi

    echo "--- Generating firewalld rich rules for services in zone: ${ZONE_NAME} ---"
    echo "  Services: ${SERVICES_STR}"
    echo "  Network Sources: ${NETWORK_SOURCES_STR}"

    # Split network sources string into an array
    IFS=',' read -r -a NETWORK_SOURCES_ARRAY <<< "$NETWORK_SOURCES_STR"

    if [ -n "$SERVICES_STR" ]; then
        IFS=',' read -r -a SERVICES_ARRAY <<< "$SERVICES_STR"
        echo "  Adding service rules..."
        for service in "${SERVICES_ARRAY[@]}"; do
            for network in "${NETWORK_SOURCES_ARRAY[@]}"; do
                local family="ipv4"
                if [[ "$network" == *:* ]]; then # Basic check for IPv6
                    family="ipv6"
                fi
                echo "    Adding permanent rich rule: allow service '$service' from $network (family: $family)"
                # Note: 'service name' is used directly instead of 'port protocol'
                firewall-cmd --permanent --zone="$ZONE_NAME" --add-rich-rule="rule family='$family' source address='$network' service name='$service' accept"
                if [ $? -ne 0 ]; then
                    echo "      Warning: Failed to add rule for service '$service' from $network. Check the service name or network address format."
                fi
            done
        done
    fi

    return 0 # Do not reload here, reload once at the end
}

# Function to manage specific ICMP types with 'accept' rules from predefined networks
# This is useful when icmp-block-inversion is 'yes' or if you want explicit allows.
# Arguments:
#   $1 - Name of the firewalld zone to apply rules to (e.g., "public")
#   $2 - Comma-separated string of ICMP types to allow (e.g., "echo-request,timestamp-reply")
#   $3 - Comma-separated string of network sources to allow these ICMP types from (e.g., "192.168.1.0/24")
function create_icmp_allow_rich_rules {
    local ZONE_NAME="$1"
    local ICMP_TYPES_STR="$2"
    local NETWORK_SOURCES_STR="$3"

    if ! check_firewalld_status; then
        return 1
    fi

    echo "--- Generating firewalld rich rules to ALLOW specific ICMP types in zone: ${ZONE_NAME} ---"
    echo "  ICMP Types to Allow: ${ICMP_TYPES_STR}"
    echo "  Network Sources to Allow from: ${NETWORK_SOURCES_STR}"

    # Split network sources string into an array
    IFS=',' read -r -a NETWORK_SOURCES_ARRAY <<< "$NETWORK_SOURCES_STR"

    if [ -n "$ICMP_TYPES_STR" ]; then
        IFS=',' read -r -a ICMP_TYPES_ARRAY <<< "$ICMP_TYPES_STR"
        echo "  Adding ICMP allow rules..."
        for icmp_type in "${ICMP_TYPES_ARRAY[@]}"; do
            for network in "${NETWORK_SOURCES_ARRAY[@]}"; do
                local family="ipv4"
                if [[ "$network" == *:* ]]; then # Basic check for IPv6
                    family="ipv6"
                fi
                echo "    Adding permanent rich rule: allow ICMP type '$icmp_type' from $network (family: $family)"
                # Use a regular 'accept' rich rule for ICMP types
                firewall-cmd --permanent --zone="$ZONE_NAME" --add-rich-rule="rule family='$family' source address='$network' protocol value='icmp' icmp-type name='$icmp_type' accept"
                if [ $? -ne 0 ]; then
                    echo "      Warning: Failed to add ICMP allow rule for type '$icmp_type' from $network. Check the ICMP type or network address format."
                fi
            done
        done
    fi

    return 0 # Do not reload here, reload once at the end
}


# --- Main Script Execution ---

TARGET_ZONE="public" # Or choose a custom zone if you created one

echo "--- Starting rich rule creation process ---"

# Check if icmp-block-inversion is enabled for the target zone
# This helps inform the user about their configuration.
INVERSION_STATUS=$(firewall-cmd --zone="$TARGET_ZONE" --query-icmp-block-inversion)
if [ "$INVERSION_STATUS" == "yes" ]; then
    echo "Note: icmp-block-inversion is ENABLED for zone '$TARGET_ZONE'."
    echo "ICMP 'accept' rules will explicitly allow traffic that would otherwise be rejected/dropped."
else
    echo "Note: icmp-block-inversion is DISABLED for zone '$TARGET_ZONE'."
    echo "You can use 'accept' rules for specific ICMP types, or 'icmp-block' rules to block them."
fi


# --- Example Usage for Ports (Original Function) ---
# Define your TCP and UDP ports
TCP_PORTS="80,443,22,8080"
UDP_PORTS="53,123,161"
# Define the networks you want to allow access from
ALLOWED_NETWORKS_PORTS="192.168.1.0/24,10.0.0.10,2001:db8::/32"

echo ""
echo "--- Applying Port Rules ---"
create_port_rich_rules "$TARGET_ZONE" "$TCP_PORTS" "$UDP_PORTS" "$ALLOWED_NETWORKS_PORTS"
PORT_RULES_STATUS=$?


# --- Example Usage for Services (New Function) ---
# Define firewalld service names
SERVICES="http,https,ssh" # Common services
# Define the networks you want to allow access to these services from
ALLOWED_NETWORKS_SERVICES="192.168.1.0/24,172.16.0.0/16"

echo ""
echo "--- Applying Service Rules ---"
create_service_rich_rules "$TARGET_ZONE" "$SERVICES" "$ALLOWED_NETWORKS_SERVICES"
SERVICE_RULES_STATUS=$?


# --- Example Usage for ICMP Allow (Revised Function) ---
# Define ICMP types to ALLOW.
# Use `firewall-cmd --get-icmptypes` to see available types.
# 'echo-request' is the type for incoming ping requests.
ICMP_TYPES_TO_ALLOW="echo-request,destination-unreachable"
# Define networks from which to allow these ICMP types.
# To allow from everywhere, use "0.0.0.0/0,::/0".
ALLOWED_NETWORKS_ICMP="192.168.1.0/24,1.2.3.4" # Allow ping from home network and a specific IP

echo ""
echo "--- Applying ICMP Allow Rules ---"
create_icmp_allow_rich_rules "$TARGET_ZONE" "$ICMP_TYPES_TO_ALLOW" "$ALLOWED_NETWORKS_ICMP"
ICMP_ALLOW_RULES_STATUS=$?


# --- Final Reload and Status Check ---
echo ""
echo "--- Finalizing rule application ---"
if [ "$PORT_RULES_STATUS" -eq 0 ] && \
   [ "$SERVICE_RULES_STATUS" -eq 0 ] && \
   [ "$ICMP_ALLOW_RULES_STATUS" -eq 0 ]; then

    echo "Reloading firewalld to apply all permanent changes..."
    firewall-cmd --reload
    if [ $? -ne 0 ]; then
        echo "Error: Failed to reload firewalld. Check firewalld logs for issues."
        exit 1
    else
        echo "Firewalld reloaded. All rules applied successfully."
        echo "You can verify with: firewall-cmd --zone=${TARGET_ZONE} --list-rich-rules"
        echo "And check ICMP block inversion status: firewall-cmd --zone=${TARGET_ZONE} --query-icmp-block-inversion"
    fi
else
    echo "One or more rule creation functions reported errors. Firewalld was not reloaded."
    echo "Please review the output above for errors and manually reload if necessary."
    exit 1
fi

echo "--- Process complete ---"