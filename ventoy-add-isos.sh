#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Ventoy ISO Copy Script"

# choose <prompt> <candidate>...: print the only candidate. If there are more, list them and ask which one to use.
choose() {
  local prompt=$1 answer c
  shift
  if (( $# == 1 )); then
    printf '%s\n' "$1"
    return 0
  fi
  echo "More than one Ventoy USB found:" >&2
  printf '  %s\n' "$@" >&2
  read -rp "$prompt" answer
  for c in "$@"; do
    if [[ "$answer" == "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  echo "❌ $answer is not in the list. Aborted." >&2
  return 1
}

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
    # -r escapes a space in a mount point as \x20: printf %b decodes it.
    mapfile -t found < <(lsblk -nr -o LABEL,MOUNTPOINT | awk '$1=="Ventoy" && $2!=""{print $2}' | while IFS= read -r m; do printf '%b\n' "$m"; done)
    if (( ${#found[@]} == 0 )); then
      echo "❌ No Ventoy mount point found. Please mount the Ventoy USB first."
      exit 1
    fi
    VENTOY_MOUNT=$(choose "Enter the Ventoy mount point to use: " "${found[@]}") || exit 1
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

# A mount point with a line break is an error of the caller (for example, two mount points in one value).
if [[ "$VENTOY_MOUNT" == *$'\n'* ]]; then
  echo "❌ The Ventoy mount point contains a line break. Give one mount point." >&2
  exit 1
fi

# Check if mount point exists and is a directory
if [[ ! -d "$VENTOY_MOUNT" ]]; then
  # Try to find and mount Ventoy partition if mount point doesn't exist
  mapfile -t found < <(lsblk -nrp -o NAME,LABEL | awk '$2=="Ventoy"{print $1}')
  if (( ${#found[@]} > 0 )); then
    VENTOY_PART=$(choose "Enter the Ventoy partition to mount (for example ${found[0]}): " "${found[@]}") || exit 1
    echo "Mount point $VENTOY_MOUNT not found. Attempting to mount Ventoy partition $VENTOY_PART to $VENTOY_MOUNT..."
    sudo mkdir -p "$VENTOY_MOUNT"
    if sudo mount "$VENTOY_PART" "$VENTOY_MOUNT"; then
      echo "✅ Mounted Ventoy at $VENTOY_MOUNT"
    else
      echo "❌ Failed to mount $VENTOY_PART to $VENTOY_MOUNT"
      exit 1
    fi
  else
    echo "❌ Ventoy mount point $VENTOY_MOUNT does not exist or is not a directory, and no Ventoy partition found to mount"
    exit 1
  fi
fi

# Resolve the mount point once: the check below and every write use this same path, also if a link changes later.
VENTOY_MOUNT=$(realpath -- "$VENTOY_MOUNT")
# The path must be the mount point itself (not a folder in it) of a file system with the label Ventoy.
if [[ "$(findmnt -n -o LABEL --mountpoint "$VENTOY_MOUNT" 2>/dev/null)" != Ventoy ]]; then
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

# Never use a path that starts with "-" as an option.
case "$ISO_DIR" in /*) ;; *) ISO_DIR=./$ISO_DIR ;; esac

# The ISO files: .iso in any case, as on Windows. Hidden files are not ISOs to copy. find does not expand the folder name.
mapfile -d '' -t ISOS < <(find "$ISO_DIR" -mindepth 1 -maxdepth 1 -iname '*.iso' ! -name '.*' -print0 | sort -z)
if (( ${#ISOS[@]} == 0 )); then
  echo "⚠️  No .iso files found in $ISO_DIR"
  exit 1
fi

FAT32_MAX=4294967295 # FAT32 file size limit: 4 GiB minus 1 byte.

# kill_tree <pid>: stop a process and all the processes under it.
kill_tree() {
  local kid
  for kid in $(pgrep -P "$1"); do kill_tree "$kid"; done
  kill "$1" 2>/dev/null || true
}
# stop <pid>: stop a background job and all its processes (for a copy, both sides of the pipe).
stop() {
  kill_tree "$1"
  wait "$1" 2>/dev/null || true
}

# Use sudo only for the USB, and only when this user cannot write to the mount (for example, a mount made by root).
# -n: never ask for a password in the middle of a copy. A background job keeps the sudo timestamp fresh.
SUDO=()
SUDO_KEEPALIVE_PID=""
if [[ ! -w "$VENTOY_MOUNT" ]]; then
  SUDO=(sudo -n)
  echo "🔐 $VENTOY_MOUNT is not writable by $(id -un). sudo is necessary to write to it."
  sudo -v
  # With sudo's timestamp_timeout=0, each sudo command asks for the password again, so no copy can work.
  if ! sudo -n true 2>/dev/null; then
    echo "❌ sudo on this computer asks for the password at each command, so the script cannot copy with sudo." >&2
    echo "   Mount the USB as your user (for example, open it in your file manager, or run udisksctl mount -b /dev/<partition>), then run the script again." >&2
    exit 1
  fi
  # The loop stops when this script ends, also when it is killed and cannot stop the loop.
  while kill -0 $$ 2>/dev/null && sudo -n -v; do sleep 60; done >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
fi

# usb_test <test arguments>: test paths on the USB as the user that writes to it, so that a root-only mount works.
# It returns 0 when the test is true, 1 when it is false, and 2 when sudo failed (the result is not known).
usb_test() {
  local r
  r=$("${SUDO[@]}" sh -c 'if test "$@"; then echo 0; else echo 1; fi' sh "$@") || true
  case $r in 0 | 1) return "$r" ;; *) return 2 ;; esac
}
# usb_exists <path>: a file, a folder or a link (also a broken link) is at <path> on the USB.
usb_exists() { usb_test -e "$1" -o -L "$1"; }

FSTYPE=$(findmnt -n -o FSTYPE --target "$VENTOY_MOUNT" 2>/dev/null || true)
TMP_COPY=""
COPY_PID=""

# Stop a running copy and remove its temporary file. Runs after each ISO, on error and on Ctrl+C.
cleanup_copy() {
  if [[ -n "$COPY_PID" ]]; then
    stop "$COPY_PID"
    COPY_PID=""
  fi
  if [[ -n "$TMP_COPY" ]]; then
    "${SUDO[@]}" rm -f -- "$TMP_COPY" || true
    if ! usb_test ! -e "$TMP_COPY" -a ! -L "$TMP_COPY"; then
      echo "⚠️  Could not remove the temporary file $TMP_COPY. Delete it yourself." >&2
    fi
    TMP_COPY=""
  fi
}
on_exit() {
  cleanup_copy
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    stop "$SUDO_KEEPALIVE_PID"
  fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Read the copy from the USB, not from the page cache: O_DIRECT bypasses the cache.
# A small direct read first finds out if the file system supports O_DIRECT ("Invalid argument" in English if not).
# If not, the copy is dropped from the page cache, fincore checks that no page of it stays there, and it is read normally.
# Any other read error fails.
usb_sha256() {
  local hash err pages
  if err=$("${SUDO[@]}" env LC_ALL=C dd if="$1" of=/dev/null iflag=direct bs=4096 count=1 status=none 2>&1); then
    hash=$("${SUDO[@]}" dd if="$1" iflag=direct bs=4M status=none | sha256sum) || return 1
  elif [[ "$err" == *"Invalid argument"* ]]; then
    "${SUDO[@]}" dd if="$1" iflag=nocache count=0 status=none || return 1
    pages=$("${SUDO[@]}" fincore -n -o PAGES -- "$1" 2>/dev/null) || pages=""
    if [[ "${pages// /}" == 0 ]]; then
      echo "   Note: this file system does not support direct reads. The copy is dropped from the page cache and read again from the USB." >&2
    else
      echo "   Note: this file system does not support direct reads. The copy is dropped from the page cache and read again, but the script could not confirm that the cache was dropped. The check can read the cache, not the USB." >&2
    fi
    hash=$("${SUDO[@]}" dd if="$1" bs=4M status=none | sha256sum) || return 1
  else
    echo "$err" >&2
    return 1
  fi
  echo "${hash%% *}"
}

# copy_iso <iso>: return 0 when copied and verified, 2 when skipped, 1 when failed.
# The caller removes the temporary file after each call.
copy_iso() {
  local iso=$1 name dest size avail src_hash copy_hash on_usb="" r=0
  name=$(basename -- "$iso")
  dest=$VENTOY_MOUNT/$name
  echo
  echo "📦 $name"
  if (( ${#SUDO[@]} > 0 )) && ! sudo -n true 2>/dev/null; then
    echo "❌ Failed: sudo needs the password again. Run the script again to copy $name." >&2
    return 1
  fi
  usb_exists "$dest" || r=$?
  if (( r == 2 )); then
    echo "❌ Failed: sudo failed, so the script could not check if $name is on the USB." >&2
    return 1
  elif (( r == 0 )); then
    # On FAT32 and exFAT, a name in another case is the same file: show the name that is on the USB.
    if [[ "$FSTYPE" == vfat || "$FSTYPE" == exfat ]]; then
      on_usb=$("${SUDO[@]}" find "$VENTOY_MOUNT" -mindepth 1 -maxdepth 1 -iname "$(sed 's/[][*?\\]/\\&/g' <<<"$name")" -print -quit 2>/dev/null) || true
    fi
    echo "⏭️  Skipped: ${on_usb:-$dest} already exists. It was not changed. To replace it, delete it first."
    return 2
  fi
  # FAT32 and exFAT do not allow these characters in a file name.
  if [[ "$FSTYPE" == vfat || "$FSTYPE" == exfat ]] && [[ "$name" == *[\"*:\<\>?\\\|]* ]]; then
    echo "❌ Failed: $name has a character that FAT32 and exFAT do not allow in a file name: \" * : < > ? \\ |. Rename the ISO, then run the script again." >&2
    return 1
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
  # Read the ISO as this user. Only the write to the USB uses sudo. { } runs both sides under one job, so stop() stops both.
  { dd if="$iso" bs=4M status=progress | "${SUDO[@]}" dd of="$TMP_COPY" bs=4M status=none; } &
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
  r=0
  usb_exists "$dest" || r=$?
  if (( r == 1 )); then
    r=0
    "${SUDO[@]}" mv -n -T -- "$TMP_COPY" "$dest" || r=1
    if (( r == 0 )); then usb_test ! -e "$TMP_COPY" -a ! -L "$dest" -a -f "$dest" || r=$?; fi
  elif (( r == 0 )); then
    r=1
  fi
  case $r in
    0) ;;
    2) echo "❌ Failed: sudo failed, so the script could not check $dest. Check the USB." >&2; return 1 ;;
    *) echo "❌ Failed: $dest appeared during the copy. It was not changed. The copy was removed." >&2; return 1 ;;
  esac
  TMP_COPY=""
  echo "✅ $name copied and SHA-256 verified."
  return 0
}

copied=() skipped=() failed=()
echo "📦 Copying ISO files from $ISO_DIR to $VENTOY_MOUNT..."
for iso in "${ISOS[@]}"; do
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
# An ISO that is already on the USB is not an error. Only a failed ISO makes the exit code 1.
if (( ${#failed[@]} > 0 )); then
  exit 1
fi
echo "✅ Done. No ISO failed."
