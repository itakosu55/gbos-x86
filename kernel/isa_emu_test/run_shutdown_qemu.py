#!/usr/bin/env python3
"""run_shutdown_qemu.py [KERNEL] [--script SHUTDOWN_SH] -- check usb/shutdown.sh on the real kernel (default usb/out/BOOTX64.EFI) in QEMU.

Two boots with the same layout as an NVMe install: GBOSSYS (FAT32) on one NVMe disk, GBOS_META (ext4) on another.
The initramfs does what stage0 does: mounts GBOSSYS rw at /gbos, starts the same helpers (kmsg.log copier, 5 s sync loop, and a
process holding kvmtrace.txt open for writing, like the kvm-trace dd), puts a read-only loop device on a file on the FAT (as super.img)
and a writable one on another file (as hook.sh's bootdisk.img on loop6, which kept GBOSSYS busy on the dynabook GZ/HWL), mounts
/metadata and switches root. In the new root (Android's place) it starts a writer in its own process group (a gbos_logcat that has not
exited), a process in group 0 with the new root (like an init subcontext: must survive), a reader of the loop image file and a process
holding the writable loop device open (as the boot HAL might hold misc).
  boot 1 (control): power off without shutdown.sh -> the FAT must come back dirty and ext4 must need journal recovery (the bug).
  boot 2 (fix): run shutdown.sh, then power off -> FAT clean, ext4 clean, the stage0 helpers and the writer gone, the others alive,
                the writable loop detached (its holder gone) and shutdown.txt readable.
--script runs another shutdown.sh in the fix boot (e.g. an older one, to see it fail).
The FAT dirty bit is read from the boot sector (FAT32 state byte, offset 0x41, bit 0) and with fsck.fat -n; ext4 with dumpe2fs -h.
Prints SHUTDOWN_QEMU_PASS when everything holds.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from run_ksu_qemu import cpio  # noqa: E402

INIT = r"""#!/bin/sh
/bin/busybox --install -s /bin 2>/dev/null
# /dev as stage0 makes it (this kernel has no devtmpfs): tmpfs, the console/kmsg/null nodes, then mdev
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t tmpfs -o mode=0755 tmpfs /dev
mknod -m 600 /dev/console c 5 1; mknod -m 600 /dev/kmsg c 1 11; mknod -m 666 /dev/null c 1 3
# NVMe namespaces appear asynchronously and in no fixed order; this busybox has no findfs: the 300 MB disk is GBOSSYS, the 64 MB one META
i=0; while [ $i -lt 30 ]; do
  mdev -s
  SYS=$(awk '$4 ~ /^nvme[0-9]n1$/ && $3 == 307200 {print "/dev/" $4}' /proc/partitions)
  META=$(awk '$4 ~ /^nvme[0-9]n1$/ && $3 == 65536 {print "/dev/" $4}' /proc/partitions)
  [ -n "$SYS" ] && [ -n "$META" ] && break; sleep 1; i=$((i+1)); done
echo "T: sys=$SYS meta=$META"
[ -n "$SYS" ] || { echo "T: partitions: $(cat /proc/partitions | tr '\n' ' ')"; echo "T: blkid: $(blkid 2>&1 | tr '\n' ' ')"; }
mkdir -p /gbos && mount -t vfat -o rw,flush,umask=000 $SYS /gbos || { echo "T: FAT mount FAILED: $(ls -l $SYS 2>&1) $(dmesg | tail -3 | tr '\n' ' ')"; }
G=/gbos/gbos; L=$G/logs/boot-1; mkdir -p $L
cp /bin/busybox /gbos/busybox; cp /shutdown.sh $G/shutdown.sh
# stage0's helpers, as in usb/stage0_init.sh and hook.sh
( exec 3</dev/kmsg; while /gbos/busybox cat <&3 >> $L/kmsg.log || /gbos/busybox sleep 1; do :; done ) &
( while /gbos/busybox sleep 5; do /gbos/busybox sync; done ) &
( exec /gbos/busybox sleep 100000 >> $L/kvmtrace.txt ) &
# the system image: a file on the FAT behind a read-only loop device
dd if=/dev/zero of=$G/super.img bs=1M count=8 2>/dev/null; mke2fs -q -F $G/super.img >/dev/null 2>&1; sync
mkdir -p /new && mount -t tmpfs tmpfs /new
mkdir -p /new/bin /new/proc /new/sys /new/dev /new/postinstall /new/metadata /new/system
cp /bin/busybox /new/bin/busybox; cp /init2 /new/init2
losetup -r /dev/loop0 $G/super.img && mount -t ext2 -o ro /dev/loop0 /new/system || echo "T: loop mount FAILED"
# hook.sh's boot disk: a writable loop device on a file on the FAT
dd if=/dev/zero of=$G/bootdisk.img bs=1M count=1 2>/dev/null; sync
losetup /dev/loop6 $G/bootdisk.img && echo "T: bootdisk on loop6: $(cat /sys/block/loop6/loop/backing_file) ro=$(cat /sys/block/loop6/ro)" \
  || echo "T: bootdisk loop FAILED"
