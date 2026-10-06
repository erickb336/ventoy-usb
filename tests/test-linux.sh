#!/usr/bin/env bash
# Safe Linux tests for ventoy-add-isos.sh and for the ISO copy of ventoy-install.sh after the install.
# No USB stick is needed and no real disk is touched: most tests copy to a temporary folder,
# and the FAT32 and mount tests use small loop images that this script creates
# (only when passwordless sudo, losetup and mkfs.vfat exist). The tests never run the Ventoy install.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/ventoy-add-isos.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/ventoy-linux-test.XXXXXX")
passes=0 failures=0 skips=0
loop_mnt="" loop_dev=""

cleanup() {
  if [[ -n "$loop_dev" ]]; then
    findmnt -n -o TARGET --source "$loop_dev" 2>/dev/null | while read -r m; do sudo umount "$m"; done
    sudo losetup -d "$loop_dev" 2>/dev/null
  fi
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
alive() { # <pid>: the process runs (a zombie that nobody reaped does not count)
  [[ "$(ps -o stat= -p "$1" 2>/dev/null)" == [^Z]* ]]
}
# run <mount> <iso dir> [PATH prefix]: run the script, answer "y" to the "not a Ventoy mount" question.
run() {
  out=$(PATH="${3:+$3:}$PATH" bash "$script" "$1" "$2" <<<y 2>&1)
  rc=$?
}

real_sync=$(command -v sync)
real_dd=$(command -v dd)
real_sleep=$(command -v sleep)
real_findmnt=$(command -v findmnt)

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
check "exit code 0 (an ISO already on the USB is not a failure)" 0 "$rc"
contains "summary says skipped" "Summary: 0 copied and SHA-256 verified, 2 skipped (already on the USB), 0 failed." "$out"
contains "skip message" "already exists. It was not changed." "$out"
check "files and mtimes unchanged" "$before" "$(hashes "$usb")"
check "no temporary files left" 0 "$(temps "$usb")"

echo "== One new ISO beside an existing one: copy the new one, skip the other"
head -c 500000 /dev/urandom >"$isos/new.iso"
run "$usb" "$isos"
check "exit code 0" 0 "$rc"
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
# Both sides of the copy (the reader with progress and the writer to the USB) record their PID and hang.
case "\$*" in
  *of=*.ventoy-copy-* | *status=progress*) echo \$\$ >>"$stub/pids"; exec "$real_sleep" 30 ;;
  *) exec "$real_dd" "\$@" ;;
esac
EOF
chmod +x "$stub/dd"
PATH="$stub:$PATH" bash "$script" "$work/usb3" "$work/isos2" <<<y >"$work/term.log" 2>&1 &
pid=$!
for _ in $(seq 100); do [[ "$(wc -l <"$stub/pids" 2>/dev/null)" -eq 2 ]] && break; sleep 0.1; done
check "temporary file exists during the copy" 1 "$(temps "$work/usb3")"
kill -TERM "$pid"
wait "$pid"
check "exit code 143" 143 "$?"
check "temporary file removed" 0 "$(temps "$work/usb3")"
[[ -e "$work/usb3/bad.iso" ]] && fail "final name absent" || pass "final name absent"
check "both sides of the copy started" 2 "$(wc -l <"$stub/pids" | tr -d ' ')"
for p in $(cat "$stub/pids"); do
  alive "$p" && { fail "copy process $p stopped"; kill "$p"; } || pass "copy process $p stopped"
done

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
printf '#!/usr/bin/env bash\n[[ "$*" == "-nr -o LABEL,MOUNTPOINT" ]] && printf "Ventoy %%s\\nVentoy %%s\\n" "%s" "%s"\n' "$work/usbA" "$work/usbB" >"$stub/lsblk"
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

echo "== Auto-detect: a mount point with a space (lsblk -r writes it as \x20)"
stub=$work/stub-space
mkdir -p "$stub" "$work/usb space"
printf '#!/usr/bin/env bash\n[[ "$*" == "-nr -o LABEL,MOUNTPOINT" ]] && echo "Ventoy %s"\n' "$work/usb\\x20space" >"$stub/lsblk"
chmod +x "$stub/lsblk"
out=$(PATH="$stub:$PATH" bash "$script" 2>&1 <<EOF

$work/isos2
y
EOF
)
rc=$?
check "exit code 0" 0 "$rc"
contains "whole mount point found" "Auto-detected Ventoy mount at: $work/usb space" "$out"
cmp -s "$work/isos2/bad.iso" "$work/usb space/bad.iso" && pass "copied to the mount point with a space" || fail "copied to the mount point with a space: $out"

