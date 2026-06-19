<!--
title: "Hibernation Setup Guide for Linux"
date: "2026-06-17"
description: "A comprehensive guide to configuring hibernation across Arch, Fedora, Ubuntu, and openSUSE with ext4 and Btrfs filesystems."
tags: ["linux", "hibernation", "tutorial", "system-administration"]
-->

# Hibernation Setup Guide for Linux

Hibernation (suspend-to-disk) saves the contents of RAM to a swap device or swapfile and powers off the machine. On resume, the kernel loads the saved state back into memory, restoring your session exactly as you left it. This guide covers hibernation setup across four major distributions — Arch Linux, Fedora, Ubuntu/Debian, and openSUSE — on both ext4 and Btrfs filesystems, with four common bootloaders: GRUB2, systemd-boot, Limine, and rEFInd.

> [!WARNING]
> **Hardware Compatibility:** Hibernation requires sufficient swap space — typically at least as much as your total RAM. Systems with large amounts of RAM (32GB+) may experience long resume times. Verify your hardware supports S4 (hibernation) sleep state with `cat /sys/power/state`; look for `disk` in the output.

## Prerequisites

- **Swap space** equal to or greater than your RAM size
- A supported **filesystem** (ext4 or Btrfs)
- **initramfs regeneration** permissions (root or sudo)
- Access to the **bootloader configuration**

## Swap: Partition vs. Swapfile

| Feature | Swap Partition | Swapfile |
|---------|---------------|----------|
| Resizing | Difficult (requires repartitioning) | Easy (`fallocate` + `swapon`) |
| Btrfs support | Fully supported | Requires `nocow` and `swapfile` subvolumes |
| Hibernate resume | Works out of the box | Requires kernel `resume=` parameter and initramfs hook |
| Performance | Slightly faster (direct block device access) | Negligible difference on modern hardware |

### Swapfile Sizing

| RAM Size | Recommended Swap Size |
|----------|----------------------|
| ≤ 4 GB | 2× RAM |
| 4–8 GB | 1.5× RAM |
| 8–16 GB | 1× RAM |
| 16–32 GB | 0.75× RAM |
| > 32 GB | 0.5× RAM (or match RAM) |

## Filesystem Preparation

### ext4

Create a swapfile anywhere on an ext4 partition:

```bash
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

Persist in `/etc/fstab`:

```text
/swapfile none swap defaults 0 0
```

### Btrfs

Btrfs has specific requirements for swapfiles. The swapfile must not be on a CoW (Copy-on-Write) subvolume and must not be compressed.

1. **Create a dedicated subvolume** for the swapfile:

```bash
sudo btrfs subvolume create /@swap
```

2. **Disable Copy-on-Write** and create the swapfile:

```bash
sudo chattr +C /@swap
sudo fallocate -l 8G /@swap/swapfile
sudo chmod 600 /@swap/swapfile
sudo mkswap /@swap/swapfile
sudo swapon /@swap/swapfile
```

3. **Persist in `/etc/fstab`**:

```text
/@swap/swapfile none swap defaults 0 0
```

> [!IMPORTANT]
> The swapfile **must** be on a subvolume with `nocow` (set via `chattr +C`). If you skip this, the kernel will refuse to use the swapfile and hibernation will fail silently.

> [!NOTE]
> Btrfs swapfiles cannot be used with zstd compression — the `chattr +C` flag on the subvolume disables compression automatically for files within it.

## Distribution-Specific Setup

### 1. Arch Linux (mkinitcpio)

#### Kernel Parameters

Add `resume=` and `resume_offset=` to your bootloader configuration.

Find the swap partition or file:

```bash
sudo findmnt -no UUID -T /swapfile       # partition UUID
sudo btrfs inspect-internal map-swapfile -r /@swap/swapfile  # offset (Btrfs only)
sudo filefrag -v /swapfile | awk '$1=="0:" {print $4}'       # offset (ext4)
```

#### mkinitcpio Configuration

Edit `/etc/mkinitcpio.conf`:

```text
HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems resume fsck)
```

The `resume` hook must appear **after** `filesystems` and before `fsck`.

Regenerate:

```bash
sudo mkinitcpio -P
```

### 2. Fedora (dracut)

#### dracut Configuration

Create `/etc/dracut.conf.d/resume.conf`:

```text
add_dracutmodules+=" resume "
```

> [!TIP]
> Fedora's default dracut configuration already includes the `resume` module via `systemd`, so the explicit module addition above may not be needed — verify with `lsinitrd | grep resume`.

#### Kernel Parameters

Ensure the following parameters are present in your bootloader configuration:

```text
resume=UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx resume_offset=xxxxx
```

Regenerate initramfs:

```bash
sudo dracut --force
```

### 3. Ubuntu / Debian (initramfs-tools)

#### initramfs-tools Configuration

Edit `/etc/initramfs-tools/conf.d/resume` (create if not exists):

```text
RESUME=UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

