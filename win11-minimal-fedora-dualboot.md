# Dual-boot Windows 11 and Fedora Minimal

## Install Windows 11

## Install Fedora

## Remove Fedora

Removing Linux dual-boot setup is a two-step process: you have to **delete the Linux partitions** to reclaim the space, and **clean up the EFI bootloader** so your computer doesn't try to boot into a non-existent operating system.

Since you are using Windows 11, you can do most of this without extra tools.

### Step 1: Delete the Linux Partitions

1. In Windows, right-click the **Start button** and select **Disk Management**.[^1]
2. Identify the Fedora partitions. They usually don't have a drive letter (like `D:` or `E:`) and will be labeled as **"Healthy (Primary Partition)"** or **"Unknown Partition"**.
    > [!TIP]
    > Look for the blocks of space that match the size you gave Fedora earlier (e.g., 60GB).

3. Right-click each Fedora partition and select **Delete Volume**.
4. Once they are deleted, you will have a block of **Unallocated Space**.
5. Right-click your Windows `C:` partition and select **Extend Volume** to soak up that empty space and return it to Windows.


### Step 2: Remove the Fedora Boot Entry (Crucial)

If you skip this, your computer might still show a "Fedora" option in the boot menu that leads to an error screen.

1. Click the **Start button**, search for `cmd`, right-click it, and select **Run as Administrator**.
2. Type `mountvol S: /s` and press Enter. (This mounts your hidden EFI system partition to drive letter `S`).
3. Type `S:` and press Enter.
4. Type `cd EFI` and press Enter.
5. Type `dir` to see the folders. You should see a folder named `fedora`.
6. To delete it, type: `rd /s fedora`
7. Press **Y** to confirm.
8. Close the Command Prompt and restart your computer.


### Step 3: Check BIOS Boot (Optional)

If you still see "Fedora" in the boot menu even after deleting the folder, it's because the entry is stored in your motherboard's **NVRAM** (its permanent memory), not just on the hard drive. Windows has a tool called `bcdedit` that can reach into that memory and scrub it.

1. Open Command Prompt (Admin)
2. Locate the Fedora Entry

    Run the following command to see all the "firmware" (BIOS/UEFI) entries:

    ```cmd
    bcdedit /enum firmware
    ```

    Look through the list for an entry that says `description Fedora`. It will have a long ID called an **identifier** that looks like this:
    `{7619dcc8-fafe-11e9-8919-806e6f6e6963}`

3. Delete the Entry

    Once you find the identifier for Fedora, type the following (replace the `{ID}` with the actual code you copied):

    ```cmd
    bcdedit /delete {your-identifier-here}
    ```

    > [TIP] 
    > In Command Prompt, you can highlight the ID with your mouse and press **Enter** to copy it, then right-click to paste it.*

4. Verify

    Run `bcdedit /enum firmware` one last time to make sure it's gone.



## References
[^1]: https://www.youtube.com/watch?v=TvtlVKJPWzI