echo "== ISO folder with glob characters in its name; .iso in any case; hidden and other files are not copied"
d="$work/isos [1]*"
mkdir -p "$d" "$work/usb-case" "$work/empty [x]"
head -c 1000 /dev/urandom >"$d/UPPER.ISO"
head -c 1000 /dev/urandom >"$d/Mixed.Iso"
head -c 1000 /dev/urandom >"$d/.hidden.iso"
echo text >"$d/notes.txt"
echo text >"$work/empty [x]/notes.txt"
run "$work/usb-case" "$d"
check "exit code 0" 0 "$rc"
contains "summary" "Summary: 2 copied and SHA-256 verified, 0 skipped (already on the USB), 0 failed." "$out"
check "only the ISOs are copied" "Mixed.Iso UPPER.ISO" "$(ls -A "$work/usb-case" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
run "$work/usb-case" "$work/empty [x]"
check "folder without ISOs: exit code 1" 1 "$rc"
contains "folder without ISOs: message" "No .iso files found in $work/empty [x]" "$out"

echo "== The mount point is a link that changes during the copy: the script writes only to the folder that it checked"
stub=$work/stub-relink
mkdir -p "$stub" "$work/usbX" "$work/usbY"
ln -s "$work/usbX" "$work/usb-link"
cat >"$stub/sync" <<EOF
#!/usr/bin/env bash
ln -sfn "$work/usbY" "$work/usb-link"
exec "$real_sync" "\$@"
EOF
chmod +x "$stub/sync"
run "$work/usb-link" "$work/isos2" "$stub"
check "exit code 0" 0 "$rc"
cmp -s "$work/isos2/bad.iso" "$work/usbX/bad.iso" && pass "copied to the folder that was checked" || fail "copied to the folder that was checked: $out"
check "nothing in the new target of the link" "" "$(ls -A "$work/usbY")"

echo "== The direct read probe runs in the C locale, so a translated error message does not matter"
stub=$work/stub-locale
mkdir -p "$stub" "$work/usb-locale"
cat >"$stub/dd" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *iflag=direct*)
    if [[ "\${LC_ALL:-}" == C ]]; then echo "dd: failed to open 'copy': Invalid argument" >&2
    else echo "dd: impossible d'ouvrir 'copy': Argument invalide" >&2; fi
    exit 1 ;;
  *) exec "$real_dd" "\$@" ;;
esac
EOF
chmod +x "$stub/dd"
LC_ALL=C.UTF-8 run "$work/usb-locale" "$work/isos2" "$stub"
check "exit code 0" 0 "$rc"
contains "fallback note" "does not support direct reads" "$out"
cmp -s "$work/isos2/bad.iso" "$work/usb-locale/bad.iso" && pass "same bytes" || fail "same bytes: $out"

echo "== Without direct reads: fincore confirms that the cache drop removed the copy from the cache"
stub=$work/stub-fincore
mkdir -p "$stub" "$work/usb-fc1" "$work/usb-fc2"
cat >"$stub/dd" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *iflag=direct*) echo "dd: failed to open 'copy': Invalid argument" >&2; exit 1 ;;
  *iflag=nocache*) touch "$stub/dropped"; exec "$real_dd" "\$@" ;;
  *) exec "$real_dd" "\$@" ;;
