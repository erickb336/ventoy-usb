#!/usr/bin/env bash
# Safe Linux tests for ventoy-add-isos.sh. No USB stick is needed and no real disk is touched:
# most tests copy to a temporary folder, and the FAT32 tests use a small loop image
# that this script creates (only when passwordless sudo, losetup and mkfs.vfat exist).
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/ventoy-add-isos.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/ventoy-linux-test.XXXXXX")
passes=0 failures=0 skips=0
loop_mnt=""

cleanup() {
  if [[ -n "$loop_mnt" ]]; then
    sudo umount "$loop_mnt" 2>/dev/null
    sudo rmdir "$loop_mnt" 2>/dev/null
  fi
  rm -rf "$work"
}
trap cleanup EXIT

pass() { passes=$((passes + 1)); echo "ok   $1"; }
fail() { failures=$((failures + 1)); echo "FAIL $1"; }
skip() { skips=$((skips + 1)); echo "SKIP $1"; }
check() { # <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$2], got [$3]"; fi
}
contains() { # <name> <needle> <text>
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1: [$2] not in output: $3" ;; esac
}
temps() { # <dir>: count the temporary copy files left in <dir>
  find "$1" -maxdepth 1 -name '.ventoy-copy-*' | wc -l | tr -d ' '
}
hashes() { # <dir>: the SHA-256 and mtime of each file in <dir>
  (cd "$1" && for f in *; do printf '%s %s\n' "$(sha256sum <"$f")" "$(stat -c %Y -- "$f")"; done)
}
# run <mount> <iso dir> [PATH prefix]: run the script, answer "y" to the "not a Ventoy mount" question.
run() {
  out=$(PATH="${3:+$3:}$PATH" bash "$script" "$1" "$2" <<<y 2>&1)
  rc=$?
}

real_sync=$(command -v sync)
real_dd=$(command -v dd)

echo "== Copy two ISOs with difficult names to an empty folder"
isos=$work/isos
usb=$work/usb
mkdir -p "$isos" "$usb"
head -c 3000000 /dev/urandom >"$isos/Win 11 [x64] (1).iso"
head -c 1234567 /dev/urandom >"$isos/-dash.iso"
run "$usb" "$isos"
check "exit code 0" 0 "$rc"
check "two files verified" 2 "$(grep -c '^✅ .* copied and SHA-256 verified\.$' <<<"$out")"
contains "summary" "Summary: 2 copied and SHA-256 verified, 0 skipped (already on the USB), 0 failed." "$out"
cmp -s "$isos/Win 11 [x64] (1).iso" "$usb/Win 11 [x64] (1).iso" && pass "name with spaces and brackets: same bytes" || fail "name with spaces and brackets: same bytes"
cmp -s "$isos/-dash.iso" "$usb/-dash.iso" && pass "name with leading '-': same bytes" || fail "name with leading '-': same bytes"
check "no temporary files left" 0 "$(temps "$usb")"

echo "== Same copy again: skip, never overwrite"
before=$(hashes "$usb")
sleep 1.1 # an overwrite would change the mtime
head -c 3000000 /dev/urandom >"$isos/Win 11 [x64] (1).iso" # new content under the same name
run "$usb" "$isos"
check "exit code 1" 1 "$rc"
contains "summary says skipped" "Summary: 0 copied and SHA-256 verified, 2 skipped (already on the USB), 0 failed." "$out"
contains "skip message" "already exists. It was not changed." "$out"
check "files and mtimes unchanged" "$before" "$(hashes "$usb")"
check "no temporary files left" 0 "$(temps "$usb")"

echo "== One new ISO beside an existing one: copy the new one, skip the other"
head -c 500000 /dev/urandom >"$isos/new.iso"
run "$usb" "$isos"
check "exit code 1" 1 "$rc"
contains "summary" "Summary: 1 copied and SHA-256 verified, 2 skipped (already on the USB), 0 failed." "$out"
cmp -s "$isos/new.iso" "$usb/new.iso" && pass "new ISO copied" || fail "new ISO copied"

