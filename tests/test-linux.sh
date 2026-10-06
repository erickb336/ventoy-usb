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
  [[ -d "$work/usb-root" ]] && sudo -n rm -rf "$work/usb-root"
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

echo "== Direct read-back fails with an I/O error: the ISO fails, no fallback"
stub=$work/stub-eio
mkdir -p "$stub" "$work/usb4"
cat >"$stub/dd" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *iflag=direct*) echo "dd: error reading 'copy': Input/output error" >&2; exit 1 ;;
  *) exec "$real_dd" "\$@" ;;
esac
EOF
chmod +x "$stub/dd"
run "$work/usb4" "$work/isos2" "$stub"
check "exit code 1" 1 "$rc"
contains "real error shown" "Input/output error" "$out"
contains "failure reported" "Failed: could not read the copy of bad.iso." "$out"
contains "summary says failed" "0 copied and SHA-256 verified, 0 skipped (already on the USB), 1 failed." "$out"
case "$out" in *"does not support direct reads"*) fail "no fallback to a cached read" ;; *) pass "no fallback to a cached read" ;; esac
[[ -e "$work/usb4/bad.iso" ]] && fail "final name absent" || pass "final name absent"
check "temporary file removed" 0 "$(temps "$work/usb4")"

echo "== File system without direct reads: drop the cache, read normally, verify"
stub=$work/stub-noodirect
mkdir -p "$stub" "$work/usb5"
cat >"$stub/dd" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *iflag=direct*) echo "dd: failed to open 'copy': Invalid argument" >&2; exit 1 ;;
  *) exec "$real_dd" "\$@" ;;
esac
EOF
chmod +x "$stub/dd"
run "$work/usb5" "$work/isos2" "$stub"
check "exit code 0" 0 "$rc"
contains "fallback note" "does not support direct reads. The copy is dropped from the page cache" "$out"
contains "verified" "bad.iso copied and SHA-256 verified." "$out"
cmp -s "$work/isos2/bad.iso" "$work/usb5/bad.iso" && pass "same bytes" || fail "same bytes"

echo "== Destination appears during the copy (just before the rename)"
stub=$work/stub-race
real_mv=$(command -v mv)
mkdir -p "$stub" "$work/usb6"
cat >"$stub/mv" <<EOF
#!/usr/bin/env bash
case "\$*" in *.ventoy-copy-*) printf 'existing' >"\${@: -1}" ;; esac
exec "$real_mv" "\$@"
EOF
chmod +x "$stub/mv"
run "$work/usb6" "$work/isos2" "$stub"
check "exit code 1" 1 "$rc"
contains "race reported" "bad.iso appeared during the copy. It was not changed. The copy was removed." "$out"
check "existing file unchanged" "existing" "$(cat "$work/usb6/bad.iso")"
check "temporary file removed" 0 "$(temps "$work/usb6")"

echo "== Mount check: a folder in a Ventoy mount is not the Ventoy mount"
stub=$work/stub-lsblk
mkdir -p "$stub" "$work/usb7"
printf '#!/usr/bin/env bash\necho "LABEL MOUNTPOINT"\necho "Ventoy %s/sub"\n' "$work/usb7" >"$stub/lsblk"
chmod +x "$stub/lsblk"
out=$(PATH="$stub:$PATH" bash "$script" "$work/usb7" "$work/isos2" <<<n 2>&1)
rc=$?
check "exit code 1" 1 "$rc"
contains "warning" "$work/usb7 does not appear to be a Ventoy mount point" "$out"
contains "aborted" "Aborted." "$out"
check "nothing written" "" "$(ls -A "$work/usb7")"

echo "== Mount check: the mount point of a file system labelled Ventoy passes without a question"
stub=$work/stub-findmnt
real_findmnt=$(command -v findmnt)
mkdir -p "$stub" "$work/usb8"
cat >"$stub/findmnt" <<EOF
#!/usr/bin/env bash
case "\$*" in "-n -o LABEL --mountpoint $work/usb8") echo Ventoy ;; *) exec "$real_findmnt" "\$@" ;; esac
EOF
chmod +x "$stub/findmnt"
out=$(PATH="$stub:$PATH" bash "$script" "$work/usb8" "$work/isos2" </dev/null 2>&1)
rc=$?
check "exit code 0" 0 "$rc"
case "$out" in *"does not appear to be a Ventoy mount point"*) fail "no warning" ;; *) pass "no warning" ;; esac

