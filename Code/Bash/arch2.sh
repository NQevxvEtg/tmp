#!/bin/bash
# PART 2: INSIDE CHROOT
# Run this AFTER 'arch-chroot /mnt'

# --- CONFIG VARIABLES (YOU MUST EDIT THESE) ---
# Run 'blkid /dev/nvme0n1p3' to find this (The Physical Partition)
LUKS_UUID="REPLACE_WITH_YOUR_PHYSICAL_NVME_UUID" 

# Run 'blkid /dev/mapper/cryptroot' to find this (The Btrfs Filesystem)
ROOT_UUID="REPLACE_WITH_YOUR_BTRFS_UUID"
# ----------------------------------------------

# --- 1. BASICS ---
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "archlinux" > /etc/hostname
# echo "root:password" | chpasswd  # Uncomment to set root password automatically

# --- 2. SINGLE SIGN-ON (KEYFILE) ---
echo "Generating Keyfile..."
dd if=/dev/urandom of=/crypto_keyfile.bin bs=1024 count=4
chmod 000 /crypto_keyfile.bin
chmod 600 /crypto_keyfile.bin
# Add key to LUKS (Will ask for your password)
echo "Adding key to LUKS (Enter your password)..."
cryptsetup luksAddKey /dev/nvme0n1p3 /crypto_keyfile.bin

# --- 3. MKINITCPIO (PURE SYSTEMD) ---
echo "Configuring Initramfs..."
# We overwrite the file to ensure exact hooks
cat <<EOF > /etc/mkinitcpio.conf
# MODULES: Explicitly load NVMe and AMD Graphics to prevent hanging
MODULES=(btrfs nvme amdgpu)
BINARIES=()
# FILES: Include the keyfile so Systemd can find it
FILES=(/crypto_keyfile.bin)
# HOOKS: Pure Systemd layout (sd-vconsole, sd-encrypt)
HOOKS=(base systemd autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck)
EOF

mkinitcpio -P

# --- 4. BOOTLOADER (GRUB) ---
echo "Installing GRUB..."
pacman -S --noconfirm grub efibootmgr os-prober

# Enable Cryptodisk
sed -i 's/#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/g' /etc/default/grub

# Configure Kernel Parameters (The complicated part)
# rd.luks.name -> Maps physical UUID to 'cryptroot'
# rd.luks.key  -> Tells Systemd to unlock that UUID with the file
# root         -> Tells Kernel to mount the Btrfs UUID
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"rd.luks.name=${LUKS_UUID}=cryptroot rd.luks.key=${LUKS_UUID}=/crypto_keyfile.bin root=UUID=${ROOT_UUID} rootflags=subvol=@\"|g" /etc/default/grub

# Install to EFI partition
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

# Generate Config
grub-mkconfig -o /boot/grub/grub.cfg

# --- 5. SWAPFILE (NoCOW) ---
echo "Creating Swap..."
truncate -s 0 /swapfile
chattr +C /swapfile
dd if=/dev/zero of=/swapfile bs=1G count=8 status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab

# --- 6. GNOME DESKTOP ---
echo "Installing GNOME..."
pacman -S --noconfirm xf86-video-amdgpu vulkan-radeon gnome gnome-extra gdm pipewire pipewire-pulse wireplumber bluez bluez-utils

systemctl enable gdm
systemctl enable NetworkManager
systemctl enable bluetooth

echo "Done! Type 'exit', 'umount -R /mnt', and 'reboot'."
