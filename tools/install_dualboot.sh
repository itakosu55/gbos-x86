#!/bin/sh
# tools/install_dualboot.sh: non-destructive dual-boot install of gbOS86 from a running Linux (no stick needed).
# Adds GBOSSYS (FAT32), GBOS_META (ext4) and GBOS_DATA (ext4) in the largest unallocated block of the target disk, puts
# the boot files in the disk's existing EFI system partition under EFI/gbos86/ (nothing else there is touched), and adds a
# GRUB entry and a UEFI boot entry for EFI/gbos86/BOOTX64.EFI (appended to BootOrder: the current boot order is kept).
# Secure Boot (README "Secure Boot"), the same layout as usb/install.sh: BOOTX64.EFI = shim, grubx64.efi = the kernel signed with
# the builder's key (tools/secureboot.py), mmx64.efi = MokManager, gbos86-mok.cer = the key. An install that already boots the
# kernel as EFI/gbos86/BOOTX64.EFI keeps it there (GRUB entries on the other OS name that file): it gets the signed kernel, no
# shim. A kernel without a .sbat section (#46 and older) or SECURE_BOOT=0: the kernel alone, unsigned (Secure Boot off).
# Re-running it on a disk that already has the partitions only updates the files: nothing is formatted unless --reformat.
# Everything is checked before the first write; partitioning or formatting asks for the disk's serial number.
# Usage: sudo tools/install_dualboot.sh --target /dev/sdX [options]

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
U=$ROOT/usb
TARGET_DISK=""
EFI_PART=""
SYS_SIZE="10G"
META_SIZE="64M"
DATA_SIZE="64G"
REFORMAT=0
DRY_RUN=0
AUTO_TAILOR=0
ALLOW_INTERNAL=0
ALLOW_ROOT=0
DO_NVRAM=1
BOOT_FIRST=0
DO_GRUB=1
GRUB_ROOT=/
MIN_DATA_MIB=4096
GRUB_LABEL="Googlebook OS (gbOS86)"
GRUB_ARGS="ibt=off i8042.nopnp androidboot.setupwizard.mode=DISABLED usbcore.autosuspend=-1"   # the same entry as usb/install.sh writes

say() { printf '\n== %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo $0 --target <disk> [options]

Options:
  --target <disk>        Target disk device (e.g. /dev/sda, /dev/nvme0n1). REQUIRED.
  --efi-part <part>      EFI system partition to use (default: the EFI-type partition of the target disk).
  --sys-size <size>      Size of GBOSSYS (default: 10G). K/M/G/T are binary units; a bare number is GiB.
  --meta-size <size>     Size of GBOS_META (default: 64M).
  --data-size <size>     Size of GBOS_DATA (default: 64G), or "rest" for the rest of the free block.
  --reformat             Re-format existing gbOS86 partitions (erases gbOS86's /data; asks for the serial).
  --allow-internal       Allow targeting internal drives (NVMe, fixed SATA).
  --allow-root           Allow targeting the disk holding the running root filesystem.
  --no-nvram             Do not add a UEFI boot entry (efibootmgr).
  --boot-first           Put the new UEFI boot entry first in BootOrder (default: append it, keeping the current order).
  --no-grub              Do not add a GRUB menu entry.
  --grub-root <dir>      The root of the Linux whose GRUB gets the entry (default: /). update-grub only runs for /.
  --dry-run              Show what would be done; write nothing.
  -h, --help             Show this help message.

Environment: SECURE_BOOT=0 installs the kernel alone, unsigned (no shim). GBOS_SB_KEYS=DIR: the signing key's directory
(tools/secureboot.py; default ~/.config/gbos86/secureboot of the user who ran sudo).

Example:
  sudo $0 --target /dev/nvme0n1 --allow-internal --allow-root --sys-size 8G --data-size rest
EOF
  exit "${1:-1}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET_DISK="$2"; shift 2;;
    --efi-part) EFI_PART="$2"; shift 2;;
    --sys-size) SYS_SIZE="$2"; shift 2;;
    --meta-size) META_SIZE="$2"; shift 2;;
    --data-size) DATA_SIZE="$2"; shift 2;;
    --reformat) REFORMAT=1; shift;;
    --allow-internal) ALLOW_INTERNAL=1; shift;;
    --allow-root) ALLOW_ROOT=1; shift;;
    --no-nvram) DO_NVRAM=0; shift;;
    --boot-first) BOOT_FIRST=1; shift;;
    --no-grub) DO_GRUB=0; shift;;
    --grub-root) GRUB_ROOT="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -a|--auto|--host) AUTO_TAILOR=1; shift;;
    -h|--help) usage 0;;
    *) die "Unknown argument: $1";;
  esac
done

# Sizes -> MiB. A bare number is GiB (sgdisk would read "+64" as 64 sectors).
to_mib() {
  _n=${1%[KkMmGgTt]}
  case "$_n" in ''|*[!0-9]*) return 1;; esac
  case "$1" in
    *[Kk]) echo $(( (_n + 1023) / 1024 ));;
    *[Mm]) echo "$_n";;
    *[Tt]) echo $(( _n * 1024 * 1024 ));;
    *) echo $(( _n * 1024 ));;
  esac
}
SYS_MIB=$(to_mib "$SYS_SIZE") || die "bad --sys-size: $SYS_SIZE"
META_MIB=$(to_mib "$META_SIZE") || die "bad --meta-size: $META_SIZE"
case "$DATA_SIZE" in
  rest|max|0|0G) DATA_MIB=0;;
  *) DATA_MIB=$(to_mib "$DATA_SIZE") || die "bad --data-size: $DATA_SIZE";;
