# Ventoy USB discovery and identity checks for macOS. Source this file; Bash 3.2.
# Facts come from `diskutil ... -plist`, parsed with plutil, never from human output.
#
# A "scope" argument selects which disks are allowed:
#   physical (default)  only disks in `diskutil list -plist external physical`
#   any                 also virtual disks (the tests use this for hdiutil images)

VT_EFI_SIZE=33554432 # Ventoy's VTOYEFI partition is exactly 32 MiB.

die() {
    echo "Error: $(mac_clean "$*")" >&2
    exit 1
}

# Print $1 without control characters (C0, DEL and UTF-8 C1), so that a USB name
# cannot send escape sequences to the terminal. Use it on text that the USB sets.
mac_clean() {
    printf '%s' "$1" | LC_ALL=C sed $'s/\xc2[\x80-\x9f]//g' | LC_ALL=C tr -d '\000-\037\177'
}

# plist_get <plist text> <key path>: print the raw value, or fail if the key is absent.
plist_get() {
    printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null
}

# Print one whole-disk id per line from `diskutil list -plist external physical`.
mac_external_disks() {
    local list i=0 disk
    list=$(diskutil list -plist external physical 2>/dev/null) || return 0
    while disk=$(plist_get "$list" "WholeDisks.$i"); do
        echo "$disk"
        i=$((i + 1))
    done
}

# mac_ventoy_disk <disk> [scope]: check that <disk> has the Ventoy layout.
# On success, set VT_DISK VT_MEDIA VT_SIZE VT_PART VT_FS VT_LABEL VT_UUID VT_MOUNT VT_WRITABLE.
# On failure, set VT_REASON and return 1.
mac_ventoy_disk() {
    local disk=$1 scope=${2:-physical} info efi data fsname
    VT_REASON="Disk $disk is not a Ventoy USB."
    if [ "$scope" != any ] && ! case " $(echo $(mac_external_disks)) " in *" $disk "*) true ;; *) false ;; esac; then
        VT_REASON="Disk $disk is not an external physical disk (or it was disconnected)."
        return 1
    fi
    info=$(diskutil info -plist "$disk" 2>/dev/null) || { VT_REASON="Disk $disk is not connected."; return 1; }
    [ "$(plist_get "$info" WholeDisk)" = true ] || return 1
    [ "$(plist_get "$info" Internal)" = false ] || { VT_REASON="Disk $disk is internal."; return 1; }
    [ "$(plist_get "$info" WritableMedia)" = true ] || { VT_REASON="Disk $disk is read-only."; return 1; }
    VT_SIZE=$(plist_get "$info" Size) || return 1
    [ "$VT_SIZE" -gt 0 ] 2>/dev/null || return 1
    VT_MEDIA=$(mac_clean "$(plist_get "$info" MediaName)")

    efi=$(diskutil info -plist "${disk}s2" 2>/dev/null) || return 1
    [ "$(plist_get "$efi" ParentWholeDisk)" = "$disk" ] &&
        [ "$(plist_get "$efi" VolumeName)" = VTOYEFI ] &&
        [ "$(plist_get "$efi" FilesystemType)" = msdos ] &&
        [ "$(plist_get "$efi" Size)" = "$VT_EFI_SIZE" ] || return 1

    data=$(diskutil info -plist "${disk}s1" 2>/dev/null) || return 1
    [ "$(plist_get "$data" ParentWholeDisk)" = "$disk" ] || return 1
    fsname=$(plist_get "$data" FilesystemName) || fsname=""
    case "$(plist_get "$data" FilesystemType)" in
        exfat) VT_FS=exFAT ;;
        ntfs) VT_FS=NTFS ;;
        msdos) [ "$fsname" = "MS-DOS FAT32" ] || return 1; VT_FS=FAT32 ;;
        *) return 1 ;;
    esac
    VT_UUID=$(plist_get "$data" VolumeUUID) || return 1
    VT_LABEL=$(mac_clean "$(plist_get "$data" VolumeName)")
    VT_MOUNT=$(plist_get "$data" MountPoint) || VT_MOUNT=""
    VT_WRITABLE=$(plist_get "$data" WritableVolume) || VT_WRITABLE=false
    VT_PART=${disk}s1
    VT_DISK=$disk
    VT_REASON=""
}