echo "== Auto-detect finds two Ventoy USBs: list them and ask"
stub=$work/stub-two
mkdir -p "$stub" "$work/usbA" "$work/usbB"
printf '#!/usr/bin/env bash\necho "LABEL MOUNTPOINT"\necho "Ventoy %s"\necho "Ventoy %s"\n' "$work/usbA" "$work/usbB" >"$stub/lsblk"
chmod +x "$stub/lsblk"
out=$(PATH="$stub:$PATH" bash "$script" 2>&1 <<EOF

$work/usbB
$work/isos2
y
EOF
)
rc=$?
check "exit code 0" 0 "$rc"
contains "both listed" "More than one Ventoy USB found:
  $work/usbA
  $work/usbB" "$out"
cmp -s "$work/isos2/bad.iso" "$work/usbB/bad.iso" && pass "copied to the chosen USB" || fail "copied to the chosen USB"
check "other USB unchanged" "" "$(ls -A "$work/usbA")"

echo "== sudo timestamp expired before a copy: fail with a clear message, no password prompt"
if [[ "$(id -u)" == 0 ]]; then
  skip "needs a non-root user (root can write to every folder, so the script never uses sudo)"
else
  stub=$work/stub-sudo-expired
  mkdir -p "$stub" "$work/usb9"
  chmod 555 "$work/usb9"
  cat >"$stub/sudo" <<EOF
#!/usr/bin/env bash
# "sudo -v" and the first "sudo -n true" succeed. Then the timestamp is expired: -n fails, other calls ask for a password.
case "\$1 \${2:-}" in
  "-v ") exit 0 ;;
  "-n true") [[ -e "$stub/used" ]] || { touch "$stub/used"; exit 0; } ;;
esac
case "\$1" in
  -n) echo "sudo: a password is required" >&2; exit 1 ;;
  *) echo "[sudo] password for \$(id -un):" >&2; exit 1 ;;
esac
EOF
  chmod +x "$stub/sudo"
  run "$work/usb9" "$work/isos2" "$stub"
  check "exit code 1" 1 "$rc"
  contains "clear message" "Failed: sudo needs the password again. Run the script again to copy bad.iso." "$out"
  case "$out" in *"password for"*) fail "no password prompt" ;; *) pass "no password prompt" ;; esac

  echo "== sudo asks for the password at each command (timestamp_timeout=0): stop before the first copy"
  stub=$work/stub-sudo-zero
  mkdir -p "$stub"
  cat >"$stub/sudo" <<'EOF'
#!/usr/bin/env bash
# "sudo -v" succeeds, but it keeps no timestamp: each "sudo -n" fails.
case "$1" in
  -v) exit 0 ;;
  -n) echo "sudo: a password is required" >&2; exit 1 ;;
  *) echo "[sudo] password for $(id -un):" >&2; exit 1 ;;
esac
EOF
  chmod +x "$stub/sudo"
  run "$work/usb9" "$work/isos2" "$stub"
  check "exit code 1" 1 "$rc"
  contains "clear message" "sudo on this computer asks for the password at each command, so the script cannot copy with sudo." "$out"
  contains "tells how to mount as the user" "Mount the USB as your user" "$out"
  case "$out" in *"📦 bad.iso"*) fail "stops before the first ISO" ;; *) pass "stops before the first ISO" ;; esac
  case "$out" in *"password for"*) fail "no password prompt" ;; *) pass "no password prompt" ;; esac
  chmod 755 "$work/usb9"
fi

echo "== Root-only mount (a folder with mode 0700 owned by root): sudo checks the names on the USB"
if [[ "$(uname -s)" != Linux || "$(id -u)" == 0 ]] || ! sudo -n true 2>/dev/null; then
  skip "needs Linux, a non-root user and passwordless sudo"
