#!/bin/bash
# Safe macOS tests. No USB stick is needed and no real disk is touched:
# unit tests use a stub diskutil, and the end-to-end tests use disk images
# that this script creates with hdiutil and checks are virtual before use.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/ventoy-mac-test.XXXXXX")" && pwd) # hdiutil shows real paths
failures=0
passes=0

cleanup() {
    local d
    [ -f "$work/attached" ] && for d in $(cat "$work/attached"); do hdiutil detach "$d" -force -quiet 2>/dev/null; done
    rm -rf "$work"
}
trap cleanup EXIT

pass() { passes=$((passes + 1)); echo "ok   $1"; }
fail() { failures=$((failures + 1)); echo "FAIL $1"; }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$2], got [$3]"; fi
}
contains() { # <name> <needle> <text>
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1: [$2] not in output: $3" ;; esac
}

. "$root/macos/disks.sh"
. "$root/macos/isos.sh"

echo "== Path parsing"
check "plain path" "/a/b.iso" "$(mac_parse_path '/a/b.iso')"
check "Finder drag with escaped spaces" "/Users/me/My Files/Win 11.iso" "$(mac_parse_path '/Users/me/My\ Files/Win\ 11.iso ')"
check "double quotes keep backslashes" '/a/x\ y.iso' "$(mac_parse_path '  "/a/x\ y.iso"  ')"
check "single quotes" "/a/x y.iso" "$(mac_parse_path "'/a/x y.iso'")"
check "tilde" "$HOME/Downloads/w.iso" "$(mac_parse_path '~/Downloads/w.iso')"
check "escaped parentheses" "/a/Win (1).iso" "$(mac_parse_path '/a/Win\ \(1\).iso')"

echo "== ISO file check"
mkdir "$work/folder.iso"
: >"$work/empty.iso"
echo data >"$work/good.ISO"
echo data >"$work/notes.txt"
mac_is_iso "$work/good.ISO" && pass "nonempty .ISO accepted" || fail "nonempty .ISO accepted"
for bad in folder.iso empty.iso notes.txt missing.iso; do
    mac_is_iso "$work/$bad" && fail "$bad rejected" || pass "$bad rejected"
done

echo "== Control characters"
# A removal must not join the bytes around it into a new C1 (U+009B is CSI).
check "ESC between C2 and 9B removed" "AB" "$(mac_clean $'A\xc2\x1b\x9bB')"
check "nested C1 removed" "AB" "$(mac_clean $'A\xc2\xc2\x9b\x9bB')"
check "other UTF-8 kept" "café Ā" "$(mac_clean 'café Ā')"

echo "== Disk eligibility (stub diskutil with plist fixtures)"
fix=$work/fixtures
mkdir -p "$fix" "$work/bin"
cat >"$work/bin/diskutil" <<'EOF'
#!/bin/bash
case "$1" in
    list) cat "$FIX/list.plist" ;;
    info) [ -f "$FIX/$3.plist" ] && cat "$FIX/$3.plist" ;;
    mount) echo "mount $2" >>"$FIX/calls"; cp "$FIX/$2.mounted.plist" "$FIX/$2.plist" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/diskutil"