esac
EOF
# fincore: 0 cached pages only after the cache drop.
printf '#!/usr/bin/env bash\nif [[ -e "%s/dropped" ]]; then echo "       0"; else echo "      12"; fi\n' "$stub" >"$stub/fincore"
chmod +x "$stub/dd" "$stub/fincore"
run "$work/usb-fc1" "$work/isos2" "$stub"
check "exit code 0" 0 "$rc"
contains "confirmed note" "The copy is dropped from the page cache and read again from the USB." "$out"
case "$out" in *"could not confirm"*) fail "no doubt in the note" ;; *) pass "no doubt in the note" ;; esac
printf '#!/usr/bin/env bash\necho "      12"\n' >"$stub/fincore"
run "$work/usb-fc2" "$work/isos2" "$stub"
check "pages still cached: exit code 0" 0 "$rc"
contains "pages still cached: the note says so" "could not confirm that the cache was dropped. The check can read the cache, not the USB." "$out"

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
  check "second run: exit code 0" 0 "$rc"
  contains "second run: skipped" "⏭️  Skipped: $rusb/bad.iso already exists. It was not changed." "$out"
  check "second run: file unchanged" "$before" "$(sudo sh -c 'sha256sum <"$1"; stat -c %Y -- "$1"' sh "$rusb/bad.iso")"

  # sudo works for the copy, but fails for each check of a path on the USB ("sudo -n sh" and "sudo -n test").
  real_sudo=$(command -v sudo)
  stub=$work/stub-root-check
  mkdir -p "$stub" "$work/isos-check"
  head -c 100000 /dev/urandom >"$work/isos-check/check.iso"
  cat >"$stub/sudo" <<EOF
#!/usr/bin/env bash
case "\${2:-}" in sh | test) echo "sudo: a password is required" >&2; exit 1 ;; esac
exec $real_sudo "\$@"
EOF
  chmod +x "$stub/sudo"
  run "$rusb" "$work/isos-check" "$stub"
  check "sudo fails at the name check: exit code 1" 1 "$rc"
  contains "sudo fails at the name check: clear message" "Failed: sudo failed, so the script could not check if check.iso is on the USB." "$out"
  check "sudo fails at the name check: nothing written" "bad.iso" "$(sudo ls -A "$rusb")"

  # Every sudo call of the copy must use -n: without it, sudo asks for a password in the middle of the copy.
  stub=$work/stub-root-n
  mkdir -p "$stub"
  cat >"$stub/sudo" <<EOF
#!/usr/bin/env bash
case "\$1" in -v | -n) exec $real_sudo "\$@" ;; esac
echo "[sudo] password for \$(id -un):" >&2
exit 1
EOF
  chmod +x "$stub/sudo"
  run "$rusb" "$work/isos-check" "$stub"
  check "sudo -n: exit code 0" 0 "$rc"
  contains "sudo -n: verified" "check.iso copied and SHA-256 verified." "$out"
  case "$out" in *"password for"*) fail "sudo -n: no password prompt" ;; *) pass "sudo -n: no password prompt" ;; esac

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
  sudo find "$rusb" -maxdepth 1 -name '.ventoy-copy-*' -delete

  # rm does nothing, mv fails, and sudo fails when it checks the temporary file: the script cannot confirm that it is gone.
  stub=$work/stub-root-rm-check
  mkdir -p "$stub"
  cat >"$stub/sudo" <<EOF
