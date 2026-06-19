<!--
title: "Hibernation Setup Guide for Linux"
date: "2026-06-17"
description: "A comprehensive guide to configuring hibernation across Arch, Fedora, Ubuntu, and openSUSE with ext4 and Btrfs filesystems."
tags: ["linux", "hibernation", "tutorial", "system-administration"]
-->

# Hibernation Setup Guide for Linux

Hibernation — also called suspend-to-disk or ACPI S4 — saves the entire contents of RAM to a swap device and powers the machine off. On the next power-on, the kernel detects the saved image in swap, restores it to memory, and resumes execution exactly where it left off. This is distinct from suspend-to-RAM (ACPI S3, `systemctl suspend`), which keeps RAM powered and drains the battery over hours or days. Hibernation uses zero power in the off state, making it the appropriate choice for laptops that may sit unused for weeks and for desktop systems where preserving an exact session state across a power outage matters.

This guide covers hibernation setup across four major distributions — Arch Linux, Fedora, Ubuntu/Debian, and openSUSE — on both ext4 and Btrfs filesystems, with four common bootloaders: GRUB2, systemd-boot, Limine, and rEFInd. It explains not only the commands but the kernel mechanisms and filesystem internals that make hibernation work.

> [!WARNING]
> **Hardware Compatibility:** Hibernation requires sufficient swap space — typically at least as much as your total RAM. Systems with large amounts of RAM (32GB+) may experience long resume times. Verify your hardware supports the S4 (hibernation) sleep state with `cat /sys/power/state`; look for `disk` in the output. If only `freeze` and `mem` appear, your firmware or kernel does not advertise S4 support.

## How Hibernation Works (The Kernel Side)

Understanding the mechanism helps diagnose failures when they arise.

### The swsusp Subsystem

The Linux kernel implements hibernation through the **swsusp** (Software Suspend) subsystem. When `systemctl hibernate` is issued, `systemd-sleep` writes `disk` to `/sys/power/state`, which triggers the following sequence:

1. **Freeze processes:** The kernel freezes all userspace tasks and filesystems.
2. **Write image:** The kernel writes the contents of all RAM pages to swap, preceded by a header that includes a signature (`SWSUSP` or `S2DISK`) and metadata about the image.
3. **Power off:** ACPI S4 is invoked and the machine powers down.

On the next boot:

1. **Early boot:** The bootloader passes the `resume=` kernel parameter to the kernel command line.
2. **Initramfs resume hook:** Before mounting the root filesystem, the initramfs resume hook reads the swap device specified by `resume=`. It scans for the swsusp signature.
3. **Image found:** If the signature is present and the image is intact, the kernel reads the metadata to learn which physical memory pages were in use and where each chunk of the image is stored in swap.
4. **Restore:** The kernel allocates the original memory layout, copies data back from swap, and jumps to the saved processor state.
5. **Cleanup:** The swsusp signature is erased from swap so the next normal boot does not attempt resume.

This is why the **order of operations in the initramfs matters**: the resume hook must run *after* the block device containing swap is available but *before* the root filesystem is fully mounted (since we may need to resume *into* that root). If the resume hook runs too early (before decryption for LUKS swap) or too late (after root is mounted), resume cannot work.

### Why Swap Must Be at Least as Large as RAM

The kernel writes a compressed copy of RAM to swap. The compression ratio depends on memory content — idle pages compress well; pages filled with random data (encrypted buffers, video frames) do not. The conservative rule of matching swap to RAM size ensures there is enough space regardless of compressibility. If swap is too small, the kernel logs `PM: Not enough free swap` and aborts hibernation without powering off.

## Swap: Partition vs. Swapfile

| Feature | Swap Partition | Swapfile |
|---------|---------------|----------|
| Resizing | Difficult (requires repartitioning) | Easy (`fallocate` + `swapon`) |
| Btrfs support | Fully supported | Requires `nocow` and `swapfile` subvolumes |
| Hibernate resume | Works out of the box | Requires kernel `resume=` parameter and initramfs hook |
| Performance | Slightly faster (direct block device access) | Negligible difference on modern hardware |
| Physical offset | Always 0 (entire partition is swap) | Must be computed and passed as `resume_offset=` |

