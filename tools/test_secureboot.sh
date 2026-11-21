#!/bin/sh
# test_secureboot.sh: the Secure Boot file layout of usb/install.sh, run on fake EFI directories (no QEMU, no root). Takes the
# installer's own find_boot / boot_layout / put_boot / check_boot and checks which files land where for a stick with and without
# shim, onto a new or existing clean install (EFI/BOOT) and dual-boot install (EFI/gbos86). The boot itself is tested by
# kernel/isa_emu_test/run_secureboot_qemu.py.
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$HERE/..
I=$ROOT/usb/install.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

sh -n "$I" && ok "sh -n install.sh" || bad "syntax"
sed -n '/^is_kernel() /p; /^find_boot() {/,/^}/p; /^boot_layout() {/,/^}/p; /^put_boot() {/,/^}/p; /^check_boot() {/,/^}/p' "$I" > $T/f.sh
[ "$(grep -c '() {' $T/f.sh)" = 5 ] && ok "found the installer's 5 boot-file functions" || bad "functions not found in install.sh"
say() { echo "$*" >> $T/say; }
die() { echo "DIE $*" >> $T/say; DIED=1; }
check() { cmp -s "$1" "$2" || die "verify failed: $2"; }
. $T/f.sh

# a kernel has "HdrS" at 0x202 (the x86 boot header); shim and MokManager do not
mk_kernel() { head -c 1024 /dev/zero > "$1"; printf HdrS | dd of="$1" bs=1 seek=514 conv=notrunc 2>/dev/null; echo "$2" >> "$1"; }
mk_file() { echo "$2" > "$1"; }
stick_sb() { rm -rf $T/stick; mkdir -p $T/stick/EFI/BOOT; d=$T/stick/EFI/BOOT
  mk_file $d/BOOTX64.EFI shim; mk_kernel $d/grubx64.efi new-signed; mk_file $d/mmx64.efi mokmanager; mk_file $d/gbos86-mok.cer key; }
stick_old() { rm -rf $T/stick; mkdir -p $T/stick/EFI/BOOT; mk_kernel $T/stick/EFI/BOOT/BOOTX64.EFI new-unsigned; }
# load DIR: what the installer does with the stick (find_boot, then the RAM copies)
load() {
  find_boot $T/stick/EFI/gbos $T/stick/EFI/BOOT
  rm -rf $T/ram; mkdir -p $T/ram/sb; cp "$KERNEL" $T/ram/kernel; KERNEL=$T/ram/kernel; SB=""
  [ -n "$SBDIR" ] && cp $SBDIR/BOOTX64.EFI $SBDIR/mmx64.efi $SBDIR/gbos86-mok.cer $T/ram/sb/ && SB=$T/ram/sb
}
# run DIR [keep]: boot_layout + put_boot + check_boot on DIR
run() { : > $T/say; DIED=; boot_layout "$@"; put_boot $1 || die "put_boot failed"; check_boot $1; }
has() { grep -q "$2" "$1" 2>/dev/null; }
files() { (cd "$1" && ls | tr '\n' ' '); }

# 1. the stick
stick_sb; load
[ "$KERNEL" = $T/ram/kernel ] && has $KERNEL new-signed && [ -n "$SB" ] && ok "shim stick: kernel = grubx64.efi, shim files found" || bad "shim stick detection"
rm $T/stick/EFI/BOOT/mmx64.efi; load
has $KERNEL new-signed && [ -z "$SB" ] && ok "shim stick without mmx64.efi: the kernel alone" || bad "incomplete shim stick"
stick_sb; mk_kernel $T/stick/EFI/BOOT/BOOTX64.EFI hand-copied; load
has $KERNEL hand-copied && [ -z "$SB" ] && ok "kernel copied over shim by hand: that kernel (it is what booted)" || bad "kernel over shim"
stick_old; load
has $KERNEL new-unsigned && [ -z "$SB" ] && ok "older stick: BOOTX64.EFI is the kernel" || bad "older stick"

# 2. new clean install from a shim stick: EFI/BOOT gets shim + kernel
stick_sb; load; E=$T/esp/EFI/BOOT; rm -rf $T/esp; mkdir -p $E
run $E
[ "$(files $E)" = "BOOTX64.EFI gbos86-mok.cer grubx64.efi mmx64.efi " ] && has $E/BOOTX64.EFI shim && has $E/grubx64.efi new-signed && [ -z "$DIED" ] \
  && ok "new clean install: $(files $E)" || bad "new clean install: $(files $E) $(cat $T/say)"