else
  rusb=$work/usb-root
  sudo mkdir -m 700 "$rusb"
  run "$rusb" "$work/isos2"
  check "first run: exit code 0" 0 "$rc"
  contains "first run: verified" "✅ bad.iso copied and SHA-256 verified." "$out"
  case "$out" in *"appeared during the copy"*) fail "first run: no false race" ;; *) pass "first run: no false race" ;; esac
  sudo cmp -s "$work/isos2/bad.iso" "$rusb/bad.iso" && pass "first run: same bytes" || fail "first run: same bytes"
  before=$(sudo sh -c 'sha256sum <"$1"; stat -c %Y -- "$1"' sh "$rusb/bad.iso")
  sleep 1.1 # an overwrite would change the mtime
  run "$rusb" "$work/isos2"
  check "second run: exit code 1" 1 "$rc"
  contains "second run: skipped" "⏭️  Skipped: $rusb/bad.iso already exists. It was not changed." "$out"
  check "second run: file unchanged" "$before" "$(sudo sh -c 'sha256sum <"$1"; stat -c %Y -- "$1"' sh "$rusb/bad.iso")"

  # A sudo wrapper: "rm" does nothing and "mv" fails, so the temporary file stays after a failed ISO.
  stub=$work/stub-root-rm
  mkdir -p "$stub" "$work/isos-root"
  head -c 100000 /dev/urandom >"$work/isos-root/other.iso"
  cat >"$stub/sudo" <<EOF
#!/usr/bin/env bash
case " \$* " in *" rm "*) exit 0 ;; *" mv "*) exit 1 ;; esac
exec $(command -v sudo) "\$@"
EOF
  chmod +x "$stub/sudo"
  run "$rusb" "$work/isos-root" "$stub"
  check "temporary file kept: exit code 1" 1 "$rc"
  contains "temporary file kept: warning" "Could not remove the temporary file $rusb/.ventoy-copy-" "$out"
  check "temporary file kept: it is there" 1 "$(sudo find "$rusb" -maxdepth 1 -name '.ventoy-copy-*' | wc -l | tr -d ' ')"
  sudo rm -rf "$rusb"
fi

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

  # The ISO is a link to a file that only root can read. The script must read the ISO as the user.
  stub=$work/stub-fat-sync
  mkdir -p "$stub" "$work/fat-secret"
  sudo sh -c 'head -c 100000 /dev/urandom >"$1" && chmod 600 "$1"' sh "$work/root-only"
  ln -s "$work/root-only" "$work/fat-secret/secret.iso"
  cat >"$stub/sync" <<EOF
#!/usr/bin/env bash
for f in "$loop_mnt"/.ventoy-copy-*; do [[ -e "\$f" ]] && stat -c %s -- "\$f" >>"$work/written"; done
exec "$real_sync" "\$@"
EOF
  chmod +x "$stub/sync"
  run "$loop_mnt" "$work/fat-secret" "$stub"
  check "root-only ISO: exit code 1" 1 "$rc"
  contains "root-only ISO: read as the user" "Permission denied" "$out"
  contains "root-only ISO: failed" "0 copied and SHA-256 verified, 0 skipped (already on the USB), 1 failed." "$out"
  check "root-only ISO: no byte written to the USB" "" "$(cat "$work/written" 2>/dev/null)"
  check "root-only ISO: temporary file removed" 0 "$(temps "$loop_mnt")"

  # A wrapper around the real sudo records each call: the script refreshes the timestamp while it runs.
  stub=$work/stub-fat-sudo
  mkdir -p "$stub" "$work/fat-keep"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\nexec %s "$@"\n' "$work/sudo.log" "$(command -v sudo)" >"$stub/sudo"
  chmod +x "$stub/sudo"
  head -c 3000000 /dev/urandom >"$work/fat-keep/keep.iso"
  run "$loop_mnt" "$work/fat-keep" "$stub"
  check "sudo keep-alive: exit code 0" 0 "$rc"
  grep -qx -- '-n -v' "$work/sudo.log" && pass "sudo keep-alive: timestamp refreshed" || fail "sudo keep-alive: timestamp refreshed: $(cat "$work/sudo.log")"
  pgrep -f "sleep 60" >/dev/null && fail "sudo keep-alive: stopped at exit" || pass "sudo keep-alive: stopped at exit"

  check "FAT32: only the verified ISOs on the USB" "keep.iso small.iso" "$(ls -A "$loop_mnt" | sort | tr '\n' ' ' | sed 's/ $//')"
fi

echo
echo "Linux tests: $passes passed, $failures failed, $skips skipped."
[[ $failures -eq 0 ]]
