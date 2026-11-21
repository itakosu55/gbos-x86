#!/bin/sh
# test_install_dualboot.sh: runs tools/install_dualboot.sh against a loop-device disk image (never a real disk):
# ESP + "Windows" + a free block holding the filesystems of a deleted older install + "Linux" + "WinRE", like a laptop that
# had gbOS86 once. Checks: dry run and a wrong serial write nothing; the install puts GBOSSYS/GBOS_META/GBOS_DATA exactly in
# the free block, formats over the old signatures, leaves the other partitions and the ESP's other files byte-identical, and
# writes one GRUB entry into a fake GRUB tree; an update keeps /data and adds nothing; a stale GRUB entry is reported; a
# --reformat needs the serial; too little free space stops before any write. efibootmgr/update-grub are stubs that fail the test
# if called (and --no-nvram is passed): the host's NVRAM and GRUB are never touched.
# Needs root (losetup, mount, mkfs):   sudo sh tools/test_install_dualboot.sh      (log: build/test_install_dualboot.txt)
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root: sudo sh $0"; exit 2; }
for c in sgdisk sfdisk losetup mkfs.vfat mkfs.ext4 dumpe2fs blkid wipefs sha256sum partprobe; do
  command -v $c >/dev/null 2>&1 || { echo "missing $c"; exit 2; }
done
T=$(mktemp -d "${TMPDIR:-/tmp}/gbos-dualboot-test.XXXXXX")
LOOPS=""
cleanup() {
  for m in $(findmnt -rn -o TARGET | grep "^$T/" | sort -r); do umount "$m" 2>/dev/null; done
  for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT INT TERM
mkdir -p "$REPO/build"; LOG=$REPO/build/test_install_dualboot.txt; : > "$LOG"
# build/ is where ./build.sh (run as the user) downloads to: hand it and the log back to the user who ran sudo
[ -n "$SUDO_UID" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$REPO/build" "$LOG"
fail=0
ok()  { echo "ok   $*" | tee -a "$LOG"; }
bad() { echo "FAIL $*" | tee -a "$LOG"; fail=1; }
MiB=2048   # sectors

# A copy of the repo's installer and payload with a small dummy system image (the real super.img is not needed here)
R=$T/root; mkdir -p "$R/tools" "$R/build" "$R/kernel/out"
cp "$REPO/tools/install_dualboot.sh" "$R/tools/"
cp -a "$REPO/usb" "$R/usb"
[ -f "$REPO/kernel/out/busybox" ] && cp "$REPO/kernel/out/busybox" "$R/kernel/out/"
head -c 8388608 /dev/urandom > "$R/build/super.img"; echo "system_a 2048 16384" > "$R/build/super.layout"
KERNEL=$R/usb/out/BOOTX64.EFI
[ -f "$KERNEL" ] || { echo "no usb/out/BOOTX64.EFI"; exit 2; }

# Stubs that must never run, and a fake GRUB tree whose grub.cfg sources custom.cfg (as Ubuntu's 41_custom does)
mkdir -p "$T/stub" "$T/g/boot/grub" "$T/g/etc/grub.d"
for s in efibootmgr update-grub grub-mkconfig grub2-mkconfig; do
  printf '#!/bin/sh\necho "STUB CALLED: $0 $*" >> %s/stub.log\nexit 1\n' "$T" > "$T/stub/$s"; chmod 755 "$T/stub/$s"
done
printf '### BEGIN /etc/grub.d/41_custom ###\nif [ -f  ${config_directory}/custom.cfg ]; then\n  source ${config_directory}/custom.cfg\nfi\n' > "$T/g/boot/grub/grub.cfg"
printf '#!/bin/sh\nexec tail -n +3 $0\n' > "$T/g/etc/grub.d/40_custom"; cp "$T/g/etc/grub.d/40_custom" "$T/40_custom.orig"
export PATH="$T/stub:$PATH"

# disk.img (sparse): p1 ESP 1-101 MiB, 32 MiB gap, p2 "Windows" 133-197, free block 197-8389 (8 GiB: the installer wants
# GBOSSYS + GBOS_META + at least 4 GiB of GBOS_DATA), p3 "Linux" 8389-8453, p4 "WinRE" 8453-8517, then a smaller tail gap.
FREE=8192; END=$((197 + FREE))
mkdisk() { # file total_MiB free_MiB
  truncate -s "$2M" "$1"
  _a=197; _b=$((_a + $3))
  sgdisk -o -n 1:$((1*MiB)):$((101*MiB-1)) -t 1:ef00 -c 1:"EFI system partition" \
            -n 2:$((133*MiB)):$((197*MiB-1)) -t 2:0700 -c 2:"Basic data partition" \
            -n 3:$((_b*MiB)):$(((_b+64)*MiB-1)) -t 3:8300 \
            -n 4:$(((_b+64)*MiB)):$(((_b+128)*MiB-1)) -t 4:2700 -c 4:"Basic data partition" "$1" >/dev/null
}
attach() { # file: sets L to the new loop device (not in $( ): LOOPS must reach the cleanup)
  L=$(losetup -f --show -P "$1") || exit 2; case "$L" in /dev/loop*) ;; *) exit 2;; esac
  LOOPS="$L $LOOPS"; udevadm settle 2>/dev/null
}

