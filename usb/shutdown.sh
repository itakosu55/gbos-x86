#!/system/bin/sh
# shutdown.sh N: leave GBOSSYS (the gbOS system partition or stick, /postinstall in Android) and /metadata read-only before power-off.
# Run by init from gbos.rc at "on shutdown" (sys.powerctl: power off and reboot), as root, before init's own shutdown sequence.
#
# Why: init's shutdown (reboot.cpp TryUmountAndFsck) unmounts only mounts whose source starts with /dev/block. stage0 mounts GBOSSYS and
# GBOS_META by their /dev/nvme*, /dev/sd* names, so both stayed read-write until power-off. Every boot logged "FAT-fs (nvme0n1p7): Volume
# was not properly unmounted" and "GBOS_META: recovering journal" (dynabook GZ/HWL, boot-2..9, HANDOFF.md 2026-11-17), and the stage0 log
# copier was still appending to kmsg.log when the power went. GBOSSYS cannot be unmounted at all (Android's system/vendor/product are erofs
# on loop devices backed by super.img on it), but it can be remounted read-only once no process has a file open there for writing (the
# loop devices are opened read-only by losetup -r and do not count). A read-only remount clears the FAT dirty bit and lets ext4 mark
# /metadata clean.
#
# Writers on GBOSSYS at this point: gbos_logcat, gbos_crashlog, gbos_sync and gbos_nativezygote (the rc stops them before this runs), and
# stage0's helpers, which outlive switch_root: the kmsg.log copier, the 5 s sync loop and the kvmtrace.txt dd. Those are found by two
# facts that only they have: process group 0 (nothing init starts has it) and a root directory that is still the initramfs, not Android's
# /. Any other process still writing to GBOSSYS is killed too, by name in the log. /metadata is only remounted, nothing is killed for it:
# if a file is open there for writing it stays read-write as before (logged with the process).
#
# Cost: kmsg.log ends here, so the rest of init's shutdown is not in the log any more. SHUTDOWN_RO=0 in gbos.cfg turns this script off.
# Not covered: a dual-boot install whose /metadata is gbos/metadata.img on a loop device: that loop keeps the image open read-write, so
# GBOSSYS stays read-write (logged).
#
# Log: logs/boot-N/shutdown.txt, written before GBOSSYS goes read-only (a failure is appended). Proof of success is in the next boot:
# no "Volume was not properly unmounted" in kmsg.log, and fsck.txt without "recovering journal" for GBOS_META.
# Test hooks (tools/test_shutdown.sh): GBOS_SD_LOGDIR, GBOS_SD_PROC, GBOS_SD_MOUNTS, GBOS_SD_FDLIST, GBOS_SD_BB, GBOS_SD_KILL,
# GBOS_SD_SYNC, GBOS_SD_KMSG, GBOS_SD_WAIT.
N=$1
L=${GBOS_SD_LOGDIR:-/postinstall/gbos/logs/boot-$N}
P=${GBOS_SD_PROC:-/proc}
MOUNTS=${GBOS_SD_MOUNTS:-/proc/mounts}
BB=${GBOS_SD_BB:-/postinstall/busybox}
KILL=${GBOS_SD_KILL:-kill}
SYNC=${GBOS_SD_SYNC:-sync}
KMSG=${GBOS_SD_KMSG:-/dev/kmsg}
WAIT=${GBOS_SD_WAIT:-1}
O=$L/shutdown.txt
FAT=/postinstall

log() {
  echo "$(date +%T 2>/dev/null) $*" >> "$O" 2>/dev/null
  echo "<6>gbos-shutdown: $*" >> "$KMSG" 2>/dev/null
}
# a stuck disk must not hang the power-off: init waits for this script before its own shutdown
to() { if command -v timeout >/dev/null 2>&1; then timeout 10 "$@"; else "$@"; fi; }

# "device type" of the mount on $1 (the last one, as in /proc/mounts order), empty if none
mount_of() {
  _r=
  while read -r _dev _dir _type _rest; do [ "$_dir" = "$1" ] && _r="$_dev $_type"; done < "$MOUNTS"
  echo "$_r"
}

