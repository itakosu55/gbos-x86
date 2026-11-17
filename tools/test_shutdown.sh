#!/bin/sh
# test_shutdown.sh: runs usb/shutdown.sh against a fake /proc, a canned "ls -l /proc/*/fd" listing and stub busybox / kill / sync
# (no Android, no root), under dash and busybox sh. Checks: only stage0's helpers (process group 0 + initramfs root) are killed, never
# init, kernel threads, zombies or init's own children; other processes are killed only for a file open for writing on GBOSSYS; nothing
# is killed for /metadata; /metadata is remounted before GBOSSYS, both with a device and a directory (no extra options); the log is
# complete before GBOSSYS goes read-only; a remaining writer is reported and the power-off is not blocked; and hook.sh wires the
# "on shutdown" action (SHUTDOWN_RO=0 turns it off) and every deploy list ships the script.
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$HERE/..
S=$ROOT/usb/shutdown.sh; H=$ROOT/usb/hook.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

sh -n "$S" && sh -n "$H" && ok "sh -n shutdown.sh hook.sh" || bad "syntax"

mkdir -p $T/bin $T/newroot $T/oldroot $T/log
# kill: record, then the process is gone (its /proc dir and its fds)
cat > $T/bin/kill <<'EOF'
#!/bin/sh
shift
echo "$@" >> "$FAKE_T/kills"
for p in "$@"; do
  rm -rf "$FAKE_T/proc/$p"
  awk -v p="$p" '/\/fd:$/ { skip = ($0 ~ ("/" p "/fd:$")) } !skip' "$FAKE_T/fdlist" > "$FAKE_T/fdlist.n" && mv "$FAKE_T/fdlist.n" "$FAKE_T/fdlist"
