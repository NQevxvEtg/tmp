#!/bin/bash

STIG_HOME="/var/ansible_tmp/STIGFIX"

# --- Start of added lines for XCCDF report configuration ---

# Define environment variables for the Ansible STIG report
# STIG_PATH points to the official STIG XML definition file used by the callback plugin
export STIG_PATH="$STIG_HOME/roles/ol9STIG/files/U_Oracle_Linux_9_STIG_V1R1_Manual-xccdf.xml"

# XML_PATH specifies the output path and filename for the generated XCCDF report.
# Using a timestamp ensures a unique filename for each run.
REPORT_DIR="$STIG_HOME/reports/ol9_stig_reports"
REPORT_FILENAME="ol9_stig_report_$(date +%Y%m%d_%H%M%S).xml"
export XML_PATH="${REPORT_DIR}/${REPORT_FILENAME}"

# Ensure the output directory exists (Ansible won't create it for the report output)
mkdir -p "${REPORT_DIR}"

# --- End of added lines ---

#ansible-playbook -v -b -i localhost, site.yml "$@"
ansible-playbook -v -b -i /dev/null $STIG_HOME/site.yml --ask-vault-pass "$@"