# stage0 helpers that survived switch_root: process group 0 and a root directory that exists but is not init's.
# Kernel threads (kthreadd = 2 and its children) and zombies are left alone.
stage0_pids() {
  for _d in $P/[0-9]*; do
    _p=${_d##*/}
    [ "$_p" = 1 ] || [ "$_p" = "$$" ] && continue
    read -r _st < "$_d/stat" 2>/dev/null || continue
    set -- ${_st##*) }
    [ "$_p" = 2 ] || [ "$2" = 2 ] || [ "$1" = Z ] && continue
    [ "$3" = 0 ] || continue
    [ -d "$_d/root/." ] || continue
    [ "$_d/root" -ef "$P/1/root" ] && continue
    echo "$_p"
  done
}

# "pid target" for every file open for writing below $1 (Android's view) or /gbos (the view of stage0's helpers).
# The owner bits of /proc/PID/fd/N are the open mode: l-wx = write only, lrwx = read-write, lr-x = read only.
fd_list() { if [ -n "$GBOS_SD_FDLIST" ]; then cat "$GBOS_SD_FDLIST"; else ls -l $P/[0-9]*/fd 2>/dev/null; fi; }
writers() {
  fd_list | while IFS= read -r _line; do
    case $_line in
      */fd:) _pid=${_line%/fd:}; _pid=${_pid##*/};;
      l?w*" -> $1/"*|l?w*" -> /gbos/"*) echo "$_pid ${_line#* -> }";;
    esac
  done
}

comm_of() { _c=; read -r _c < "$P/$1/comm" 2>/dev/null; echo "${_c:-?}"; }

# kill -9 every pid given (never init or this script), logging each with its name
kill_pids() {
  _why=$1; shift
  _k=
  for _p in "$@"; do
    [ "$_p" = 1 ] || [ "$_p" = "$$" ] && continue
    case " $_k " in *" $_p "*) continue;; esac
    _k="$_k $_p"
    log "kill $_p ($(comm_of $_p)): $_why"
  done
  [ -n "$_k" ] && $KILL -9 $_k 2>/dev/null
}

# remount $2 read-only. busybox with a device and a directory passes no other options; toybox's mount would add the ones in
# /proc/mounts (seclabel, codepage, ...), which a remount can reject.
remount_ro() {
  if [ -x "$BB" ]; then _out=$(to "$BB" mount -o remount,ro "$1" "$2" 2>&1)
  else _out=$(to mount -o remount,ro "$2" 2>&1); fi
}

log "shutdown.sh start: boot $N"
fatm=$(mount_of $FAT); metam=$(mount_of /metadata)
log "$FAT: ${fatm:-not mounted}; /metadata: ${metam:-not mounted}"

# 1. stage0's helpers (kmsg.log ends with these lines). A second pass catches a child a loop started meanwhile.
for pass in 1 2 3; do
  s0=$(stage0_pids)
  [ -z "$s0" ] && break
  [ $pass = 1 ] && sleep 0.3 2>/dev/null   # let the kmsg copier write the lines above
  kill_pids "stage0 helper (pass $pass)" $s0
  sleep 0.2 2>/dev/null || sleep 1
done

# 2. anything else still writing to GBOSSYS: the stopped gbos_* services get $WAIT s to exit on init's SIGTERM, then SIGKILL
w=$(writers $FAT)
if [ -n "$w" ]; then
  sleep $WAIT
  w=$(writers $FAT)
  if [ -n "$w" ]; then
    echo "$w" | while read -r _p _t; do log "still writing: pid $_p ($(comm_of $_p)) $_t"; done
    kill_pids "open for writing on GBOSSYS" $(echo "$w" | while read -r _p _t; do echo $_p; done)
    sleep 0.2 2>/dev/null || sleep 1
  fi
fi

to $SYNC

# 3. /metadata (ext4 only: tmpfs on a live boot)
set -- $metam
if [ "$2" = ext4 ]; then
  if remount_ro "$1" /metadata; then
    log "/metadata ($1) remounted read-only"
  else
    log "/metadata ($1) remount ro FAILED: $_out"
    writers /metadata | while read -r _p _t; do log "  /metadata writer: pid $_p ($(comm_of $_p)) $_t"; done
  fi
fi

# 4. GBOSSYS. The log is complete before this; afterwards nothing more can be written there.
set -- $fatm
if [ -z "$1" ]; then
  log "$FAT not mounted: nothing to do"
  exit 0
fi
log "remounting $FAT ($1) read-only: this log ends here"
to $SYNC
for try in 1 2; do
  if remount_ro "$1" $FAT; then exit 0; fi
  log "$FAT remount ro FAILED (try $try): $_out"
  w=$(writers $FAT)
  [ -z "$w" ] && { log "  no process has a file open for writing there (a loop device, e.g. gbos/metadata.img?)"; break; }
  echo "$w" | while read -r _p _t; do log "  writer: pid $_p ($(comm_of $_p)) $_t"; done
  [ $try = 1 ] && kill_pids "open for writing on GBOSSYS (retry)" $(echo "$w" | while read -r _p _t; do echo $_p; done)
  sleep 0.2 2>/dev/null || sleep 1
  to $SYNC
done
log "$FAT stays read-write (synced)"
exit 0