For swapfiles, add the `resume` and `resume_offset` kernel parameters instead (see bootloader section).

Update initramfs:

```bash
sudo update-initramfs -u -k all
```

#### Kernel Parameters

```text
resume=UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx resume_offset=xxxxx
```

### 4. openSUSE (dracut)

openSUSE uses dracut, similar to Fedora. Create `/etc/dracut.conf.d/resume.conf`:

```text
add_dracutmodules+=" resume "
```

Regenerate:

```bash
sudo mkinitrd   # or: sudo dracut --force
```

> [!NOTE]
> On openSUSE, `mkinitrd` is a wrapper around dracut. The two commands are interchangeable.

#### Kernel Parameters

```text
resume=UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx resume_offset=xxxxx
```

## Bootloader Configuration

### GRUB2

Edit `/etc/default/grub`:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash resume=UUID=xxxxxxxx resume_offset=xxxxx"
```

Regenerate:

```bash
# On Arch, Fedora, openSUSE:
sudo grub-mkconfig -o /boot/grub/grub.cfg

# On Ubuntu/Debian:
sudo update-grub
```

### systemd-boot

Edit the appropriate loader entry in `/boot/loader/entries/` (e.g., `arch.conf` or `fedora.conf`):

```text
title   Fedora Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=yyyyyyy quiet splash resume=UUID=xxxxxxxx resume_offset=xxxxx
```

### Limine

Edit `/boot/limine/limine.conf` (or equivalent, e.g., `/etc/default/limine` for Omarchy):

```text
KERNEL_CMDLINE[default]="root=UUID=yyyyyyy quiet splash resume=UUID=xxxxxxxx resume_offset=xxxxx"
```

> [!IMPORTANT]
> If you update your Limine configuration, no separate bootloader generation step is needed. Limine reads its configuration file directly at boot time.

### rEFInd

rEFInd auto-detects kernels and passes kernel parameters from the `refind_linux.conf` file in the same directory as the kernel image (typically `/boot/refind_linux.conf`):

```text
"Boot with defaults"  "root=UUID=yyyyy quiet splash resume=UUID=xxxxxxxx resume_offset=xxxxx"
"Boot to single-user mode"  "root=UUID=yyyyy single resume=UUID=xxxxxxxx resume_offset=xxxxx"
"Boot with minimal options"  "root=UUID=yyyyy ro quiet"
```

> [!TIP]
> rEFInd also supports manual entries in `/boot/efi/EFI/refind/refind.conf` if you prefer centralized configuration.

## Resume Offset: Btrfs Only

When using a swapfile on Btrfs, the kernel needs the physical offset of the swapfile on the device. Obtain it with:

```bash
sudo btrfs inspect-internal map-swapfile -r /@swap/swapfile
```

Example output:

```text
physical_offset 2013265920
```

This value becomes the `resume_offset=` kernel parameter.

> [!WARNING]
> If you delete and recreate the swapfile (for example, after resizing it), the offset **will change**. You must update `resume_offset=` everywhere it appears and regenerate the initramfs and bootloader configuration.

## Resume Offset: ext4

For ext4 swapfiles, obtain the offset using `filefrag`:

```bash
sudo filefrag -v /swapfile | awk '$1=="0:" {print $4}'
```

The output is the offset in filesystem blocks (typically 4096 bytes). Use this value for `resume_offset=`.

## Quick-Reference Tables

### Initramfs Generation

| Distribution | Tool | Config File | Command |
|-------------|------|-------------|---------|
| Arch Linux | mkinitcpio | `/etc/mkinitcpio.conf` | `sudo mkinitcpio -P` |
| Fedora | dracut | `/etc/dracut.conf.d/resume.conf` | `sudo dracut --force` |
| Ubuntu/Debian | initramfs-tools | `/etc/initramfs-tools/conf.d/resume` | `sudo update-initramfs -u -k all` |
| openSUSE | dracut | `/etc/dracut.conf.d/resume.conf` | `sudo mkinitrd` |

### Bootloader Update Commands

| Bootloader | Config File | Update Command |
|------------|-------------|----------------|
| GRUB2 | `/etc/default/grub` | `sudo grub-mkconfig -o /boot/grub/grub.cfg` or `update-grub` |
| systemd-boot | `/boot/loader/entries/*.conf` | No regeneration step (reads config directly) |
| Limine | `/boot/limine/limine.conf` | No regeneration step (reads config directly) |
| rEFInd | `/boot/refind_linux.conf` | No regeneration step (reads config directly) |

### Kernel Parameter Reference

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `resume=` | Swap device UUID for resume | `resume=UUID=a1b2c3d4-...` |
| `resume_offset=` | Physical offset of swapfile on disk | `resume_offset=2013265920` |
| `noresume` | Skip resume attempt (use as fallback) | `noresume` |

## Testing Hibernation

Before relying on hibernation daily, test it with a controlled cycle:

### Test Procedure

1. Save all work and close critical applications.
2. Trigger hibernation:

```bash
sudo systemctl hibernate
```

The system should power off completely.

3. Power on the machine. The bootloader should load normally, but instead of a clean boot, the kernel will detect a hibernation image and resume.

4. Verify the session is restored exactly as left — open applications, cursor position, and unsaved documents should all be present.

> [!TIP]
> To test without shutting down, run `sudo pm-hibernate` (if `pm-utils` is installed) or `sudo systemctl hibernate`. The latter is the modern, distribution-agnostic approach.

## Troubleshooting

### Hibernation Fails Silently

If the system powers off but boots normally (no resume):

- Verify `resume=` and `resume_offset=` are correct in the bootloader config.
- Confirm the initramfs contains the resume hook/module:
  - **mkinitcpio:** `lsinitcpio /boot/initramfs-linux.img | grep resume`
  - **dracut:** `lsinitrd | grep resume`
  - **initramfs-tools:** `lsinitramfs /boot/initrd.img-$(uname -r) | grep resume`
- Check that swap is enabled: `swapon --show`

### Resume Offset is Wrong

If `hibernate` works (system powers off) but resume fails (clean boot instead of restoring):

- Recalculate the offset: `sudo btrfs inspect-internal map-swapfile -r /@swap/swapfile`
- Update all kernel parameter locations and regenerate initramfs + bootloader config.

### "Not enough free swap" Error

```text
PM: Not enough free swap
```

This means the swap space is smaller than the amount of RAM in use. Solutions:

- Increase swap size (recommended: at least equal to RAM).
- Close memory-heavy applications before hibernating.
- Check `zram` or `zswap` usage — these compressed swap devices **cannot** be used for hibernation. Disable them or ensure a regular swap device/file is available.

### Btrfs: "Swapfile is not supported on Btrfs"

If the kernel rejects the swapfile:

- Ensure the subvolume has `nocow`: `sudo chattr +C /path/to/subvolume`
- Ensure the swapfile was created **after** setting `nocow` on the subvolume.
- Verify the subvolume is not the root subvolume (create a dedicated subvolume like `@swap`).

### Resume from Hibernate Takes Too Long

- Large RAM systems (32GB+) may take 30–60 seconds to read the entire memory image from disk.
- Using an SSD instead of an HDD significantly improves resume speed.
- Encrypted swap will add decryption overhead — this is expected.

## Secure Boot Considerations

If Secure Boot is enabled, the kernel and initramfs must be signed, and the `resume=` kernel parameter must be properly configured before signing. On systems using **systemd-boot** or **GRUB** with `shim` + `sbctl`, regenerating the bootloader configuration and initramfs may require re-signing files.

For **Limine** with Secure Boot and custom keys, re-run the signing process after any initramfs regeneration:

```bash
sudo sbctl sign /boot/EFI/LIMINE/LIMINE.EFI
sudo sbctl sign /boot/vmlinuz-linux
```

> [!NOTE]
> See the [Secure Boot section of the Omarchy dual-boot guide](./dualboot-win11-omarchy.md#secure-boot-implementation-optional) for detailed instructions on key enrollment with `sbctl`.

## References

- [Power management/Suspend and hibernate - Arch Wiki](https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate)
- [Hibernation - Fedora Wiki](https://fedoraproject.org/wiki/Hibernation)
- [SwapFaq - Ubuntu Community Wiki](https://help.ubuntu.com/community/SwapFaq)
- [Btrfs Wiki - Swapfile](https://btrfs.wiki.kernel.org/index.php/Manually_making_a_swapfile)
- [systemd-sleep - freedesktop.org](https://www.freedesktop.org/software/systemd/man/systemd-sleep.html)
- [dracut wiki - Kernel command line](https://dracut.wiki.kernel.org/index.php/Dracut.kernel)
- [mkinitcpio - Arch Wiki](https://wiki.archlinux.org/title/Mkinitcpio)