mount -t ext4 $META /new/metadata && echo data > /new/metadata/x || echo "T: META mount FAILED"
mount --bind /gbos /new/postinstall
echo "T: stage0 done, switching root"
mount --move /dev /new/dev; mount --move /proc /new/proc; mount --move /sys /new/sys
exec switch_root /new /init2
"""

INIT2 = r"""#!/bin/busybox sh
/bin/busybox --install -s /bin 2>/dev/null
export PATH=/bin
MODE=control; grep -q gbos_test=fix /proc/cmdline && MODE=fix
L=/postinstall/gbos/logs/boot-1
setsid sh -c "exec sleep 100000 >> $L/logcat.txt" &
WRITER=$!
sleep 100000 &
KEEP=$!
setsid sh -c "exec sleep 100000 < /postinstall/gbos/super.img" &
READER=$!
setsid sh -c "exec sleep 100000 < /dev/loop6" &
HOLDER=$!
sleep 2
echo "T: mode=$MODE writer=$WRITER keep=$KEEP reader=$READER holder=$HOLDER"
[ -e /sys/block/loop6/loop/backing_file ] && echo "T: loop6 attached before: $(cat /sys/block/loop6/loop/backing_file)"
s0() { for d in /proc/[0-9]*; do p=${d##*/}; [ $p = 1 ] && continue; read -r st < $d/stat 2>/dev/null || continue; set -- ${st##*) }
       [ "$2" = 2 ] || [ $p = 2 ] || [ "$1" = Z ] && continue; [ "$3" = 0 ] && ! [ $d/root -ef /proc/1/root ] && echo -n "$p "; done; }
echo "T: stage0 helpers before: $(s0)"
grep -E ' /(postinstall|metadata) ' /proc/mounts | sed 's/^/T: mount before: /'
if [ $MODE = fix ]; then
  echo "<6>T: marker before shutdown.sh" > /dev/kmsg; sleep 1
  sh /postinstall/gbos/shutdown.sh 1
  rc=$?
  echo "T: shutdown.sh rc=$rc"
  echo "<6>T: marker after shutdown.sh" > /dev/kmsg; sleep 1
  echo "T: stage0 helpers after: $(s0)"
  kill -0 $WRITER 2>/dev/null && echo "T: writer alive" || echo "T: writer gone"
  kill -0 $KEEP 2>/dev/null && echo "T: keep alive" || echo "T: keep gone"
  kill -0 $READER 2>/dev/null && echo "T: reader alive" || echo "T: reader gone"
  kill -0 $HOLDER 2>/dev/null && echo "T: holder alive" || echo "T: holder gone"
  [ -e /sys/block/loop6/loop/backing_file ] && echo "T: loop6 still attached" || echo "T: loop6 detached"
  grep -E ' /(postinstall|metadata) ' /proc/mounts | sed 's/^/T: mount after: /'
  grep -c 'marker after shutdown.sh' $L/kmsg.log | sed 's/^/T: kmsg.log lines after: /'
  sed 's/^/T: log: /' $L/shutdown.txt
  ls /system >/dev/null 2>&1 && echo "T: system image still readable"
  touch /postinstall/gbos/x 2>/dev/null && echo "T: FAT still writable" || echo "T: FAT read-only"
fi
echo "T: END"
poweroff -f
"""


def run(kernel, rd, fat, meta, mode, log):
    cmd = ["qemu-system-x86_64", "-machine", "q35", "-cpu", "Skylake-Client", "-m", "1024", "-smp", "2", "-nographic",
           "-no-reboot", "-nic", "none", "-kernel", kernel, "-initrd", str(rd),
           "-drive", "file=%s,format=raw,if=none,id=d0" % fat, "-device", "nvme,drive=d0,serial=gbossys",
           "-drive", "file=%s,format=raw,if=none,id=d1" % meta, "-device", "nvme,drive=d1,serial=gbosmeta",
           "-append", "console=ttyS0 8250.nr_uarts=1 panic=-1 loglevel=4 rdinit=/init gbos_test=%s" % mode]
    r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=900)
    out = r.stdout + r.stderr
    log.write("===== %s\n%s\n" % (mode, out))
    return out


def fat_dirty(fat):
    with open(fat, "rb") as f:
        f.seek(0x41)
        return f.read(1)[0] & 1


def fsck_fat(fat):
    r = subprocess.run(["fsck.fat", "-n", str(fat)], capture_output=True, text=True, errors="replace")
    return r.stdout + r.stderr


def ext4_needs_recovery(meta):
    r = subprocess.run(["dumpe2fs", "-h", str(meta)], capture_output=True, text=True, errors="replace")
    feat = re.search(r"^Filesystem features:(.*)$", r.stdout, re.M)
    state = re.search(r"^Filesystem state:\s*(.*)$", r.stdout, re.M)
    return ("needs_recovery" in feat.group(1)) if feat else None, state.group(1).strip() if state else "?"


def main():
    args = sys.argv[1:]
    script = ROOT / "usb/shutdown.sh"
    if "--script" in args:
        i = args.index("--script")
        script = pathlib.Path(args[i + 1])
        del args[i:i + 2]
    kernel = args[0] if args else str(ROOT / "usb/out/BOOTX64.EFI")
    busybox = ROOT / "kernel/out/busybox"
    if not busybox.exists():
        print("no busybox (kernel/out/busybox): run tools/fetch_busybox.sh")
        return 2
    bb = busybox.read_bytes()
    files = [("dev", 0o40755, b""), ("proc", 0o40755, b""), ("sys", 0o40755, b""), ("bin", 0o40755, b""),
             ("dev/console", 0o20600, b""), ("bin/busybox", 0o100755, bb), ("bin/sh", 0o100755, bb),
             ("init", 0o100755, INIT.encode()), ("init2", 0o100755, INIT2.encode()),
             ("shutdown.sh", 0o100755, script.read_bytes())]
    fails = 0

    def check(cond, what):
        nonlocal fails
        print(("ok   " if cond else "FAIL ") + what)
        if not cond:
            fails += 1

    with tempfile.TemporaryDirectory() as tmp, open(HERE / "last_shutdown_qemu.log", "w") as log:
        t = pathlib.Path(tmp)
        rd = t / "rd.cpio"
        rd.write_bytes(cpio(files))
        for mode in ("control", "fix"):
            fat, meta = t / ("fat-%s.img" % mode), t / ("meta-%s.img" % mode)
            subprocess.run(["truncate", "-s", "300M", str(fat)], check=True)
            subprocess.run(["mkfs.fat", "-F", "32", "-n", "GBOSSYS", str(fat)], check=True, capture_output=True)
            subprocess.run(["truncate", "-s", "64M", str(meta)], check=True)
            subprocess.run(["mke2fs", "-q", "-F", "-t", "ext4", "-L", "GBOS_META", str(meta)], check=True, capture_output=True)
            out = run(kernel, rd, fat, meta, mode, log)
            t_lines = [l for l in out.splitlines() if l.startswith("T: ")]
            print("== %s boot" % mode)
            for l in t_lines:
                print("   " + l)
            check("T: END" in out, "%s: the test ran to the end" % mode)
            check("T: stage0 helpers before: " in out and re.search(r"T: stage0 helpers before: \d+ \d+", out),
                  "%s: stage0 helpers are found after switch_root (group 0, initramfs root)" % mode)
            check(re.search(r"T: bootdisk on loop6: /gbos/gbos/bootdisk.img ro=0", out) is not None,
                  "%s: a writable loop device on a file on GBOSSYS (as gbos/bootdisk.img)" % mode)
            dirty = fat_dirty(fat)
            rec, state = ext4_needs_recovery(meta)
            fsck = fsck_fat(fat)
            log.write("fsck.fat -n (%s):\n%s\n" % (mode, fsck))
            if mode == "control":
                check(dirty == 1, "control: the FAT is left dirty without shutdown.sh (the bug is reproduced)")
                check(rec is True, "control: ext4 needs journal recovery without shutdown.sh (the bug is reproduced)")
            else:
                check(dirty == 0, "fix: the FAT dirty bit is clear after shutdown.sh")
                check("Dirty bit is set" not in fsck, "fix: fsck.fat -n reports no dirty bit")
                check(rec is False, "fix: ext4 needs no journal recovery (state: %s)" % state)
                check("T: shutdown.sh rc=0" in out, "fix: shutdown.sh exits 0")
                check(re.search(r"T: stage0 helpers after: *$", out, re.M) is not None, "fix: every stage0 helper is gone")
                check("T: writer gone" in out, "fix: a process writing to GBOSSYS is killed")
                check("T: keep alive" in out, "fix: a group-0 process with the new root is kept")
                check("T: reader alive" in out, "fix: a reader of the image file is kept")
                check("T: holder gone" in out, "fix: the process holding the writable loop device open is killed")
                check("T: loop6 detached" in out, "fix: the writable loop device is detached")
                check("loop6 (/gbos/gbos/bootdisk.img) detached" in out, "fix: the detach is in shutdown.txt (image path as seen from the new root)")
                check("T: kmsg.log lines after: 0" in out, "fix: kmsg.log stops at shutdown.sh (copier killed)")
                check("T: FAT read-only" in out, "fix: GBOSSYS is read-only afterwards")
                check(re.search(r"T: mount after: \S+ /postinstall vfat ro", out) is not None, "fix: /proc/mounts shows /postinstall ro")
                check(re.search(r"T: mount after: \S+ /metadata ext4 ro", out) is not None, "fix: /proc/mounts shows /metadata ro")
                check("T: system image still readable" in out, "fix: the loop-mounted image is still readable")
                check("this log ends here" in out, "fix: shutdown.txt was written before the remount")
    print("%d check(s) failed" % fails)
    print("SHUTDOWN_QEMU_PASS" if not fails else "SHUTDOWN_QEMU_FAIL")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