esac
[ "$SYS_MIB" -ge 1024 ] || die "--sys-size must be at least 1G (the system image alone is several GB)"
[ "$META_MIB" -ge 16 ] || die "--meta-size must be at least 16M"
[ "$DATA_MIB" = 0 ] || [ "$DATA_MIB" -ge "$MIN_DATA_MIB" ] || die "--data-size must be at least $((MIN_DATA_MIB / 1024))G"
GRUB_ROOT=${GRUB_ROOT%/}; GR=$GRUB_ROOT; [ -n "$GRUB_ROOT" ] || GRUB_ROOT=/   # GR: path prefix ("" for /)

[ -n "$TARGET_DISK" ] || usage 1
[ -b "$TARGET_DISK" ] || die "$TARGET_DISK is not a valid block device."
[ "$(id -u)" -eq 0 ] || die "This script requires root privileges. Please run with sudo."
for c in sfdisk sgdisk lsblk blkid wipefs mkfs.vfat mkfs.ext4 findmnt; do
  command -v $c >/dev/null 2>&1 || die "missing '$c'"
done

# Safety guard 1: the disk that holds the running root filesystem
_d=${TARGET_DISK##*/}
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | head -1 || true)
if [ "$ROOT_DISK" = "$_d" ] || { [ -z "$ROOT_DISK" ] && echo "$ROOT_DEV" | grep -q "$_d"; }; then
  [ $ALLOW_ROOT -eq 1 ] || die "$TARGET_DISK holds your running root filesystem ($ROOT_DEV). Pass --allow-root if you intend to use free space on this drive."
fi
# Safety guard 2: an internal disk (NVMe or fixed SATA, often Windows) needs --allow-internal. Removable and USB disks do not.
if [ "$(cat /sys/block/$_d/removable 2>/dev/null)" != 1 ] && ! readlink -f "/sys/block/$_d" 2>/dev/null | grep -q '/usb[0-9]'; then
  [ $ALLOW_INTERNAL -eq 1 ] || die "$TARGET_DISK is an internal disk. To protect internal Windows/Linux drives, pass --allow-internal to confirm."
fi

say "Target disk: $TARGET_DISK"
PT=$(sfdisk -d "$TARGET_DISK" 2>/dev/null) || die "cannot read the partition table of $TARGET_DISK"
echo "$PT" | grep -q '^label: gpt' || die "dual-boot needs a GPT disk; $TARGET_DISK is not"
SS=$(cat /sys/block/$_d/queue/logical_block_size 2>/dev/null || echo 512)
SPM=$((1048576 / SS))   # sectors per MiB

# A partition by GPT name (it exists before it has a filesystem), else by filesystem label.
part_by_name() { echo "$PT" | awk -v n="name=\"$1\"" 'index($0, n) {print $1; exit}'; }
part_by_label() { lsblk -rn -o NAME,LABEL "$TARGET_DISK" 2>/dev/null | awk -v l="$1" '$2 == l {print "/dev/" $1; exit}'; }
find_part() { _p=$(part_by_name "$1"); [ -n "$_p" ] || _p=$(part_by_label "$1"); echo "$_p"; }
part_field() { echo "$PT" | awk -v p="$1" -v f="$2" '$1 == p { if (match($0, f "= *[0-9]+")) { s = substr($0, RSTART, RLENGTH); sub(/.*= */, "", s); print s } }'; }
fstype() { blkid -p -s TYPE -o value "$1" 2>/dev/null || true; }
fslabel() { blkid -p -s LABEL -o value "$1" 2>/dev/null || true; }
has_fs() { [ "$(fstype "$1")" = "$2" ] && [ "$(fslabel "$1")" = "$3" ]; }   # dev type label

# The EFI system partition: GPT type first, the usual labels as a fallback
if [ -z "$EFI_PART" ]; then
  EFI_PART=$(echo "$PT" | awk 'toupper($0) ~ /TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ {print $1; exit}')
  [ -n "$EFI_PART" ] || EFI_PART=$(lsblk -rn -o NAME,LABEL "$TARGET_DISK" 2>/dev/null | awk '$2 ~ /^(EFI|SYSTEM|ESP|GBOS_EFI)$/ {print "/dev/" $1; exit}')
fi
[ -n "$EFI_PART" ] && [ -b "$EFI_PART" ] || die "Could not identify the EFI partition on $TARGET_DISK. Specify it with --efi-part."
[ "$(fstype "$EFI_PART")" = vfat ] || die "$EFI_PART is not a FAT EFI system partition"
ESP_UUID=$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null || true)
echo "EFI partition: $EFI_PART (UUID $ESP_UUID)"

# What gets installed must all be here before anything is written.
KERNEL=$U/out/BOOTX64.EFI
[ -f "$KERNEL" ] || die "no kernel: $KERNEL is missing"
TMP_MNTS=""; SB_DIR=""
cleanup() { for m in $TMP_MNTS; do umount "$m" 2>/dev/null; rmdir "$m" 2>/dev/null; done; [ -z "$SB_DIR" ] || rm -rf "$SB_DIR"; }
trap cleanup EXIT INT TERM

