#!/bin/bash
# PART 1: OUTSIDE CHROOT
# Run this from the live ISO terminal

# --- 1. PREP ---
timedatectl set-ntp true

# --- 2. PARTITIONING ---
echo "Opening Partition Manager..."
echo "Create a new partition for Arch. Do NOT touch the EFI (p1) or Windows (p2/p3)."
cfdisk /dev/nvme0n1
# Assume new partition is /dev/nvme0n1p3 (Adjust if needed!)
TARGET_PARTITION="/dev/nvme0n1p3"
EFI_PARTITION="/dev/nvme0n1p1"

# --- 3. ENCRYPTION ---
echo "Encrypting drive..."
# Use LUKS2. 
cryptsetup luksFormat /dev/nvme0n1p3
echo "Opening container..."
cryptsetup open /dev/nvme0n1p3 cryptroot

# --- 4. BTRFS FORMATTING ---
echo "Formatting Btrfs..."
mkfs.btrfs /dev/mapper/cryptroot

# --- 5. SUBVOLUMES ---
echo "Creating Subvolumes..."
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt

# --- 6. MOUNTING (The Safe Way) ---
echo "Mounting..."
# Mount Root
mount -o noatime,compress=zstd,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt

# Create dirs
mkdir -p /mnt/{home,var,.snapshots,boot/efi}

# Mount Subvolumes
mount -o noatime,compress=zstd,space_cache=v2,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,subvol=@var /dev/mapper/cryptroot /mnt/var
mount -o noatime,compress=zstd,space_cache=v2,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots

# Mount Windows EFI (CRITICAL: Mount to /boot/efi, NOT /boot)
mount "$EFI_PARTITION" /mnt/boot/efi

# --- 7. INSTALL BASE ---
echo "Installing packages..."
# Including 'amd-ucode' because you have AMD
pacstrap /mnt base linux linux-firmware base-devel btrfs-progs nano networkmanager git amd-ucode

# --- 8. FSTAB ---
genfstab -U /mnt >> /mnt/etc/fstab

echo "Part 1 Complete. Now copy 'arch_install_part2.sh' to /mnt and run: arch-chroot /mnt"
