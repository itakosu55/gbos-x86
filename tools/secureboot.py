#!/usr/bin/env python3
"""Secure Boot for gbOS86: shim in front of a kernel signed with a key of your own (a Machine Owner Key, MOK).

The firmware trusts Microsoft's UEFI CA, which signed shim (Ubuntu's shim-signed, usb/shim/). Shim trusts the keys in its MOK list;
MokManager enrolls one from a file the first time the stick boots with Secure Boot on. This tool keeps that key on the build
machine (never in the repository), signs the kernel with it and lays out the boot files in one directory:

    BOOTX64.EFI      shim: what the firmware, a boot entry or the Windows boot menu starts
    grubx64.efi      the kernel, signed (shim's fixed name for what it starts next; there is no GRUB)
    mmx64.efi        MokManager: shim starts it when the kernel's key is not enrolled yet
    gbos86-mok.cer   the public half of the key, for MokManager's "Enroll key from disk"

  tools/secureboot.py key                  create the key if there is none; print where it is
  tools/secureboot.py check KERNEL         exit 0 if KERNEL can be signed (an EFI kernel with a .sbat section)
  tools/secureboot.py sign KERNEL OUT      sign KERNEL with the key
  tools/secureboot.py esp DIR [KERNEL]     write the four files into DIR, e.g. the stick's EFI/BOOT (KERNEL: usb/out/BOOTX64.EFI)

The key is in $GBOS_SB_KEYS (default ~/.config/gbos86/secureboot): mok.key (private), mok.crt, mok.cer. Anyone with mok.key can
sign a kernel that a laptop with this key enrolled will start: keep it private, and keep a copy (a new key means enrolling again).
sbsign/openssl run on this machine when installed (Debian/Ubuntu: apt install sbsigntool), otherwise in docker (alpine).
"""
import datetime, hashlib, os, pathlib, secrets, shlex, shutil, struct, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHIM = ROOT / 'usb/shim'
KEYS = pathlib.Path(os.environ.get('GBOS_SB_KEYS') or pathlib.Path.home() / '.config/gbos86/secureboot')
ALPINE = 'alpine:3.22'
APK = {'sbsign': 'sbsigntool', 'sbverify': 'sbsigntool', 'openssl': 'openssl'}
# Extensions of the key: a self-signed code-signing certificate (the form shim was tested with). No module-signing-only EKU
# (1.3.6.1.4.1.2312.16.1.2): shim refuses to boot images signed by such a key.
OPENSSL_CNF = """[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3
[ dn ]
CN = {cn}
[ v3 ]
basicConstraints = critical,CA:TRUE
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
"""


def die(msg):
    sys.exit(f'secureboot: {msg}')


def tool(name, *args, mounts=()):
    """Run sbsign/sbverify/openssl here, or in docker when it is not installed. Returns stdout+stderr; exits on failure.
    mounts: the directories the files are in (bound at the same path in the container)."""
    if shutil.which(name):
        cmd = [name, *args]
    elif shutil.which('docker'):
        dirs = sorted({str(pathlib.Path(m).resolve()) for m in mounts})
        vols = [x for d in dirs for x in ('-v', f'{d}:{d}')]
        # the files the tool writes would belong to root on a Linux host: hand them back to this user
        script = (f'apk add -q {APK[name]} >/dev/null && "$0" "$@"; r=$?; '
                  f'chown -R {os.getuid()}:{os.getgid()} {" ".join(shlex.quote(d) for d in dirs)} 2>/dev/null; exit $r')
        cmd = ['docker', 'run', '--rm', '-i', '--platform', 'linux/amd64', *vols, ALPINE, 'sh', '-c', script, name, *args]
    else:
        die(f"'{name}' is not installed (Debian/Ubuntu: apt install {'sbsigntool' if name != 'openssl' else 'openssl'}) and there is no docker to run it in")
    r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if r.returncode:
        die(f'{name} failed:\n{r.stdout}{r.stderr}')
    return r.stdout + r.stderr


def sections(data):
    """PE section names, or None if this is not a PE image."""
    if data[:2] != b'MZ':
        return None
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        return None
    n, = struct.unpack_from('<H', data, pe + 6)
    optsz, = struct.unpack_from('<H', data, pe + 20)
    st = pe + 24 + optsz
    out = {}
    for k in range(n):
        name, vsize, va, rsize, roff = struct.unpack_from('<8sIIII', data, st + 40 * k)
        out[name.rstrip(b'\0').decode('ascii', 'replace')] = data[roff:roff + min(vsize, rsize)]
    return out


def is_kernel(data):
    return data[0x202:0x206] == b'HdrS'


def problem(path):
    """Why the kernel at path cannot be booted through shim, or None."""
    data = pathlib.Path(path).read_bytes()
    secs = sections(data)
    if secs is None or not is_kernel(data):
        return f'{path} is not an EFI kernel image'
    sbat = secs.get('.sbat')
    if sbat is None:
        return (f'{path} has no .sbat section, and shim refuses to start a kernel without one. It was built before '
                f'CONFIG_EFI_SBAT_FILE (kernel/build_kernel.sh): build the kernel again')
    if not sbat.startswith(b'sbat,1,'):
        return f'{path}: its .sbat section does not start with an "sbat,1," line'
    return None


