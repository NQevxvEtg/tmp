#!/bin/bash

# This script now expects the path to the vault password file as the first argument.
VAULT_PASS_FILE=$1

# Check if the password file argument was provided.
if [ -z "$VAULT_PASS_FILE" ]; then
    echo "Error: Path to vault password file not provided as the first argument." >&2
    exit 1
fi

# Check if the file exists and is readable.
if [ ! -r "$VAULT_PASS_FILE" ]; then
    echo "Error: Vault password file not found or is not readable at: $VAULT_PASS_FILE" >&2
    exit 1
fi


# Shift the arguments so that "$@" can be passed cleanly to ansible-playbook later.
shift

STIG_HOME="/var/ansible_tmp/STIGFIX"

# --- Report configuration ---
export STIG_PATH="$STIG_HOME/roles/ol8STIG/files/U_Oracle_Linux_8_STIG_V2R5_Manual-xccdf.xml"
REPORT_DIR="$STIG_HOME/reports/ol8_stig_reports"
REPORT_FILENAME="ol8_stig_report_$(date +%Y%m%d_%H%M%S).xml"
export XML_PATH="${REPORT_DIR}/${REPORT_FILENAME}"
mkdir -p "${REPORT_DIR}"
# --- End of report configuration ---

# Use the vault password file instead of prompting.
ansible-playbook -v -b -i /dev/null $STIG_HOME/site.yml --vault-password-file "$VAULT_PASS_FILE" "$@"