### Why Swapfiles Need a Resume Offset

A swap partition is an entire block device dedicated to swap. The kernel knows that physical sector 0 of that device is the start of swap. A swapfile is just a regular file on a filesystem. The kernel's swsusp code does not understand filesystem metadata — it writes directly to raw block device offsets. The `resume_offset=` parameter tells the kernel which sector on the block device corresponds to byte 0 of the swapfile, bridging the gap between the filesystem abstraction and the raw block access the resume code requires.

On ext4, this offset is computed from the file's extents. On Btrfs, it is computed from the filesystem's internal chunk mapping via `btrfs inspect-internal map-swapfile`. If the swapfile is deleted and recreated, the offset changes because the new file may occupy different physical extents.

### Swapfile Sizing

| RAM Size | Recommended Swap Size |
|----------|----------------------|
| ≤ 4 GB | 2× RAM |
| 4–8 GB | 1.5× RAM |
| 8–16 GB | 1× RAM |
| 16–32 GB | 0.75× RAM |
| > 32 GB | 0.5× RAM (or match RAM) |

These recommendations account for the sum of active memory (which must be saved) and anonymous pages that may already be paged out to swap. A system with 32 GB of RAM and 24 GB actively in use needs at least 24 GB of swap — the table's 0.75× factor builds in a safety margin for most workloads.

## Filesystem Preparation

### ext4

ext4 swapfiles have minimal restrictions: no holes (sparse files), no compression, and a contiguous extent is preferred but not strictly required. The kernel's swsusp code reads the file's extents from the raw block device during resume, so the filesystem must not be mounted when resume runs — this is guaranteed because the resume hook runs before root is mounted.

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

Btrfs presents unique challenges for swapfiles. The kernel's swap code performs direct block-level I/O, bypassing the filesystem layer entirely. This conflicts with Btrfs's Copy-on-Write (CoW) semantics in two ways:

1. **CoW would relocate swap data:** If Btrfs applied CoW to swap writes, physical blocks could move under the kernel's swsusp code, which reads from fixed offsets during resume.
2. **Compression invalidates offsets:** Btrfs compression (zstd, zlib, lzo) stores data in non-contiguous extents. The kernel's resume code expects the swapfile to be a linear sequence of blocks.

The solution is to place the swapfile on a dedicated subvolume with `nocow` enabled and compression disabled:

1. **Create a dedicated subvolume:**

```bash
sudo btrfs subvolume create /@swap
```

2. **Disable Copy-on-Write** (`chattr +C` must be set *before* the swapfile is created — setting it after only affects new files):

```bash
sudo chattr +C /@swap
sudo fallocate -l 8G /@swap/swapfile
sudo chmod 600 /@swap/swapfile
sudo mkswap /@swap/swapfile
sudo swapon /@swap/swapfile
```

3. **Persist in `/etc/fstab`:**

```text
/@swap/swapfile none swap defaults 0 0
```

> [!IMPORTANT]
> The swapfile **must** be on a subvolume with `nocow` (set via `chattr +C`). If you skip this, the kernel will refuse to use the swapfile with the error "swapfile is not supported on Btrfs" and hibernation will fail silently. The `chattr +C` flag also implicitly disables compression on the subvolume, since compression is implemented through CoW in Btrfs.

> [!NOTE]
> You cannot place the swapfile on the root subvolume (ID 5) or on a subvolume that is snapshotted, because snapshots would capture the swapfile header and CoW would be re-enabled. Creating a dedicated `@swap` subvolume avoids these interactions.

## LUKS Encryption and Hibernation

Encrypted swap adds a complication: the resume hook must be able to unlock the swap device before it can scan for the swsusp signature.

### Swap on a Separate LUKS Partition

When swap is on its own LUKS partition, the initramfs must contain the key or be able to prompt for it at boot. This is the simplest encrypted setup because the swap device is independent of the root filesystem:

```text
resume=UUID=<luks-partition-uuid>
```

The initramfs decrypts the swap partition, the resume hook scans it, and if no image is found, the root filesystem is mounted as normal.

### Swapfile Inside LUKS Root

When the swapfile lives on the root filesystem and root is LUKS-encrypted, the resume hook must:

1. Decrypt the root LUKS container.
2. Mount the root filesystem (or at least make the block device available).
3. Read the swapfile from the decrypted block device using `resume_offset=`.

This is the more common scenario (single LUKS container for everything). The initramfs handles it automatically as long as the resume hook is configured:

```text
resume=/dev/mapper/<cryptroot> resume_offset=<offset>
```

> [!WARNING]
> If you use a swapfile inside a LUKS-encrypted root, the `resume=` parameter should reference the decrypted mapper device, not the LUKS partition UUID. This is because the `resume_offset=` is relative to the decrypted block device, not the raw encrypted partition.

## Distribution-Specific Setup

Each distribution uses a different initramfs generator, and each generator requires a different configuration method. The fundamental task is the same: include the resume hook and ensure it runs at the correct point in the boot sequence.

### 1. Arch Linux (mkinitcpio)

mkinitcpio uses a hook-based system where `HOOKS` is an ordered array. The `resume` hook adds the swsusp resume logic into the initramfs.

#### Why the Hook Order Matters

The resume hook must be placed:
- **After `filesystems`:** The filesystems hook loads kernel modules for the filesystem type (e.g., `btrfs`) and makes the root device accessible.
- **After `block`:** The block hook loads storage drivers (NVMe, SATA, etc.) so the swap device is reachable.
- **Before `fsck`:** The filesystem check hook must not run before resume, because if the system is resuming, the root filesystem is still in the state it was left during hibernation — running fsck on it could corrupt the hibernation image.

#### Configuration

Edit `/etc/mkinitcpio.conf`:

```text
HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems resume fsck)
```

Find the swap device UUID and, if using a swapfile, the offset:

```bash
sudo findmnt -no UUID -T /swapfile                       # partition UUID
sudo btrfs inspect-internal map-swapfile -r /@swap/swapfile  # offset (Btrfs only)
sudo filefrag -v /swapfile | awk '$1=="0:" {print $4}'       # offset (ext4)
```

Regenerate:

```bash
sudo mkinitcpio -P
```

The `-P` flag rebuilds all existing presets (all kernels), which is what you want after a configuration change.

### 2. Fedora (dracut)

Fedora uses dracut, which generates initramfs from modules rather than hooks. Dracut automatically includes the `resume` module when it detects a `resume=` kernel parameter exists in the running kernel's command line or in `/proc/cmdline`. However, because the parameter is not yet present at install time for a new swap configuration, you should add the module explicitly.

#### Why Dracut Differs from mkinitcpio

Dracut's module system is declarative and dependency-resolved. Instead of an ordered hook list, dracut modules declare what they need (binaries, kernel modules, udev rules) and dracut resolves the dependency tree. The `resume` module, for example, depends on `systemd` (or `base`) for the initramfs init system and on `kernel-modules` for block device drivers. You do not specify order; dracut figures it out.

#### Configuration

Create `/etc/dracut.conf.d/resume.conf`:

```text
add_dracutmodules+=" resume "
```

You also need to ensure the `systemd` module is included (it usually is by default on Fedora), because the resume module uses `systemd-sleep` infrastructure:

```text
add_dracutmodules+=" systemd resume "
```

> [!TIP]
> Fedora's default dracut configuration on Fedora 40+ includes the `resume` module implicitly via the `systemd` module, but older releases or custom configurations may not. Verify with: `lsinitrd | grep resume`

Add the kernel parameters (see bootloader section), then regenerate:

```bash
sudo dracut --force
```

The `--force` flag overwrites any existing initramfs. Without it, dracut refuses to overwrite.

### 3. Ubuntu / Debian (initramfs-tools)

initramfs-tools uses a script-based approach: it sources configuration files from `/etc/initramfs-tools/conf.d/` and `/etc/initramfs-tools/initramfs.conf` and assembles an initramfs by running hook scripts from `/usr/share/initramfs-tools/hooks/`.

#### The `RESUME` Configuration Variable

Unlike mkinitcpio and dracut where kernel parameters drive resume configuration, initramfs-tools reads the `RESUME` variable from its configuration files. The value is typically set to the UUID of the swap partition:

```text
RESUME=UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

This file is created automatically during installation if a swap partition is detected. For swapfiles, initramfs-tools does not set `RESUME` — you must pass `resume=` and `resume_offset=` as kernel parameters instead. This is because initramfs-tools' resume hook assumes a swap partition when `RESUME` is set and does not understand `resume_offset`.

Create `/etc/initramfs-tools/conf.d/resume`:

```text
# For swap partition:
RESUME=UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# For swapfile, leave RESUME unset and use kernel parameters
```

Update initramfs:

```bash
sudo update-initramfs -u -k all
```

The `-k all` flag updates initramfs for every installed kernel version.

#### Why Ubuntu Needs Kernel Parameters for Swapfiles

The initramfs-tools resume hook script (`/usr/share/initramfs-tools/hooks/resume`) only understands the `RESUME` configuration variable, which maps to a swap *partition*. For swapfiles, the resume logic relies entirely on the kernel's built-in parameter parsing: when `resume=` and `resume_offset=` are passed on the command line, the kernel itself handles the resume internally. initramfs-tools does not need to add any special hook for this case, but you must ensure the parameters reach the kernel.

### 4. openSUSE (dracut)

openSUSE uses dracut but with a distribution-specific wrapper, `mkinitrd`. The wrapper sets openSUSE defaults (e.g., including `lvm` and `md` modules by default) and then calls dracut internally.

Create `/etc/dracut.conf.d/resume.conf`:

```text
add_dracutmodules+=" resume "
```

Regenerate:

```bash
sudo mkinitrd
```

> [!NOTE]
> On openSUSE, `mkinitrd` is a wrapper around dracut. Running `sudo dracut --force` produces the same result, but `mkinitrd` is the distribution-idiomatic command. The wrapper also handles versioned initramfs filenames (e.g., `initrd-6.5.0-1-default`) automatically.

#### Kernel Parameters

All four distributions ultimately need the same kernel parameters — the difference is only how initramfs ensures the resume code is present:

```text
resume=UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx resume_offset=xxxxx
```

## Bootloader Configuration

The bootloader must pass the `resume=` and `resume_offset=` parameters to the kernel. Each bootloader has a different configuration file and regeneration mechanism (or lack thereof).

### Why Bootloader Configuration Matters

The kernel command line is the only channel through which the resume parameters reach swsusp. The initramfs resume hook can also read these parameters from `/proc/cmdline` (which the kernel populates from the bootloader). If the parameters are missing from the bootloader configuration, the kernel does not know where to find the hibernation image, and a clean boot occurs instead of resume.

### GRUB2

GRUB2 generates its configuration from `/etc/default/grub` by running `grub-mkconfig`. The variable `GRUB_CMDLINE_LINUX_DEFAULT` sets parameters that appear on every boot entry.

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

`update-grub` is a wrapper script that calls `grub-mkconfig` with the correct output path. The two commands are equivalent on Ubuntu/Debian.

### systemd-boot

systemd-boot reads individual loader entry files from `/boot/loader/entries/`. Each `.conf` file specifies a kernel and initramfs path and an `options` line for kernel parameters.

```text
title   Fedora Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=yyyyyyy quiet splash resume=UUID=xxxxxxxx resume_offset=xxxxx
```

> [!TIP]
> systemd-boot does not require a regeneration step after editing entry files because it reads the filesystem directly at boot. This makes it simpler than GRUB2 for iterative configuration changes.

### Limine

Limine uses a flat configuration file, typically `/boot/limine/limine.conf` or `/etc/default/limine` on Omarchy. The `KERNEL_CMDLINE` array defines per-entry or default kernel parameters.

```text
KERNEL_CMDLINE[default]="root=UUID=yyyyyyy quiet splash resume=UUID=xxxxxxxx resume_offset=xxxxx"
```

> [!IMPORTANT]
> Limine reads its configuration file directly at boot time. There is no separate generation step — changes take effect on the next reboot immediately. This also means syntax errors in the config file will only become apparent at boot.

### rEFInd

rEFInd can discover kernels automatically and passes parameters from a file called `refind_linux.conf` located in the same directory as the kernel image, typically `/boot/refind_linux.conf`. Each line is a named entry; the parameters are space-separated.

```text
"Boot with defaults"  "root=UUID=yyyyy quiet splash resume=UUID=xxxxxxxx resume_offset=xxxxx"
"Boot to single-user mode"  "root=UUID=yyyyy single resume=UUID=xxxxxxxx resume_offset=xxxxx"
"Boot with minimal options"  "root=UUID=yyyyy ro quiet"
```

> [!TIP]
> rEFInd also supports manual entries in `/boot/efi/EFI/refind/refind.conf` if you prefer centralized configuration, but `refind_linux.conf` is simpler for auto-detection setups.

## Resume Offset: Btrfs

When using a swapfile on Btrfs, the kernel needs the physical offset of the swapfile on the block device. This offset is the byte position within the Btrfs volume where the swapfile's first block is located, after translating through Btrfs's chunk tree (which maps logical addresses to physical device offsets).

```bash
sudo btrfs inspect-internal map-swapfile -r /@swap/swapfile
```

Example output:

```text
physical_offset 2013265920
```

This value becomes the `resume_offset=` kernel parameter.

> [!WARNING]
> If you delete and recreate the swapfile (for example, after resizing it), the offset **will change**. Btrfs allocates new physical space for the new file, which likely differs from the original offset. You must update `resume_offset=` in every bootloader configuration and regenerate the initramfs.

## Resume Offset: ext4

For ext4 swapfiles, obtain the offset using `filefrag`:

```bash
sudo filefrag -v /swapfile | awk '$1=="0:" {print $4}'
```

The output is the offset in filesystem blocks (typically 4096 bytes). This value, when multiplied by the block size, gives the byte offset on the block device. The kernel expects the value in units of 1024-byte sectors, so the raw `filefrag` output is used directly — the kernel internally converts.

## Quick-Reference Tables

### Initramfs Generation

| Distribution | Tool | Config File | Command |
|-------------|------|-------------|---------|
| Arch Linux | mkinitcpio | `/etc/mkinitcpio.conf` | `sudo mkinitcpio -P` |
| Fedora | dracut | `/etc/dracut.conf.d/resume.conf` | `sudo dracut --force` |
| Ubuntu/Debian | initramfs-tools | `/etc/initramfs-tools/conf.d/resume` | `sudo update-initramfs -u -k all` |
| openSUSE | dracut | `/etc/dracut.conf.d/resume.conf` | `sudo mkinitrd` |

### Bootloader Configuration

| Bootloader | Config File | Update Command |
|------------|-------------|----------------|
| GRUB2 | `/etc/default/grub` | `sudo grub-mkconfig -o /boot/grub/grub.cfg` or `update-grub` |
| systemd-boot | `/boot/loader/entries/*.conf` | None (reads config directly) |
| Limine | `/boot/limine/limine.conf` | None (reads config directly) |
| rEFInd | `/boot/refind_linux.conf` | None (reads config directly) |

### Kernel Parameter Reference

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `resume=` | Swap device UUID for resume | `resume=UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890` |
| `resume_offset=` | Physical offset of swapfile on disk (sectors) | `resume_offset=2013265920` |
| `noresume` | Skip resume attempt (fallback for failed resume) | `noresume` |
| `resumewait` | Wait for the resume device to appear (useful with LUKS) | `resumewait` |

The `noresume` parameter is useful as a one-time recovery mechanism: if a resume attempt fails and the system hangs, you can interrupt the boot, edit the kernel command line (via GRUB's `e` key, systemd-boot's `e` key, or rEFInd's F2/F10), add `noresume`, and boot normally. After booting, you can diagnose the issue and manually clear the swap signature with `swapoff /swapfile && swapon /swapfile`.

## Testing Hibernation

Before relying on hibernation, test it with a controlled cycle. A single successful test reduces confidence — run three cycles before considering the configuration stable.

### Test Procedure

1. Save all work and close critical applications.
2. Trigger hibernation:

```bash
sudo systemctl hibernate
```

The system should power off completely. If it returns to the login screen instead, hibernation was aborted — check `journalctl -xe` for the "Not enough free swap" message.

3. Power on the machine. The bootloader should load normally, but instead of a clean boot, the kernel will detect a hibernation image and resume. The resume process may take 5–60 seconds depending on RAM size and storage speed.

4. Verify the session is restored exactly as left — open applications, cursor position, and unsaved documents should all be present.

5. Hibernate and resume two more times to confirm stability.

> [!TIP]
> After a successful resume, you can check `journalctl -b -t kernel | grep "PM:"` to see kernel hibernation/resume messages like `PM: hibernation: resume from disk` or `PM: hibernation: Restoring platform`.

## Troubleshooting

### Hibernation Fails Silently (Clean Boot After Hibernate)

If the system powers off but boots normally (no resume):

- **Kernel parameters missing:** Verify `resume=` and `resume_offset=` are present in the bootloader configuration. Check with `cat /proc/cmdline` — the kernel exposes the parameters it actually received. If they are absent, the bootloader configuration was not updated after editing.
- **Initramfs lacks resume hook:** Run `lsinitrd | grep resume` (dracut), `lsinitcpio /boot/initramfs-linux.img | grep resume` (mkinitcpio), or `lsinitramfs /boot/initrd.img-$(uname -r) | grep resume` (initramfs-tools). If no resume-related files appear, the initramfs needs regeneration.
- **Swap is inactive:** Run `swapon --show`. If no swap devices appear, the swapfile or partition is not enabled. Check `/etc/fstab` and run `sudo swapon -a`.
- **Wrong UUID or offset:** The `resume=` UUID must point to the block device containing swap, not to the root filesystem. For swapfiles, double-check the offset calculation.

### Resume Offset Changed After Update

Some kernel or btrfs-progs updates can cause the Btrfs chunk tree to be rebalanced, which changes the physical location of the swapfile's data. This is rare but possible. After a major kernel update:

1. Recalculate the offset: `sudo btrfs inspect-internal map-swapfile -r /@swap/swapfile`
2. If it changed, update the bootloader configuration and regenerate initramfs.

### "Not enough free swap" Error

```text
PM: Not enough free swap
```

The kernel found swap but it was too small to hold the memory image. This typically means:

- Active memory usage exceeds swap size. Reduce memory pressure by closing applications, then retry.
- A zram device is consuming swap space. `zram` (compressed RAM-backed swap) counts toward the total swap available, but the swsusp code cannot use it for hibernation because zram data is lost on power-off. Disable zram before hibernation or ensure a regular swap device larger than RAM exists alongside zram.

To check zram status:

```bash
zramctl
```

If zram is active and consuming space, you may see:

```text
NAME       DISKSIZE  DATA  COMPR  TOTAL  STREAMS
/dev/zram0     8G    4.5G   1.8G   2.0G        4
```

The remedy is to ensure a disk-backed swap device (partition or file) of sufficient size exists. zram can coexist with disk swap as long as the disk swap alone is larger than RAM.

### Btrfs: "Swapfile is not supported on Btrfs"

```text
swapon: /@swap/swapfile: swapon failed: Invalid argument
dmesg: swapfile is not supported on Btrfs
```

This error from the kernel means the swapfile does not meet Btrfs's requirements:

- **Subvolume must have `nocow`:** Verify with `lsattr -d /@swap`. The output should show a `C` in the attribute flags. If not, run `sudo chattr +C /@swap`, delete the swapfile, recreate it, and re-run `mkswap`.
- **Swapfile must be on a subvolume, not the root inode:** Run `btrfs subvolume show /@swap` to confirm it is a subvolume. If `/@swap` returns "not a subvolume", you created a regular directory instead.
- **Swapfile was created after `chattr +C` was set:** Setting `nocow` on a directory only affects *new* files. If the swapfile was created first and `chattr +C` set after, the swapfile still has CoW enabled. Delete and recreate.

### Resume from Hibernate Takes Too Long

- **Large RAM:** Reading 16–64 GB from disk takes time. An NVMe SSD can read at ~3–6 GB/s, so 32 GB takes roughly 5–10 seconds. An HDD at ~150 MB/s would take 3+ minutes.
- **Encrypted swap:** If swap is LUKS-encrypted, each sector must be decrypted during resume. This is CPU-bound. AES-NI hardware acceleration helps significantly.
- **Fragmented swapfile:** If the swapfile has many extents, the kernel must read from non-contiguous sectors, reducing throughput. Recreate the swapfile with `fallocate` (which tries for contiguous allocation) rather than `dd`.

### LUKS + Hibernation: "Device not ready" on Resume

If the resume device is LUKS-encrypted and separate from root, the initramfs must include the LUKS unlock infrastructure. On dracut, ensure `rd.luks.uuid=<swap-luks-uuid>` is present on the kernel command line. On mkinitcpio, ensure `encrypt` or `sd-encrypt` hooks are present and configured.

For a swapfile inside a LUKS-encrypted root, the `resume=` parameter should point to the unlocked mapper device, not the LUKS partition:

```text
# Correct (points to decrypted device):
resume=/dev/mapper/cryptroot resume_offset=2013265920

# Wrong (kernel tries to read swsusp signature from encrypted data):
resume=UUID=<luks-partition-uuid> resume_offset=2013265920
```

### GRUB2: Parameters Not Taking Effect

If `cat /proc/cmdline` shows the resume parameters are missing after a GRUB2 update:

1. Verify the parameters are set in `/etc/default/grub`.
2. Run the generation command again (`grub-mkconfig` or `update-grub`).
3. Check that the generated `/boot/grub/grub.cfg` contains the parameters in the `linux` lines for your kernel entries.
4. If you have multiple `GRUB_CMDLINE_LINUX` variants (e.g., `GRUB_CMDLINE_LINUX`, `GRUB_CMDLINE_LINUX_DEFAULT`), ensure the parameters land in the right one. `GRUB_CMDLINE_LINUX_DEFAULT` applies to all entries; `GRUB_CMDLINE_LINUX` applies only to non-recovery entries.

## Secure Boot Considerations

If Secure Boot is enabled, the kernel and initramfs must be cryptographically signed. The `resume=` kernel parameter is part of the kernel command line, which is not signed — the bootloader passes it to the kernel at runtime. This means changing kernel parameters for hibernation does not require re-signing as long as the kernel and initramfs files themselves are unchanged.

However, if you regenerate the initramfs (to add the resume hook) and Secure Boot is active, you must sign the new initramfs:

```bash
sudo sbctl sign /boot/initramfs-linux.img
sudo sbctl sign /boot/vmlinuz-linux
```

For **Limine** with Secure Boot and custom keys:

```bash
sudo sbctl sign /boot/EFI/LIMINE/LIMINE.EFI
sudo sbctl sign /boot/vmlinuz-linux
```

> [!NOTE]
> See the [Secure Boot section of the Omarchy dual-boot guide](./dualboot-win11-omarchy.md#secure-boot-implementation-optional) for detailed instructions on key enrollment with `sbctl`, including how to generate custom keys and enroll Microsoft keys for dual-boot compatibility.

## References

- [Power management/Suspend and hibernate - Arch Wiki](https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate)
- [Hibernation - Fedora Wiki](https://fedoraproject.org/wiki/Hibernation)
- [SwapFaq - Ubuntu Community Wiki](https://help.ubuntu.com/community/SwapFaq)
- [Btrfs Wiki - Swapfile](https://btrfs.wiki.kernel.org/index.php/Manually_making_a_swapfile)
- [systemd-sleep - freedesktop.org](https://www.freedesktop.org/software/systemd/man/systemd-sleep.html)
- [dracut wiki - Kernel command line](https://dracut.wiki.kernel.org/index.php/Dracut.kernel)
- [mkinitcpio - Arch Wiki](https://wiki.archlinux.org/title/Mkinitcpio)
- [initramfs-tools - Debian Wiki](https://wiki.debian.org/initramfs)
- [Linux kernel documentation: Power Management](https://www.kernel.org/doc/html/latest/admin-guide/pm/index.html)
- [Linux kernel documentation: swsusp](https://www.kernel.org/doc/html/latest/admin-guide/pm/sleep-states.html)
- [ACPI Specification 6.5 - Section 4.4: Sleeping States](https://uefi.org/specs/ACPI/6.5/04_ACPI_Overview.html#sleeping-states)
- [systemd-cryptenroll(1) - man page](https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html)
- [Btrfs send/receive and swapfiles - kernel.org](https://btrfs.readthedocs.io/en/latest/Swapfile.html)