#!/usr/bin/env bash
case " \$* " in *" rm "*) exit 0 ;; *" mv "*) exit 1 ;; esac
if [[ "\${2:-}" == @(sh|test) && "\$*" == *.ventoy-copy-* ]]; then echo "sudo: a password is required" >&2; exit 1; fi
exec $real_sudo "\$@"
EOF
  chmod +x "$stub/sudo"
  run "$rusb" "$work/isos-root" "$stub"
  check "temporary file not confirmed gone: exit code 1" 1 "$rc"
  contains "temporary file not confirmed gone: warning" "Could not remove the temporary file $rusb/.ventoy-copy-" "$out"
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

  mkdir -p "$work/fat-case" "$work/fat-char"
  head -c 1000 /dev/urandom >"$work/fat-case/SMALL.iso"
  run "$loop_mnt" "$work/fat-case"
  check "same name in another case: exit code 0" 0 "$rc"
  contains "same name in another case: the name on the USB" "Skipped: $loop_mnt/small.iso already exists. It was not changed." "$out"

  head -c 1000 /dev/urandom >"$work/fat-char/a:b.iso"
  run "$loop_mnt" "$work/fat-char"
  check "character not allowed on FAT32: exit code 1" 1 "$rc"
  contains "character not allowed on FAT32: clear message" "Failed: a:b.iso has a character that FAT32 and exFAT do not allow in a file name" "$out"
  check "character not allowed on FAT32: temporary file removed" 0 "$(temps "$loop_mnt")"

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

  # A wrapper around the real sudo records each call. "sleep 60" of the keep-alive loop takes 0.1 s here.
  stub=$work/stub-fat-sudo
  mkdir -p "$stub" "$work/fat-keep"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\nexec %s "$@"\n' "$work/sudo.log" "$(command -v sudo)" >"$stub/sudo"
  printf '#!/usr/bin/env bash\n[[ "$1" == 60 ]] && exec %s 0.1\nexec %s "$@"\n' "$real_sleep" "$real_sleep" >"$stub/sleep"
  chmod +x "$stub/sudo" "$stub/sleep"
  refreshes() { grep -cx -- '-n -v' "$work/sudo.log"; }
  head -c 3000000 /dev/urandom >"$work/fat-keep/keep.iso"
  run "$loop_mnt" "$work/fat-keep" "$stub"
  check "sudo keep-alive: exit code 0" 0 "$rc"
  [[ "$(refreshes)" -ge 1 ]] && pass "sudo keep-alive: timestamp refreshed" || fail "sudo keep-alive: timestamp refreshed: $(cat "$work/sudo.log")"
  n1=$(refreshes); sleep 1; n2=$(refreshes)
  check "sudo keep-alive: stopped at exit" "$n1" "$n2"

  # The script is killed (SIGKILL), so it cannot stop the keep-alive loop. The loop must stop by itself.
  printf '#!/usr/bin/env bash\ncase "$*" in *status=progress*) exec %s 30 ;; esac\nexec %s "$@"\n' "$real_sleep" "$real_dd" >"$stub/dd"
  chmod +x "$stub/dd"
  mkdir -p "$work/fat-kill"
  head -c 1000 /dev/urandom >"$work/fat-kill/kill.iso"
  PATH="$stub:$PATH" bash "$script" "$loop_mnt" "$work/fat-kill" <<<y >"$work/kill.log" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [[ "$(sudo find "$loop_mnt" -maxdepth 1 -name '.ventoy-copy-*' | wc -l)" -eq 1 ]] && break; sleep 0.1; done
  kids=$(pgrep -P "$pid" | tr '\n' ' ')
  kids="$kids $(for k in $kids; do pgrep -P "$k"; done | tr '\n' ' ')"
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null
  sleep 0.5
  n1=$(refreshes); sleep 1; n2=$(refreshes)
  check "sudo keep-alive: stops after SIGKILL of the script" "$n1" "$n2"
  for k in $kids; do kill "$k" 2>/dev/null; done
  sudo find "$loop_mnt" -maxdepth 1 -name '.ventoy-copy-*' -delete

  check "FAT32: only the verified ISOs on the USB" "keep.iso small.iso" "$(ls -A "$loop_mnt" | sort | tr '\n' ' ' | sed 's/ $//')"
fi

echo "== Mount argument with a line break: refused before any sudo"
stub=$work/stub-newline
mkdir -p "$stub"
printf '#!/usr/bin/env bash\necho "sdz1 Ventoy"\n' >"$stub/lsblk"
printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n' "$work/sudo-newline.log" >"$stub/sudo"
chmod +x "$stub/lsblk" "$stub/sudo"
run "$work/missing1"$'\n'"$work/missing2" "$work/isos2" "$stub"
check "exit code 1" 1 "$rc"
contains "clear message" "The Ventoy mount point contains a line break. Give one mount point." "$out"
check "no sudo call" "" "$(cat "$work/sudo-newline.log" 2>/dev/null)"
[[ -e "$work/missing1" ]] && fail "no folder made" || pass "no folder made"

# Tests of copy_isos_to in ventoy-install.sh: the copy to the USB that the installer just installed.
installer=$root/ventoy-install.sh
# hand_off <device> <PATH prefix> <downloaded ISO folder>: call copy_isos_to as the installer does after the install.
hand_off() {
  out=$(cd "$root" && TEMP_ISO_DIR=$3 PATH="$2:$PATH" bash -c 'source "$1"; copy_isos_to "$2"' _ "$installer" "$1" <<<y 2>&1)
  rc=$?
}

