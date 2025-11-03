firwalld_drop() {
    # Ensure firewalld is installed and running
    if ! systemctl is-active firewalld >/dev/null 2>&1; then
        echo "firewalld is not running. Please install and start firewalld before running this fix."
        return 1
    fi

    # Detect currently listening TCP and UDP ports before making any changes
    echo "Detecting listening ports..."
    allowed_ports=$(ss -tuln | awk 'NR>1 {
        proto = tolower($1);
        if (match($5, /([^:]+):([0-9]+)$/, a)) {
            print a[2] "/" proto;
        }
    }' | sort -u)
    echo "Detected ports:"
    echo "$allowed_ports"

    # Define the custom zone name and file paths
    ZONE="drop"
    ZONEFILE="/etc/firewalld/zones/${ZONE}.xml"
    DROPFILE="/usr/lib/firewalld/zones/drop.xml"

    # Always start with a fresh custom zone file.
    if [ -f "$ZONEFILE" ]; then
        backup_file="${ZONEFILE}.bak_$(date +%Y%m%d%H%M%S)"
        echo "Existing $ZONEFILE found. Backing it up to $backup_file..."
        cp "$ZONEFILE" "$backup_file"
    fi

    # Verify drop.xml exists and copy it to create a new custom zone file.
    if [ ! -f "$DROPFILE" ]; then
        echo "drop.xml not found at $DROPFILE. Cannot proceed."
        return 1
    fi

    echo "Creating new custom zone file based on drop.xml..."
    cp "$DROPFILE" "$ZONEFILE"
    # Change the short name to our custom zone name
    sed -i "s/<short>Drop<\/short>/<short>${ZONE}<\/short>/" "$ZONEFILE"
    echo "Custom zone file updated at $ZONEFILE."

    # Reset the firewall to clear any existing runtime rules and start fresh.
    echo "Resetting firewall configuration..."
    firewall-cmd --complete-reload
    echo "Firewall configuration reset."

    # Define predefined networks (only these sources will be allowed access to detected ports).
    PREDEFINED_NETWORKS=("127.0.0.0/8" "::1/128" "10.0.0.0/16" "10.0.0.0/16" "10.0.0.0/16")

    # Add allowed ports as rich rules to the custom zone but only for connections from the predefined networks.
    if [ -n "$allowed_ports" ]; then
        echo "Adding rich rules for detected ports in zone $ZONE, restricted to predefined networks..."
        while IFS= read -r port_proto; do
            port=$(echo "$port_proto" | cut -d'/' -f1)
            proto=$(echo "$port_proto" | cut -d'/' -f2)
            for network in "${PREDEFINED_NETWORKS[@]}"; do
                if [[ "$network" == *:* ]]; then
                    family="ipv6"
                else
                    family="ipv4"
                fi
                echo "  Adding rich rule for port: $port, protocol: $proto for network: $network (family: $family)"
                firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="rule family='$family' source address='$network' port protocol='$proto' port='$port' accept"
            done
        done <<< "$allowed_ports"
    else
        echo "No listening ports detected; skipping port rich rules."
    fi

    # Reassign non-loopback interfaces to the custom zone if not already set.
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')
    for iface in $interfaces; do
        current_zone=$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null)
        if [ "$current_zone" != "$ZONE" ]; then
            echo "Assigning interface $iface to zone $ZONE..."
            firewall-cmd --permanent --zone="$ZONE" --change-interface="$iface"
        else
            echo "Interface $iface is already in zone $ZONE."
        fi
    done

    # Set the custom zone as the default zone (drop by default unless matched by rich rules)
    firewall-cmd --set-default-zone="$ZONE"
    echo "Default zone set to $ZONE (drop by default unless matched by rich rules)."

    # Reload firewall configuration to apply all changes
    firewall-cmd --reload
    echo "Firewall configuration reloaded."
    echo "Custom drop-by-default, allow-by-exception firewall setup completed."
}

firwalld_drop()