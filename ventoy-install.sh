#!/usr/bin/env bash
set -euo pipefail

# copy_isos_to <device>: copy the ISOs to the Ventoy partition of <device>, the USB that this script installed.
# It never uses a Ventoy USB of another device. It keeps the downloaded ISOs (TEMP_ISO_DIR) unless all of them were copied.
# It returns 0 when the copy is complete.
copy_isos_to() {
  local device=$1 parts=() mount="" own_mount="" iso_dir status=0
  mapfile -t parts < <(lsblk -nr -o PATH,LABEL "$device" | awk '$2=="Ventoy"{print $1}')
  if (( ${#parts[@]} != 1 )); then
    echo "❌ Expected 1 partition with the label Ventoy on $device, found ${#parts[@]}. No ISO was copied." >&2
    status=1
  else
    mount=$(findmnt -n -f -o TARGET --source "${parts[0]}" || true)
    if [[ -z "$mount" ]]; then
      echo "Ventoy partition ${parts[0]} is not mounted. Mounting it..."
      own_mount=$(mktemp -d "${TMPDIR:-/tmp}/ventoy.XXXXXX")
      if sudo mount "${parts[0]}" "$own_mount"; then
        mount=$own_mount
      else
        echo "❌ Could not mount ${parts[0]}. No ISO was copied." >&2
        rmdir "$own_mount"
        own_mount=""
        status=1
      fi
    fi
  fi

  if (( status == 0 )); then
    echo "📂 Ventoy partition ${parts[0]} is mounted at: $mount"
    if [[ -n "${TEMP_ISO_DIR:-}" ]]; then
      ./ventoy-add-isos.sh "$mount" "$TEMP_ISO_DIR" || status=$?
    else
      echo
      read -rp "Optional: directory containing ISO files (leave empty to skip): " iso_dir
      if [[ -n "$iso_dir" ]]; then
        ./ventoy-add-isos.sh "$mount" "$iso_dir" || status=$?
      fi
    fi
    echo "🔄 Syncing data to USB..."
    sync
  fi

  if [[ -n "$own_mount" ]]; then
    if sudo umount "$own_mount"; then
      rmdir "$own_mount"
      mount=""
    else
      echo "⚠️  Could not unmount $own_mount. Unmount it before you remove the USB." >&2
    fi
  fi
  if [[ -n "${TEMP_ISO_DIR:-}" ]]; then
    if (( status == 0 )); then
      rm -rf "$TEMP_ISO_DIR"
    else
      echo "📁 Not all downloaded ISOs were copied. The script kept all of them in $TEMP_ISO_DIR" >&2
      echo "   To copy them later, mount the USB and run: ./ventoy-add-isos.sh ${mount:-<Ventoy mount point>} $TEMP_ISO_DIR" >&2
    fi
  fi
  return "$status"
}

# Tests source this file to call the function above. Then nothing below runs.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

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
  TEMP_ISO_DIR=$(mktemp -d)
  echo "📥 Downloading ISOs to $TEMP_ISO_DIR..."
  for url in "${ISO_URLS[@]}"; do
    filename=$(basename "$url")
    echo "Downloading $filename..."
    curl -L -o "$TEMP_ISO_DIR/$filename" "$url"
  done
  echo "✅ ISO downloads complete."
fi

echo
echo "🚀 Installing Ventoy on $DEVICE, this may take a few minutes ..."
# Unmount any existing partitions on the device
for part in $(lsblk -o NAME "$DEVICE" | tail -n +2 | sed 's/[^a-zA-Z0-9]//g'); do
  sudo umount "/dev/$part" 2>/dev/null || true
done
sudo ./Ventoy2Disk.sh -I "$DEVICE"

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
