# Dual-Booting Windows 11 and Omarchy on a Single Disk

Omarchy is designed to run on a LUKS-encrypted Btrfs filesystem using the Limine
bootloader. While the official Omarchy ISO automates this by wiping the drive,
you can perform a manual dual-boot installation. 
This involves setting up your Btrfs subvolume architecture, 
installing a base Arch system via `archinstall`,
and then running the Omarchy bootstrap script.

> [!WARNING] 
> **Hardware Compatibility:** Because this setup uses full-disk encryption, 
> you must enter your LUKS password before the Bluetooth stack initializes. 
> **Bluetooth keyboards will not work for decryption.** 
> You must use a built-in laptop keyboard, a wired USB keyboard, 
> or a 2.4GHz wireless keyboard with a USB dongle.

## Prerequisites & Preparation

Before beginning, ensure your system is prepared:

- **Windows 11 Installed:** It is significantly easier to install Linux
  alongside an existing Windows partition than vice-versa.
- **Manage BitLocker:** If BitLocker is enabled, either disable it or ensure you
  have your Recovery Key handy.
- **Firmware Settings:** Disable **Fast Boot** in both Windows and your
  BIOS/UEFI. Disable **Secure Boot** (unless you are prepared to manually sign
  your kernels later).
- **Unallocated Space:** Use _Disk Management_ in Windows to "Shrink Volume" on
  your primary drive. Leave at least **50–100GB** of **Unallocated Space**.

## Phase 1: Pre-Installation

1. **Boot the Arch Linux ISO:** Ensure you boot the standard vanilla Arch ISO in
   UEFI mode.
2. **Network Connection:** Use `iwctl` for Wi-Fi or connect an Ethernet cable.
   Verify connectivity: `ping archlinux.org`

3. **Sync System Clock:** Run `timedatectl set-ntp true`.

## Phase 2: Executing `archinstall`

Run `archinstall` and configure the following options. Leave any unlisted
settings at their defaults:

| Section                  | Recommended Option                                                        |
| ------------------------ | ------------------------------------------------------------------------- |
| **Mirrors**              | Select regions > Your local country                                       |
| **Disk configuration**   |                                                                           |
| > **Partition**          | Manual partitioning > Select your disk > Follow the subvolume table below |
| > **File system**        | `btrfs` (Use compression)                                                 |
| > **Encryption**         | Encryption type: `LUKS` + Set Password + Apply to the Arch partition      |
| **Hostname**             | Choose a unique system name                                               |
| **Bootloader**           | `Limine` (Install to removable location: No)                              |
| **Authentication**       | Create a User account (Superuser: Yes)                                    |
| **Applications > Audio** | `pipewire`                                                                |
| **Network config**       | Copy ISO network configuration                                            |

### Recommended Partition Schema

| Partition          | Size       | Type                                      | Mount Point  |
| ------------------ | ---------- | ----------------------------------------- | ------------ |
| **EFI System**     | ~100-500MB | EFI (Already exists from Windows)         | `/boot/efi`  |
| **Boot**           | 1GB        | Linux Extended (Optional but recommended) | `/boot`      |
| **LUKS Container** | Remaining  | Linux LUKS                                | `/` (Mapped) |

### Recommended Btrfs Subvolume Layout

| Name    | Mountpoint              |
| ------- | ----------------------- |
| `@`     | `/`                     |
| `@home` | `/home`                 |
| `@log`  | `/var/log`              |
| `@pkg`  | `/var/cache/pacman/pkg` |

> [!IMPORTANT] 
> You **must** enable disk encryption. 
> Omarchy’s security model relies on full-disk encryption to protect 
> the auto-login mechanism used after the drive is decrypted at boot.

## Phase 3: Install Omarchy

Once the base Arch installation finishes, 
reboot and log in to your new user account. 
To transform the base install into Omarchy, run:

```bash
curl -fsSL https://omarchy.org/install | bash
```

The script will prompt for your `sudo` password. 
The process takes **5–30 minutes** depending on your hardware and internet speed.
Once complete, the script will ask permission to reboot.

> [!TIP] 
> If the installation fails due to a network timeout, 
> simply select **Retry Installation**.

## Phase 4: Post-Installation (Windows Dual-Boot)

By default, 
the Limine bootloader may not immediately display the Windows 11 entry. 
To resolve this:

1. Run `limine-scan` (or the specific configuration tool provided by Omarchy) to
   detect the Windows EFI partition.
2. Add the detected entry to your boot menu configuration.

## Secure Boot Implementation (Optional)