echo "== Install hand-off: two Ventoy USBs are connected, the installed one is the second"
stub=$work/stub-handoff
mkdir -p "$stub" "$work/hA" "$work/hB" "$work/dl1"
cat >"$stub/lsblk" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-nrp -o NAME,LABEL /dev/fakeA") printf '/dev/fakeA \n/dev/fakeA1 Ventoy\n/dev/fakeA2 VTOYEFI\n' ;;
  "-nrp -o NAME,LABEL /dev/fakeB") printf '/dev/fakeB \n/dev/fakeB1 Ventoy\n/dev/fakeB2 VTOYEFI\n' ;;
  "-nrp -o NAME,LABEL /dev/fakeC") printf '/dev/fakeC \n/dev/fakeC1 \n' ;;
  "-nrp -o NAME,LABEL /dev/fakeD") printf '/dev/fakeD \n/dev/fakeD1 Ventoy\n/dev/fakeD2 Ventoy\n' ;;
  *) printf 'Ventoy $work/hA\nVentoy $work/hB\n' ;; # all devices: the other USB comes first
esac
EOF
cat >"$stub/findmnt" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-n -f -o TARGET --source /dev/fakeA1") echo "$work/hA" ;;
  "-n -f -o TARGET --source /dev/fakeB1") echo "$work/hB" ;;
  *) exec "$real_findmnt" "\$@" ;;
esac
EOF
chmod +x "$stub/lsblk" "$stub/findmnt"
cp "$work/isos2/bad.iso" "$work/dl1/dl.iso"
hand_off /dev/fakeB "$stub" "$work/dl1"
check "exit code 0" 0 "$rc"
contains "mount of the installed USB" "Ventoy partition /dev/fakeB1 is mounted at: $work/hB" "$out"
cmp -s "$work/isos2/bad.iso" "$work/hB/dl.iso" && pass "copied to the installed USB" || fail "copied to the installed USB: $out"
check "other Ventoy USB unchanged" "" "$(ls -A "$work/hA")"
[[ -e "$work/dl1" ]] && fail "downloads removed after a complete copy" || pass "downloads removed after a complete copy"

echo "== Install hand-off: a download that is already on the USB counts as copied"
mkdir -p "$work/dl2"
cp "$work/isos2/bad.iso" "$work/dl2/dl.iso" # already on the USB: skipped
head -c 100000 /dev/urandom >"$work/dl2/new.iso"
hand_off /dev/fakeB "$stub" "$work/dl2"
check "exit code 0" 0 "$rc"
contains "skip line in the summary" "skipped: dl.iso" "$out"
[[ -e "$work/dl2" ]] && fail "downloads removed: each one is on the USB" || pass "downloads removed: each one is on the USB"

echo "== Install hand-off: no Ventoy partition, or two, on the installed USB: stop, copy nothing"
for dev in /dev/fakeC:0 /dev/fakeD:2; do
  mkdir -p "$work/dl3"
  cp "$work/isos2/bad.iso" "$work/dl3/other.iso"
  hand_off "${dev%:*}" "$stub" "$work/dl3"
  check "${dev%:*}: exit code 1" 1 "$rc"
  contains "${dev%:*}: clear message" "Expected 1 partition with the label Ventoy on ${dev%:*}, found ${dev#*:}. No ISO was copied." "$out"
  contains "${dev%:*}: how to copy later without a mount" "To copy them later, connect the USB, run ./ventoy.sh and choose 2." "$out"
  check "${dev%:*}: downloads kept" "other.iso" "$(ls -A "$work/dl3")"
  check "${dev%:*}: nothing copied to another Ventoy USB" "" "$(ls -A "$work/hA")"
  rm -rf "$work/dl3"
done

echo "== Installer read from stdin (bash -s): the source guard works without BASH_SOURCE"
stub=$work/stub-stdin
mkdir -p "$stub" "$work/stdin-run"
printf '#!/usr/bin/env bash\nexit 22\n' >"$stub/curl"
chmod +x "$stub/curl"
out=$(cd "$work/stdin-run" && PATH="$stub:$PATH" bash -s 9.9.9 <"$installer" 2>&1)
contains "the installer runs" "Using specified Ventoy version: 9.9.9" "$out"
case "$out" in *"unbound variable"*) fail "no unbound variable" ;; *) pass "no unbound variable" ;; esac