# Secure Boot: sign the kernel and gather shim, MokManager and the key in SB_DIR (tools/secureboot.py esp) before anything is
# written, as the user who ran sudo: the key lives in that user's home, and root's own home must not get a second key.
is_kernel() { [ "$(dd if="$1" bs=1 skip=514 count=4 2>/dev/null)" = HdrS ]; }   # the x86 boot header; shim has none
as_user() {
  if [ "$(id -u)" = 0 ] && [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != root ]; then
    sudo -u "$SUDO_USER" -H env ${GBOS_SB_KEYS:+GBOS_SB_KEYS="$GBOS_SB_KEYS"} "$@"
  else "$@"; fi
}
SB=0; SB_WHY=""
if [ "${SECURE_BOOT:-1}" = 0 ]; then SB_WHY="SECURE_BOOT=0"
elif [ ! -f "$U/shim/shimx64.efi" ] || [ ! -f "$U/shim/mmx64.efi" ]; then SB_WHY="no shim in $U/shim (tools/fetch_shim.sh)"
elif ! SB_WHY=$(python3 "$ROOT/tools/secureboot.py" check "$KERNEL" 2>&1 >/dev/null); then SB_WHY=${SB_WHY#secureboot: }
elif [ $DRY_RUN -eq 1 ]; then SB=1
else
  SB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gbos86-sb.XXXXXX")
  [ "$(id -u)" = 0 ] && [ -n "$SUDO_USER" ] && chown "$SUDO_USER" "$SB_DIR"
  if as_user python3 "$ROOT/tools/secureboot.py" esp "$SB_DIR" "$KERNEL"; then SB=1; else SB_WHY="signing the kernel failed (see above)"; fi
fi
[ $SB = 1 ] || warn "Secure Boot: $SB_WHY. The kernel is installed alone and unsigned: boot gbOS86 with Secure Boot off."
# The boot files' sources: the signed kernel and shim's files, or the kernel alone. A dry run signs nothing: its sizes are estimates.
if [ $SB = 0 ]; then BOOT_KERNEL=$KERNEL
elif [ -n "$SB_DIR" ]; then BOOT_KERNEL=$SB_DIR/grubx64.efi
else BOOT_KERNEL=$KERNEL; fi
U_HOME=$HOME; [ "$(id -u)" = 0 ] && [ -n "$SUDO_USER" ] && U_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
KEY_CER=${GBOS_SB_KEYS:-$U_HOME/.config/gbos86/secureboot}/mok.cer   # the key's public half, for mokutil
SB_FILES="mmx64.efi gbos86-mok.cer shim-COPYRIGHT.txt BOOTX64.EFI"   # after the kernel; shim (BOOTX64.EFI) last
sb_src() { # name: the source of one of SB_FILES (in a dry run, usb/shim's; the key is a few hundred bytes)
  if [ -n "$SB_DIR" ]; then echo "$SB_DIR/$1"; else case $1 in BOOTX64.EFI) echo "$U/shim/shimx64.efi";; shim-COPYRIGHT.txt) echo "$U/shim/COPYRIGHT";; gbos86-mok.cer) ;; *) echo "$U/shim/$1";; esac; fi
}
kb() { [ -f "$1" ] && echo $(( ($(stat -c %s "$1") + 1023) / 1024 )) || echo 0; }
SUPER=""
for s in "$ROOT/dist" "$ROOT/build"; do [ -f "$s/super.img" ] && [ -f "$s/super.layout" ] && { SUPER=$s; break; }; done
if [ -z "$SUPER" ]; then
  for n in system_a vendor_a product_a system_ext_a system_dlkm_a vendor_dlkm_a; do
    [ -f "$ROOT/lapis/parts/$n.img" ] && continue
    [ $DRY_RUN -eq 1 ] && { warn "no system image yet ($ROOT/lapis/parts/$n.img): ./build.sh downloads it"; break; }
    die "no system image: $ROOT/lapis/parts/$n.img is missing (run ./build.sh first)"
  done
fi

# Existing gbOS86 partitions? GBOSSYS and GBOS_DATA are required, GBOS_META is optional (gbos/metadata.img replaces it).
SYS_PART=$(find_part GBOSSYS); META_PART=$(find_part GBOS_META); DATA_PART=$(find_part GBOS_DATA)
if [ -n "$SYS_PART" ] && [ -n "$DATA_PART" ]; then
  ALREADY_PARTITIONED=1
  say "Found existing gbOS86 partitions on $TARGET_DISK: GBOSSYS $SYS_PART, GBOS_META ${META_PART:-none}, GBOS_DATA $DATA_PART"
elif [ -n "$SYS_PART$META_PART$DATA_PART" ]; then
  die "only some gbOS86 partitions exist on $TARGET_DISK (GBOSSYS '${SYS_PART}', GBOS_META '${META_PART}', GBOS_DATA '${DATA_PART}'). Delete them or create the missing ones by hand; nothing was changed."
else
  ALREADY_PARTITIONED=0
fi