**Secure Boot** is a critical security standard within the UEFI framework.
It protects the pre-boot environment by ensuring only cryptographically signed
binaries are allowed to execute. By managing a "whitelist" of authorized keys,
it prevents tampered boot managers, kernels, or initramfs images from
compromising the system at its most vulnerable stage.

### Prerequisites & Tools

Ensure the following utilities are installed on your system:

- **`sbctl`**: A high-level Secure Boot key management tool that simplifies the
  enrollment process.
- **`limine`**: The modern UEFI bootloader (installed during the Omarchy base
  setup).

### Step 1: Transition UEFI to Setup Mode

Before you can enroll custom keys, the firmware must be placed in a state where
it is willing to accept them.

1. Reboot into your **BIOS/UEFI Firmware Settings**.
2. Locate the **Secure Boot** section.
3. Select the option to **Clear/Delete/Restore Factory Keys**.

> [!NOTE] 
> This action places the system into "Setup Mode"

> [!WARNING] 
> **Do not** enable Secure Boot yet.

4. Save changes and exit.

> [!WARNING] 
> Clearing keys is non-destructive to your data, 
> but it is a prerequisite for enrolling custom ownership of the boot process.

### Step 2: Verify Firmware Status

Once back in your OS, confirm the system is ready for key generation.

```bash
sudo sbctl status
```

**Expected Output:**

- **Secure Boot:** `Disabled`
- **Setup Mode:** `Enabled` (A red '✘' here is normal; it simply indicates the
  mode is active and awaiting keys).

### Step 3: Generate and Enroll Custom Keys

Now, you will create your own "Root of Trust" and inject it into the
motherboard's NVRAM.

1. **Generate Keys:**

```bash
sudo sbctl create-keys
```

This creates your unique signature database in `/usr/share/secureboot/keys/`.

2. **Enroll Keys:**

```bash
sudo sbctl enroll-keys -m
```

> [!TIP] 
> The `-m` flag is highly recommended. 
> It enrolls Microsoft’s keys alongside your own, 
> ensuring that Windows dual-boots and various hardware drivers (Option ROMs) 
> continue to function.

3. **Verify:** Run `sudo sbctl status` again. 
   **Setup Mode** should now be `Disabled` (Locked), and 
   your keys should be listed under the PK, KEK, and DB entries.

### Step 4: Configure the Boot Image

For Secure Boot to remain effective, your initial RAM disk must be properly
configured to handle the encrypted hand-off.

1. **Edit the configuration:**

```bash
sudo nano /etc/mkinitcpio.conf.d/omarchy_hooks.conf   # or
sudo nano /etc/mkinitcpio.conf
```

2. **Update Hooks:** Add `btrfs-overlayfs` to the `HOOKS` array to ensure proper
   filesystem mounting during the secure hand-off.

```bash
HOOKS=(... btrfs-overlayfs)
```

3. **Rebuild & Update:** Regenerate the initramfs and refresh the Limine
   bootloader configuration.

```bash
sudo limine-mkinitcpio
```

### Step 5: Final Activation

1. Reboot directly into the firmware:

```bash
sudo systemctl reboot --firmware-setup
```

2. In the UEFI settings:
   - **Enable Secure Boot.**
   - Ensure the Secure Boot Mode is set to **"User"** or **"Custom"** (this
     varies by manufacturer).

3. Save and Exit.

**Validation:** Once logged back in, run `bootctl status` or `sbctl status`. You
should see a definitive **Secure Boot: Enabled**.

## TPM2 & LUKS Auto-Unlock (Optional)

It is possible to encrypt volumes using keys securely stored in the TPM. 
This approach ensures that your drives remain locked unless the TPM is present 
and specific conditions are met, such as the integrity of the firmware or 
Secure Boot state.

This mechanism can be used to automatically decrypt the root volume during the
boot process, similarly to how BitLocker works on Windows or FileVault on macOS.
While this provides strong protection if the drive is removed from the computer
with the TPM, data protection will only rely on basic measures like user
passwords and system settings if the entire PC is stolen.

On Arch Linux, the most modern and straightforward way to do this is by using
`systemd-cryptenroll`.

### Prerequisites

- **TPM 2.0** hardware.
- **LUKS2** partition format (standard for modern Arch).
- **Secure Boot** enabled (highly recommended for actual security).

### Step 1: Verify Hardware & Version

Ensure your system recognizes the TPM and your partition is LUKS2.

1. **Check TPM 2.0:** `systemd-cryptenroll --tpm2-device=list` (Look for
   `/dev/tpmrm0`).
2. **Confirm LUKS2:** `sudo cryptsetup luksDump /dev/nvme0n1p2 | grep Version`

> [!NOTE] 
> If it says Version 1, you must upgrade the header before proceeding.