# 3. older clean install (BOOTX64.EFI = kernel): converted, kernel written before shim replaces the old one
rm -rf $T/esp; mkdir -p $E; mk_kernel $E/BOOTX64.EFI old
run $E
has $E/BOOTX64.EFI shim && has $E/grubx64.efi new-signed && [ -z "$DIED" ] && [ "$(head -1 $T/say)" = "  kernel ($E/grubx64.efi)" ] && tail -1 $T/say | grep -q 'BOOTX64.EFI (shim)' \
  && ok "older clean install converted to shim (kernel first, shim last)" || bad "clean conversion: $(cat $T/say)"
# 4. update of a shim install with nothing new: nothing copied
run $E
[ ! -s $T/say ] && ok "unchanged update copies nothing" || bad "unchanged update: $(cat $T/say)"

# 5. new dual-boot install (EFI/gbos86 does not exist yet): shim layout
D=$T/esp/EFI/gbos86; rm -rf $T/esp; mkdir -p $D
run $D keep
has $D/BOOTX64.EFI shim && has $D/grubx64.efi new-signed && [ "${KDST##*/}" = grubx64.efi ] && ok "new dual-boot install: shim layout, GRUB entry names grubx64.efi" || bad "new dual-boot"
# 6. older dual-boot install (EFI/gbos86/BOOTX64.EFI = kernel, GRUB entries name it): stays, gets the signed kernel
rm -rf $T/esp; mkdir -p $D; mk_kernel $D/BOOTX64.EFI old
run $D keep
[ "$(files $D)" = "BOOTX64.EFI " ] && has $D/BOOTX64.EFI new-signed && ok "older dual-boot install: kernel stays EFI/gbos86/BOOTX64.EFI (signed one)" || bad "older dual-boot: $(files $D)"
# 7. shim dual-boot install: updated in place
rm -rf $T/esp; mkdir -p $D; mk_file $D/BOOTX64.EFI oldshim; mk_kernel $D/grubx64.efi old; mk_file $D/mmx64.efi oldmm; mk_file $D/gbos86-mok.cer key
run $D keep
has $D/BOOTX64.EFI '^shim' && has $D/grubx64.efi new-signed && has $D/mmx64.efi mokmanager && ok "shim dual-boot install updated in place" || bad "shim dual-boot update"

# 8. older stick onto a shim install: the kernel goes to grubx64.efi, shim stays
stick_old; load
rm -rf $T/esp; mkdir -p $E; mk_file $E/BOOTX64.EFI shim; mk_kernel $E/grubx64.efi old; mk_file $E/mmx64.efi mm; mk_file $E/gbos86-mok.cer key
run $E
has $E/grubx64.efi new-unsigned && has $E/BOOTX64.EFI shim && [ -z "$DIED" ] && ok "older stick onto a shim install: grubx64.efi updated, shim kept" || bad "older stick onto shim"
# 9. older stick, new clean install: BOOTX64.EFI = kernel, as before
rm -rf $T/esp; mkdir -p $E
run $E
[ "$(files $E)" = "BOOTX64.EFI " ] && has $E/BOOTX64.EFI new-unsigned && ok "older stick, new install: the kernel alone as BOOTX64.EFI" || bad "older stick new install: $(files $E)"

# 10. check_boot notices a bad copy
stick_sb; load; rm -rf $T/esp; mkdir -p $E; run $E; echo corrupt > $E/mmx64.efi; : > $T/say; DIED=; check_boot $E
[ -n "$DIED" ] && ok "check_boot fails on a changed mmx64.efi" || bad "check_boot missed a bad file"

# 11. the GRUB entry and the UEFI entry: GRUB names the kernel's file, the UEFI entry starts BOOTX64.EFI (shim or kernel)
grep -q 'linux /EFI/gbos86/${KDST##\*/} ' "$I" && ok "GRUB entry boots EFI/gbos86/\${KDST##*/}" || bad "GRUB entry"
grep -q "_loader='\\\\EFI\\\\gbos86\\\\BOOTX64.EFI'" "$I" && ok "UEFI entry still starts \\EFI\\gbos86\\BOOTX64.EFI" || bad "UEFI entry"

[ $fail = 0 ] && echo "SECUREBOOT_LAYOUT_PASS" || { echo "SECUREBOOT_LAYOUT_FAIL"; exit 1; }
