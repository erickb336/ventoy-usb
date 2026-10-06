# ISO selection and verified copy for macOS. Source after disks.sh; Bash 3.2.

VT_FAT32_MAX=4294967295 # FAT32 limit: 4 GiB minus 1 byte.
VT_WIN11_URL=https://www.microsoft.com/software-download/windows11

# Turn typed or pasted text into a path. It accepts surrounding quotes,
# paths dragged from Finder (spaces escaped with a backslash) and a leading ~.
mac_parse_path() {
    local p=$1
    p=${p#"${p%%[![:space:]]*}"}
    p=${p%"${p##*[![:space:]]}"}
    case "$p" in
        \"*\") p=${p#\"}; p=${p%\"} ;;
        \'*\') p=${p#\'}; p=${p%\'} ;;
        *) p=$(printf '%s' "$p" | sed 's/\\\(.\)/\1/g') ;;
    esac
    case "$p" in
        "~") p=$HOME ;;
        "~/"*) p=$HOME/${p#"~/"} ;;
    esac
    printf '%s\n' "$p"
}

# Succeed for an existing, nonempty, regular .iso file.
mac_is_iso() {
    case "$1" in
        *.[iI][sS][oO]) [ -f "$1" ] && [ -s "$1" ] ;;
        *) return 1 ;;
    esac
}

# ISO menu. Set VT_ISO to the chosen path, or to "" for Skip.
mac_read_iso() {
    local choice line
    VT_ISO=""
    echo
    echo "ISO: [1] Windows 11  [2] Local ISO  [3] Skip"
    read -r -p "Select: " choice || die "No selection."
    case "$choice" in
        1)
            echo "Download the Windows 11 disk image (ISO) to this Mac: $VT_WIN11_URL"
            echo "Choose the architecture of the target PC: x64 for an Intel or AMD PC, Arm64 for an Arm PC."
            echo "Watch progress in the browser's Downloads list (Option-Command-L in Safari or Chrome)."
            echo "This terminal cannot see the browser download. Wait until it is complete."
            echo "Do not open the ISO. Drag the finished file into this window, or type its path."
            open "$VT_WIN11_URL" 2>/dev/null || echo "Could not open a browser. Open the URL above yourself."
            ;;
        2) ;;
        3) return 0 ;;
        *) die "Invalid ISO selection." ;;
    esac
    echo "Waiting for your ISO path. USB copying starts only after you enter it."
    read -r -p "ISO path (drag the file here, quotes optional): " line || die "No path."
    VT_ISO=$(mac_parse_path "$line")
    mac_is_iso "$VT_ISO" || die "Select an existing, nonempty .iso file (not a folder or an unfinished download): $VT_ISO"
}

mac_progress() { # <copied bytes> <total bytes> <elapsed seconds>
    awk -v c="$1" -v t="$2" -v e="$3" 'BEGIN {
        if (e < 1) e = 1
        r = c / e; p = (t > 0) ? int(100 * c / t) : 100
        eta = (r > 0) ? int((t - c) / r) : 0
        printf "\r  %3d%% | %.2f / %.2f GiB | %.1f MiB/s | ETA %dm%02ds  ", p, c / 2^30, t / 2^30, r / 2^20, eta / 60, eta % 60
    }'
}

mac_sha256() {
    shasum -a 256 <"$1" | awk '{ print $1 }'
}

# Remove the temp file after Ctrl+C or an error. Set as the EXIT trap during a copy.
mac_copy_cleanup() {
    if [ -n "${VT_COPY_PID:-}" ]; then
        kill "$VT_COPY_PID" 2>/dev/null
        wait "$VT_COPY_PID" 2>/dev/null
        VT_COPY_PID=""
    fi
    if [ -n "${VT_TMP:-}" ]; then
        rm -f "$VT_TMP"
        [ -e "$VT_TMP" ] && echo "Could not remove the temporary file $VT_TMP. Delete it yourself." >&2
        VT_TMP=""
    fi
}