done
EOF
# busybox mount -o remount,ro DEV DIR: EBUSY while the listing still has a file open for writing below DIR
cat > $T/bin/bb <<'EOF'
#!/bin/sh
echo "$@" >> "$FAKE_T/bb"
d=$5
[ "$d" = /postinstall ] && pat=' -> (/postinstall|/gbos)/' || pat=" -> $d/"
if grep -E '^l.w' "$FAKE_T/fdlist" | grep -q -E "$pat"; then echo "mount: mounting $4 on $d failed: Device or resource busy" >&2; exit 1; fi
echo remounted >> "$FAKE_T/log/shutdown.txt.after"
EOF
printf '#!/bin/sh\necho sync >> "$FAKE_T/syncs"\n' > $T/bin/sync
chmod +x $T/bin/*

# pid state ppid pgrp root(new|old|none) comm
mkproc() {
  mkdir -p $T/proc/$1
  echo "$1 ($6) $2 $3 $4 0 0 0" > $T/proc/$1/stat
  echo "$6" > $T/proc/$1/comm
  case $5 in new) ln -s $T/newroot $T/proc/$1/root;; old) ln -s $T/oldroot $T/proc/$1/root;; esac
}
setup() {
  rm -rf $T/proc $T/kills $T/bb $T/syncs $T/log/*
  mkproc 1       S 0       0       new init
  mkproc 2       S 0       0       old kthreadd
  mkproc 4000030 I 2       0       old kworker/0:1       # kernel thread: initramfs root, pgrp 0, but a child of kthreadd
  mkproc 4000242 S 1       0       old init              # stage0's kmsg.log copier loop
  mkproc 4000245 S 4000242 0       old busybox           # its cat, appending to kmsg.log
  mkproc 4001217 S 1       0       old busybox           # kvmtrace.txt dd
  mkproc 4000903 S 1       0       old 'a) b (c'         # stage0 helper with ") " in its name
  mkproc 4000300 S 1       0       new init              # pgrp 0 but Android's root (e.g. an init subcontext): keep
  mkproc 4000301 Z 1       0       old busybox           # zombie: nothing to kill
  mkproc 4000302 S 1       0       none sh               # root not readable: not proof of anything, keep
  mkproc 4000900 S 1       4000900 new logcat            # gbos_logcat that has not exited yet
  mkproc 4000905 S 1       4000905 new reader            # reads super.img: keep
  mkproc 4000910 S 1       4000910 new aconfigd          # writes /metadata: never killed
  cat > $T/fdlist <<EOF
/proc/4000245/fd:
total 0
lr-x------ 1 root root 64 2026-11-17 14:54 3 -> /dev/kmsg
l-wx------ 1 root root 64 2026-11-17 14:54 1 -> /gbos/gbos/logs/boot-9/kmsg.log

/proc/4000900/fd:
l-wx------ 1 root root 64 2026-11-17 14:54 3 -> /postinstall/gbos/logs/boot-9/logcat.txt
lrwx------ 1 root root 64 2026-11-17 14:54 4 -> /data/misc/x

/proc/4000905/fd:
lr-x------ 1 root root 64 2026-11-17 14:54 5 -> /postinstall/gbos/super.img
EOF
  cat > $T/mounts <<EOF
/dev/nvme0n1p7 /postinstall vfat rw,relatime,fmask=0000,dmask=0000,codepage=437,shortname=mixed,errors=remount-ro 0 0
/dev/nvme0n1p8 /metadata ext4 rw,seclabel,nosuid,nodev,noatime 0 0
EOF
}
export FAKE_T=$T GBOS_SD_LOGDIR=$T/log GBOS_SD_PROC=$T/proc GBOS_SD_MOUNTS=$T/mounts GBOS_SD_FDLIST=$T/fdlist \
       GBOS_SD_BB=$T/bin/bb GBOS_SD_KILL=$T/bin/kill GBOS_SD_SYNC=$T/bin/sync GBOS_SD_KMSG=$T/kmsg GBOS_SD_WAIT=0
LOG=$T/log/shutdown.txt
killed() { tr ' ' '\n' < $T/kills 2>/dev/null | grep -qx "$1"; }

for SH in dash "busybox sh"; do
  command -v ${SH%% *} >/dev/null 2>&1 || { echo "skip $SH (not installed)"; continue; }
  echo "== $SH"

  # 1. a normal shutdown
  setup
  $SH $S 9 >/dev/null 2>&1; rc=$?
  [ $rc = 0 ] && ok "exit 0" || bad "exit $rc"
  for p in 4000242 4000245 4001217 4000903; do killed $p && ok "stage0 helper $p killed" || bad "stage0 helper $p not killed"; done
  for p in 1 2 4000030 4000300 4000301 4000302 4000905 4000910; do killed $p && bad "$p killed" || ok "$p kept"; done
  killed 4000900 && ok "a gbos service still writing to GBOSSYS is killed" || bad "writer 4000900 not killed"
  grep -q 'kill 4000903 (a) b (c): stage0 helper' $LOG && ok "a name with ') ' is parsed and logged" || bad "odd name: $(grep 4000903 $LOG)"
  [ "$(sed -n 1p $T/bb)" = "mount -o remount,ro /dev/nvme0n1p8 /metadata" ] && ok "/metadata first, as remount,ro DEV DIR" || bad "first remount: $(sed -n 1p $T/bb)"
  [ "$(sed -n 2p $T/bb)" = "mount -o remount,ro /dev/nvme0n1p7 /postinstall" ] && ok "then GBOSSYS, as remount,ro DEV DIR" || bad "second remount: $(sed -n 2p $T/bb)"
  [ "$(wc -l < $T/bb | tr -d ' ')" = 2 ] && ok "one remount each" || bad "remounts: $(cat $T/bb)"
  grep -q '/metadata (/dev/nvme0n1p8) remounted read-only' $LOG && ok "/metadata result logged" || bad "/metadata result not logged"
  tail -1 $LOG | grep -q 'this log ends here' && ok "log complete before GBOSSYS goes read-only (last line)" || bad "last log line: $(tail -1 $LOG)"
  [ "$(wc -l < $T/syncs | tr -d ' ')" -ge 2 ] && ok "synced before the remounts" || bad "syncs: $(cat $T/syncs 2>&1)"
  grep -q 'gbos-shutdown: shutdown.sh start' $T/kmsg && ok "also logs to kmsg" || bad "no kmsg lines"

  # 2. init itself still writes to GBOSSYS: never killed, remount fails, reported, power-off not blocked
  setup
  printf '/proc/1/fd:\nl-wx------ 1 root root 64 2026-11-17 14:54 9 -> /postinstall/gbos/logs/x\n' >> $T/fdlist
  $SH $S 9 >/dev/null 2>&1; rc=$?
  [ $rc = 0 ] && ok "exit 0 with a writer left" || bad "exit $rc"
  killed 1 && bad "init killed" || ok "init never killed"
  grep -q 'remount ro FAILED (try 2)' $LOG && grep -q 'writer: pid 1 (init) /postinstall/gbos/logs/x' $LOG && grep -q 'stays read-write' $LOG \
    && ok "failure, the writer and the outcome are logged" || bad "failure log: $(cat $LOG)"

  # 3. something writes to /metadata: not killed, /metadata stays rw (logged), GBOSSYS still goes read-only
  setup
  printf '/proc/4000910/fd:\nlrwx------ 1 root root 64 2026-11-17 14:54 7 -> /metadata/aconfig/flags.val\n' >> $T/fdlist
  $SH $S 9 >/dev/null 2>&1
  killed 4000910 && bad "/metadata writer killed" || ok "/metadata writer not killed"
  grep -q '/metadata (/dev/nvme0n1p8) remount ro FAILED' $LOG && grep -q '/metadata writer: pid 4000910 (aconfigd)' $LOG \
    && ok "/metadata failure and writer logged" || bad "/metadata failure log: $(cat $LOG)"
  grep -q 'remount,ro /dev/nvme0n1p7 /postinstall' $T/bb && [ -s $T/log/shutdown.txt.after ] && ok "GBOSSYS still remounted" || bad "GBOSSYS not remounted"

  # 4. live boot: /metadata is tmpfs, left alone
  setup
  printf '/dev/sdb2 /postinstall vfat rw 0 0\ntmpfs /metadata tmpfs rw 0 0\n' > $T/mounts
  $SH $S 9 >/dev/null 2>&1
  grep -q /metadata $T/bb && bad "tmpfs /metadata remounted" || ok "tmpfs /metadata left alone"
  grep -q 'remount,ro /dev/sdb2 /postinstall' $T/bb && ok "stick remounted read-only" || bad "stick: $(cat $T/bb)"

  # 5. a loop device (gbos/metadata.img) keeps GBOSSYS busy with no process holding it: reported, no kill spree
  setup
  cat > $T/bin/bb <<'EOF'
#!/bin/sh
echo "$@" >> "$FAKE_T/bb"; [ "$5" = /postinstall ] && { echo "Device or resource busy" >&2; exit 1; }; exit 0
EOF
  chmod +x $T/bin/bb
  $SH $S 9 >/dev/null 2>&1; rc=$?
  [ $rc = 0 ] && grep -q 'no process has a file open for writing there' $LOG && [ "$(grep -c 'remount,ro /dev/nvme0n1p7' $T/bb)" = 1 ] \
    && ok "busy with no writer: one try, reason logged" || bad "loop case: rc=$rc $(cat $LOG)"
  cat > $T/bin/bb <<'EOF'
#!/bin/sh
echo "$@" >> "$FAKE_T/bb"
d=$5
[ "$d" = /postinstall ] && pat=' -> (/postinstall|/gbos)/' || pat=" -> $d/"
if grep -E '^l.w' "$FAKE_T/fdlist" | grep -q -E "$pat"; then echo "mount: mounting $4 on $d failed: Device or resource busy" >&2; exit 1; fi
echo remounted >> "$FAKE_T/log/shutdown.txt.after"
EOF
  chmod +x $T/bin/bb
done

# 6. hook.sh: the "on shutdown" action, generated the way hook.sh does it
awk '/^  if \[ "\$\{SHUTDOWN_RO:-1\}" != 0 \]/{p=1} p{print} p&&/; fi$/{exit}' $H > $T/rc.sh
[ -s $T/rc.sh ] && ok "hook.sh: SHUTDOWNRC block found" || bad "hook.sh: SHUTDOWNRC block missing"
mkdir -p $T/g && : > $T/g/shutdown.sh
RC=$(G=$T/g N=7 sh -c ". $T/rc.sh; echo \"\$SHUTDOWNRC\"")
echo "$RC" | grep -q '^on shutdown$' && ok "rc: on shutdown" || bad "rc: no 'on shutdown': $RC"
for s in gbos_logcat gbos_crashlog gbos_sync gbos_nativezygote; do
  echo "$RC" | grep -q "^    stop $s$" && ok "rc stops $s" || bad "rc does not stop $s"
  grep -q "^service $s " $H && ok "$s is a service in gbos.rc" || bad "$s is not defined in gbos.rc"
done
echo "$RC" | grep -q '^    exec u:r:shell:s0 root root -- /system/bin/sh /postinstall/gbos/shutdown.sh 7$' && ok "rc: exec with seclabel and the boot number" || bad "rc exec line: $RC"
[ "$(echo "$RC" | tail -1 | grep -c exec)" = 1 ] && ok "rc: the script runs after the stops" || bad "rc order"
RC0=$(G=$T/g N=7 SHUTDOWN_RO=0 sh -c ". $T/rc.sh; echo \"\$SHUTDOWNRC\"")
case $RC0 in "#"*) ok "SHUTDOWN_RO=0: only a comment";; *) bad "SHUTDOWN_RO=0: $RC0";; esac
RCM=$(G=$T/none N=7 sh -c ". $T/rc.sh; echo \"\$SHUTDOWNRC\"")
case $RCM in "#"*) ok "no gbos/shutdown.sh: only a comment";; *) bad "missing script: $RCM";; esac
awk '/cat > \/tmp\/sysinit\/gbos.rc <<RC/{p=1;next} /^RC$/{p=0} p' $H | grep -q '^\$SHUTDOWNRC$' && ok "gbos.rc contains \$SHUTDOWNRC" || bad "\$SHUTDOWNRC not in gbos.rc"
grep -q '^#SHUTDOWN_RO=0' $ROOT/usb/gbos.cfg && ok "gbos.cfg documents SHUTDOWN_RO" || bad "gbos.cfg lacks SHUTDOWN_RO"
for f in tools/deploy_stick.sh tools/make_gbos86_image.sh tools/install_dualboot.sh usb/install.sh; do
  grep -q 'shutdown\.sh' $ROOT/$f && ok "$f ships shutdown.sh" || bad "$f does not ship shutdown.sh"
done

[ $fail = 0 ] && echo SHUTDOWN_PASS || { echo SHUTDOWN_FAIL; exit 1; }
