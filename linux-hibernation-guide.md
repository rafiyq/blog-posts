<!--
title: "Hibernation Setup Guide for Linux"
date: "2026-06-17"
description: "A distribution-agnostic guide to setting up hibernation across ext4 and Btrfs filesystems, covering Arch, Fedora, Ubuntu, and openSUSE."
tags: ["linux", "hibernation", "tutorial", "guide"]
-->
# Hibernation Setup Guide for Linux
Hibernation (suspend-to-disk) saves the contents of RAM to your swap device and powers off the machine. On the next boot, the kernel reads the saved image back, restoring your exact session. This guide covers the full setup across **ext4** and **Btrfs** filesystems on **Arch Linux**, **Fedora**, **Ubuntu/Debian**, and **openSUSE**.
At a high level, hibernation requires:
- Kernel support for the `disk` sleep state
- A swap area large enough to hold a compressed memory image (≥ RAM)
- An initramfs with a `resume` hook to restore the image early in boot
- Kernel parameters telling the initramfs where to find the image
## How Hibernation Works
When you run `systemctl hibernate`, the kernel:
1. Compresses and writes RAM to the configured swap area
2. Records the swap location and image size in `/sys/power/`
3. Powers off
On reboot, the bootloader passes `resume=DEVICE resume_offset=OFFSET` to the kernel. The initramfs's `resume` hook reads the image from that location and jumps back into it. If the image is missing or corrupted (e.g. swap was overwritten), the system boots fresh.
> [!NOTE]
> The `resume_offset` parameter is only needed for **swap files**. A dedicated swap partition does not need it, because the partition itself *is* the offset.
## Prerequisites
### Check Kernel Support
```bash
cat /sys/power/state       # must include "disk"
cat /sys/power/image_size  # max hibernation image size in bytes
If /sys/power/state does not list disk, hibernation is not supported by your kernel or hardware.
Determine Your Root Filesystem
findmnt -no FSTYPE -T /
This tells you whether you're on ext4, Btrfs, or another filesystem — critical for choosing the right swap setup.
Check Available RAM
free -h
Your swap must be at least as large as total RAM (the default image size is 2/5 of RAM, but you can increase it — see Troubleshooting).
Swap Setup by Filesystem
ext4
With ext4 you have two options. A swap partition is simpler and doesn't need resume_offset. A swap file is more flexible (no repartitioning needed) but requires the offset.
Option A: Swap Partition
# Identify the partition (e.g. /dev/sda3)
sudo mkswap /dev/sda3
sudo swapon /dev/sda3
# Persist in fstab
echo "/dev/sda3 none swap defaults 0 0" | sudo tee -a /etc/fstab
No resume_offset is needed — the kernel parameter will be resume=/dev/sda3.
Option B: Swap File
# Create a contiguous swap file sized to your total RAM
sudo fallocate -l "$(free -k | awk '/Mem:/ {print $2}')k" /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
# Persist in fstab
echo "/swapfile none swap defaults 0 0" | sudo tee -a /etc/fstab
# Get the resume_offset for kernel parameters later
sudo filefrag -v /swapfile | awk '/^[ ]+0:/ {print $4}' | sed 's/\.//'
> !IMPORTANT
> The swap file must be contiguous. fallocate guarantees this on ext4. If fallocate is not available, use dd if=/dev/zero of=/swapfile bs=1M count=$RAM_MB — but always verify with filefrag -v /swapfile.
# Verify contiguity — look for "expected physical" column to be sequential
sudo filefrag -v /swapfile
Btrfs
Btrfs swap files require a dedicated subvolume with nouveau COW (copy-on-write disabled) and kernel 5.0+. Modern btrfs-progs provide btrfs filesystem mkswapfile which handles sizing automatically.
# Create a COW-disabled subvolume for swap
sudo btrfs subvolume create /swap
sudo chattr +C /swap
# Create a swap file sized to total RAM
sudo btrfs filesystem mkswapfile -s "$(free -k | awk '/Mem:/ {print $2}')k" /swap/swapfile
# Persist and enable
echo "/swap/swapfile none swap defaults 0 0" | sudo tee -a /etc/fstab
sudo swapon /swap/swapfile
# Get the resume device (strip any subvol from the mount source)
RESUME_DEVICE=$(findmnt -no SOURCE -T /swap/swapfile | sed 's/\[.*\]//')
# Get the resume offset
RESUME_OFFSET=$(sudo btrfs inspect-internal map-swapfile -r /swap/swapfile)
echo "resume=$RESUME_DEVICE resume_offset=$RESUME_OFFSET"
> !WARNING
> Never place the swap file inside a snapshotted subvolume (e.g. @). Snapshots would duplicate swap data and corrupt the hibernation image. The separate /swap subvolume avoids this.
Initramfs Configuration
The initramfs must include a resume hook. How you add it depends on your distribution's initramfs generator.
Distribution	Generator
Arch Linux	mkinitcpio
Fedora	dracut
Ubuntu / Debian	initramfs-tools
openSUSE	dracut
Arch Linux
Add the resume hook to your mkinitcpio configuration. It must appear before filesystems:
echo "HOOKS+=(resume)" | sudo tee /etc/mkinitcpio.conf.d/resume.conf
sudo mkinitcpio -P
> !TIP
> If you already have a custom /etc/mkinitcpio.conf, edit the HOOKS array directly instead of using the drop-in.
Fedora
dracut ships the resume module by default. No additional initramfs configuration is needed — kernel parameters are sufficient. Rebuild anyway to confirm:
sudo dracut --force --regenerate-all
Ubuntu / Debian
Tell initramfs-tools which swap device to use for resume:
RESUME_UUID=$(findmnt -no UUID -T /swapfile 2>/dev/null || findmnt -no UUID /dev/sda3)
echo "RESUME=UUID=$RESUME_UUID" | sudo tee /etc/initramfs-tools/conf.d/resume
sudo update-initramfs -u -k all
> !IMPORTANT
> If using a swap file, the RESUME= line should contain the UUID of the block device hosting the swap file (not the swap file itself). The filesystem-specific offset is passed via the kernel cmdline instead.
openSUSE
openSUSE uses dracut, which includes the resume module automatically. Regenerate the initrd:
sudo mkinitrd
Bootloader Configuration
The kernel command line must include resume=DEVICE (and resume_offset=OFFSET for swap files).
Bootloader
GRUB2
systemd-boot
Limine
rEFInd
GRUB2 (All Distros)
Add the parameters to GRUB_CMDLINE_LINUX in /etc/default/grub:
# Edit /etc/default/grub and modify or add:
GRUB_CMDLINE_LINUX="resume=UUID=xxxxxxxx resume_offset=12345"
Then regenerate:
# Arch / openSUSE
sudo grub-mkconfig -o /boot/grub/grub.cfg
# Fedora / RHEL
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
# Ubuntu / Debian
sudo update-grub
systemd-boot
Edit the corresponding entry in /boot/loader/entries/ and append the resume and resume_offset parameters to the options line:
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=... resume=UUID=... resume_offset=12345 rw
Limine
Create a kernel-cmdline drop-in and rebuild:
echo 'KERNEL_CMDLINE[default]+=" resume=UUID=xxxxxxxx resume_offset=12345"' | sudo tee /etc/limine-entry-tool.d/resume.conf
sudo limine-mkinitcpio
rEFInd
Edit /boot/refind_linux.conf and add the parameters to your default boot stanza:
"Boot with standard options" "root=UUID=... resume=UUID=... resume_offset=12345 ro"
Verification
One-Time Test
Save all work, then hibernate:
sudo systemctl hibernate
The system should power off. On boot, it should restore your session rather than starting fresh.
Check Logs After Resume
# Check the previous boot's journal for hibernation messages
journalctl -b -1 | grep -i "resume\|hibernate\|PM:"
# Or the current boot (after resume)
journalctl -b -0 | grep -i "resume\|hibernate"
Successful resume lines look like:
PM: hibernation: resume from hibernation
PM: hibernation: Reading hibernation image ...
PM: hibernation: Image successfully loaded
> !WARNING
> On first test, save all open documents and be prepared to force-power-cycle (hold the power button) if the system hangs. A failed resume will boot cleanly — the old hibernation image is discarded and no data is lost.
Troubleshooting
System boots fresh instead of resuming
Common causes, in order of likelihood:
Cause
Wrong resume_offset
Wrong resume= device
Initramfs missing resume hook
Swap smaller than image
Hibernation image too large
The default image size is 2/5 of RAM. If your swap is smaller than RAM, raise the limit:
# Set to full RAM size (persist across boots)
echo "GRUB_CMDLINE_LINUX=\"resume_offset=... resume=... \"" | sudo tee -a /etc/default/grub
# ... plus add to your init script or udev rule
A simpler one-shot test:
echo "$(free -b | awk '/Mem:/ {print $2}')" | sudo tee /sys/power/image_size
sudo systemctl hibernate
Resume hangs at black screen
- NVIDIA GPUs: Add nvidia_resume= and nvidia_modeset=1 to the kernel cmdline. The exact nvidia_resume= value comes from nvidia-smi or the nvidia driver documentation.
- LUKS: Ensure systemd initramfs hooks are used so the decrypted device is available early enough for resume.
- s2idle systems: If /sys/power/mem_sleep only shows s2idle, the system may need rtc_cmos.use_acpi_alarm=1 for reliable wake-from-hibernate.
Secure Boot
If Secure Boot is enabled and resume fails, the initramfs may not be signed:
# Install sbctl if not present
# Sign all initramfs images
sudo sbctl sign /boot/initramfs-*.img
References
- ArchWiki: Power management/Suspend and hibernate (https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate)
- Fedora Wiki: Hibernate (https://fedoraproject.org/wiki/Changes/Hibernation)
- Ubuntu Help: PowerManagement/Hibernate (https://help.ubuntu.com/community/PowerManagement/Hibernate)
- openSUSE Wiki: SDB: Suspend to disk (https://en.opensuse.org/SDB:Suspend_to_disk)
- Kernel documentation: Power Management (https://www.kernel.org/doc/html/latest/admin-guide/pm/sleep-states.html)
