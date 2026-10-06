#!/usr/bin/env bash
set -euo pipefail

# fetch <url> [curl option]...: download over https only. A redirect to http stops the download.
# -q (the first option) ignores ~/.curlrc, so that a setting there cannot change the download or its verification.
fetch() {
  curl -q -fL --proto =https --proto-redir =https "${@:2}" "$1"
}

# release_digest <version>: print the SHA-256 that the GitHub release gives for ventoy-<version>-linux.tar.gz
# (the asset's "digest" field, as the Windows installer uses it). It prints nothing when the release has no digest.
# python3 parses the JSON when it is installed; otherwise awk reads the release as the API prints it, one field per line.
release_digest() {
  local json
  json=$(fetch "https://api.github.com/repos/ventoy/Ventoy/releases/tags/v$1" -sS -H 'Accept: application/vnd.github+json') || return 1
  if command -v python3 >/dev/null; then
    python3 -c 'import json, sys
for asset in json.load(sys.stdin).get("assets", []):
    if asset.get("name") == sys.argv[1]:
        print(asset.get("digest") or "")' "ventoy-$1-linux.tar.gz" <<<"$json"
  else
    awk -v name="\"ventoy-$1-linux.tar.gz\"," '
      $1 == "\"name\":" { asset = ($2 == name) }
      asset && $1 == "\"digest\":" { print $2; exit }' <<<"$json"
  fi | sed -n -E 's/^"?sha256:([0-9a-fA-F]{64})"?,?$/\1/p' | tr 'A-F' 'a-f'
}

# url_decode <text>: print <text> with each %XX code decoded (Win%2011 becomes Win 11).
url_decode() {
  local s=$1 out=""
  if command -v python3 >/dev/null; then
    python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "$s"
    return
  fi
  while [[ "$s" =~ ^([^%]*)%([0-9a-fA-F]{2})(.*)$ ]]; do
    out+=${BASH_REMATCH[1]}$(printf "\\x${BASH_REMATCH[2]}")
    s=${BASH_REMATCH[3]}
  done
  printf '%s\n' "$out$s"
}

