#!/usr/bin/env python3
"""run_secureboot_qemu.py [KERNEL] -- Secure Boot test of the shim + own-key boot (tools/secureboot.py), in QEMU/OVMF.

OVMF with Secure Boot on and Microsoft's keys enrolled (Debian/Ubuntu: apt install ovmf; or set OVMF_CODE / OVMF_VARS), shim from
usb/shim/, a throwaway signing key (GBOS_SB_KEYS in a temporary directory: the real key is never touched). KERNEL defaults to
usb/out/BOOTX64.EFI. A kernel built before CONFIG_EFI_SBAT_FILE gets a test-only .sbat section added here (said in the output), so
the boot chain can be tested before the kernel is rebuilt; tools/secureboot.py itself refuses such a kernel.

  1. stick layout (tools/secureboot.py esp -> EFI/BOOT on a virtual FAT disk), key enrolled in the MOK list: the kernel starts
     (a CPU runs kernel code: RIP in 0xffff8000_00000000 and up)
  2. the same disk, key not enrolled: shim refuses the kernel (no kernel code within the wait)
  3. key enrolled, the kernel signed but without .sbat: shim refuses it
  4. QEMU's -shim path (shim and the signed kernel from fw_cfg, -append console=ttyS0): the kernel reports Secure Boot on and
     stage0 runs
The key is enrolled by writing the MokList variable into the firmware's variable store, as MokManager does after "Enroll key from
disk" (that screen itself is shim's and is not driven here). Prints SECUREBOOT_QEMU_PASS.
"""
import json, os, pathlib, shutil, socket, struct, subprocess, sys, tempfile, time, uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import secureboot  # noqa: E402

OVMF_CANDIDATES = [('/usr/share/OVMF/OVMF_CODE_4M.secboot.fd', '/usr/share/OVMF/OVMF_VARS_4M.ms.fd'),
                   ('/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd', '/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd')]
SHIM_LOCK = uuid.UUID('605dab50-e046-4300-abb6-3dd810dd8b23')
CERT_X509 = uuid.UUID('a5c059a1-94e4-4aa7-87b5-ab155c2bf072')
AUTH_STORE = uuid.UUID('aaf32c78-947b-439a-a180-2e144ec37792')
KVM = os.access('/dev/kvm', os.R_OK | os.W_OK)
SLOW = 1 if KVM else 4
FAIL = []


def check(ok, what):
    print(('PASS ' if ok else 'FAIL ') + what, flush=True)
    if not ok:
        FAIL.append(what)


def add_test_sbat(src, dst):
    """Add a .sbat section the way CONFIG_EFI_SBAT does: a 4th section header in the free (0xff) slot after the section table
    (arch/x86/boot/setup.ld leaves it), the data at the end of the file. Test kernels only."""
    d = bytearray(pathlib.Path(src).read_bytes())
    data = (ROOT / 'kernel/sbat.csv').read_bytes()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    n, = struct.unpack_from('<H', d, pe + 6)
    optsz, = struct.unpack_from('<H', d, pe + 20)
    o = pe + 24
    salign, falign = struct.unpack_from('<II', d, o + 32)
    st = o + optsz
    new = st + 40 * n
    assert set(d[new:new + 40]) == {0xff} and new + 40 <= 0x1ef, 'no free section header slot in this kernel'
    up = lambda x, a: (x + a - 1) // a * a
    va = up(max(sum(struct.unpack_from('<II', d, st + 40 * k + 8)) for k in range(n)), salign)
    off = up(len(d), falign)
    d += b'\0' * (off - len(d))
    d[new:new + 40] = struct.pack('<8sIIIIIIHHI', b'.sbat', len(data), va, up(len(data), falign), off, 0, 0, 0, 0, 0x40000040)
    struct.pack_into('<H', d, pe + 6, n + 1)
    struct.pack_into('<I', d, o + 56, up(va + len(data), salign))
    d += data + b'\0' * (up(len(data), falign) - len(data))
    pathlib.Path(dst).write_bytes(d)