### Step 2: Enroll the TPM Key

Bind your LUKS key to specific **PCR (Platform Configuration Register)** slots.

- **PCR 7:** Secure Boot state (Recommended).
- **PCR 0:** System firmware/BIOS.

Run the following (replace `/dev/nvme0n1p2` with your partition):

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p2
```

> [!Important] 
> Keep your manual passphrase as a backup! 
> Do not wipe the passphrase slot; 
> if your BIOS updates, the TPM might refuse to unlock.

### Step 3: Switch to systemd Hooks

To use the TPM during early boot, you must switch from `busybox` hooks to
`systemd` hooks.

1. Edit `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` or `/etc/mkinitcpio.conf`.
2. Replace value below in the `HOOKS` array:
   - Replace `udev` with `systemd`
   - Replace `keymap` and `consolefont` with `sd-vconsole`
   - Replace `encrypt` with `sd-encrypt`
3. **Regenerate initramfs:** `sudo limine-mkinitcpio`

### Step 4: Configure Limine Bootloader

Identify your partition UUID using `blkid` (look for `TYPE="crypto_LUKS"`) and
update your `/etc/default/limine` entry.

**Example Configuration:**

```text
KERNEL_CMDLINE[default]="root=/dev/mapper/root zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs"
KERNEL_CMDLINE[default]+="rd.luks.name=UUID=root rd.luks.options=UUID=tpm2-device=auto"
KERNEL_CMDLINE[default]+="quiet splash"
```

**Parameters Explained:**

- `rd.luks.name`: Maps the UUID to `/dev/mapper/root`.
- `rd.luks.options`: Directs `sd-encrypt` to use the TPM for this specific UUID.
- `root`: Sets the final root filesystem location.

### Step 5: Reboot

Reboot your system. If configured correctly, the system will query the TPM and
bypass the manual password prompt entirely.

> [!WARNING] 
> **Important Maintenance Note:** Any time you update your BIOS/UEFI,
> turn Secure Boot on/off, or change hardware, the TPM PCRs will change, and 
> it will refuse to unlock your drive. 
> When this happens, you will be prompted for your standard LUKS password.
> Once booted, you will need to wipe the old TPM slot and re-enroll it using 
> `systemd-cryptenroll --wipe-slot=tpm2`.

## How to Remove Omarchy

If you need to uninstall the dual-boot setup, 
you must reclaim the disk space and clean up the EFI boot entry.

### Step 1: Delete Linux Partitions

1. In Windows, right-click **Start** and select **Disk Management**.
2. Identify the Linux partitions. They will likely be labeled **"Healthy
   (Primary Partition)"** or **"Unknown Partition"** and won't have a drive
   letter.
   - _Look for sizes that match your Linux install (e.g., 60GB)._

3. Right-click the Linux partitions and select **Delete Volume**.
4. Once the space is marked as **Unallocated**, right-click your Windows `C:`
   partition and select **Extend Volume** to reclaim the space.

### Step 2: Clean the EFI Bootloader

To prevent your computer from trying to boot into a deleted OS:

1. Open **Command Prompt** as **Administrator**.
2. Mount the EFI partition: `mountvol S: /s`
3. Access the partition: `S:` then `cd EFI`
4. View folders: `dir`
5. Locate the folder (likely named `arch` or `limine`) and delete it:
   `rd /s [foldername]`
6. Confirm with **Y** and restart.

### Step 3: Clear NVRAM (Optional)

If a "Ghost" entry still appears in your BIOS boot menu:

1. Open **Command Prompt (Admin)**.
2. List firmware entries: `bcdedit /enum firmware`
3. Find the entry labeled `description Omarchy` or `Arch`. 
   Copy its **identifier** (the long string in brackets `{}`).
4. Delete the entry:

   ```cmd
   bcdedit /delete {your-identifier-here}
   ```

5. Verify by running the `enum` command again.

## References

- [Manual Installation - The Omarchy Manual](https://learn.omacom.io/2/the-omarchy-manual/96/manual-installation)
- [Manual Partitioning in archinstall for dual boot Omarchy #1651](https://github.com/basecamp/omarchy/discussions/1651)
- [Omarchy Dual-Boot Secure Boot Setup (Custom Keys Guide) #2296](https://github.com/basecamp/omarchy/discussions/2296)
- [Unified Extensible Firmware Interface/Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot)
- [Trusted Platform Module](https://wiki.archlinux.org/title/Trusted_Platform_Module#LUKS_encryption)
- [systemd-cryptenroll - ArchWiki](https://wiki.archlinux.org/title/Systemd-cryptenroll)