mkdisk "$T/disk.img" 8700 $FREE
# The deleted older install: GBOSSYS (2 GiB FAT32) then GBOS_DATA (ext4) in the free block. Formatted, then the partitions deleted.
sgdisk -n 5:$((197*MiB)):$(((197+2048)*MiB-1)) -n 6:$(((197+2048)*MiB)):$((END*MiB-1)) "$T/disk.img" >/dev/null
attach "$T/disk.img"
mkfs.vfat -F 32 -n GBOSSYS ${L}p5 >/dev/null 2>&1; mkfs.ext4 -F -q -L GBOS_DATA ${L}p6
mkfs.vfat -n ESP ${L}p1 >/dev/null
mkdir -p "$T/m"; mount ${L}p1 "$T/m"
mkdir -p "$T/m/EFI/Microsoft/Boot" "$T/m/EFI/ubuntu" "$T/m/EFI/BOOT"
for f in EFI/Microsoft/Boot/bootmgfw.efi EFI/ubuntu/shimx64.efi EFI/BOOT/BOOTX64.EFI; do head -c 1048576 /dev/urandom > "$T/m/$f"; done
(cd "$T/m" && find . -type f | sort | xargs sha256sum) > "$T/esp.before"; umount "$T/m"
for p in 2 3 4; do head -c $((64 * 1048576)) /dev/urandom > ${L}p$p; done
losetup -d "$L"; LOOPS=""
sgdisk -d 5 -d 6 "$T/disk.img" >/dev/null
attach "$T/disk.img"; DEV=${L#/dev/}
SERIAL=$(lsblk -dno SERIAL "$L" | tr -d ' '); [ -n "$SERIAL" ] || SERIAL=$DEV
sfdisk -d "$L" | grep "^$L" > "$T/pt.before"
for p in 2 3 4; do sha256sum < ${L}p$p; done > "$T/raw.before"
INST="sh $R/tools/install_dualboot.sh --target $L --allow-internal --sys-size 2G --data-size rest --no-nvram --grub-root $T/g"
run() { # name stdin args...: runs the installer, output to $T/<name>.out and the log, returns its status
  _n=$1; _in=$2; shift 2
  printf '%s\n' "$_in" | $INST "$@" > "$T/$_n.out" 2>&1; _rc=$?
  { echo "----- $_n (rc $_rc): $INST $*"; cat "$T/$_n.out"; } >> "$LOG"; return $_rc
}
pt_same() { sfdisk -d "$L" | grep "^$L" | cmp -s - "$T/pt.before"; }

sh -n "$R/tools/install_dualboot.sh" && ok "sh -n install_dualboot.sh" || bad "syntax"

# 1. dry run
run dryrun "" --dry-run && grep -q "Plan: in the free block of $FREE MiB" "$T/dryrun.out" && pt_same \
  && ok "dry run: plans the $FREE MiB free block, writes nothing" || bad "dry run (see $T/dryrun.out in the log)"

# 2. wrong serial
run cancel "not-the-serial" ; rc=$?
[ $rc != 0 ] && grep -q "Cancelled" "$T/cancel.out" && pt_same && ok "wrong serial: cancelled, nothing written" || bad "wrong serial (rc $rc)"

# 3. install
run install "$SERIAL"; rc=$?
[ $rc = 0 ] && ok "install exits 0" || bad "install failed (rc $rc)"
PT=$(sfdisk -d "$L")
grep -q . "$T/pt.before" && echo "$PT" | grep "^$L" | grep -v 'name="GBOS' | cmp -s - "$T/pt.before" && ok "existing partition entries unchanged" || bad "existing partition entries changed"
pf() { echo "$PT" | awk -v n="name=\"$1\"" -v f="$2" 'index($0, n) { if (match($0, f "= *[0-9]+")) { s = substr($0, RSTART, RLENGTH); sub(/.*= */, "", s); print s } }'; }
pd() { echo "$PT" | awk -v n="name=\"$1\"" 'index($0, n) {print $1; exit}'; }
SYS=$(pd GBOSSYS); META=$(pd GBOS_META); DATA=$(pd GBOS_DATA)
[ "$(pf GBOSSYS start)" = $((197*MiB)) ] && [ "$(pf GBOSSYS size)" = $((2048*MiB)) ] && \
[ "$(pf GBOS_META start)" = $((2245*MiB)) ] && [ "$(pf GBOS_META size)" = $((64*MiB)) ] && \
[ "$(pf GBOS_DATA start)" = $((2309*MiB)) ] && [ $(( $(pf GBOS_DATA start) + $(pf GBOS_DATA size) )) = $((END*MiB)) ] \
  && ok "GBOSSYS/GBOS_META/GBOS_DATA fill the free block exactly ($SYS $META $DATA)" || { bad "partition placement"; echo "$PT" >> "$LOG"; }
for p in 2 3 4; do sha256sum < ${L}p$p; done | cmp -s - "$T/raw.before" && ok "Windows/Linux/WinRE partitions byte-identical" || bad "an existing partition's data changed"
[ "$(blkid -p -s TYPE -o value $SYS)$(blkid -p -s LABEL -o value $SYS)" = vfatGBOSSYS ] && ok "GBOSSYS is FAT32 GBOSSYS" || bad "GBOSSYS filesystem"
[ "$(blkid -p -s LABEL -o value $META)" = GBOS_META ] && \
  [ $(( $(dumpe2fs -h $META 2>/dev/null | awk -F: '/^Block count/ {print $2}') * $(dumpe2fs -h $META 2>/dev/null | awk -F: '/^Block size/ {print $2}') )) -le $((64 * 1048576)) ] \
  && ok "GBOS_META formatted over the old GBOS_DATA superblock (label and size are the new ones)" || bad "GBOS_META still shows the old filesystem"
dumpe2fs -h $DATA 2>/dev/null | grep -i '^Filesystem features' | grep -q verity && [ "$(blkid -p -s LABEL -o value $DATA)" = GBOS_DATA ] \
  && [ "$(dumpe2fs -h $DATA 2>/dev/null | awk -F: '/^Reserved block count/ {gsub(/ /,"",$2); print $2}')" = 0 ] \
  && ok "GBOS_DATA is ext4 with verity, no reserved blocks" || bad "GBOS_DATA filesystem"
[ "$(wipefs -p $META 2>/dev/null | grep -vc '^#')" = 1 ] && ok "no leftover signatures on GBOS_META" || bad "leftover signatures on GBOS_META: $(wipefs $META 2>&1 | tr '\n' ' ')"
mount -o ro ${L}p1 "$T/m"
(cd "$T/m" && find . -type f ! -path './EFI/gbos86/*' | sort | xargs sha256sum) | cmp -s - "$T/esp.before" && ok "ESP: every other file unchanged" || bad "ESP: other files changed"
cmp -s "$KERNEL" "$T/m/EFI/gbos86/BOOTX64.EFI" && ok "ESP: EFI/gbos86/BOOTX64.EFI is the kernel" || bad "ESP kernel"
ESP_UUID=$(blkid -s UUID -o value ${L}p1); umount "$T/m"
mount -o ro $SYS "$T/m"
cmp -s "$R/build/super.img" "$T/m/gbos/super.img" && cmp -s "$KERNEL" "$T/m/EFI/BOOT/BOOTX64.EFI" && grep -q '^MODE=boot' "$T/m/gbos/gbos.cfg" \
  && [ -f "$T/m/gbos/native_zygote.sh" ] && [ -f "$T/m/gbos/hook.sh" ] && [ -f "$T/m/gbos/logs/dualboot-install.txt" ] \
  && ok "GBOSSYS: super.img, kernel, MODE=boot, scripts, install log" || bad "GBOSSYS contents"
umount "$T/m"
[ "$(grep -c 'menuentry "Googlebook OS (gbOS86)"' "$T/g/boot/grub/custom.cfg" 2>/dev/null)" = 1 ] && grep -q -- "--fs-uuid --set=root $ESP_UUID" "$T/g/boot/grub/custom.cfg" \
  && grep -q "linux /EFI/gbos86/BOOTX64.EFI" "$T/g/boot/grub/custom.cfg" && cmp -s "$T/g/etc/grub.d/40_custom" "$T/40_custom.orig" \
  && ok "GRUB: one entry in custom.cfg (this ESP, EFI/gbos86), 40_custom untouched" || bad "GRUB entry"
[ -n "$(findmnt -rn -o SOURCE | grep "^$L")" ] && bad "partitions of $L left mounted" || ok "nothing left mounted"

# 4. update: no prompt (stdin is empty), /data kept, nothing added
mount $DATA "$T/m"; echo keep > "$T/m/marker"; umount "$T/m"
NPART=$(sfdisk -d "$L" | grep -c "^$L")
printf 'x' >> "$R/build/super.img"
$INST < /dev/null > "$T/update.out" 2>&1; rc=$?; { echo "----- update (rc $rc)"; cat "$T/update.out"; } >> "$LOG"
mount -o ro $DATA "$T/m"; [ -f "$T/m/marker" ] && m=1 || m=0; umount "$T/m"
mount -o ro $SYS "$T/m"; cmp -s "$R/build/super.img" "$T/m/gbos/super.img" && s=1 || s=0; umount "$T/m"
[ $rc = 0 ] && [ $m = 1 ] && [ $s = 1 ] && [ "$(sfdisk -d "$L" | grep -c "^$L")" = "$NPART" ] && grep -q "update the files" "$T/update.out" \
  && [ "$(grep -c 'menuentry' "$T/g/boot/grub/custom.cfg")" = 1 ] \
  && ok "update: no serial asked, /data kept, super.img refreshed, no partition or GRUB entry added" || bad "update (rc $rc marker $m super $s)"

# 5. a stale GRUB entry (the deleted install's chainloader entry) is reported; a working entry is added next to it
cp "$T/g/boot/grub/custom.cfg" "$T/custom.good"
printf '\nmenuentry "Googlebook OS (gbOS86 persistent)" {\n    search --no-floppy --fs-uuid --set=root 1234-ABCD\n    chainloader /EFI/BOOT/BOOTX64.EFI\n}\n' > "$T/g/boot/grub/custom.cfg"
run stale "" ; rc=$?
[ $rc = 0 ] && grep -q "WARNING: .*custom.cfg has a 'Googlebook OS' entry that does not boot this install" "$T/stale.out" \
  && grep -q -- "--fs-uuid --set=root $ESP_UUID" "$T/g/boot/grub/custom.cfg" && grep -q "1234-ABCD" "$T/g/boot/grub/custom.cfg" \
  && ok "stale GRUB entry: reported and kept, a working entry added" || bad "stale GRUB entry (rc $rc)"
cp "$T/custom.good" "$T/g/boot/grub/custom.cfg"

# 6. --reformat with a wrong serial: cancelled, /data kept
run reformat "nope" --reformat; rc=$?
mount -o ro $DATA "$T/m"; [ -f "$T/m/marker" ] && m=1 || m=0; umount "$T/m"
[ $rc != 0 ] && [ $m = 1 ] && grep -q "Cancelled" "$T/reformat.out" && ok "--reformat asks for the serial; a wrong one keeps /data" || bad "--reformat without the serial (rc $rc marker $m)"

# 7. no room: a 1 GiB free block stops before any write
mkdisk "$T/small.img" 1600 1024
L1=$L; attach "$T/small.img"; L2=$L; L=$L1
mkfs.vfat -n ESP ${L2}p1 >/dev/null; sfdisk -d "$L2" > "$T/small.before"
printf '%s\n' "${L2#/dev/}" | sh "$R/tools/install_dualboot.sh" --target $L2 --allow-internal --sys-size 2G --data-size rest --no-nvram --grub-root "$T/g" > "$T/small.out" 2>&1; rc=$?
{ echo "----- no room (rc $rc)"; cat "$T/small.out"; } >> "$LOG"
[ $rc != 0 ] && grep -q "too small" "$T/small.out" && sfdisk -d "$L2" | cmp -s - "$T/small.before" && ok "too little free space: stops, table unchanged" || bad "no-room case (rc $rc)"

[ -s "$T/stub.log" ] && bad "a stub was called: $(cat "$T/stub.log")" || ok "efibootmgr/update-grub never called"
if [ $fail = 0 ]; then echo "INSTALL_DUALBOOT_TEST_PASS" | tee -a "$LOG"; else echo "INSTALL_DUALBOOT_TEST_FAIL (log: $LOG)" | tee -a "$LOG"; fi
exit $fail