echo "== Installer downloads: each file gets a name that ends in .iso; two equal names stop before any download"
stub=$work/stub-curl
mkdir -p "$stub" "$work/dltmp"
cat >"$stub/curl" <<EOF
#!/usr/bin/env bash
while (( \$# )); do case \$1 in -o) out=\$2; shift ;; esac; url=\$1; shift; done
echo "\$url" >>"$stub/calls"
printf 'ISO %s' "\$url" >"\$out"
EOF
chmod +x "$stub/curl"
download() { # <url>...: call download_isos as the installer does, then print the folder
  out=$(cd "$root" && TMPDIR=$work/dltmp PATH="$stub:$PATH" bash -c 'source "$1"; shift; download_isos "$@"; echo "DIR=$TEMP_ISO_DIR"' _ "$installer" "$@" 2>&1)
  rc=$?
}
download 'https://example.test/a.iso?x=1#top' 'https://example.test/get' 'https://example.test/B.ISO' 'https://example.test/dir/'
check "exit code 0" 0 "$rc"
dir=$(sed -n 's/^DIR=//p' <<<"$out")
check "file names" "B.ISO a.iso download.iso get.iso" "$(ls -A "$dir" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
check "the full URL is downloaded" "ISO https://example.test/a.iso?x=1#top" "$(cat "$dir/a.iso" 2>/dev/null)"
rm -f "$stub/calls"
download 'https://a.test/x.iso' 'https://b.test/X.iso?y=1'
check "same name: exit code 1" 1 "$rc"
contains "same name: clear message" "Two URLs give the same file name: X.iso. Give each ISO once. Aborted." "$out"
check "same name: nothing downloaded" "" "$(cat "$stub/calls" 2>/dev/null)"

echo "== Install hand-off: a download that is not copied (a hidden file) keeps the downloads; the command is pasteable"
stub=$work/stub-handoff
dl="$work/dl 5"
mkdir -p "$dl"
head -c 1000 /dev/urandom >"$dl/v.iso"
head -c 1000 /dev/urandom >"$dl/.h.iso"
hand_off /dev/fakeB "$stub" "$dl"
check "exit code 1" 1 "$rc"
contains "the download is named" "The download .h.iso is not on the USB." "$out"
check "downloads kept" ".h.iso v.iso" "$(ls -A "$dl" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
contains "pasteable command" "run: ./ventoy-add-isos.sh $(printf '%q %q' "$work/hB" "$dl")" "$out"

echo "== Install hand-off: the Ventoy partition is not mounted (loop image): mount at a new folder, copy, unmount"
if [[ "$(uname -s)" != Linux ]] || ! sudo -n true 2>/dev/null || ! command -v mkfs.vfat >/dev/null || ! command -v losetup >/dev/null; then
  skip "needs Linux, passwordless sudo, losetup and mkfs.vfat"
else
  img=$work/handoff.img
  truncate -s 64M "$img"
  mkfs.vfat -F 32 -n Ventoy "$img" >/dev/null
  # Only the loop device that losetup returns for this image is used.
  loop_dev=$(sudo losetup -f --show "$img")
  stub=$work/stub-handoff-loop
  mkdir -p "$stub" "$work/dl4"
  printf '#!/usr/bin/env bash\n[[ "$*" == "-nrp -o NAME,LABEL %s" ]] && echo "%s Ventoy"\n' "$loop_dev" "$loop_dev" >"$stub/lsblk"
  chmod +x "$stub/lsblk"
  # The question for an ISO folder comes before the mount: an interrupted answer (here: end of input) leaves no mount.
  mnts_before=$(ls -d /mnt/ventoy.* 2>/dev/null)
  out=$(cd "$root" && TEMP_ISO_DIR="" PATH="$stub:$PATH" bash -c 'source "$1"; copy_isos_to "$2"' _ "$installer" "$loop_dev" </dev/null 2>&1)
  check "no answer to the folder question: no mount" "" "$(findmnt -n -o TARGET --source "$loop_dev")"
  check "no answer to the folder question: no new folder in /mnt" "$mnts_before" "$(ls -d /mnt/ventoy.* 2>/dev/null)"
  head -c 300000 /dev/urandom >"$work/dl4/loop.iso"
  cp "$work/dl4/loop.iso" "$work/loop.iso"
  hand_off "$loop_dev" "$stub" "$work/dl4"
  check "exit code 0" 0 "$rc"
  contains "mount announced" "Ventoy partition $loop_dev is not mounted. Mounting it..." "$out"
  m=$(sed -n "s|^📂 Ventoy partition $loop_dev is mounted at: ||p" <<<"$out")
  case "$m" in /mnt/ventoy.??????) pass "mounted at a new folder in /mnt that only root can change" ;; *) fail "mounted at a new folder in /mnt that only root can change: [$m]" ;; esac
  check "unmounted after the copy" "" "$(findmnt -n -o TARGET --source "$loop_dev")"
  [[ -n "$m" && ! -e "$m" ]] && pass "temporary folder removed" || fail "temporary folder removed: [$m]"
  [[ -e "$work/dl4" ]] && fail "downloads removed after a complete copy" || pass "downloads removed after a complete copy"
  chk=$(mktemp -d "${TMPDIR:-/tmp}/ventoy-check.XXXXXX")
  sudo mount -o ro "$loop_dev" "$chk"
  cmp -s "$work/loop.iso" "$chk/loop.iso" && pass "ISO on the installed USB" || fail "ISO on the installed USB"
  sudo umount "$chk"
  rmdir "$chk"

  echo "== Installer, whole run with stubs: Ventoy2Disk is a stub script, nothing writes to a disk"
  # The device is the loop device of this test (only for the block device check). The stub Ventoy2Disk.sh asks
  # the two questions of the real one and records the install. lsblk shows the Ventoy partition only after that.
  e2e=$work/e2e
  stub=$e2e/stub
  mkdir -p "$e2e/app" "$stub" "$e2e/usb" "$e2e/pkg/ventoy-9.9.9" "$e2e/tmp"
  cp "$installer" "$script" "$e2e/app/"
  cat >"$e2e/pkg/ventoy-9.9.9/Ventoy2Disk.sh" <<EOF