# Which partitions get a new filesystem: all new ones; existing ones with --reformat, or when they lack their filesystem
# (type and label: an earlier run stopped between partitioning and formatting).
FORMAT_SYS=0; FORMAT_META=0; FORMAT_DATA=0
if [ $ALREADY_PARTITIONED -eq 0 ] || [ $REFORMAT -eq 1 ]; then
  FORMAT_SYS=1; FORMAT_DATA=1; [ $ALREADY_PARTITIONED -eq 0 ] || [ -n "$META_PART" ] && FORMAT_META=1
else
  has_fs "$SYS_PART" vfat GBOSSYS || FORMAT_SYS=1
  has_fs "$DATA_PART" ext4 GBOS_DATA || FORMAT_DATA=1
  [ -z "$META_PART" ] || has_fs "$META_PART" ext4 GBOS_META || FORMAT_META=1
fi
for x in "$SYS_PART $FORMAT_SYS" "$META_PART $FORMAT_META" "$DATA_PART $FORMAT_DATA"; do
  set -- $x
  [ "$2" = 1 ] && [ -n "$(findmnt -n -o TARGET --source "$1" 2>/dev/null)" ] && die "$1 is mounted and would be formatted; unmount it first"
done

# New partitions: placed one after another at the start of the largest free block, at explicit sectors.
if [ $ALREADY_PARTITIONED -eq 0 ]; then
  FREE_FIRST=$(sgdisk -F "$TARGET_DISK" 2>/dev/null | tail -1)
  FREE_LAST=$(sgdisk -E "$TARGET_DISK" 2>/dev/null | tail -1)
  case "$FREE_FIRST$FREE_LAST" in ''|*[!0-9]*) die "sgdisk could not find free space on $TARGET_DISK";; esac
  FREE_MIB=$(( (FREE_LAST - FREE_FIRST + 1) / SPM ))
  S1=$FREE_FIRST;                                   E1=$(( S1 + SYS_MIB * SPM - 1 ))
  S2=$(( (E1 + SPM) / SPM * SPM ));                 E2=$(( S2 + META_MIB * SPM - 1 ))
  S3=$(( (E2 + SPM) / SPM * SPM ))
  if [ "$DATA_MIB" = 0 ]; then E3=$FREE_LAST; else E3=$(( S3 + DATA_MIB * SPM - 1 )); fi
  [ "$E3" -le "$FREE_LAST" ] && [ $(( (E3 - S3 + 1) / SPM )) -ge $MIN_DATA_MIB ] || die "the largest free block on $TARGET_DISK is $FREE_MIB MiB (sectors $FREE_FIRST-$FREE_LAST): too small for GBOSSYS $SYS_MIB MiB + GBOS_META $META_MIB MiB + GBOS_DATA $([ "$DATA_MIB" = 0 ] && echo "at least $MIN_DATA_MIB" || echo $DATA_MIB) MiB. Nothing was changed."
  DATA_MIB_REAL=$(( (E3 - S3 + 1) / SPM ))
  say "Plan: in the free block of $FREE_MIB MiB (sectors $FREE_FIRST-$FREE_LAST):"
  echo "  GBOSSYS   FAT32  $SYS_MIB MiB  (sectors $S1-$E1)"
  echo "  GBOS_META ext4   $META_MIB MiB  (sectors $S2-$E2)"
  echo "  GBOS_DATA ext4   $DATA_MIB_REAL MiB  (sectors $S3-$E3)"
else
  say "Plan: update the files on the existing partitions."
  [ $FORMAT_SYS = 1 ] && echo "  GBOSSYS $SYS_PART will be formatted"
  [ $FORMAT_META = 1 ] && echo "  GBOS_META $META_PART will be formatted"
  [ $FORMAT_DATA = 1 ] && echo "  GBOS_DATA $DATA_PART will be formatted (gbOS86's apps and data are erased)"
fi