# plist <file> <key=type:value>...: write a fixture with plutil.
plist() {
    local f=$fix/$1.plist kv key tv
    shift
    plutil -create xml1 "$f"
    for kv in "$@"; do
        key=${kv%%=*}
        tv=${kv#*=}
        plutil -insert "$key" "-${tv%%:*}" "${tv#*:}" "$f"
    done
}
plist list
plutil -insert WholeDisks -array "$fix/list.plist"
# whole <disk> <internal> <writable media>, efi <disk> <label> <size>, data <disk> <fs type> <fs name> <mount> <writable>
whole() {
    plutil -insert WholeDisks -string "$1" -append "$fix/list.plist"
    plist "$1" WholeDisk=bool:true Internal=bool:"$2" WritableMedia=bool:"$3" Size=integer:62008590336 MediaName=string:"SanDisk $1"
}
efi() { plist "$1s2" ParentWholeDisk=string:"$1" VolumeName=string:"$2" FilesystemType=string:msdos Size=integer:"$3"; }
data() {
    plist "$1s1" ParentWholeDisk=string:"$1" FilesystemType=string:"$2" FilesystemName=string:"$3" \
        VolumeName=string:Ventoy VolumeUUID=string:"UUID-$1" MountPoint=string:"$4" WritableVolume=bool:"$5"
}
whole disk4 false true; efi disk4 VTOYEFI 33554432; data disk4 exfat ExFAT /Volumes/Ventoy true
whole disk5 false true; efi disk5 VTOYEFI 33554432; data disk5 ntfs NTFS /Volumes/Ventoy true
whole disk6 false true; efi disk6 VTOYEFI 49641984; data disk6 exfat ExFAT /Volumes/Ventoy true
whole disk7 false false; efi disk7 VTOYEFI 33554432; data disk7 exfat ExFAT /Volumes/Ventoy true
whole disk8 true true; efi disk8 VTOYEFI 33554432; data disk8 exfat ExFAT /Volumes/Ventoy true
whole disk9 false true; efi disk9 EFI 33554432; data disk9 exfat ExFAT /Volumes/Ventoy true
whole disk10 false true; efi disk10 VTOYEFI 33554432; data disk10 msdos "MS-DOS FAT32" "" false
whole disk11 false true; efi disk11 VTOYEFI 33554432; data disk11 msdos "MS-DOS FAT16" /Volumes/Ventoy true
whole disk12 false true; efi disk12 VTOYEFI 33554432; data disk12 exfat ExFAT /Volumes/Ventoy false
cp "$fix/disk10s1.plist" "$fix/disk10s1.mounted.plist"
plutil -replace MountPoint -string /Volumes/Ventoy "$fix/disk10s1.mounted.plist"
plutil -replace WritableVolume -bool true "$fix/disk10s1.mounted.plist"
# A hostile USB: its names hold ESC (C0) and U+009B (C1) terminal escapes.
evil=$'Ev\033[31mil\xc2\x9b2J'
whole disk14 false true; efi disk14 VTOYEFI 33554432
plutil -replace MediaName -string "$evil" "$fix/disk14.plist"
plist disk14s1 ParentWholeDisk=string:disk14 FilesystemType=string:exfat FilesystemName=string:ExFAT \
    VolumeName=string:"$evil" VolumeUUID=string:UUID-disk14 MountPoint=string:"/Volumes/$evil" WritableVolume=bool:true
plist disk13 WholeDisk=bool:true Internal=bool:false WritableMedia=bool:true Size=integer:1 # not in the list

realpath_=$PATH
PATH=$work/bin:$PATH FIX=$fix
export FIX
listing=$(mac_list_ventoy_disks)
check "eligible disks listed by number" "[1] /dev/disk4 | SanDisk disk4 | 57.75 GiB | data: Ventoy (exFAT)
[2] /dev/disk5 | SanDisk disk5 | 57.75 GiB | data: Ventoy (NTFS)
[3] /dev/disk10 | SanDisk disk10 | 57.75 GiB | data: Ventoy (FAT32)
[4] /dev/disk12 | SanDisk disk12 | 57.75 GiB | data: Ventoy (exFAT)
[5] /dev/disk14 | Ev[31mil2J | 57.75 GiB | data: Ev[31mil2J (exFAT)" "$listing"
mac_ventoy_disk disk13 any && fail "disk without partitions rejected" || pass "disk without partitions rejected"
out=$(mac_ventoy_disk disk13; echo "$VT_REASON")
contains "disk not in external physical list rejected" "not an external physical disk" "$out"

out=$(mac_select_disk 2>&1 <<<3; echo "selected=$VT_SELECTED_DISK uuid=$VT_SELECTED_UUID")
contains "select by list number, not disk id" "selected=disk10 uuid=UUID-disk10" "$out"
out=$(mac_select_disk 2>&1 <<<01; echo "selected=$VT_SELECTED_DISK")
contains "leading zero accepted" "selected=disk4" "$out"
for answer in 0 6 disk4 "" 000 0001 99999999999999999999 18446744073709551617; do
    out=$(mac_select_disk 2>&1 <<<"$answer"; echo "selected=${VT_SELECTED_DISK:-}")
    check "selection [$answer] rejected" "Error: Invalid USB selection." "$(echo "$out" | grep -v '^\[' | grep -v '^Ventoy USB disks:')"
done
# "08" and "09" are not octal. A list of 9 stands in for 9 connected USB disks.
for answer in 08 09; do
    out=$(mac_list_ventoy_disks() { VT_CAND_DISKS=(d1 d2 d3 d4 d5 d6 d7 d8 d9); VT_CAND_UUIDS=(u1 u2 u3 u4 u5 u6 u7 u8 u9); }
        mac_select_disk 2>&1 <<<"$answer"; echo "selected=$VT_SELECTED_DISK")
    check "selection [$answer] is decimal" "Ventoy USB disks:
selected=d${answer#0}" "$out"
done
out=$(mac_prepare_volume disk5 UUID-disk5 2>&1)
contains "NTFS rejected as read-only on macOS" "macOS can only read NTFS" "$out"
out=$(mac_prepare_volume disk12 UUID-disk12 2>&1)
contains "read-only mount refused" "mounted read-only" "$out"
out=$(mac_prepare_volume disk4 UUID-other 2>&1)
contains "changed volume UUID refused" "The USB changed." "$out"
out=$(mac_prepare_volume disk10 UUID-disk10; echo "mount=$VT_MOUNT fs=$VT_FS")
check "unmounted data partition mounted with diskutil" "mount disk10s1" "$(cat "$fix/calls")"
check "mounted volume used" "mount=/Volumes/Ventoy fs=FAT32" "$out"
# The menu, with option 2 and the hostile USB: Skip the ISO, do not eject.
out=$(printf '2\n5\n3\nn\n' | /bin/bash "$root/macos/ventoy-mac.sh" 2>&1)
contains "menu shows the volume without control characters" "Ventoy data volume: /Volumes/Ev[31mil2J (exFAT)" "$out"
case "$out$listing" in *$'\033'* | *$'\xc2\x9b'*) fail "no ESC or C1 in output" ;; *) pass "no ESC or C1 in output" ;; esac
plutil -replace WritableVolume -bool false "$fix/disk14s1.plist"
out=$(mac_prepare_volume disk14 UUID-disk14 2>&1)
check "error message without control characters" "Error: The Ventoy data partition at /Volumes/Ev[31mil2J is mounted read-only." "$out"
plist list
plutil -insert WholeDisks -array "$fix/list.plist"
out=$(printf '2\n' | /bin/bash "$root/macos/ventoy-mac.sh" 2>&1)
contains "no disk: clear message" "No Ventoy USB found. Connect the USB and run again, or use option 1 to create one." "$out"
# After option 1 (Mactoy not installed; open is stubbed), the hint is about reconnecting, not option 1.
printf '#!/bin/bash\n' >"$work/bin/open"
chmod +x "$work/bin/open"
out=$(printf '1\n\n' | HOME=$work /bin/bash "$root/macos/ventoy-mac.sh" 2>&1)
contains "option 1 tells how to check Mactoy" "spctl -a -vv /Applications/Mactoy.app
It must show \"source=Notarized Developer ID\"" "$out"
contains "no disk after option 1: reconnect hint" "No Ventoy USB found. If Mactoy finished, unplug and reconnect the USB, then run ./ventoy.sh and choose 2." "$out"
rm "$work/bin/open"
PATH=$realpath_

echo "== End to end on hdiutil disk images"
# image_disk <image>: print the whole disk that `hdiutil info -plist` lists for <image>, if any.
image_disk() {
    local info i=0 j path dev
    info=$(hdiutil info -plist)
    while path=$(plist_get "$info" "images.$i.image-path"); do
        j=0
        [ "$path" = "$1" ] && while dev=$(plist_get "$info" "images.$i.system-entities.$j.dev-entry"); do
            case "$dev" in /dev/disk*s*) ;; /dev/disk*) echo "${dev#/dev/}" ;; esac
            j=$((j + 1))
        done
        i=$((i + 1))
    done
}
# image_owns <image> <disk>: succeed only if <disk> is the virtual disk that hdiutil attached for <image>.
image_owns() {
    [ -n "$2" ] && [ "$(image_disk "$1")" = "$2" ] &&
        [ "$(plist_get "$(diskutil info -plist "$2")" VirtualOrPhysical)" = Virtual ]
}
# make_image <data fs> <data MB> <data label>: create, attach and partition a Ventoy-like image
# $work/image-<data fs>.dmg; print the disk id. Use a label unique to this run, so that another
# volume with the same name (another run, or a real Ventoy USB) does not move the mount point.
make_image() {
    local img=$work/image-$1.dmg disk sectors
    sectors=$((($2 + 40) * 2048)) # data + 32 MiB VTOYEFI + free space
    hdiutil create -sectors "$sectors" -layout NONE -o "$img" >/dev/null 2>&1 || return 1
    disk=$(hdiutil attach -nomount -noverify "$img" 2>/dev/null | awk 'NR == 1 { sub("/dev/", "", $1); print $1 }')
    # Safety: detach only the disk that hdiutil lists for this image, and partition
    # $disk only when it is that disk.
    image_disk "$img" >>"$work/attached"
    image_owns "$img" "$disk" || return 1
    diskutil partitionDisk "$disk" MBR "$1" "$3" "$(($2 * 1048576))B" "MS-DOS FAT16" VTOYEFI 33554432B "Free Space" free R >/dev/null 2>&1 || return 1
    echo "$disk"
}