def enroll_mok(src, dst, cer):
    """Copy the OVMF variable store src to dst with MokList (NV+BS, shim's GUID) = one X.509 certificate."""
    b = bytearray(pathlib.Path(src).read_bytes())
    assert b[0x28:0x2c] == b'_FVH', 'not a firmware volume'
    vs, = struct.unpack_from('<H', b, 0x30)
    assert uuid.UUID(bytes_le=bytes(b[vs:vs + 16])) == AUTH_STORE, 'not an authenticated variable store'
    size, = struct.unpack_from('<I', b, vs + 16)
    off = vs + 28
    while struct.unpack_from('<H', b, off)[0] == 0x55aa:   # AUTHENTICATED_VARIABLE_HEADER (60 bytes); name, data unpadded
        ns, ds = struct.unpack_from('<II', b, off + 36)
        off += 60 + ns + ds
        off += -off % 4
    der = pathlib.Path(cer).read_bytes()
    esl = struct.pack('<16sIII', CERT_X509.bytes_le, 28 + 16 + len(der), 0, 16 + len(der)) + SHIM_LOCK.bytes_le + der
    name = 'MokList\0'.encode('utf-16le')
    var = struct.pack('<HBBIQ16sIII16s', 0x55aa, 0x3f, 0, 0x3, 0, b'\0' * 16, 0, len(name), len(esl), SHIM_LOCK.bytes_le) + name + esl
    assert set(b[off:off + len(var)]) == {0xff} and off + len(var) <= vs + size, 'no room in the variable store'
    b[off:off + len(var)] = var
    pathlib.Path(dst).write_bytes(b)