#!/usr/bin/env bash
read -rp 'Continue? (y/n) ' a; [[ \$a == y ]] || exit 0
read -rp 'Double-check. Continue? (y/n) ' a; [[ \$a == y ]] || exit 0
touch "$e2e/installed"
echo "Install Ventoy to \$2 successfully finished."
EOF
  chmod +x "$e2e/pkg/ventoy-9.9.9/Ventoy2Disk.sh"
  tar -czf "$e2e/ventoy.tar.gz" -C "$e2e/pkg" ventoy-9.9.9
  cat >"$stub/curl" <<EOF
#!/usr/bin/env bash
while (( \$# )); do case \$1 in -o) out=\$2; shift ;; esac; url=\$1; shift; done
case \$url in *-linux.tar.gz) cp "$e2e/ventoy.tar.gz" "\$out" ;; *) printf 'ISO %s' "\$url" >"\$out" ;; esac
EOF
  cat >"$stub/lsblk" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-nrp -o NAME,LABEL $loop_dev") echo "$loop_dev "; [[ -e "$e2e/installed" ]] && echo "/dev/vlhfake1 Ventoy" ;;
  "-o TRAN $loop_dev") printf 'TRAN\nusb\n' ;;
  "-o SIZE -n $loop_dev") echo 1G ;;
  "-o NAME $loop_dev") printf 'NAME\nvlhfake\n' ;;
  *) printf 'NAME TRAN SIZE MODEL MOUNTPOINT\nvlhfake usb 1G Fake\n' ;;
esac
EOF
  cat >"$stub/findmnt" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-n -f -o TARGET --source /dev/vlhfake1") echo "$e2e/usb" ;;
  "-n -o LABEL --mountpoint $e2e/usb") echo Ventoy ;;
  *) exec "$real_findmnt" "\$@" ;;