# The boot files have to fit on the EFI partition (they replace older ones of the same names). Mount it read-only to look.
mount_part() { # dev [ro]: sets MP to its mount point. An existing mount is reused (for writing only if it is read-write).
  MP=$(findmnt -n -o TARGET --source "$1" 2>/dev/null | head -1)
  if [ -n "$MP" ]; then
    [ "$2" = ro ] || findmnt -n -o OPTIONS --source "$1" | head -1 | grep -q '^rw' || { warn "$1 is mounted read-only on $MP; unmount it first"; return 1; }
    return 0
  fi
  MP=$(mktemp -d); mount ${2:+-o $2} "$1" "$MP" || { rmdir "$MP"; return 1; }; TMP_MNTS="$MP $TMP_MNTS"
}
umount_part() { case " $TMP_MNTS " in *" $1 "*) umount "$1" && rmdir "$1"; TMP_MNTS=$(echo " $TMP_MNTS " | sed "s# $1 # #");; esac; }
mount_part "$EFI_PART" ro || die "cannot mount $EFI_PART"; EFI_MNT=$MP
# Layout (usb/install.sh's boot_layout ... keep): the kernel is EFI/gbos86/grubx64.efi when that is already there, or for a new
# install with Secure Boot files; an install that boots the kernel as EFI/gbos86/BOOTX64.EFI keeps it there, signed, without shim.
ED=$EFI_MNT/EFI/gbos86
if [ -f "$ED/grubx64.efi" ] || { [ $SB = 1 ] && ! is_kernel "$ED/BOOTX64.EFI"; }; then KNAME=grubx64.efi; else KNAME=BOOTX64.EFI; fi
SHIM=0; [ $SB = 1 ] && [ $KNAME = grubx64.efi ] && SHIM=1
NEW_KB=$(( $(kb "$BOOT_KERNEL") + 4 )); OLD_KB=$(kb "$ED/$KNAME")   # +4: the signature
if [ $SHIM = 1 ]; then for f in $SB_FILES; do NEW_KB=$(( NEW_KB + $(kb "$(sb_src $f)") + 4 )); OLD_KB=$(( OLD_KB + $(kb "$ED/$f") )); done; fi
EFI_FREE_KB=$(df -kP "$EFI_MNT" | awk 'NR==2 {print $4}')
[ $(( EFI_FREE_KB + OLD_KB )) -ge $(( NEW_KB + 1024 )) ] || die "$EFI_PART has $((EFI_FREE_KB / 1024)) MB free; the boot files need $((NEW_KB / 1024 + 1)) MB$([ $OLD_KB -gt 0 ] && echo " ($((OLD_KB / 1024)) MB of it is freed by the files they replace)"). Nothing was changed."
if [ $SHIM = 1 ]; then echo "  boot files -> $EFI_PART EFI/gbos86/: BOOTX64.EFI (shim), grubx64.efi (the kernel, signed), mmx64.efi (MokManager), gbos86-mok.cer (the key)"
elif [ $SB = 1 ]; then echo "  kernel -> $EFI_PART EFI/gbos86/BOOTX64.EFI, signed; no shim: this install already boots the kernel as that file"
else echo "  kernel -> $EFI_PART EFI/gbos86/$KNAME, unsigned$([ $KNAME = grubx64.efi ] && echo " (the shim already there stays: with Secure Boot on it refuses this kernel)")"; fi
echo "    $((NEW_KB / 1024)) MB, $((EFI_FREE_KB / 1024)) MB free$([ $OLD_KB -gt 0 ] && echo ", replaces the existing files")"
umount_part "$EFI_MNT"

# GRUB: an entry that boots the kernel (EFI/gbos86/$KNAME) from this ESP (as usb/install.sh writes it) or chainloads this
# GBOSSYS's EFI/BOOT/BOOTX64.EFI (shim or the kernel, see below) is current; any other "Googlebook OS" entry is stale (an older
# install; with shim, one that names EFI/gbos86/BOOTX64.EFI would start shim as a kernel) and is reported, not edited.
GRUB_DIR=""; GRUB_FILE=""; GRUB_STALE=""; GRUB_OK=""
if [ $DO_GRUB = 1 ]; then
  for g in "$GR/boot/grub" "$GR/boot/grub2"; do [ -f "$g/grub.cfg" ] && { GRUB_DIR=$g; break; }; done
  SYS_UUID=""; [ -n "$SYS_PART" ] && [ $FORMAT_SYS = 0 ] && SYS_UUID=$(blkid -s UUID -o value "$SYS_PART" 2>/dev/null || true)
  for f in "$GRUB_DIR/custom.cfg" "$GR/etc/grub.d/40_custom"; do
    [ -f "$f" ] && grep -q "Googlebook OS" "$f" 2>/dev/null || continue
    if { [ -n "$ESP_UUID" ] && grep -q -- "--fs-uuid --set=root $ESP_UUID" "$f" && grep -q "linux /EFI/gbos86/$KNAME" "$f"; } || \
       { [ -n "$SYS_UUID" ] && grep -q -- "--fs-uuid --set=root $SYS_UUID" "$f" && grep -q "chainloader /EFI/BOOT/BOOTX64.EFI" "$f"; }; then
      GRUB_OK="$GRUB_OK $f"
    else
      GRUB_STALE="$GRUB_STALE $f"
    fi
  done
  if [ -n "$GRUB_OK" ]; then echo "  GRUB: an entry for this install is already in$GRUB_OK: not changed"
  elif [ -n "$GRUB_DIR" ] && grep -q 'custom\.cfg' "$GRUB_DIR/grub.cfg" 2>/dev/null; then GRUB_FILE=$GRUB_DIR/custom.cfg; echo "  GRUB: add '$GRUB_LABEL' to $GRUB_FILE"
  elif [ -f "$GR/etc/grub.d/40_custom" ]; then GRUB_FILE=$GR/etc/grub.d/40_custom; echo "  GRUB: add '$GRUB_LABEL' to $GRUB_FILE$([ "$GRUB_ROOT" = / ] && echo " and run update-grub")"
  else echo "  GRUB: none found under $GRUB_ROOT; boot gbOS86 from the UEFI boot menu"; fi
  for f in $GRUB_STALE; do
    warn "$f has a 'Googlebook OS' entry that does not boot this install (an older install?). It is left as it is; remove it by hand:"
    grep -n -A7 "Googlebook OS" "$f" | sed 's/^/    /' >&2
  done
fi