class Qemu:
    def __init__(self, work, name, code, vars_, extra):
        self.work, self.name = work, name
        v = work / f'{name}.vars'
        shutil.copyfile(vars_, v)
        self.serial = work / f'{name}.serial'
        cmd = ['qemu-system-x86_64', '-machine', 'q35,smm=on' + (',accel=kvm' if KVM else ''), '-cpu', 'host' if KVM else 'max',
               '-m', '2048', '-smp', '2', '-global', 'driver=cfi.pflash01,property=secure,value=on', '-global', 'ICH9-LPC.disable_s3=1',
               '-drive', f'if=pflash,format=raw,unit=0,readonly=on,file={code}', '-drive', f'if=pflash,format=raw,unit=1,file={v}',
               '-nic', 'none', '-vga', 'std', '-display', 'none', '-serial', f'file:{self.serial}',
               '-qmp', f'unix:{name}.qmp,server=on,wait=off', *extra]
        self.p = subprocess.Popen(cmd, cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(50):
            if (work / f'{name}.qmp').exists():
                break
            time.sleep(0.1)

    def qmp(self, cmd, args=None):
        s = socket.socket(socket.AF_UNIX)
        cwd = os.getcwd()
        os.chdir(self.work)       # the socket path relative to work: an absolute one can exceed the 108-byte limit
        try:
            s.connect(f'{self.name}.qmp')
        finally:
            os.chdir(cwd)
        f = s.makefile('rw')
        f.readline()
        r = None
        for c in ({'execute': 'qmp_capabilities'}, {'execute': cmd, **({'arguments': args} if args else {})}):
            f.write(json.dumps(c) + '\n'); f.flush()
            while True:
                r = json.loads(f.readline())
                if 'return' in r or 'error' in r:
                    break
        s.close()
        return r.get('return', '')

    def hmp(self, line):
        return self.qmp('human-monitor-command', {'command-line': line})

    def in_kernel(self):
        regs = self.hmp('info registers -a')
        return any(int(x.split()[0], 16) >= 0xffff800000000000 for x in regs.split('RIP=')[1:])

    def wait_kernel(self, seconds):
        end = time.time() + seconds * SLOW
        while time.time() < end:
            if self.p.poll() is not None:
                return False
            if self.in_kernel():
                return True
            time.sleep(1)
        return False

    def wait_serial(self, needles, seconds):
        end = time.time() + seconds * SLOW
        while time.time() < end and self.p.poll() is None:
            t = self.serial.read_text(errors='replace') if self.serial.exists() else ''
            if all(n in t for n in needles):
                return t
            time.sleep(1)
        return self.serial.read_text(errors='replace') if self.serial.exists() else ''

    def stop(self, shot=None):
        if shot and self.p.poll() is None:
            try:
                self.qmp('screendump', {'filename': shot, 'format': 'png'})
            except OSError:
                pass
        self.p.kill(); self.p.wait()
        err = self.p.stderr.read().decode(errors='replace').strip()
        if err:
            print('  qemu: ' + err.replace('\n', '\n  qemu: '))


def main():
    kernel = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / 'usb/out/BOOTX64.EFI').resolve()
    code, vars_ = os.environ.get('OVMF_CODE'), os.environ.get('OVMF_VARS')
    if not (code and vars_):
        code, vars_ = next(((c, v) for c, v in OVMF_CANDIDATES if os.path.exists(c) and os.path.exists(v)), (None, None))
    if not code:
        sys.exit('no Secure Boot OVMF (OVMF_CODE_4M.secboot.fd + OVMF_VARS_4M.ms.fd): apt install ovmf, or set OVMF_CODE/OVMF_VARS')
    print(f'kernel {kernel}\nfirmware {code} + {vars_}{"" if KVM else " (no KVM: TCG, slower)"}')
    work = pathlib.Path(tempfile.mkdtemp(prefix='sbtest.'))
    os.environ['GBOS_SB_KEYS'] = str(work / 'keys')
    secureboot.KEYS = work / 'keys'
    try:
        k = kernel
        if secureboot.problem(kernel) and '.sbat' in secureboot.problem(kernel):
            k = work / 'kernel-sbat.efi'
            add_test_sbat(kernel, k)
            print('NOTE: this kernel has no .sbat section (built before CONFIG_EFI_SBAT_FILE); testing a copy with a test-only .sbat\n'
                  '      added. tools/secureboot.py refuses the kernel itself until it is rebuilt.')
        esp = work / 'esp'
        r = subprocess.run([sys.executable, str(ROOT / 'tools/secureboot.py'), 'esp', str(esp / 'EFI/BOOT'), str(k)],
                           capture_output=True, text=True)
        print('  ' + (r.stdout + r.stderr).strip().replace('\n', '\n  '))
        check(r.returncode == 0, 'tools/secureboot.py esp wrote the boot files')
        if r.returncode:
            return
        names = sorted(p.name for p in (esp / 'EFI/BOOT').iterdir())
        check(names == ['BOOTX64.EFI', 'gbos86-mok.cer', 'grubx64.efi', 'mmx64.efi', 'shim-COPYRIGHT.txt'], f'EFI/BOOT holds {names}')
        check((esp / 'EFI/BOOT/BOOTX64.EFI').read_bytes() == (ROOT / 'usb/shim/shimx64.efi').read_bytes(), 'BOOTX64.EFI is shim')
        cer = esp / 'EFI/BOOT/gbos86-mok.cer'
        enrolled = work / 'mok-enrolled.vars'
        enroll_mok(vars_, enrolled, cer)
        disk = lambda d: ['-drive', f'file=fat:{d},format=raw,if=none,id=esp,readonly=on', '-device', 'virtio-blk-pci,drive=esp,bootindex=1']

        q = Qemu(work, 'enrolled', code, enrolled, disk(esp))
        ok = q.wait_kernel(90)
        q.stop(None if ok else str(pathlib.Path('last-secureboot-1.png').resolve()))
        check(ok, '1. firmware -> shim -> signed kernel (key enrolled): the kernel runs')

        q = Qemu(work, 'notenrolled', code, vars_, disk(esp))
        ok = not q.wait_kernel(40)
        q.stop(str(pathlib.Path('last-secureboot-2.png').resolve()))
        check(ok, '2. key not enrolled: shim does not start the kernel (screen: last-secureboot-2.png)')

        nosbat = work / 'esp-nosbat'
        shutil.copytree(esp, nosbat)
        src = kernel if not secureboot.sections(kernel.read_bytes()).get('.sbat') else None
        if src:
            k2, crt, _ = secureboot.key()
            secureboot.tool('sbsign', '--key', str(k2), '--cert', str(crt), '--output', str(nosbat / 'EFI/BOOT/grubx64.efi'), str(src),
                            mounts=[work])
            q = Qemu(work, 'nosbat', code, enrolled, disk(nosbat))
            ok = not q.wait_kernel(40)
            q.stop(str(pathlib.Path('last-secureboot-3.png').resolve()))
            check(ok, '3. key enrolled, kernel without .sbat: shim does not start it (screen: last-secureboot-3.png)')
        else:
            print('SKIP 3. (this kernel has its own .sbat; no kernel without one to test)')

        q = Qemu(work, 'fwcfg', code, enrolled, ['-shim', str(ROOT / 'usb/shim/shimx64.efi'), '-kernel', str(esp / 'EFI/BOOT/grubx64.efi'),
                                                  '-append', 'console=ttyS0'])
        t = q.wait_serial(['Secure boot enabled', 'gbos-stage0: === gbOS86 boot'], 90)
        q.stop()
        check('Secure boot enabled' in t, '4. -shim path: the kernel reports "Secure boot enabled"')
        check('gbos-stage0: === gbOS86 boot' in t, '4. -shim path: stage0 runs')
        print('  ' + ' | '.join(l.strip() for l in t.splitlines() if 'Secure boot' in l or 'secureboot' in l)[:300])
        lock = [l for l in t.splitlines() if 'lockdown' in l.lower()]
        print('  lockdown lines: ' + (' | '.join(lock) if lock else 'none (CONFIG_SECURITY_LOCKDOWN_LSM is off)'))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print('SECUREBOOT_QEMU_FAIL: ' + '; '.join(FAIL) if FAIL else 'SECUREBOOT_QEMU_PASS')
    sys.exit(1 if FAIL else 0)


if __name__ == '__main__':
    main()
