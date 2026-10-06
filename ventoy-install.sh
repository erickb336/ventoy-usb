#!/usr/bin/env bash
set -euo pipefail

# download_isos <url>...: download the ISOs into a new folder, TEMP_ISO_DIR. Each file gets a name that ends in .iso,
# so that ventoy-add-isos.sh copies it. Two URLs with the same file name stop the script before any download.
download_isos() {
  local url name names=() n i
  (( $# > 0 )) || return 0
  for url in "$@"; do
    name=${url%%#*}
    name=${name%%\?*}
    name=${name##*/}
    [[ -n "$name" ]] || name=download
    [[ "${name,,}" == *.iso ]] || name=$name.iso
    for n in "${names[@]}"; do
      if [[ "${n,,}" == "${name,,}" ]]; then
        echo "❌ Two URLs give the same file name: $name. Give each ISO once. Aborted." >&2
        return 1
      fi
    done
    names+=("$name")
  done
  TEMP_ISO_DIR=$(mktemp -d)
  echo "📥 Downloading ISOs to $TEMP_ISO_DIR..."
  for i in "${!names[@]}"; do
    echo "Downloading ${names[i]}..."
    curl -fL -o "$TEMP_ISO_DIR/${names[i]}" "${@:i+1:1}"
  done
}

# downloads_kept [mount]: tell where the downloaded ISOs are and how to copy them later. [mount]: the Ventoy mount, if it is still mounted.
downloads_kept() {
  echo "📁 Not all downloaded ISOs are on the USB. The script kept them in: $TEMP_ISO_DIR" >&2
  if [[ -n "${1:-}" ]]; then
    echo "   To copy them later, run: $(printf '%q %q %q' ./ventoy-add-isos.sh "$1" "$TEMP_ISO_DIR")" >&2
  else
    echo "   To copy them later, connect the USB, run ./ventoy.sh and choose 2. At the ISO directory prompt, give this folder:" >&2
    echo "   $TEMP_ISO_DIR" >&2
  fi
}

# copy_isos_to <device>: copy the ISOs to the Ventoy partition of <device>, the USB that this script installed.
# It never uses a Ventoy USB of another device. It removes the downloaded ISOs (TEMP_ISO_DIR) only when no ISO failed
# and each downloaded file is on the USB. It returns 0 when the copy is complete.
copy_isos_to() {
  local device=$1 parts=() mount="" own_mount="" iso_dir=${TEMP_ISO_DIR:-} status=0 f
  # Ask before the mount, so that Ctrl+C at the question leaves no mount behind.
  if [[ -z "$iso_dir" ]]; then
    echo
    read -rp "Optional: directory containing ISO files (leave empty to skip): " iso_dir
    [[ -n "$iso_dir" ]] || return 0
  fi
  mapfile -t parts < <(lsblk -nrp -o NAME,LABEL "$device" | awk '$2=="Ventoy"{print $1}')
  if (( ${#parts[@]} != 1 )); then
    echo "❌ Expected 1 partition with the label Ventoy on $device, found ${#parts[@]}. No ISO was copied." >&2
    status=1
  else
    mount=$(findmnt -n -f -o TARGET --source "${parts[0]}" || true)
    if [[ -z "$mount" ]]; then
      echo "Ventoy partition ${parts[0]} is not mounted. Mounting it..."
      # A new folder that only root can change, so that no other user can put a link in its place before the mount.
      if own_mount=$(sudo mktemp -d /mnt/ventoy.XXXXXX) && sudo mount "${parts[0]}" "$own_mount"; then
        mount=$own_mount
      else
        echo "❌ Could not mount ${parts[0]}. No ISO was copied." >&2
        [[ -z "$own_mount" ]] || sudo rmdir "$own_mount"
        own_mount=""
        status=1
      fi
    fi
  fi

  if (( status == 0 )); then
    echo "📂 Ventoy partition ${parts[0]} is mounted at: $mount"
    ./ventoy-add-isos.sh "$mount" "$iso_dir" || status=$?
    if [[ -n "${TEMP_ISO_DIR:-}" ]] && (( status == 0 )); then
      while IFS= read -r -d '' f; do
        if [[ ! -e "$mount/$f" ]]; then
          echo "⚠️  The download $f is not on the USB." >&2
          status=1
        fi
      done < <(find "$TEMP_ISO_DIR" -mindepth 1 -maxdepth 1 -printf '%f\0')
    fi
    echo "🔄 Syncing data to USB..."
    sync
  fi

  if [[ -n "$own_mount" ]]; then
    if sudo umount "$own_mount"; then
      sudo rmdir "$own_mount"
      mount=""
    else
      echo "⚠️  Could not unmount $own_mount. Unmount it before you remove the USB." >&2
    fi
  fi
  if [[ -n "${TEMP_ISO_DIR:-}" ]]; then
    if (( status == 0 )); then
      rm -rf -- "$TEMP_ISO_DIR"
    else
      downloads_kept "$mount"
    fi
    TEMP_ISO_DIR=""
  fi
  return "$status"
}

# Tests source this file to call the functions above. Then nothing below runs.
if [[ "${BASH_SOURCE[0]:-$0}" != "$0" ]]; then
  return 0
fi

# Only the downloads of this run, never a TEMP_ISO_DIR from the environment.
TEMP_ISO_DIR=""
# If the script stops before the copy, tell where the downloaded ISOs are.
trap '[[ -z "$TEMP_ISO_DIR" || ! -d "$TEMP_ISO_DIR" ]] || downloads_kept' EXIT

echo "🚀 Ventoy USB Installer Script"

# Check for version argument or ask interactively
if [[ $# -gt 0 ]]; then
  VENTOY_VERSION="$1"
  VENTOY_VERSION=${VENTOY_VERSION#v}  # Remove leading 'v' if present
  echo "Using specified Ventoy version: $VENTOY_VERSION"
else
  echo "Fetching latest Ventoy version..."
  VENTOY_VERSION=$(curl -s https://api.github.com/repos/ventoy/Ventoy/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
  VENTOY_VERSION=${VENTOY_VERSION#v}  # Remove leading 'v' if present

  if [[ -z "$VENTOY_VERSION" ]]; then
    echo "❌ Failed to retrieve Ventoy version. Check your internet connection."
    exit 1
  fi

  echo "Latest version: $VENTOY_VERSION"
  read -rp "Press Enter to use latest, or enter a specific version: " USER_VERSION
  if [[ -n "$USER_VERSION" ]]; then
    VENTOY_VERSION="$USER_VERSION"
    VENTOY_VERSION=${VENTOY_VERSION#v}
    echo "Using specified version: $VENTOY_VERSION"
  fi
fi

VENTOY_URL="https://github.com/ventoy/Ventoy/releases/download/v$VENTOY_VERSION/ventoy-$VENTOY_VERSION-linux.tar.gz"

echo "📥 Downloading Ventoy $VENTOY_VERSION..."
curl -L -o ventoy.tar.gz "$VENTOY_URL"

if [[ ! -f ventoy.tar.gz ]] || [[ ! -s ventoy.tar.gz ]]; then
  echo "❌ Download failed. Check your internet connection or try again later."
  exit 1
fi

# Verify the downloaded file is a valid tar.gz
if ! tar -tzf ventoy.tar.gz >/dev/null 2>&1; then
  echo "❌ Downloaded file is not a valid tar.gz archive. The Ventoy version or URL may be incorrect."
  echo "URL attempted: $VENTOY_URL"
  exit 1
fi

echo "📦 Extracting Ventoy..."
tar -xzf ventoy.tar.gz

if [[ ! -d "ventoy-$VENTOY_VERSION" ]]; then
  echo "❌ Extraction failed."
  exit 1
fi

cd "ventoy-$VENTOY_VERSION"

# Allow root to write to the directory
sudo chmod -R 755 .

echo "🔍 Detecting removable devices..."
# Refresh block devices
sudo udevadm trigger --subsystem-match=block --action=change
sleep 2
echo

lsblk -o NAME,TRAN,SIZE,MODEL,MOUNTPOINT | grep -E "usb|NAME"

echo
read -rp "Enter USB device (e.g. /dev/sdb): " DEVICE

if [[ ! -b "$DEVICE" ]]; then
  echo "❌ $DEVICE is not a valid block device"
  exit 1
fi

# Check device size
DEVICE_SIZE=$(lsblk -o SIZE -n "$DEVICE" | head -1)
if [[ "$DEVICE_SIZE" == "0B" ]]; then
  echo "⚠️  Warning: Device size reported as 0B. This may indicate the device is not ready or faulty."
  echo "Actual size may be different. Proceed with caution."
fi

if ! lsblk -o TRAN "$DEVICE" | tail -n +2 | grep -q usb; then
  echo "❌ $DEVICE does not appear to be a USB device"
  exit 1
fi

echo
echo "⚠️  WARNING: This will ERASE ALL DATA on $DEVICE"
read -rp "Type YES to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
  echo "Aborted."
  exit 1
fi

echo
read -rp "Do you want to download ISO files from URLs first? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  read -rp "Enter ISO URLs separated by spaces: " -a ISO_URLS
  download_isos "${ISO_URLS[@]}"
  echo "✅ ISO downloads complete."
fi

echo
echo "🚀 Installing Ventoy on $DEVICE, this may take a few minutes ..."
# Unmount any existing partitions on the device
for part in $(lsblk -o NAME "$DEVICE" | tail -n +2 | sed 's/[^a-zA-Z0-9]//g'); do
  sudo umount "/dev/$part" 2>/dev/null || true
done
# Ventoy2Disk asks "Continue? (y/n)" and "Double-check. Continue? (y/n)". After "n" it exits with code 0,
# so only its "successfully finished." message tells that it installed Ventoy.
if ! { VENTOY_OUT=$(sudo ./Ventoy2Disk.sh -I "$DEVICE" | tee /dev/fd/3); } 3>&1 ||
  [[ "$VENTOY_OUT" != *"successfully finished."* ]]; then
  echo "❌ Ventoy was not installed on $DEVICE. See the messages above."
  exit 1
fi
echo "✅ Ventoy installed successfully."

# Verify device is still available
if [[ ! -b "$DEVICE" ]]; then
  echo "❌ Device $DEVICE is no longer available after installation"
  echo "Try unplugging and re-plugging the USB, then run the script again."
  echo "Alternatively, check 'lsblk' for a new device name."
  exit 1
fi

# Re-read partition table
sudo partprobe "$DEVICE"

sleep 3

cd ..
# Ventoy is installed now. A failed ISO copy must not stop the cleanup below.
COPY_STATUS=0
copy_isos_to "$DEVICE" || COPY_STATUS=$?

# Cleanup
rm -rf "ventoy-$VENTOY_VERSION" ventoy.tar.gz

echo
if [[ $COPY_STATUS -ne 0 ]]; then
  echo "⚠️  Ventoy is installed, but not all ISOs were copied. See the messages above."
  exit "$COPY_STATUS"
fi
echo "🎉 Ventoy USB is ready!"
echo "➡️  Boot from this USB and select an ISO to install."
