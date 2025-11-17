# Replace with your actual server FQDN and realm
IPA_SERVER_FQDN="ipa.example.com"
IPA_REALM="EXAMPLE.COM"

# To run non-interactively using the admin password
# Note: Providing the password on the command line can be a security risk in history logs.
sudo ipa-client-install --server=$IPA_SERVER_FQDN \
    --realm=$IPA_REALM \
    --domain=$IPA_REALM \
    --principal=admin \
    --password \
    --mkhomedir \
    --no-ntp \
    --force-join \
    -U # -U flag prevents system restart/shutdown

# When prompted, enter the admin password