def key():
    """Create the key if there is none. Returns (key, crt, cer)."""
    if ROOT in KEYS.resolve().parents or KEYS.resolve() == ROOT:
        die(f'{KEYS} is inside the repository: keep the signing key outside it (the repository is public)')
    k, crt, cer = KEYS / 'mok.key', KEYS / 'mok.crt', KEYS / 'mok.cer'
    if k.exists() and crt.exists() and cer.exists():
        return k, crt, cer
    if k.exists() or crt.exists():
        die(f'{KEYS} has only part of a key (mok.key, mok.crt, mok.cer): restore it, or move it away to make a new one')
    KEYS.mkdir(parents=True, exist_ok=True)
    os.chmod(KEYS, 0o700)
    cn = f'gbOS86 kernel key {datetime.date.today().isoformat()} {secrets.token_hex(3)}'
    with tempfile.TemporaryDirectory(dir=KEYS) as t:
        t = pathlib.Path(t)
        (t / 'cnf').write_text(OPENSSL_CNF.format(cn=cn))
        tool('openssl', 'req', '-new', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '36500',
             '-config', str(t / 'cnf'), '-keyout', str(t / 'mok.key'), '-out', str(t / 'mok.crt'), mounts=[t])
        tool('openssl', 'x509', '-in', str(t / 'mok.crt'), '-outform', 'DER', '-out', str(t / 'mok.cer'), mounts=[t])
        for f in ('mok.key', 'mok.crt', 'mok.cer'):
            os.chmod(t / f, 0o600 if f == 'mok.key' else 0o644)
            os.replace(t / f, KEYS / f)
    print(f'secureboot: created a signing key "{cn}" in {KEYS}\n'
          f'  Keep mok.key private and keep a copy: a laptop that enrolled this key starts any kernel signed with it,\n'
          f'  and a new key has to be enrolled again.')
    return k, crt, cer


def fingerprint(cer):
    return hashlib.sha1(pathlib.Path(cer).read_bytes()).hexdigest()


def sign(kernel, out):
    why = problem(kernel)
    if why:
        die(why)
    k, crt, cer = key()
    out = pathlib.Path(out).resolve()
    with tempfile.TemporaryDirectory() as t:
        tmp = pathlib.Path(t) / 'signed.efi'
        src = pathlib.Path(t) / 'kernel.efi'
        shutil.copyfile(kernel, src)
        tool('sbsign', '--key', str(k), '--cert', str(crt), '--output', str(tmp), str(src), mounts=[KEYS, t])
        r = tool('sbverify', '--cert', str(crt), str(tmp), mounts=[KEYS, t])
        if 'Signature verification OK' not in r:
            die(f'the signed kernel does not verify against {crt}:\n{r}')
        put(tmp, out)


def put(src, dst):
    """Copy src to dst through dst.part (an interrupted copy never leaves a half file under the real name), then compare."""
    dst = pathlib.Path(dst)
    part = dst.with_name(dst.name + '.part')
    shutil.copyfile(src, part)
    os.replace(part, dst)
    if pathlib.Path(src).read_bytes() != dst.read_bytes():
        die(f'{dst} does not match after copying')


def esp(d, kernel):
    d = pathlib.Path(d)
    for f in ('shimx64.efi', 'mmx64.efi', 'COPYRIGHT'):
        if not (SHIM / f).exists():
            die(f'missing {SHIM / f} (tools/fetch_shim.sh)')
    why = problem(kernel)
    if why:
        die(why)
    d.mkdir(parents=True, exist_ok=True)
    k, crt, cer = key()
    # The kernel first: if anything fails, the directory still has what it had (an older stick: BOOTX64.EFI = the kernel).
    sign(kernel, d / 'grubx64.efi')
    put(SHIM / 'mmx64.efi', d / 'mmx64.efi')
    put(cer, d / 'gbos86-mok.cer')
    put(SHIM / 'COPYRIGHT', d / 'shim-COPYRIGHT.txt')
    put(SHIM / 'shimx64.efi', d / 'BOOTX64.EFI')
    print(f'secureboot: {d}: BOOTX64.EFI (shim), grubx64.efi ({pathlib.Path(kernel).name}, signed), mmx64.efi, gbos86-mok.cer\n'
          f'  key {KEYS}/mok.key, certificate SHA1 {fingerprint(cer)}')


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help'):
        print(__doc__.strip())
        return 0
    op, args = argv[1], argv[2:]
    if op == 'key' and not args:
        k, crt, cer = key()
        print(f'{k}\n{crt}\n{cer}  (certificate SHA1 {fingerprint(cer)})')
    elif op == 'check' and len(args) == 1:
        why = problem(args[0])
        if why:
            print(f'secureboot: {why}', file=sys.stderr)
            return 1
        sbat = sections(pathlib.Path(args[0]).read_bytes())['.sbat'].rstrip(b'\0').decode('ascii', 'replace').strip()
        print(f'secureboot: {args[0]} can be signed; its .sbat:\n  ' + sbat.replace('\n', '\n  '))
    elif op == 'sign' and len(args) == 2:
        sign(*args)
    elif op == 'esp' and len(args) in (1, 2):
        esp(args[0], args[1] if len(args) == 2 else ROOT / 'usb/out/BOOTX64.EFI')
    else:
        die(f'unknown command: {" ".join(argv[1:])} (see --help)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
