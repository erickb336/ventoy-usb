#!/bin/bash
# macOS entry point. ./ventoy.sh starts this on macOS. No sudo; Bash 3.2.
set -u

here=$(cd "$(dirname "$0")" && pwd)
. "$here/disks.sh"
. "$here/isos.sh"

MACTOY_URL=https://github.com/cashcon57/mactoy/releases

open_mactoy() {
    local app
    echo
    echo "Ventoy has no macOS installer. This tool uses Mactoy, a free app that installs Ventoy on macOS 13.5 or later."
    for app in /Applications/Mactoy.app "$HOME/Applications/Mactoy.app"; do
        if [ -d "$app" ]; then
            echo "Opening $app"
            open -a "$app" || die "Could not open $app."
            break
        fi
        app=""
    done
    if [ -z "$app" ]; then
        echo "Mactoy is not installed. Download the Mactoy .dmg file from:"
        echo "  $MACTOY_URL"
        echo "Open the .dmg file, drag Mactoy to Applications, then open Mactoy."
        open "$MACTOY_URL" 2>/dev/null || echo "Could not open a browser. Open the URL above yourself."
    fi
    cat <<'EOF'

WARNING: Installing Ventoy erases every file on the USB you choose. Back it up first.
In Mactoy:
  1. Connect the USB. Select its card in the sidebar. Check its name and size.
  2. On the "Install Ventoy" tab, keep the defaults: version Latest, MBR, Secure Boot on.
  3. If macOS asks, allow Mactoy in System Settings > General > Login Items ("Allow in the Background").
  4. If Mactoy asks for Full Disk Access, use its button to open System Settings and turn it on.
  5. Confirm the erase only when the USB name and size are correct. Wait until Mactoy has finished.

EOF
    read -r -p "Press Enter when Mactoy has finished, or Ctrl+C to quit " _ || exit 1
}

echo "Ventoy USB Setup (macOS)"
echo "[1] Create a new Ventoy USB (with Mactoy)"
echo "[2] Add ISO to existing Ventoy USB"
read -r -p "Select: " action || exit 1
case "$action" in
    1) open_mactoy ;;
    2) ;;
    *) die "Invalid selection." ;;
esac

echo
mac_select_disk
mac_prepare_volume "$VT_SELECTED_DISK" "$VT_SELECTED_UUID"
echo "Ventoy data volume: $VT_MOUNT ($VT_FS)"
mac_read_iso
if [ -n "$VT_ISO" ]; then
    mac_copy_iso "$VT_SELECTED_DISK" "$VT_SELECTED_UUID" "$VT_ISO"
fi
read -r -p "Eject the USB now? [y/N] " answer || answer=""
case "$answer" in
    y | Y | yes | YES) diskutil eject "$VT_SELECTED_DISK" ;;
    *) echo "Eject the USB in Finder before you unplug it." ;;
esac
