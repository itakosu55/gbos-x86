#!/bin/sh
# Refresh usb/shim/ (shim and MokManager for Secure Boot, see tools/secureboot.py) from Ubuntu's shim-signed package.
#
#   sh tools/fetch_shim.sh                       copy them from the installed package (Debian/Ubuntu: apt install shim-signed)
#   sh tools/fetch_shim.sh shim-signed_*.deb     take them from a downloaded package (needs dpkg-deb)
#
# shimx64.efi is the shim Microsoft signed (UEFI CA 2011): firmware with Secure Boot on starts it. mmx64.efi (MokManager) is signed
# by Canonical, whose certificate that shim carries. Writes usb/shim/{shimx64.efi,mmx64.efi,COPYRIGHT,SOURCE.txt}; commit them together.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$ROOT/usb/shim
if [ -n "$1" ]; then
  W=$(mktemp -d "${TMPDIR:-/tmp}/shim.XXXXXX"); trap 'rm -rf "$W"' EXIT
  dpkg-deb -x "$1" "$W"
  S=$W/usr/lib/shim; DOC=$W/usr/share/doc/shim-signed; VER=$(dpkg-deb -f "$1" Version); FROM=$(basename "$1")
else
  S=/usr/lib/shim; DOC=/usr/share/doc/shim-signed
  VER=$(dpkg-query -W -f '${Version}' shim-signed 2>/dev/null) || { echo "shim-signed is not installed: apt install shim-signed, or pass a .deb"; exit 1; }
  # the installed files must still be the package's
  dpkg --verify shim-signed 2>&1 | grep -q '/usr/lib/shim/\(shimx64.efi.signed.latest\|mmx64.efi\)$' && { echo "the installed shim files differ from the package"; exit 1; }
  FROM="installed package"
fi
[ -f "$S/shimx64.efi.signed.latest" ] && [ -f "$S/mmx64.efi" ] || { echo "no shimx64.efi.signed.latest / mmx64.efi in $S"; exit 1; }
mkdir -p "$D"
cp "$S/shimx64.efi.signed.latest" "$D/shimx64.efi"
cp "$S/mmx64.efi" "$D/mmx64.efi"
cp "$DOC/copyright" "$D/COPYRIGHT"
signer() { command -v sbverify >/dev/null 2>&1 && sbverify --list "$1" 2>/dev/null | sed -n 's/^ - subject: .*CN=\(.*\)/\1/p' | head -1; }
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
cat > "$D/SOURCE.txt" <<EOF
Ubuntu shim-signed $VER ($FROM), written by tools/fetch_shim.sh.
Source: https://launchpad.net/ubuntu/+source/shim-signed (shim: https://github.com/rhboot/shim, BSD-2-Clause, see COPYRIGHT)

shimx64.efi  = /usr/lib/shim/shimx64.efi.signed.latest  sha256 $(sum "$D/shimx64.efi")  signed by: $(signer "$D/shimx64.efi")
mmx64.efi    = /usr/lib/shim/mmx64.efi                  sha256 $(sum "$D/mmx64.efi")  signed by: $(signer "$D/mmx64.efi")
COPYRIGHT    = /usr/share/doc/shim-signed/copyright
EOF
cat "$D/SOURCE.txt"
