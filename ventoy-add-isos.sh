#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Ventoy ISO Copy Script"

# Check arguments
if [[ $# -eq 2 ]]; then
  VENTOY_MOUNT="$1"
  ISO_DIR="$2"
elif [[ $# -eq 0 ]]; then
  # Interactive mode
  echo "This script copies ISO files to an existing Ventoy USB drive."
  echo
  read -rp "Enter Ventoy mount point (leave empty to auto-detect): " VENTOY_MOUNT
  if [[ -z "$VENTOY_MOUNT" ]]; then
    # Auto-detect Ventoy mount
    VENTOY_MOUNT=$(lsblk -o LABEL,MOUNTPOINT | awk '$1=="Ventoy"{print $2}' | head -1)
    if [[ -z "$VENTOY_MOUNT" ]]; then
      echo "❌ No Ventoy mount point found. Please mount the Ventoy USB first."
      exit 1
    fi
    echo "Auto-detected Ventoy mount at: $VENTOY_MOUNT"
  fi
  read -rp "Enter directory containing ISO files: " ISO_DIR
  if [[ -z "$ISO_DIR" ]]; then
    echo "❌ ISO directory cannot be empty."
    exit 1
  fi
else
  echo "Usage: $0 [ventoy_mount_point] [iso_directory]"
  echo "If no arguments provided, runs in interactive mode."
  echo "Example: $0 /mnt/ventoy /./isos"
  exit 1
fi

# Check if mount point exists and is a directory
if [[ ! -d "$VENTOY_MOUNT" ]]; then
  # Try to find and mount Ventoy partition if mount point doesn't exist
  VENTOY_PART=$(lsblk -o NAME,LABEL --noheadings | awk '$2=="Ventoy"{print $1}' | sed 's/[^a-zA-Z0-9]*//g' | head -1)
  if [[ -n "$VENTOY_PART" ]]; then
    echo "Mount point $VENTOY_MOUNT not found. Attempting to mount Ventoy partition /dev/$VENTOY_PART to $VENTOY_MOUNT..."
    sudo mkdir -p "$VENTOY_MOUNT"
    if sudo mount "/dev/$VENTOY_PART" "$VENTOY_MOUNT"; then
      echo "✅ Mounted Ventoy at $VENTOY_MOUNT"
    else
      echo "❌ Failed to mount /dev/$VENTOY_PART to $VENTOY_MOUNT"
      exit 1
    fi
  else
    echo "❌ Ventoy mount point $VENTOY_MOUNT does not exist or is not a directory, and no Ventoy partition found to mount"
    exit 1
  fi
fi

# Check if it's actually a Ventoy mount (optional, but good)
if ! lsblk -o LABEL,MOUNTPOINT | grep -q "Ventoy.*$VENTOY_MOUNT"; then
  echo "⚠️  Warning: $VENTOY_MOUNT does not appear to be a Ventoy mount point"
  read -rp "Continue anyway? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# Check if ISO directory exists
if [[ ! -d "$ISO_DIR" ]]; then
  echo "❌ ISO directory $ISO_DIR does not exist"
  exit 1
fi

# Check for ISO files
if ! compgen -G "$ISO_DIR/*.iso" > /dev/null; then
  echo "⚠️  No .iso files found in $ISO_DIR"
  exit 1
fi

# Never use a path that starts with "-" as an option.
case "$VENTOY_MOUNT" in /*) ;; *) VENTOY_MOUNT=./$VENTOY_MOUNT ;; esac
case "$ISO_DIR" in /*) ;; *) ISO_DIR=./$ISO_DIR ;; esac

FAT32_MAX=4294967295 # FAT32 file size limit: 4 GiB minus 1 byte.

# Use sudo only when this user cannot write to the mount (for example, a mount made by root).
SUDO=()
if [[ ! -w "$VENTOY_MOUNT" ]]; then
  SUDO=(sudo)
  echo "🔐 $VENTOY_MOUNT is not writable by $(id -un). sudo is necessary to write to it."
  sudo -v
fi

FSTYPE=$(findmnt -n -o FSTYPE --target "$VENTOY_MOUNT" 2>/dev/null || true)
TMP_COPY=""
COPY_PID=""

# Stop a running copy and remove its temporary file. Runs after each ISO, on error and on Ctrl+C.
cleanup_copy() {
  if [[ -n "$COPY_PID" ]]; then
    kill "$COPY_PID" 2>/dev/null || true
    wait "$COPY_PID" 2>/dev/null || true
    COPY_PID=""
  fi
  if [[ -n "$TMP_COPY" ]]; then
    "${SUDO[@]}" rm -f -- "$TMP_COPY" || true
    if [[ -e "$TMP_COPY" ]]; then
      echo "⚠️  Could not remove the temporary file $TMP_COPY. Delete it yourself." >&2
    fi
    TMP_COPY=""
  fi
}
trap cleanup_copy EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Read the copy from the USB, not from the page cache: O_DIRECT bypasses the cache.
# Some file systems do not support O_DIRECT. Then read normally after the sync.
usb_sha256() {
  local hash
  if hash=$("${SUDO[@]}" dd if="$1" iflag=direct bs=4M status=none 2>/dev/null | sha256sum); then
    echo "${hash%% *}"
  else
    echo "   Note: direct read is not supported here. Reading the copy through the page cache." >&2
    hash=$("${SUDO[@]}" cat -- "$1" | sha256sum) || return 1
    echo "${hash%% *}"
  fi
}

# copy_iso <iso>: return 0 when copied and verified, 2 when skipped, 1 when failed.
# The caller removes the temporary file after each call.
copy_iso() {
  local iso=$1 name dest size avail src_hash copy_hash
  name=$(basename -- "$iso")
  dest=$VENTOY_MOUNT/$name
  echo
  echo "📦 $name"
  if [[ -e "$dest" || -L "$dest" ]]; then
    echo "⏭️  Skipped: $dest already exists. It was not changed. To replace it, delete it first."
    return 2
  fi
  if [[ ! -f "$iso" || ! -s "$iso" ]]; then
    echo "❌ Failed: $iso is not a nonempty regular file." >&2
    return 1
  fi
  size=$(stat -L -c %s -- "$iso") || return 1
  if [[ "$FSTYPE" == vfat && "$size" -gt "$FAT32_MAX" ]]; then
    echo "❌ Failed: $name is larger than the FAT32 file size limit (4 GiB). Use a Ventoy USB with exFAT (the default)." >&2
    return 1
  fi
  avail=$(df -P -k -- "$VENTOY_MOUNT" | awk 'NR == 2 { print $4 }') || return 1
  if (( avail * 1024 < size )); then
    echo "❌ Failed: not enough free space on $VENTOY_MOUNT for $name ($size bytes, $((avail * 1024)) bytes free)." >&2
    return 1
  fi

  TMP_COPY=$("${SUDO[@]}" mktemp -- "$VENTOY_MOUNT/.ventoy-copy-XXXXXX") || {
    TMP_COPY=""
    echo "❌ Failed: could not create a temporary file on $VENTOY_MOUNT." >&2
    return 1
  }
  echo "[1/3] Copying ISO to USB..."
  "${SUDO[@]}" dd if="$iso" of="$TMP_COPY" bs=4M status=progress &
  COPY_PID=$!
  if ! wait "$COPY_PID"; then
    COPY_PID=""
    echo "❌ Failed: the copy of $name stopped with an error." >&2
    return 1
  fi
  COPY_PID=""
  echo "🔄 Flushing data to the USB. Please wait..."
  sync

  echo "[2/3] Reading source ISO for SHA-256 verification..."
  src_hash=$(sha256sum <"$iso") || return 1
  src_hash=${src_hash%% *}
  echo "[3/3] Reading USB copy for SHA-256 verification. Keep the USB connected..."
  copy_hash=$(usb_sha256 "$TMP_COPY") || {
    echo "❌ Failed: could not read the copy of $name." >&2
    return 1
  }
  if [[ -z "$src_hash" || "$src_hash" != "$copy_hash" ]]; then
    echo "❌ Failed: SHA-256 mismatch for $name. The copy was removed." >&2
    return 1
  fi

  # -T: never move into a folder. -n: never replace a file that appeared during the copy.
  if [[ -e "$dest" || -L "$dest" ]] ||
    ! "${SUDO[@]}" mv -n -T -- "$TMP_COPY" "$dest" ||
    [[ -e "$TMP_COPY" || -L "$dest" || ! -f "$dest" ]]; then
    echo "❌ Failed: $dest appeared during the copy. It was not changed. The copy was removed." >&2
    return 1
  fi
  TMP_COPY=""
  echo "✅ $name copied and SHA-256 verified."
  return 0
}

copied=() skipped=() failed=()
echo "📦 Copying ISO files from $ISO_DIR to $VENTOY_MOUNT..."
for iso in "$ISO_DIR"/*.iso; do
  status=0
  copy_iso "$iso" || status=$?
  cleanup_copy
  case $status in
    0) copied+=("$(basename -- "$iso")") ;;
    2) skipped+=("$(basename -- "$iso")") ;;
    *) failed+=("$(basename -- "$iso")") ;;
  esac
done

echo
echo "Summary: ${#copied[@]} copied and SHA-256 verified, ${#skipped[@]} skipped (already on the USB), ${#failed[@]} failed."
for n in "${copied[@]}"; do echo "  ✅ copied:  $n"; done
for n in "${skipped[@]}"; do echo "  ⏭️  skipped: $n"; done
for n in "${failed[@]}"; do echo "  ❌ failed:  $n"; done
if (( ${#skipped[@]} + ${#failed[@]} > 0 )); then
  exit 1
fi
echo "✅ ISO files copied successfully!"