# own_mount: set VT_MOUNT to the mount point of this run's image now, or fail.
own_mount() {
    VT_MOUNT=""
    mac_ventoy_disk "$disk" any && [ -n "$VT_MOUNT" ]
}

disk=$(make_image ExFAT 160 "VT$$E")
if [ -z "$disk" ]; then
    fail "create exFAT disk image"
else
    pass "create exFAT disk image /dev/$disk"
    check "image VTOYEFI is 32 MiB" 33554432 "$(plist_get "$(diskutil info -plist "${disk}s2")" Size)"
    mac_ventoy_disk "$disk" physical && fail "virtual disk rejected without 'any'" || pass "virtual disk rejected without 'any'"
    mac_ventoy_disk "$disk" any && pass "image has the Ventoy layout" || fail "image has the Ventoy layout: $VT_REASON"
    uuid=$VT_UUID
    diskutil unmount "${disk}s1" >/dev/null
    head -c 20000000 /dev/urandom >"$work/Test Image.iso"
    out=$(mac_copy_iso "$disk" "$uuid" "$work/Test Image.iso" any 2>&1)
    rc=$?
    contains "copy prints verified" "ISO copied and SHA-256 verified." "$out"
    contains "copy shows progress" "100% | 0.02 / 0.02 GiB" "$out"
    check "copy exit code" 0 "$rc"
    own_mount
    check "data volume has this run's label" "VT$$E" "$VT_LABEL"
    check "copy hash matches source" "$(mac_sha256 "$work/Test Image.iso")" "$(mac_sha256 "$VT_MOUNT/Test Image.iso")"
    check "no temp file after success" "" "$(ls -A "$VT_MOUNT" | grep ventoy-copy)"
    check "no AppleDouble ._ file after success" "" "$(ls -A "$VT_MOUNT" | grep '^\._')"

    out=$(mac_copy_iso "$disk" "$uuid" "$work/Test Image.iso" any 2>&1)
    rc=$?
    contains "existing name refused" "Already exists: $VT_MOUNT/Test Image.iso" "$out"
    check "existing name exit code" 1 "$rc"

    # Interactive ISO menu: Local ISO with a path dragged from Finder, then copy.
    cp "$work/Test Image.iso" "$work/Drag Test.iso"
    dragged=$(printf '%s' "$work/Drag Test.iso" | sed 's/ /\\ /g')
    iso=$( (mac_read_iso >/dev/null <<<"2
$dragged "; echo "$VT_ISO") | tail -1)
    check "ISO menu accepts a Finder-dragged path" "$work/Drag Test.iso" "$iso"
    out=$(mac_copy_iso "$disk" "$uuid" "$iso" any 2>&1)
    contains "dragged ISO copied" "ISO copied and SHA-256 verified." "$out"
    # Windows 11 choice opens Microsoft's page (open is stubbed) and then waits for a path.
    mkdir -p "$work/open-stub"
    printf '#!/bin/bash\necho "$*" >>"%s/opened"\n' "$work" >"$work/open-stub/open"
    chmod +x "$work/open-stub/open"
    out=$( (PATH=$work/open-stub:$PATH mac_read_iso <<<"1
'$work/Drag Test.iso'"; echo "iso=$VT_ISO") 2>&1)
    check "Windows 11 page opened" "https://www.microsoft.com/software-download/windows11" "$(cat "$work/opened")"
    contains "Windows 11 path accepted" "iso=$work/Drag Test.iso" "$out"
    out=$( (mac_read_iso <<<3; echo "iso=[$VT_ISO]") 2>&1)
    contains "Skip copies nothing" "iso=[]" "$out"

    dd if=/dev/zero of="$work/big.iso" bs=1 count=0 seek=200000000 2>/dev/null
    out=$(mac_copy_iso "$disk" "$uuid" "$work/big.iso" any 2>&1)
    contains "free space checked" "Not enough free space" "$out"

    mkdir -p "$work/bad-shasum"
    printf '#!/bin/bash\necho "$RANDOM$RANDOM  -"\n' >"$work/bad-shasum/shasum"
    chmod +x "$work/bad-shasum/shasum"
    cp "$work/Test Image.iso" "$work/mismatch.iso"
    out=$(PATH=$work/bad-shasum:$PATH mac_copy_iso "$disk" "$uuid" "$work/mismatch.iso" any 2>&1)
    rc=$?
    contains "checksum mismatch refused" "Copied ISO checksum mismatch." "$out"
    check "mismatch exit code" 1 "$rc"
    own_mount
    check "no temp file after mismatch" "" "$(ls -A "$VT_MOUNT" | grep ventoy-copy)"
    [ -e "$VT_MOUNT/mismatch.iso" ] && fail "no ISO after mismatch" || pass "no ISO after mismatch"

    # Simulated Ctrl+C: a slow cat lets the test stop the copy while it writes.
    mkdir -p "$work/slow-cat"
    printf '#!/bin/bash\nhead -c 1000000 "$1"\nexec sleep 30\n' >"$work/slow-cat/cat"
    chmod +x "$work/slow-cat/cat"
    cp "$work/Test Image.iso" "$work/interrupt.iso"
    own_mount
    set -m # job control, so the background copy receives SIGINT like Ctrl+C
    (PATH=$work/slow-cat:$PATH mac_copy_iso "$disk" "$uuid" "$work/interrupt.iso" any >/dev/null 2>&1) &
    copier=$!
    set +m
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        ls -A "$VT_MOUNT" | grep -q ventoy-copy && break
        sleep 0.25
    done
    ls -A "$VT_MOUNT" | grep -q ventoy-copy && pass "temp file exists during copy" || fail "temp file exists during copy"
    kill -INT "$copier"
    wait "$copier"
    check "no temp file after interrupt" "" "$(ls -A "$VT_MOUNT" | grep ventoy-copy)"
    [ -e "$VT_MOUNT/interrupt.iso" ] && fail "no ISO after interrupt" || pass "no ISO after interrupt"

    # A link to an ISO: its size is the size of the ISO, not of the link.
    ln -s "$work/Test Image.iso" "$work/linked.iso"
    out=$(mac_copy_iso "$disk" "$uuid" "$work/linked.iso" any 2>&1)
    contains "ISO behind a symbolic link copied" "ISO copied and SHA-256 verified." "$out"
    own_mount
    check "linked ISO copy matches" "$(mac_sha256 "$work/Test Image.iso")" "$(mac_sha256 "$VT_MOUNT/linked.iso")"

    cp "$work/Test Image.iso" "$work/-x.iso"
    out=$(cd "$work" && mac_copy_iso "$disk" "$uuid" -x.iso any 2>&1)
    contains "relative ISO name that starts with - copied" "ISO copied and SHA-256 verified." "$out"
    own_mount
    check "-x.iso copy matches" "$(mac_sha256 "$work/-x.iso")" "$(mac_sha256 "$VT_MOUNT/-x.iso")"

    # Hooks around the real tools, to change the USB at exact moments.
    hook=$work/hook
    mkdir -p "$hook" "$work/outside"
    cat >"$hook/diskutil" <<'EOF2'
#!/bin/bash
# STOP_ON_MOUNT: on "mount", stop the caller with SIGTERM and do not mount. (SIGINT, as from
# Ctrl+C, takes the same cleanup path, but a background job ignores it.)
# FLIP: from the FLIP_AT-th "info -plist FLIP_PART" on, replace a key ("Key -type value").
# MOUNT_AT: on "mount", mount at this folder (as when the usual mount point is taken by another volume).
[ "$1" = mount ] && [ -n "${STOP_ON_MOUNT:-}" ] && { kill -TERM $PPID; exit 1; }
[ "$1" = mount ] && [ -n "${MOUNT_AT:-}" ] && exec /usr/sbin/diskutil mount -mountPoint "$MOUNT_AT" "$2"
if [ "$1 $2 $3" = "info -plist ${FLIP_PART:-}" ]; then
    n=$(($(cat "$FLIP_COUNT" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FLIP_COUNT"
    [ "$n" -ge "$FLIP_AT" ] && { /usr/sbin/diskutil "$@" | plutil -replace $FLIP -o - -; exit; }
fi
exec /usr/sbin/diskutil "$@"
EOF2
    cat >"$hook/shasum" <<'EOF2'
#!/bin/bash
# HOOK_KIND: create HOOK_DEST as a file, a folder or a link during the verification.
if [ -n "${HOOK_KIND:-}" ] && [ ! -e "$HOOK_DEST" ] && [ ! -L "$HOOK_DEST" ]; then
    case "$HOOK_KIND" in
        file) echo other >"$HOOK_DEST" ;;
        dir) mkdir "$HOOK_DEST" ;;
        link) ln -s "$HOOK_TARGET" "$HOOK_DEST" ;;
    esac
fi
exec /usr/bin/shasum "$@"
EOF2
    cat >"$hook/mv" <<'EOF2'
#!/bin/bash
# HOOK_MV_FAIL: fail without moving. HOOK_MV_DIR: create the target as a folder first.
[ -n "${HOOK_MV_FAIL:-}" ] && exit 1
[ -n "${HOOK_MV_DIR:-}" ] && mkdir "${@: -1}"
exec /bin/mv "$@"
EOF2
    chmod +x "$hook"/*
    chmod 555 "$work/outside" # a link to it is refused before mv can follow it off the USB
    export FLIP_COUNT=$work/flip-count HOOK_TARGET=$work/outside
    leftovers() { find "$VT_MOUNT" -name '.ventoy-copy*' -o -name '._.ventoy-copy*'; }

    # hooked <name> <env>...: copy a new ISO <name>.iso with the hooks and the env; set out, rc, dest.
    hooked() {
        local n=$1
        shift
        rm -f "$FLIP_COUNT"
        cp "$work/Test Image.iso" "$work/$n.iso"
        own_mount || return 1
        dest=$VT_MOUNT/$n.iso
        out=$(env PATH="$hook:$PATH" "$@" /bin/bash -c '. "$1/macos/disks.sh"; . "$1/macos/isos.sh"; mac_copy_iso "$2" "$3" "$4" any' _ \
            "$root" "$disk" "$uuid" "$work/$n.iso" 2>&1)
        rc=$?
    }
    # Identity changes between the selection and the write: nothing is written.
    hooked before FLIP_PART="${disk}s1" FLIP_AT=2 FLIP="VolumeUUID -string OTHER"
    contains "USB changed before the write refused" "Error: The USB changed. Run again" "$out"
    case "$out" in *"[1/3]"*) fail "nothing written after the change" ;; *) pass "nothing written after the change" ;; esac
    # Mount point changes between the selection and the write: nothing is written.
    mkdir "$work/other"
    hooked before-mount FLIP_PART="${disk}s1" FLIP_AT=2 FLIP="MountPoint -string $work/other"
    contains "mount point change before the write refused" "Error: The USB changed. Run again" "$out"
    case "$out" in *"[1/3]"*) fail "nothing written after the mount point change" ;; *) pass "nothing written after the mount point change" ;; esac
    check "nothing written to the new mount point" "" "$(ls -A "$work/other")"
    # Identity changes across the remount: refused, temp file removed.
    for flip in "VolumeUUID -string OTHER" "WritableVolume -bool false"; do
        hooked across FLIP_PART="${disk}s1" FLIP_AT=3 FLIP="$flip"
        contains "USB change across the remount refused ($flip)" "Error: The USB changed during the copy." "$out"
        check "no ISO or temp file after the change ($flip)" "" "$([ -e "$dest" ] && echo "$dest"; leftovers)"
    done

    # The same volume mounts again at another folder: the copy continues there.
    mkdir "$work/mnt"
    hooked elsewhere MOUNT_AT="$work/mnt"
    contains "copy continues at the new mount point" "ISO copied and SHA-256 verified." "$out"
    own_mount
    check "volume mounted at the new folder" "$work/mnt" "$VT_MOUNT"
    check "copy at the new mount point matches" "$(mac_sha256 "$work/Test Image.iso")" "$(mac_sha256 "$work/mnt/elsewhere.iso")"
    check "no temp file at the new mount point" "" "$(leftovers)"
    diskutil unmount "${disk}s1" >/dev/null && diskutil mount "${disk}s1" >/dev/null

    # A stop (Ctrl+C or SIGTERM) while the volume is unmounted: the hidden file name is shown.
    hooked stop STOP_ON_MOUNT=1
    check "stop while unmounted exit code" 143 "$rc"
    diskutil mount "${disk}s1" >/dev/null
    own_mount
    left=$(ls -A "$VT_MOUNT" | grep '^\.ventoy-copy')
    [ -n "$left" ] && pass "temp file stays on the unmounted USB" || fail "temp file stays on the unmounted USB"
    contains "stop while unmounted names the hidden file" "The hidden temporary file $left can remain on the USB." "$out"
    [ -n "$left" ] && own_mount && rm -f "$VT_MOUNT/$left" "$VT_MOUNT/._$left"

    # The ISO name appears during the verification, or at the rename.
    for kind in file dir link mv-dir; do
        case "$kind" in
            mv-dir) hooked "$kind" HOOK_MV_DIR=1 ;;
            *) hooked "$kind" HOOK_KIND="$kind" HOOK_DEST="$VT_MOUNT/$kind.iso" ;;
        esac
        contains "name collision refused ($kind)" "Error: Already exists: $dest." "$out"
        case "$out" in *verified*) fail "no 'verified' after collision ($kind)" ;; *) pass "no 'verified' after collision ($kind)" ;; esac
        check "no temp file after collision ($kind)" "" "$(leftovers)"
        own_mount && rm -rf "$VT_MOUNT/$kind.iso" "$VT_MOUNT/._$kind.iso" # the hook, not the copy, made this ._ file
    done
    check "existing link target untouched" "" "$(ls -A "$work/outside")"
    hooked mvfail HOOK_MV_FAIL=1
    contains "failed rename refused" "Error: Could not rename the copy to $dest" "$out"
    check "no ISO or temp file after failed rename" "" "$([ -e "$dest" ] && echo "$dest"; leftovers)"
    check "no ._ file on the volume after all copies" "" "$(ls -A "$VT_MOUNT" | grep '^\._')"
fi

disk=$(make_image "MS-DOS FAT32" 100 "VT$$F")
if [ -z "$disk" ]; then
    fail "create FAT32 disk image"
else
    mac_ventoy_disk "$disk" any && check "FAT32 data partition detected" FAT32 "$VT_FS" || fail "FAT32 image layout: $VT_REASON"
    dd if=/dev/zero of="$work/huge.iso" bs=1 count=0 seek=4294967296 2>/dev/null
    out=$(mac_copy_iso "$disk" "$VT_UUID" "$work/huge.iso" any 2>&1)
    contains "FAT32 4 GiB limit refused" "larger than the FAT32 file size limit" "$out"
    ln -s "$work/huge.iso" "$work/huge-link.iso"
    out=$(mac_copy_iso "$disk" "$VT_UUID" "$work/huge-link.iso" any 2>&1)
    contains "FAT32 limit refused for a link to a large ISO" "larger than the FAT32 file size limit" "$out"
    case "$out" in *"[1/3]"*) fail "nothing copied for a link to a large ISO" ;; *) pass "nothing copied for a link to a large ISO" ;; esac
    image_owns "$work/image-MS-DOS FAT32.dmg" "$disk" && pass "image guard accepts its own disk" || fail "image guard accepts its own disk"
    image_owns "$work/image-ExFAT.dmg" "$disk" && fail "image guard refuses another image's disk" || pass "image guard refuses another image's disk"
fi

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