# mac_copy_iso <disk> <volume uuid> <iso> [scope]: copy <iso> to the Ventoy data volume and verify it.
mac_copy_iso() {
    local disk=$1 uuid=$2 iso=$3 scope=${4:-physical}
    local name dest size mount avail start copied tmpname src_hash copy_hash
    mac_is_iso "$iso" || die "Select an existing, nonempty .iso file: $iso"
    mac_prepare_volume "$disk" "$uuid" "$scope"
    mount=$VT_MOUNT
    name=$(basename "$iso")
    dest=$mount/$name
    size=$(stat -f %z "$iso")
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        die "Already exists: $dest. Rename or remove it yourself, then run again."
    fi
    if [ "$VT_FS" = FAT32 ] && [ "$size" -gt "$VT_FAT32_MAX" ]; then
        die "This ISO is larger than the FAT32 file size limit (4 GiB). Use a Ventoy USB with exFAT (the default)."
    fi
    avail=$(df -k "$mount" | awk 'NR == 2 { print $4 }')
    if [ "$((avail * 1024))" -lt "$size" ]; then
        die "Not enough free space on $mount."
    fi

    echo "Copying $iso to /dev/$disk, $dest"
    # Recheck the disk and volume immediately before the first write.
    mac_same_volume "$disk" "$uuid" "$mount" "$scope" || die "The USB changed. Run again and select the USB again."
    trap mac_copy_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    VT_TMP=$(mktemp "$mount/.ventoy-copy-XXXXXX") || die "Could not create a temporary file on $mount."

    echo "[1/3] Copying ISO to USB..."
    start=$SECONDS
    cat "$iso" >"$VT_TMP" &
    VT_COPY_PID=$!
    while kill -0 "$VT_COPY_PID" 2>/dev/null; do
        copied=$(stat -f %z "$VT_TMP" 2>/dev/null) || copied=0
        mac_progress "$copied" "$size" $((SECONDS - start))
        sleep 0.25
    done
    wait "$VT_COPY_PID" || die "Copy failed."
    VT_COPY_PID=""
    copied=$(stat -f %z "$VT_TMP")
    mac_progress "$copied" "$size" $((SECONDS - start))
    echo
    [ "$copied" = "$size" ] || die "Copy is incomplete."
    echo "Flushing data to the USB. Please wait..."
    sync

    # Unmount and mount again, so the hash reads the USB and not the cache.
    tmpname=$(basename "$VT_TMP")
    diskutil unmount "$VT_PART" >/dev/null || die "Could not unmount /dev/$VT_PART to verify the copy."
    if ! diskutil mount "$VT_PART" >/dev/null; then
        VT_TMP=""
        die "Could not mount /dev/$VT_PART again. Mount it, then delete $tmpname from its top folder."
    fi
    mac_ventoy_disk "$disk" "$scope" && [ "$VT_UUID" = "$uuid" ] && [ -n "$VT_MOUNT" ] ||
        { VT_TMP=""; die "The USB changed during the copy. Delete $tmpname from its top folder."; }
    mount=$VT_MOUNT
    dest=$mount/$name
    VT_TMP=$mount/$tmpname

    echo "[2/3] Reading source ISO for SHA-256 verification..."
    src_hash=$(mac_sha256 "$iso")
    echo "[3/3] Reading USB copy for SHA-256 verification. Keep the USB connected..."
    copy_hash=$(mac_sha256 "$VT_TMP")
    [ -n "$src_hash" ] && [ "$src_hash" = "$copy_hash" ] || die "Copied ISO checksum mismatch."
    mv -n "$VT_TMP" "$dest"
    [ -e "$VT_TMP" ] && die "Already exists: $dest. It appeared during the copy; the copy was removed."
    VT_TMP=""
    trap - EXIT INT TERM
    echo "ISO copied and SHA-256 verified."
}
