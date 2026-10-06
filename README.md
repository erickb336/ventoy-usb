# Ventoy USB Setup for Windows and Linux

Create a multiboot USB and copy installer ISOs using **native PowerShell on Windows** or the existing **Bash scripts on Linux**. Install Ventoy once; add ISOs later without reinstalling it.

**Creating a Ventoy USB erases every partition and file on the selected USB disk. Back it up first.** Adding an ISO does not reinstall Ventoy. Creating the USB does not install Windows or erase your PC; that is a separate operation on the target PC.

## Platform compatibility

| Computer running this utility | Supported? | Entry point |
| --- | --- | --- |
| Windows 10/11 (Intel/AMD) | Yes, native PowerShell | `ventoy.ps1` |
| Linux | Yes, Bash and Linux disk utilities | `./ventoy.sh` |
| macOS | No native support in this project | Use a Windows or Linux computer to prepare the USB |

**macOS and Linux are not interchangeable here.** The Bash scripts require Linux tools such as `lsblk`, `udevadm` and `partprobe`, and download the Linux Ventoy installer. They do not run natively on macOS just because it has a terminal or Bash. This table describes the computer preparing the USB, not which operating systems or hardware can boot a particular ISO.

## Windows quick start

Prerequisites: Windows 10/11 on an Intel/AMD PC, Windows PowerShell 5.1 or PowerShell 7, the built-in Storage module, internet for installation, and a USB with enough room for your ISO. A 16 GB or larger USB is a practical choice for Windows 11. Git is only needed to clone; a downloaded repository ZIP works too.

### 1. Open an Administrator PowerShell window

Open **Start**, type **Windows PowerShell**, right-click it, and choose **Run as administrator**. Approve the Windows prompt. The window title should include **Administrator**. Opening a normal PowerShell window is not enough, even if your Windows account is an administrator.

### 2. Download the project and enter its folder

**Run each command separately, from top to bottom. Press Enter after each one.** Copy only the command, not the `PS C:\...>` prompt or Markdown backticks.

If you have Git and have not downloaded this project yet:

```powershell
git clone https://github.com/erickb336/ventoy-usb.git
```

Then:

```powershell
cd ventoy-usb
```

If you already have the project, do not clone again. Run `cd` with the actual folder containing `ventoy.ps1`. For example, replace the example path below with yours:

```powershell
cd "C:\path\to\ventoy-usb"
```

You can also download the repository ZIP from GitHub's **Code > Download ZIP**, extract it, and enter the extracted folder. Do not run the scripts from inside the ZIP.

Confirm you are in the correct folder:

```powershell
Get-Item .\ventoy.ps1
```

If this says the file cannot be found, correct the folder before continuing. An Administrator PowerShell window often starts in `C:\Windows\System32`, which is not this project's folder.

### 3. Start the utility