# UEFI boot entry
EFI_NUM=$(cat "/sys/class/block/${EFI_PART##*/}/partition" 2>/dev/null || echo "$EFI_PART" | grep -o '[0-9]*$')
EFI_DISK=/dev/$(lsblk -no PKNAME "$EFI_PART" 2>/dev/null | head -1)
[ "$EFI_DISK" != /dev/ ] || EFI_DISK=$(echo "$EFI_PART" | sed -E 's/p?[0-9]+$//')
NVRAM=0
if [ $DO_NVRAM = 1 ]; then
  if ! command -v efibootmgr >/dev/null 2>&1 || [ ! -d /sys/firmware/efi/efivars ]; then echo "  UEFI: no efibootmgr/efivars: no boot entry added"
  elif efibootmgr 2>/dev/null | grep -q "Googlebook OS"; then echo "  UEFI: a 'Googlebook OS' boot entry exists: not changed"
  else NVRAM=1; echo "  UEFI: add boot entry '$GRUB_LABEL' ($EFI_DISK partition $EFI_NUM, \\EFI\\gbos86\\BOOTX64.EFI), $([ $BOOT_FIRST = 1 ] && echo "first in BootOrder" || echo "at the end of BootOrder (the current order is kept)")"; fi
fi

if [ $DRY_RUN -eq 1 ]; then
  say "[DRY RUN] nothing was written."
  exit 0
fi

# Partitioning or formatting: show the disk and make the user type its serial (the same rule as the live USB installer).
if [ $ALREADY_PARTITIONED -eq 0 ] || [ $FORMAT_SYS$FORMAT_META$FORMAT_DATA != 000 ]; then
  say "Disk $TARGET_DISK:"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,PARTTYPENAME "$TARGET_DISK" 2>/dev/null
  DSERIAL=$(lsblk -dno SERIAL "$TARGET_DISK" 2>/dev/null | tr -d ' ')
  [ -n "$DSERIAL" ] || DSERIAL=$(basename "$TARGET_DISK")
  if [ $ALREADY_PARTITIONED -eq 0 ]; then
    echo "This adds GBOSSYS, GBOS_META and GBOS_DATA in the unallocated space as planned above. No existing partition is changed."
  else
    echo "This formats the gbOS86 partitions named in the plan above. No other partition is changed."
  fi
  printf 'To continue type the serial number (%s) exactly: ' "$DSERIAL"
  read -r _a
  [ "$_a" = "$DSERIAL" ] || die "Cancelled. Nothing was written to $TARGET_DISK."
fi

if [ $ALREADY_PARTITIONED -eq 0 ]; then
  say "Creating the gbOS86 partitions ..."
  sgdisk \
    -n 0:$S1:$E1 -t 0:0700 -c 0:GBOSSYS \
    -n 0:$S2:$E2 -t 0:8300 -c 0:GBOS_META \
    -n 0:$S3:$E3 -t 0:8300 -c 0:GBOS_DATA \
    "$TARGET_DISK" || die "sgdisk failed to create the partitions (sgdisk does not save a table when an operation fails)."
  # The other partitions of a disk in use stay busy: tell the kernel about the new ones only.
  partprobe "$TARGET_DISK" 2>/dev/null || partx -a "$TARGET_DISK" 2>/dev/null || true
  i=0
  while :; do
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 2>/dev/null || sleep 1
    PT=$(sfdisk -d "$TARGET_DISK" 2>/dev/null)
    SYS_PART=$(part_by_name GBOSSYS); META_PART=$(part_by_name GBOS_META); DATA_PART=$(part_by_name GBOS_DATA)
    [ -b "$SYS_PART" ] && [ -b "$META_PART" ] && [ -b "$DATA_PART" ] && break
    i=$((i + 1)); [ $i -lt 10 ] || die "the new partitions (GBOSSYS '$SYS_PART', GBOS_META '$META_PART', GBOS_DATA '$DATA_PART') did not appear as block devices. They are empty: reboot and run this again with --reformat (it keeps them and formats them)."
    partx -a "$TARGET_DISK" 2>/dev/null || partx -u "$TARGET_DISK" 2>/dev/null || true
    sleep 1
  done
  # They must be exactly what was planned (so a format can never hit another partition).
  for x in "$SYS_PART $S1 $E1" "$META_PART $S2 $E2" "$DATA_PART $S3 $E3"; do
    set -- $x
    _s=$(part_field "$1" start); _n=$(part_field "$1" size)
    [ "$_s" = "$2" ] && [ $(( _s + _n - 1 )) = "$3" ] || die "$1 is not where it was planned (start $_s size $_n, planned $2-$3); not formatting anything"
  done
  echo "  GBOSSYS $SYS_PART, GBOS_META $META_PART, GBOS_DATA $DATA_PART"
fi

# Format. wipefs first: the space can hold signatures of an older, deleted install.
if [ $FORMAT_SYS = 1 ]; then say "Formatting GBOSSYS ($SYS_PART) ..."; wipefs -a -q "$SYS_PART"; mkfs.vfat -F 32 -n GBOSSYS "$SYS_PART"; fi
if [ $FORMAT_META = 1 ]; then say "Formatting GBOS_META ($META_PART) ..."; wipefs -a -q "$META_PART"; mkfs.ext4 -F -q -L GBOS_META "$META_PART"; fi
if [ $FORMAT_DATA = 1 ]; then say "Formatting GBOS_DATA ($DATA_PART) ..."; wipefs -a -q "$DATA_PART"; mkfs.ext4 -F -q -m 0 -O verity -L GBOS_DATA "$DATA_PART"; fi
command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 2>/dev/null || true

