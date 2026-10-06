#!/bin/bash
# Safe macOS tests. No USB stick is needed and no real disk is touched:
# unit tests use a stub diskutil, and the end-to-end tests use disk images
# that this script creates with hdiutil and checks are virtual before use.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ventoy-mac-test.XXXXXX")
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
plist disk13 WholeDisk=bool:true Internal=bool:false WritableMedia=bool:true Size=integer:1 # not in the list

realpath_=$PATH
PATH=$work/bin:$PATH FIX=$fix
export FIX
listing=$(mac_list_ventoy_disks)
check "eligible disks listed by number" "[1] /dev/disk4 | SanDisk disk4 | 57.75 GiB | data: Ventoy (exFAT)
[2] /dev/disk5 | SanDisk disk5 | 57.75 GiB | data: Ventoy (NTFS)
[3] /dev/disk10 | SanDisk disk10 | 57.75 GiB | data: Ventoy (FAT32)
[4] /dev/disk12 | SanDisk disk12 | 57.75 GiB | data: Ventoy (exFAT)" "$listing"
mac_ventoy_disk disk13 any && fail "disk without partitions rejected" || pass "disk without partitions rejected"
out=$(mac_ventoy_disk disk13; echo "$VT_REASON")
contains "disk not in external physical list rejected" "not an external physical disk" "$out"

out=$(mac_select_disk 2>&1 <<<3; echo "selected=$VT_SELECTED_DISK uuid=$VT_SELECTED_UUID")
contains "select by list number, not disk id" "selected=disk10 uuid=UUID-disk10" "$out"
for answer in 0 5 disk4 ""; do
    out=$(mac_select_disk 2>&1 <<<"$answer")
    contains "selection [$answer] rejected" "Invalid USB selection." "$out"
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
plist list
plutil -insert WholeDisks -array "$fix/list.plist"
out=$(mac_select_disk 2>&1 <<<1)
contains "no disk: clear message" "No Ventoy USB found. Connect the USB and run again, or use option 1" "$out"
PATH=$realpath_

echo "== End to end on hdiutil disk images"
# make_image <data fs> <data MB>: create, attach and partition a Ventoy-like image; print the disk id.
make_image() {
    local img=$work/img$RANDOM.dmg disk sectors
    sectors=$((($2 + 40) * 2048)) # data + 32 MiB VTOYEFI + free space
    hdiutil create -sectors "$sectors" -layout NONE -o "$img" >/dev/null 2>&1 || return 1
    disk=$(hdiutil attach -nomount -noverify "$img" 2>/dev/null | awk 'NR == 1 { sub("/dev/", "", $1); print $1 }')
    [ -n "$disk" ] || return 1
    echo "$disk" >>"$work/attached"
    # Safety: partition only a virtual disk image that this script attached.
    [ "$(plist_get "$(diskutil info -plist "$disk")" VirtualOrPhysical)" = Virtual ] || return 1
    hdiutil info | grep -q "$img" || return 1
    diskutil partitionDisk "$disk" MBR "$1" Ventoy "$(($2 * 1048576))B" "MS-DOS FAT16" VTOYEFI 33554432B "Free Space" free R >/dev/null 2>&1 || return 1
    echo "$disk"
}

disk=$(make_image ExFAT 160)
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
    mac_ventoy_disk "$disk" any
    check "copy hash matches source" "$(mac_sha256 "$work/Test Image.iso")" "$(mac_sha256 "$VT_MOUNT/Test Image.iso")"
    check "no temp file after success" "" "$(ls -A "$VT_MOUNT" | grep ventoy-copy)"

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
    mac_ventoy_disk "$disk" any
    check "no temp file after mismatch" "" "$(ls -A "$VT_MOUNT" | grep ventoy-copy)"
    [ -e "$VT_MOUNT/mismatch.iso" ] && fail "no ISO after mismatch" || pass "no ISO after mismatch"

    # Simulated Ctrl+C: a slow cat lets the test stop the copy while it writes.
    mkdir -p "$work/slow-cat"
    printf '#!/bin/bash\nhead -c 1000000 "$1"\nexec sleep 30\n' >"$work/slow-cat/cat"
    chmod +x "$work/slow-cat/cat"
    cp "$work/Test Image.iso" "$work/interrupt.iso"
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
fi

disk=$(make_image "MS-DOS FAT32" 100)
if [ -z "$disk" ]; then
    fail "create FAT32 disk image"
else
    mac_ventoy_disk "$disk" any && check "FAT32 data partition detected" FAT32 "$VT_FS" || fail "FAT32 image layout: $VT_REASON"
    dd if=/dev/zero of="$work/huge.iso" bs=1 count=0 seek=4294967296 2>/dev/null
    out=$(mac_copy_iso "$disk" "$VT_UUID" "$work/huge.iso" any 2>&1)
    contains "FAT32 4 GiB limit refused" "larger than the FAT32 file size limit" "$out"
fi

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