Run this single command from the project folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\ventoy.ps1"
```

This command handles the common **running scripts is disabled** error for this process only. It does not permanently change your system execution policy and does not grant administrator rights; step 1 is still required. It cannot override organizational Group Policy. Only run scripts you have reviewed and trust.

If your execution policy already permits scripts, the shorter entry point also works:

```powershell
.\ventoy.ps1
```

### 4. Select the correct USB and confirm

Choose **1** to create a new Ventoy USB, or **2** to copy an ISO to an existing one without reinstalling Ventoy.

At **Select USB by list number**, enter the number in square brackets, **not the physical disk number or drive letter**. For example:

```text
[1]
Disk 3 | General UDisk | 58.59 GiB
Select USB by list number: 1
```

In this example, type `1`, not `3` or `D:`. Your USB's name, capacity and disk number may differ. A marketed 64 GB USB commonly appears as about 58.6 GiB.

If you are unsure which disk is your USB, stop with **Ctrl+C before confirming erasure**. Unplug the USB and run:

```powershell
Get-Disk | Format-Table Number, FriendlyName, BusType, @{Name='SizeGiB';Expression={[math]::Round($_.Size/1GB,1)}}, IsBoot, IsSystem
```

Plug it back in, wait a few seconds, and run the same command again. Identify the newly appearing disk and match its model and capacity. It should show `USB`, with `IsBoot` and `IsSystem` both `False`. Disconnect other external drives if that helps identify it. Disk numbers can change after reconnection, so rerun the utility and verify the current details.

For a new USB, the utility downloads and verifies Ventoy, then displays the physical disk again. Type uppercase **`YES` only after confirming the intended USB and backing up anything on it**. This erases every partition on that USB. Installation uses GPT and leaves Secure Boot support enabled. Do not unplug it while installation is running.

### 5. Add your Windows 11 or local ISO

After installation (or immediately for option 2), choose:

- **1 — Windows 11:** open Microsoft's official download page. Download the **Windows 11 Disk Image (ISO)** matching the target PC; use x64 for an Intel/AMD PC. Save the file to your computer and wait until the download finishes.
- **2 — Local ISO:** use an ISO you already downloaded.
- **3 — Skip:** finish without copying an ISO. You can rerun the utility with option 2 later.

When asked for the ISO path, paste the full file path, for example:

```text
"C:\Users\YourName\Downloads\Windows11.iso"
```

Replace the example with your actual filename. Spaces, brackets and optional surrounding double quotes are supported. Wait for copying and SHA-256 verification to finish, then safely eject the USB in Windows before unplugging it.

### How to tell what is happening

| Stage | Where to see progress |
| --- | --- |
| Downloading the Windows ISO | In your browser, press **Ctrl+J**. The utility cannot track this browser download. Wait until the browser says it is complete. |
| Terminal asks for an ISO path | The utility is waiting for you; no USB copy has started. Paste the completed file's path and press Enter. Do not double-click the ISO or start Windows Setup on this PC. |
| Downloading Ventoy | Terminal download activity indicator; PowerShell may also display received-byte progress. |
| Installing Ventoy | Terminal percentage when reported by the installer, otherwise a waiting indicator. |
| Copying the ISO | Terminal progress bar with percentage, GiB copied, average MiB/s and estimated time remaining. Speed and estimates can fluctuate. |
| Flushing / verifying | Separate flushing status and source/USB checksum progress bars. Copying reaching 100% does not mean verification is finished. |
| Finished | **ISO copied and SHA-256 verified.** You can now safely eject the USB. |

Updates to the script apply on the next run. Let any current installation or copy finish. If Ventoy is already installed, select **2 — Add ISO to existing Ventoy USB** next time; do not reinstall just to get progress indicators.

The Windows path uses [Ventoy's supported CLI](https://www.ventoy.net/en/doc_windows_cli.html) with a physical disk number (`/PhyDrive:N`), not GUI automation or a destructive drive-letter command. It rejects non-USB, boot/system, offline, read-only and zero-size disks, and rechecks disk identity after confirmation. USB-attached external SSDs may still appear, even when Windows calls them fixed disks. Check their model, size and serial carefully. Keep the USB connected throughout the operation.

Copying requires the standard Ventoy partition layout on the selected disk, checks free space and FAT32 limits, refuses filename collisions, and uses a temporary file until checksum verification succeeds. This checks copy integrity, not ISO authenticity.

For a downloaded ZIP, use Properties > Unblock before extraction if needed. Do not change machine-wide execution policy for this utility.

## Linux quick start

Prerequisites: Bash, `curl`, `tar`, `grep`, `sed`, `awk`, `lsblk`, `sudo`, `udevadm`, `partprobe`, and standard mount/copy utilities. Installation needs sudo and internet access; your system must support mounting exFAT. On Debian/Ubuntu, `partprobe` is in the `parted` package.

```bash
git clone https://github.com/erickb336/ventoy-usb.git
cd ventoy-usb
./ventoy.sh
```

Run from the repository directory. If you downloaded a ZIP, restore permissions with:

```bash
chmod +x ventoy.sh ventoy-install.sh ventoy-add-isos.sh
```

The Linux scripts are unchanged. You can also run them directly:

```bash
./ventoy-install.sh          # latest release, USB selection, YES confirmation
./ventoy-install.sh 1.1.17   # optional explicit version (example)
./ventoy-add-isos.sh         # interactive copy
./ventoy-add-isos.sh /mnt/ventoy ./isos
```

Select a whole USB device such as `/dev/sdb`, not `/dev/sdb1`. Check `lsblk -o NAME,TRAN,SIZE,MODEL,LABEL,MOUNTPOINT` before confirming. The installer uses force-install (`-I`), which erases existing Ventoy installations too. It offers ISO URL downloads and copying from a local directory. Only use trusted direct ISO URLs; download Windows ISOs manually because Microsoft links can expire.

Linux retains Ventoy's default partition style (MBR); the Windows path explicitly uses GPT. Existing Linux scripts find mounts by the `Ventoy` label, so connect only one Ventoy USB and verify the mount point. Their copy command can overwrite matching filenames. These behaviors were preserved, not rewritten for this Windows addition.

## Windows 11 installation media

The Windows 11 menu option opens [Microsoft's official download page](https://www.microsoft.com/software-download/windows11). Select **Download Windows 11 Disk Image (ISO)** and the architecture matching the target PC. Save it to the host PC, wait for completion, then paste its path into the prompt. The utility does not scrape temporary Microsoft download URLs. If the browser cannot open, use the printed URL manually. On Linux, download the ISO in your browser and place it in the ISO directory.

Compare the ISO's SHA-256 against Microsoft's published checksum for your chosen download when available:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\path\Windows11.iso'
```