# Populate GBOSSYS
mount_part "$SYS_PART" || die "cannot mount $SYS_PART"; MNT_SYS=$MP
LOG=$MNT_SYS/gbos/logs/dualboot-install.txt
mkdir -p "$MNT_SYS/EFI/BOOT" "$MNT_SYS/gbos/logs"
{ echo "== $(date -u '+%Y-%m-%d %H:%M:%S UTC') install_dualboot.sh $(git -c safe.directory="$ROOT" -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"
  echo "target $TARGET_DISK  efi $EFI_PART  sys $SYS_PART  meta ${META_PART:-none}  data $DATA_PART  formatted sys=$FORMAT_SYS meta=$FORMAT_META data=$FORMAT_DATA"
  echo "boot EFI/gbos86/$KNAME = kernel ($([ $SB = 1 ] && echo signed || echo "unsigned: $SB_WHY")), shim $([ $SHIM = 1 ] && echo yes || echo no)"; } >> "$LOG"

# Create loopback metadata.img if physical GBOS_META partition is absent
if [ -z "$META_PART" ] && [ ! -f "$MNT_SYS/gbos/metadata.img" ]; then
  say "Creating loopback metadata.img (64 MB ext4) inside GBOSSYS..."
  dd if=/dev/zero of="$MNT_SYS/gbos/metadata.img" bs=1M count=64 status=none
  mkfs.ext4 -F -q -L GBOS_META "$MNT_SYS/gbos/metadata.img"
fi

say "Copying system files to $SYS_PART (GBOSSYS)..."
# GBOSSYS's own EFI/BOOT: what an older GRUB entry chainloads and what some firmware adds a boot entry for by itself. It is
# gbOS86's partition, so it always gets the full layout: shim + the signed kernel, or the kernel alone (shim's files removed).
if [ $SB = 1 ]; then
  cp "$BOOT_KERNEL" "$MNT_SYS/EFI/BOOT/grubx64.efi"
  for f in $SB_FILES; do cp "$SB_DIR/$f" "$MNT_SYS/EFI/BOOT/$f"; done
else
  cp "$KERNEL" "$MNT_SYS/EFI/BOOT/BOOTX64.EFI"
  rm -f "$MNT_SYS/EFI/BOOT/grubx64.efi" "$MNT_SYS/EFI/BOOT/mmx64.efi" "$MNT_SYS/EFI/BOOT/gbos86-mok.cer" "$MNT_SYS/EFI/BOOT/shim-COPYRIGHT.txt"
fi
[ -f "$ROOT/kernel/out/busybox" ] && cp "$ROOT/kernel/out/busybox" "$MNT_SYS/busybox"

for f in hook.sh optimize.sh aidiag.sh native_zygote.sh early_patch.sh hwdetect.sh install.sh apex_patch.sh gbos.cfg \
         crossystem bootdisk.img libkm_compat.so system_ext_manifest.xml soft_gk; do
  [ -f "$U/$f" ] && cp "$U/$f" "$MNT_SYS/gbos/$f"
done

for d in firmware patched audio installer kmod modules surface ksu; do
  [ -d "$U/$d" ] && { mkdir -p "$MNT_SYS/gbos/$d"; cp -R "$U/$d/." "$MNT_SYS/gbos/$d/"; }
done
# Ensure both '+' and non-'+' versions exist on the FAT32 filesystem
for _m in "$MNT_SYS/gbos/modules/lib/modules/"*-gbos-whl+; do
  if [ -d "$_m" ]; then
    _base="${_m%+}"
    [ ! -d "$_base" ] && cp -a "$_m" "$_base" 2>/dev/null || true
  fi
done
for _m in "$MNT_SYS/gbos/modules/lib/modules/"*-gbos-whl; do
  if [ -d "$_m" ]; then
    _plus="${_m}+"
    [ ! -d "$_plus" ] && cp -a "$_m" "$_plus" 2>/dev/null || true
  fi
done

# The system image: build it from lapis/parts (the same call as tools/make_gbos86_image.sh), unless a built one is around
if [ -z "$SUPER" ]; then
  P=$ROOT/lapis/parts
  mkdir -p "$ROOT/build"
  say "Building super.img from lapis/parts ..."
  python3 "$U/make_super.py" "$ROOT/build/super.img" "$ROOT/build/super.layout" \
    system_a="$P/system_a.img" vendor_a="$P/vendor_a.img" product_a="$P/product_a.img" \
    system_ext_a="$P/system_ext_a.img" system_dlkm_a="$P/system_dlkm_a.img" vendor_dlkm_a="$P/vendor_dlkm_a.img" || die "make_super.py failed"
  SUPER=$ROOT/build
fi
say "Copying $SUPER/super.img ..."
cp "$SUPER/super.img" "$MNT_SYS/gbos/super.img" && cp "$SUPER/super.layout" "$MNT_SYS/gbos/super.layout" || die "copying super.img failed"

# Ensure MODE=boot in gbos.cfg
sed -i 's/^MODE=.*/MODE=boot/' "$MNT_SYS/gbos/gbos.cfg" 2>/dev/null || true

# Apply hardware auto-tailoring if enabled
if [ "$AUTO_TAILOR" = 1 ]; then
  if [ -f "$ROOT/tools/detect_hardware.sh" ]; then
    . "$ROOT/tools/detect_hardware.sh"
    detect_host_hardware
    say "Tailoring gbos.cfg for host hardware: $DETECTED_DEVICE_MODEL ..."
    apply_hardware_config "$MNT_SYS/gbos/gbos.cfg"
  fi