esac
EOF
  # sudo runs the command as this user. partprobe fails when the file partprobe-fails exists.
  printf '#!/usr/bin/env bash\nwhile [[ "$1" == -* ]]; do shift; done\nexec "$@"\n' >"$stub/sudo"
  printf '#!/usr/bin/env bash\n[[ ! -e "%s/partprobe-fails" ]]\n' "$e2e" >"$stub/partprobe"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$stub/udevadm"
  cp "$stub/udevadm" "$stub/umount"
  cp "$stub/udevadm" "$stub/sleep"
  chmod +x "$stub"/*
  install_run() { # <input>: run the installer with the stubs, from a copy of the scripts
    rm -f "$e2e/installed"
    out=$(cd "$e2e/app" && TMPDIR=$e2e/tmp PATH="$stub:$PATH" bash ventoy-install.sh 9.9.9 <<<"$1" 2>&1)
    rc=$?
    dl=$(sed -n 's/^📥 Downloading ISOs to \(.*\)\.\.\.$/\1/p' <<<"$out")
  }

  install_run "$loop_dev
YES
yhttps://example.test/one.iso?x=1 https://example.test/get
y
y"
  check "complete run: exit code 0" 0 "$rc"
  contains "complete run: end message" "🎉 Ventoy USB is ready!" "$out"
  check "complete run: ISOs on the USB" "get.iso one.iso" "$(ls -A "$e2e/usb" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  [[ -n "$dl" && ! -e "$dl" ]] && pass "complete run: downloads removed" || fail "complete run: downloads removed: [$dl]"

  install_run "$loop_dev
YES
yhttps://example.test/one.iso
y
y"
  check "ISO already on the USB: exit code 0" 0 "$rc"
  contains "ISO already on the USB: skip line" "skipped: one.iso" "$out"
  contains "ISO already on the USB: end message" "🎉 Ventoy USB is ready!" "$out"

  install_run "$loop_dev
YES
yhttps://example.test/.hidden.iso
y
y"
  check "ISO not copied: exit code 1" 1 "$rc"
  contains "ISO not copied: end message" "⚠️  Ventoy is installed, but not all ISOs were copied. See the messages above." "$out"
  case "$out" in *"Ventoy USB is ready"*) fail "ISO not copied: not ready" ;; *) pass "ISO not copied: not ready" ;; esac
  [[ -e "$dl/.hidden.iso" ]] && pass "ISO not copied: downloads kept" || fail "ISO not copied: downloads kept: [$dl]"

  install_run "$loop_dev
YES
yhttps://example.test/no.iso
n"
  check "answer n to Ventoy2Disk: exit code 1" 1 "$rc"
  contains "answer n to Ventoy2Disk: clear message" "❌ Ventoy was not installed on $loop_dev. See the messages above." "$out"
  case "$out" in *"Ventoy installed successfully"*) fail "answer n to Ventoy2Disk: no success message" ;; *) pass "answer n to Ventoy2Disk: no success message" ;; esac
  contains "answer n to Ventoy2Disk: downloads named" "The script kept them in: $dl" "$out"
  contains "answer n to Ventoy2Disk: how to copy later" "run ./ventoy.sh and choose 2" "$out"
  [[ -e "$dl/no.iso" ]] && pass "answer n to Ventoy2Disk: downloads kept" || fail "answer n to Ventoy2Disk: downloads kept: [$dl]"

  touch "$e2e/partprobe-fails"
  install_run "$loop_dev
YES
yhttps://example.test/late.iso
y
y"
  rm -f "$e2e/partprobe-fails"
  check "partprobe fails: exit code 1" 1 "$rc"
  contains "partprobe fails: downloads named" "The script kept them in: $dl" "$out"
  [[ -e "$dl/late.iso" ]] && pass "partprobe fails: downloads kept" || fail "partprobe fails: downloads kept: [$dl]"

  # A TEMP_ISO_DIR in the environment is not a download of this run: the installer never copies or removes it.
  mkdir -p "$e2e/other"
  head -c 1000 /dev/urandom >"$e2e/other/other.iso"
  out=$(cd "$e2e/app" && rm -f "$e2e/installed" && TEMP_ISO_DIR=$e2e/other TMPDIR=$e2e/tmp PATH="$stub:$PATH" bash ventoy-install.sh 9.9.9 2>&1 <<<"$loop_dev
YES
Ny
y
")
  rc=$?
  check "TEMP_ISO_DIR from the environment: exit code 0" 0 "$rc"
  [[ -e "$e2e/other/other.iso" ]] && pass "TEMP_ISO_DIR from the environment: not removed" || fail "TEMP_ISO_DIR from the environment: not removed"
  [[ -e "$e2e/usb/other.iso" ]] && fail "TEMP_ISO_DIR from the environment: not copied" || pass "TEMP_ISO_DIR from the environment: not copied"
fi

echo
echo "Linux tests: $passes passed, $failures failed, $skips skipped."
[[ $failures -eq 0 ]]