```bash
sha256sum /path/Windows11.iso
```

## Booting and clean installation

1. Safely eject the USB, insert it into the target PC and open its one-time boot menu (check the manufacturer's key).
2. Choose the UEFI USB entry. In Ventoy, select the Windows ISO and start in normal mode.
3. Back up needed files before deleting anything. In Windows Setup, identify the intended **internal physical disk**. To replace dual boot, remove its old Windows/Linux partitions only when ready to lose their contents, then install onto its unallocated space. Do not select the Ventoy USB as the destination.
4. After installation, boot Windows Boot Manager on the internal SSD instead of restarting the USB installer.

Two SSDs remain two physical devices. Removing Linux can reclaim space but does not merge both drives. A straightforward setup is Windows on one SSD and a data volume on the second. Identify and back up both disks before planning that later change. This utility does not modify internal SSDs or remove dual boot entries.

## Secure Boot

The Windows installer leaves Secure Boot support enabled by omitting `/NOSB`. It does not configure firmware or guarantee compatibility with every PC. Ventoy may require key enrollment on first boot; keys can change between releases. Follow the current [official Secure Boot instructions](https://www.ventoy.net/en/doc_secure.html). Some firmware requires its Microsoft third-party UEFI CA option. Ventoy's image validation policy is separate from enabling firmware Secure Boot; consult upstream instructions if you need strict validation.

## Troubleshooting

| Problem | Action |
| --- | --- |
| Running scripts is disabled | From the project folder, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\ventoy.ps1"`. No permanent policy change is needed. |
| `ventoy.ps1` is not recognized / cannot be found | Run `cd` to the folder containing the script first, then check `Get-Item .\ventoy.ps1`. Run commands in the documented order. |
| PowerShell displays `>>` instead of its normal prompt | Press Ctrl+C to cancel incomplete input, then paste one complete command at a time. |
| Access denied | Open PowerShell as Administrator. The script does not silently elevate. |
| No eligible disks | Reconnect the USB and inspect `Get-Disk`. Internal, boot/system, offline and read-only disks are excluded. |
| Disk changed | Restart and select again. Do not swap drives during a run. |
| Download/API/TLS failure | Check internet, proxy and trusted TLS certificates. GitHub rate limits also apply. No installation starts before verified download and confirmation. |
| Missing digest/hash mismatch | Installation stops. Retry the official release; do not bypass verification. |
| Installer failed | Read the last 40 log lines displayed. Close apps using the USB and inspect its state before retrying. |
| Layout not recognized | Option 2 expects data partition 1 (exFAT/NTFS/FAT32) and a 32 MiB FAT `VTOYEFI` partition 2. Renamed EFI volumes and custom layouts are rejected. |
| No drive letter | Identify the USB's large data partition in Disk Management and assign a letter, then retry option 2. Do not assign one to its small EFI partition. |
| File already exists | Rename the source or deliberately remove/rename the old ISO yourself. Windows copying refuses overwrites. |
| ISO too large | Check free space. FAT32 limits files to 4 GiB minus one byte; new Windows installs use Ventoy's default exFAT. |
| USB does not boot | Try the UEFI boot entry, check the ISO checksum, firmware settings and Secure Boot guidance. Test on the target PC. |

Errors and Ctrl+C clean up temporary downloads and partial copies where possible. If Ventoy is already writing a disk, the wrapper waits for the process before removing its working files. Do not unplug the USB or close the terminal mid-installation. Forced termination or power loss can leave temporary files or an incomplete USB. Failure log excerpts are displayed before the temporary package is removed.

## Development and safe validation

- `ventoy.ps1`: interactive UI, prerequisites, orchestration and cleanup.
- `windows/Disks.ps1`: discovery, physical disk identity and partition checks.
- `windows/Install.ps1`: release resolution, verified extraction and CLI installation.
- `windows/Isos.ps1`: ISO selection, Microsoft page and verified copying.

No Pester dependency is needed:

```powershell
.\tests\Test-Windows.ps1
.\tests\Test-Download.ps1  # optional real download/extraction; never launches Ventoy
```

The unit suite replaces disk, network and process operations with fixtures and only writes temporary local test files. It never runs the installer or formats a disk. For a read-only enumeration check in an elevated terminal:

```powershell
. .\windows\Disks.ps1
Get-UsbDisks | ForEach-Object { Show-UsbDisk $_ }
```

Actual installation, USB re-enumeration, cancellation while writing, and UEFI/Secure Boot/Windows installer boot require manual verification with disposable USB media. Never run destructive installation in automated tests.

## License

Scripts are provided as-is. [Ventoy](https://github.com/ventoy/Ventoy) is a separate upstream project licensed under GPL v3.0.