fi

# The boot files on the EFI partition: only EFI/gbos86/ is written. The kernel first: until shim replaces an older kernel as
# BOOTX64.EFI, that one still boots.
mount_part "$EFI_PART" || die "cannot mount $EFI_PART read-write"; EFI_MNT=$MP; ED=$EFI_MNT/EFI/gbos86
mkdir -p "$ED"
boot_files() { # FN: FN SOURCE NAME for each boot file, the kernel first
  $1 "$BOOT_KERNEL" $KNAME
  [ $SHIM = 0 ] || for f in $SB_FILES; do $1 "$SB_DIR/$f" $f; done
}
put_file() { cmp -s "$1" "$ED/$2" || cp "$1" "$ED/$2" || die "copying $2 to $EFI_PART failed"; }
check_file() { cmp -s "$1" "$ED/$2" || die "EFI/gbos86/$2 on $EFI_PART does not match $1"; }
boot_files put_file
[ -f "$U/Add-gbOS-to-Windows-BootMenu.bat" ] && cp "$U/Add-gbOS-to-Windows-BootMenu.bat" "$ED/" 2>/dev/null || true
sync
boot_files check_file
if [ $SHIM = 1 ]; then say "Installed the boot files to $EFI_PART -> EFI/gbos86/: BOOTX64.EFI (shim), grubx64.efi (the kernel, signed), mmx64.efi, gbos86-mok.cer"
else say "Installed the kernel to $EFI_PART -> EFI/gbos86/$KNAME ($([ $SB = 1 ] && echo signed || echo unsigned))"; fi
umount_part "$EFI_MNT"

# UEFI boot entry. efibootmgr -c puts a new entry first in BootOrder; unless --boot-first, the old order is restored with
# the new entry appended.
if [ $NVRAM = 1 ]; then
  OLD_ORDER=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: *//p')
  echo "BootOrder before: $OLD_ORDER" >> "$LOG"
  say "Adding UEFI boot entry '$GRUB_LABEL' ..."
  if efibootmgr -c -d "$EFI_DISK" -p "$EFI_NUM" -L "$GRUB_LABEL" -l '\EFI\gbos86\BOOTX64.EFI' >/dev/null; then
    NEW=$(efibootmgr 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} Googlebook OS.*/\1/p' | head -1)
    if [ $BOOT_FIRST = 0 ] && [ -n "$NEW" ] && [ -n "$OLD_ORDER" ]; then
      efibootmgr -o "$OLD_ORDER,$NEW" >/dev/null || warn "could not restore BootOrder; it is now: $(efibootmgr | sed -n 's/^BootOrder: *//p'). Restore it with: efibootmgr -o $OLD_ORDER,$NEW"
    fi
  else
    warn "efibootmgr could not add the boot entry; boot gbOS86 from GRUB"
  fi
  echo "BootOrder after:  $(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: *//p')" | tee -a "$LOG"
fi

# GRUB entry
if [ -n "$GRUB_FILE" ]; then
  [ -n "$ESP_UUID" ] || die "no UUID on $EFI_PART; cannot write a GRUB entry"
  cp "$GRUB_FILE" "$GRUB_FILE.gbos-bak" 2>/dev/null || true
  cat >> "$GRUB_FILE" <<GRUB_EOF

# Googlebook OS (gbOS86) Persistent
menuentry "$GRUB_LABEL" --class android --class os {
    insmod part_gpt
    insmod fat
    search --no-floppy --fs-uuid --set=root $ESP_UUID
    linux /EFI/gbos86/$KNAME $GRUB_ARGS
}
GRUB_EOF
  say "Added '$GRUB_LABEL' to $GRUB_FILE (the previous file is $GRUB_FILE.gbos-bak)"
  echo "GRUB entry added to $GRUB_FILE" >> "$LOG"
  case "$GRUB_FILE" in
    */etc/grub.d/40_custom)
      if [ "$GRUB_ROOT" = / ]; then
        if command -v update-grub >/dev/null 2>&1; then update-grub || warn "update-grub failed"
        elif command -v grub2-mkconfig >/dev/null 2>&1; then grub2-mkconfig -o "$GRUB_DIR/grub.cfg" || warn "grub2-mkconfig failed"
        else warn "run update-grub (or grub-mkconfig) yourself"; fi
      fi;;
  esac
fi

sync
umount_part "$MNT_SYS"
say "gbOS86 dual-boot installation complete!"
echo "Reboot and select '$GRUB_LABEL' in GRUB, or in the UEFI boot menu."
if [ $SHIM = 1 ]; then
  echo "Secure Boot can stay on. The first boot of the UEFI entry with it asks once to enroll the gbOS86 key (README \"Secure Boot\":"
  echo "MokManager, Enroll key from disk, EFI/gbos86/gbos86-mok.cer). To boot it from GRUB first, enroll the key from here instead:"
  echo "  sudo mokutil --import $KEY_CER"
elif [ $SB = 1 ]; then
  echo "Secure Boot: the kernel is signed, but this install has no shim (it boots EFI/gbos86/BOOTX64.EFI as the kernel). With Secure"
  echo "Boot on, boot it from GRUB after enrolling the key: sudo mokutil --import $KEY_CER"
fi