# List eligible disks as [n] and set VT_CAND_DISKS / VT_CAND_UUIDS (index n-1).
mac_list_ventoy_disks() {
    local scope=${1:-physical} disk n=0
    VT_CAND_DISKS=()
    VT_CAND_UUIDS=()
    for disk in $(mac_external_disks); do
        mac_ventoy_disk "$disk" "$scope" || continue
        VT_CAND_DISKS[$n]=$disk
        VT_CAND_UUIDS[$n]=$VT_UUID
        n=$((n + 1))
        printf '[%d] /dev/%s | %s | %s GiB | data: %s (%s)\n' "$n" "$disk" "${VT_MEDIA:-unknown}" \
            "$(awk -v s="$VT_SIZE" 'BEGIN { printf "%.2f", s / 1073741824 }')" "${VT_LABEL:-no name}" "$VT_FS"
    done
}

# mac_select_disk [hint] [scope]: ask for a list number. Set VT_SELECTED_DISK and VT_SELECTED_UUID.
# <hint> follows "No Ventoy USB found." when no disk is eligible.
mac_select_disk() {
    local hint=${1:-Connect the USB and run again, or use option 1 to create one.} scope=${2:-physical} answer
    echo "Ventoy USB disks:"
    mac_list_ventoy_disks "$scope"
    if [ "${#VT_CAND_DISKS[@]}" -eq 0 ]; then
        die "No Ventoy USB found. $hint"
    fi
    read -r -p "Select USB by list number: " answer || die "No selection."
    case "$answer" in
        '' | *[!0-9]*) die "Invalid USB selection." ;;
    esac
    if [ "$answer" -lt 1 ] || [ "$answer" -gt "${#VT_CAND_DISKS[@]}" ]; then
        die "Invalid USB selection."
    fi
    VT_SELECTED_DISK=${VT_CAND_DISKS[$((answer - 1))]}
    VT_SELECTED_UUID=${VT_CAND_UUIDS[$((answer - 1))]}
}

# mac_prepare_volume <disk> <volume uuid> [scope]: mount the data partition writable.
mac_prepare_volume() {
    local disk=$1 uuid=$2 scope=${3:-physical}
    mac_ventoy_disk "$disk" "$scope" || die "$VT_REASON Run again and select the USB again."
    [ "$VT_UUID" = "$uuid" ] || die "The USB changed. Run again and select the USB again."
    if [ "$VT_FS" = NTFS ]; then
        die "The Ventoy data partition is NTFS. macOS can only read NTFS, so it cannot copy an ISO to it. Use exFAT (the Ventoy default), or copy from Windows or Linux."
    fi
    if [ -z "$VT_MOUNT" ]; then
        diskutil mount "$VT_PART" >/dev/null || die "Could not mount /dev/$VT_PART."
        mac_ventoy_disk "$disk" "$scope" || die "$VT_REASON"
        [ "$VT_UUID" = "$uuid" ] || die "The USB changed. Run again and select the USB again."
    fi
    [ -n "$VT_MOUNT" ] || die "The Ventoy data partition is not mounted."
    [ "$VT_WRITABLE" = true ] || die "The Ventoy data partition at $VT_MOUNT is mounted read-only."
}

# mac_same_volume <disk> <uuid> <mount> [scope]: fail unless the data volume is unchanged.
mac_same_volume() {
    mac_ventoy_disk "$1" "${4:-physical}" && [ "$VT_UUID" = "$2" ] && [ "$VT_MOUNT" = "$3" ] &&
        [ "$VT_WRITABLE" = true ]
}