echo "== Checksum mismatch: the copy changes on the USB before verification"
stub=$work/stub-corrupt
mkdir -p "$stub" "$work/usb2" "$work/isos2"
head -c 2000000 /dev/urandom >"$work/isos2/bad.iso"
cat >"$stub/sync" <<EOF
#!/usr/bin/env bash
for f in "$work/usb2"/.ventoy-copy-*; do printf 'X' | "$real_dd" of="\$f" conv=notrunc status=none; done
exec "$real_sync" "\$@"
EOF
chmod +x "$stub/sync"
run "$work/usb2" "$work/isos2" "$stub"
check "exit code 1" 1 "$rc"
contains "mismatch reported" "SHA-256 mismatch for bad.iso. The copy was removed." "$out"
contains "summary says failed" "0 copied and SHA-256 verified, 0 skipped (already on the USB), 1 failed." "$out"
[[ -e "$work/usb2/bad.iso" ]] && fail "final name absent" || pass "final name absent"
check "temporary file removed" 0 "$(temps "$work/usb2")"

echo "== SIGTERM during the copy"
stub=$work/stub-slow
mkdir -p "$stub" "$work/usb3"
cat >"$stub/dd" <<EOF
#!/usr/bin/env bash
# The copy writes part of the ISO, then hangs. Other dd calls run normally.
case "\$*" in
  *of=*.ventoy-copy-*) "$real_dd" "\${@/status=progress/status=none}" count=1; exec sleep 60 ;;
  *) exec "$real_dd" "\$@" ;;
esac
EOF
chmod +x "$stub/dd"
PATH="$stub:$PATH" bash "$script" "$work/usb3" "$work/isos2" <<<y >"$work/term.log" 2>&1 &
pid=$!
for _ in $(seq 100); do [[ "$(temps "$work/usb3")" == 1 ]] && break; sleep 0.1; done
check "temporary file exists during the copy" 1 "$(temps "$work/usb3")"
kill -TERM "$pid"
wait "$pid"
check "exit code 143" 143 "$?"
check "temporary file removed" 0 "$(temps "$work/usb3")"
[[ -e "$work/usb3/bad.iso" ]] && fail "final name absent" || pass "final name absent"
pgrep -f "sleep 60" >/dev/null && fail "copy process stopped" || pass "copy process stopped"

echo "== FAT32 loop image (root-owned mount, so the script uses sudo)"
if [[ "$(uname -s)" != Linux ]] || ! sudo -n true 2>/dev/null || ! command -v mkfs.vfat >/dev/null || ! command -v losetup >/dev/null; then
  skip "FAT32 tests need Linux, passwordless sudo, losetup and mkfs.vfat"
else
  img=$work/fat32.img
  truncate -s 64M "$img"
  mkfs.vfat -F 32 -n Ventoy "$img" >/dev/null
  loop_mnt=$(mktemp -d "${TMPDIR:-/tmp}/ventoy-fat32.XXXXXX")
  # -o loop attaches only the image file of this test.
  sudo mount -o loop -t vfat "$img" "$loop_mnt"
  [[ -w "$loop_mnt" ]] && fail "mount is root-owned" || pass "mount is root-owned"

  mkdir -p "$work/fat-ok" "$work/fat-space" "$work/fat-big"
  head -c 5000000 /dev/urandom >"$work/fat-ok/small.iso"
  run "$loop_mnt" "$work/fat-ok"
  check "small ISO: exit code 0" 0 "$rc"
  contains "small ISO: sudo announced" "sudo is necessary" "$out"
  contains "small ISO: verified" "small.iso copied and SHA-256 verified." "$out"
  case "$out" in *"direct read is not supported"*) fail "small ISO: read back with O_DIRECT" ;; *) pass "small ISO: read back with O_DIRECT" ;; esac
  cmp -s "$work/fat-ok/small.iso" "$loop_mnt/small.iso" && pass "small ISO: same bytes on FAT32" || fail "small ISO: same bytes on FAT32"

  truncate -s 100M "$work/fat-space/large.iso" # sparse: takes no space on the runner
  run "$loop_mnt" "$work/fat-space"
  check "no free space: exit code 1" 1 "$rc"
  contains "no free space: refused" "Failed: not enough free space on $loop_mnt for large.iso" "$out"

  truncate -s 4G "$work/fat-big/big.iso" # 4 GiB = the FAT32 limit + 1 byte
  run "$loop_mnt" "$work/fat-big"
  check "over 4 GiB: exit code 1" 1 "$rc"
  contains "over 4 GiB: refused" "Failed: big.iso is larger than the FAT32 file size limit (4 GiB)." "$out"

  check "FAT32: only small.iso on the USB" "small.iso" "$(ls -A "$loop_mnt")"
fi

echo
echo "Linux tests: $passes passed, $failures failed, $skips skipped."
[[ $failures -eq 0 ]]
