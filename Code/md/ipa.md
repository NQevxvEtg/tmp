### 1. Install the Trust Software
Even though FreeIPA is installed, the AD trust packages are often not included by default to save resources.

*   **RHEL/AlmaLinux/Rocky:**
    ```bash
    sudo dnf install ipa-server-trust-ad
    ```
*   **Fedora:**
    ```bash
    sudo dnf install freeipa-server-trust-ad
    ```
*   **Ubuntu/Debian:**
    ```bash
    sudo apt-get install freeipa-server-trust-ad
    ```

### 2. Run the Trust Configuration Script
This is the critical step for existing installations. This script configures Samba, generates SIDs for your existing users, and prepares the server to act like an AD Domain Controller.

Run this command:
```bash
sudo ipa-adtrust-install --netbios-name=IPA
```
*(Replace `IPA` with a short name for your domain, e.g., if your domain is `corp.example.com`, maybe use `CORP` or `IPA`—it must be different from your AD NetBIOS name).*

**What will happen:**
*   It will ask for the `admin` password.
*   It will ask if you want to enable the feature. Address any warnings it presents.
*   **Crucially**, it will restart your FreeIPA services.

### 3. Open Firewall Ports
The trust mechanism uses Windows-specific protocols (SMB, RPC, etc.) that are not open by default on a standard FreeIPA install. You must open these on the FreeIPA server [access.redhat.com](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/linux_domain_identity_authentication_and_policy_guide/install-server-trust), [freeipa.org](https://www.freeipa.org/page/Active_Directory_trust_setup).

```bash
# For firewalld (RHEL/CentOS/Fedora)
sudo firewall-cmd --add-service=freeipa-trust --permanent
sudo firewall-cmd --reload
```
If you are manually managing `iptables` or a cloud firewall (AWS Security Groups, Azure NSG), ensure these specific ports are open in addition to the standard web/LDAP ports:
*   **TCP:** 135, 139, 445
*   **UDP:** 138
*   **TCP Range:** 49152-65535 (required for RPC communications)

### 4. Add the DNS Forwarder
Your FreeIPA server needs to know exactly where to find the AD Domain Controller.

1.  Log into FreeIPA Web UI or CLI.
2.  Setup a DNS zone forwarder for the AD domain.
    ```bash
    ipa dnsforwardzone-add ad.example.com --forwarder=192.168.1.50 --forward-policy=only
    ```
    *(Replace `ad.example.com` with the AD domain and `192.168.1.50` with the AD DC IP).*

### 5. Establish the Trust
Now that the software is installed and ports are open, you issue the command to link them.

1.  **Obtain a Kerberos ticket:**
    ```bash
    kinit admin
    ```
2.  **Add the trust:**
    ```bash
    ipa trust-add --type=ad "ad.example.com" --admin "Administrator" --password
    ```
    *(Note: If your AD DNS does not yet point to FreeIPA, you might get a verification error. You can sometimes bypass simple verification warnings, but it's safer to fix DNS first).*

### Common troubleshooting for this phase
*   **"RPC server unavailable":** This almost always means the firewall ports (Create specific rules for 135/445 and the high RPC ports) are blocked between FreeIPA and AD.
*   **"Clock skew too great":** Ensure `chronyd` or `ntp` is syncing both servers to the same time source.
*   **DNS failure:** If `ipa trust-add` fails saying it can't find the domain controller, verify you can `ping` the AD domain name from the FreeIPA box.