# download_isos <url>...: download the ISOs into a new folder, TEMP_ISO_DIR. Each file gets a name that ends in .iso,
# so that ventoy-add-isos.sh copies it. An http URL, a name that would be hidden, or two URLs with the same file name,
# stop the script before any download. A download goes to <name>.part and gets its name only when it is complete,
# so the folder never holds a truncated .iso.
download_isos() {
  local url name names=() urls=("$@") n i part
  for url in "$@"; do
    if [[ "${url,,}" != https://* ]]; then
      echo "❌ Only https URLs are allowed: $url. Aborted." >&2
      return 1
    fi
    name=${url%%#*}
    name=${name%%\?*}
    name=${name##*/}
    [[ -n "$name" ]] || name=download
    name=$(url_decode "$name")
    [[ "${name,,}" == *.iso ]] || name=$name.iso
    if [[ "$name" == .* || "$name" == */* ]]; then
      echo "❌ The URL $url gives the file name $name, which is hidden or has a slash, so it cannot be copied to the USB. Aborted." >&2
      return 1
    fi
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
    part=$TEMP_ISO_DIR/${names[i]}.part
    url=${urls[i]}
    if ! fetch "$url" -o "$part"; then
      rm -f -- "$part"
      echo "❌ Download failed: $url. Check the URL and your internet connection, then run the script again." >&2
      return 1
    fi
    mv -- "$part" "$TEMP_ISO_DIR/${names[i]}"
  done
}

# downloads_kept [mount]: tell where the downloaded ISOs are and how to copy them later. [mount]: the Ventoy mount, if it is still mounted.
# An empty folder (no download was complete) is removed instead.
downloads_kept() {
  if rmdir -- "$TEMP_ISO_DIR" 2>/dev/null; then
    return 0
  fi
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
  local device=$1 parts=() mount="" own_mount="" iso_dir=${TEMP_ISO_DIR:-} status=0 f on_usb
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
        # A mount that only root can read (umask=077) needs sudo for the check, as the copy did.
        if [[ -r "$mount" ]]; then on_usb=$([[ -e "$mount/$f" ]] && echo 1 || echo 0); else on_usb=$(sudo test -e "$mount/$f" && echo 1 || echo 0); fi
        if (( on_usb == 0 )); then
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

echo "🚀 Ventoy USB Installer Script"

MISSING=""
for tool in sha256sum curl tar lsblk findmnt; do
  command -v "$tool" >/dev/null || MISSING="$MISSING $tool"
done
if [[ -n "$MISSING" ]]; then
  echo "❌ These programs are not installed:$MISSING. Install them, then run the script again."
  exit 1
fi

# Only the downloads of this run, never a TEMP_ISO_DIR from the environment.
TEMP_ISO_DIR=""
# The Ventoy package is downloaded, verified, extracted and run in a private folder that only this user can read.
# It is removed at the end, also after an error. If the script stops before the copy, tell where the downloaded ISOs are.
START_DIR=$PWD
WORK_DIR=$(mktemp -d)
cleanup() {
  [[ -z "$TEMP_ISO_DIR" || ! -d "$TEMP_ISO_DIR" ]] || downloads_kept
  cd "$START_DIR"
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

# Arguments: [version] [--sha256 <hex>]. --sha256 gives the expected SHA-256 of the package yourself,
# for a release that has no digest. It needs an explicit version. There is no way to skip the verification.
VENTOY_VERSION="" EXPECTED_SHA256=""
while (( $# )); do
  case $1 in
    --sha256)
      EXPECTED_SHA256=$(tr 'A-F' 'a-f' <<<"${2:-}")
      if [[ ! "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        echo "❌ --sha256 needs the 64 hex characters of the expected SHA-256."
        exit 1
      fi
      shift ;;
    -*) echo "❌ Unknown option: $1. Usage: ./ventoy-install.sh [version] [--sha256 <hex>]"; exit 1 ;;
    *) VENTOY_VERSION=${1#v} ;;  # Remove leading 'v' if present
  esac
  shift
done

if [[ -n "$VENTOY_VERSION" ]]; then
  echo "Using specified Ventoy version: $VENTOY_VERSION"
elif [[ -n "$EXPECTED_SHA256" ]]; then
  echo "❌ --sha256 needs an explicit version: ./ventoy-install.sh <version> --sha256 <hex>"
  exit 1
else
  echo "Fetching latest Ventoy version..."
  # || true: a failed request gives an empty version and the message below, not a silent stop.
  VENTOY_VERSION=$(fetch https://api.github.com/repos/ventoy/Ventoy/releases/latest -sS | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || true)
  VENTOY_VERSION=${VENTOY_VERSION#v}  # Remove leading 'v' if present

  if [[ -z "$VENTOY_VERSION" ]]; then
    echo "❌ Failed to retrieve Ventoy version. Check your internet connection."
    echo "   GitHub also limits the requests of its API (error 403): wait an hour, or give the version yourself: ./ventoy-install.sh 1.1.17"
    exit 1
  fi

  echo "Latest version: $VENTOY_VERSION"
  read -rp "Press Enter to use latest, or enter a specific version: " USER_VERSION
  if [[ -n "$USER_VERSION" ]]; then
    VENTOY_VERSION=${USER_VERSION#v}
    echo "Using specified version: $VENTOY_VERSION"
  fi
fi

if [[ ! "$VENTOY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ $VENTOY_VERSION is not a Ventoy version such as 1.1.17."
  exit 1
fi

VENTOY_URL="https://github.com/ventoy/Ventoy/releases/download/v$VENTOY_VERSION/ventoy-$VENTOY_VERSION-linux.tar.gz"

# The package runs as root later, so its SHA-256 must match the digest of the GitHub release (or the --sha256 that you gave)
# before anything extracts or runs it. Without a digest, the install stops: there is no way to skip this check.
if [[ -z "$EXPECTED_SHA256" ]]; then
  echo "🔍 Reading the SHA-256 of Ventoy $VENTOY_VERSION from the GitHub release..."
  if ! EXPECTED_SHA256=$(release_digest "$VENTOY_VERSION") || [[ -z "$EXPECTED_SHA256" ]]; then
    echo "❌ The GitHub release v$VENTOY_VERSION gives no SHA-256 digest for ventoy-$VENTOY_VERSION-linux.tar.gz, so the download cannot be verified."
    echo "   Check the version and your internet connection, then retry. Do not bypass the verification."
    echo "   If you have the SHA-256 from a source that you trust: ./ventoy-install.sh $VENTOY_VERSION --sha256 <hex>"
    exit 1
  fi
fi

cd "$WORK_DIR"
echo "📥 Downloading Ventoy $VENTOY_VERSION..."
if ! fetch "$VENTOY_URL" -o ventoy.tar.gz || [[ ! -s ventoy.tar.gz ]]; then
  echo "❌ Download failed. Check the version, your internet connection, or try again later."
  echo "URL attempted: $VENTOY_URL"
  exit 1
fi

ACTUAL_SHA256=$(sha256sum ventoy.tar.gz | cut -d' ' -f1)
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "❌ SHA-256 mismatch for ventoy-$VENTOY_VERSION-linux.tar.gz. The download was removed and nothing was installed."
  echo "   expected: $EXPECTED_SHA256"
  echo "   got:      $ACTUAL_SHA256"
  echo "   Retry the download. Do not bypass the verification."
  exit 1
fi
echo "✅ SHA-256 verified."

echo "📦 Extracting Ventoy..."
if ! tar -xzf ventoy.tar.gz || [[ ! -d "ventoy-$VENTOY_VERSION" ]]; then
  echo "❌ Extraction failed. The package could not be unpacked (a damaged download, or no space left in $WORK_DIR). Nothing was installed. Run the script again."
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
  if (( ${#ISO_URLS[@]} == 0 )); then
    echo "No URL given. You can give a local ISO folder after the install."
  else
    download_isos "${ISO_URLS[@]}"
    echo "✅ ISO downloads complete."
  fi
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

cd "$START_DIR"
# Ventoy is installed now. A failed ISO copy must not stop the cleanup.
COPY_STATUS=0
copy_isos_to "$DEVICE" || COPY_STATUS=$?

echo
if [[ $COPY_STATUS -ne 0 ]]; then
  echo "⚠️  Ventoy is installed, but not all ISOs were copied. See the messages above."
  exit "$COPY_STATUS"
fi
echo "🎉 Ventoy USB is ready!"
echo "➡️  Boot from this USB and select an ISO to install."
