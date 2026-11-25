#!/usr/bin/env python3
"""Build the bramble sweetbox (xnu 1205) and write it past the HFS volume from RAM TWRP.

  python tools/sweetbox.py build USERLAND_DIR LAUNCHD_PLIST OUT.box
  python tools/sweetbox.py write OUT.box          (phone in TWRP, adb root)
  python tools/sweetbox.py check OUT.box          (read the area back and compare)

USERLAND_DIR: the userland CI artifact (wland, btd, bluetool, fastrpcd, RedwoodAudio.driver, ...).
LAUNCHD_PLIST: /System/Library/xpc/launchd.plist pulled with tools/hfs-read.py; the box carries an edited copy
(wland, btd and fastrpcd jobs; BlueTool and bluetoothd pointed at the phone/bt stand-ins).
Firmware comes from fw-bramble/ and the rmtfs images from ../backup (both stay on this PC and the phone).

Box layout (little endian), at byte 32 GiB of userdata (the HFS volume is 16 GiB, the log ring is in the
last 17 MiB): 4 KiB header "SWEETBOX" | u32 1 | u32 count | u64 seq | u64 bytes | u32 fnv1a | u32 0, then
entries u32 type (1 file, 2 dir, 3 remove) | u32 mode | u32 path len | u32 0 | u64 len | path | pad8 | data | pad8.
"""
import hashlib
import os
import plistlib
import struct
import subprocess
import sys
import time

OFF = 0x800000000
DEV = '/dev/block/sda19'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FW = os.path.join(ROOT, 'fw-bramble')
BACKUP = os.path.join(os.path.dirname(ROOT), 'backup')
ENV = dict(os.environ, MSYS_NO_PATHCONV='1')


def fnv(h, b):
    for c in b:
        h = ((h ^ c) * 16777619) & 0xffffffff
    return h


class Box:
    def __init__(self):
        self.ents = []

    def d(self, path, mode=0o755):
        self.ents.append((2, mode, path, b''))

    def f(self, path, data, mode=0o644):
        self.ents.append((1, mode, path, data))

    def rm(self, path):
        self.ents.append((3, 0, path, b''))

    def blob(self):
        body = bytearray()
        for t, mode, path, data in self.ents:
            p = path.encode()
            body += struct.pack('<IIIIQ', t, mode, len(p), 0, len(data)) + p + b'\0' * (-len(p) % 8)
            body += data + b'\0' * (-len(data) % 8)
        seq = int(time.time())
        head = b'SWEETBOX' + struct.pack('<IIQQII', 1, len(self.ents), seq, len(body), fnv(2166136261, body), 0)
        out = head + b'\0' * (4096 - len(head)) + bytes(body)
        return out + b'\0' * (-len(out) % 65536), seq


def jobs(plist):
    j = plist['LaunchDaemons']
    path = '/var/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    j['/System/Library/LaunchDaemons/org.iosonpixel.wland.plist'] = {
        'Label': 'org.iosonpixel.wland', 'ProgramArguments': ['/var/local/bin/wland', 'auto'],
        'RunAtLoad': True, 'UserName': 'root', 'EnvironmentVariables': {'PATH': path}}
    j['/System/Library/LaunchDaemons/org.iosonpixel.btd.plist'] = {
        'Label': 'org.iosonpixel.btd', 'ProgramArguments': ['/var/local/bin/btd', '--bridge'],
        'RunAtLoad': True, 'KeepAlive': True, 'UserName': 'root', 'EnvironmentVariables': {'PATH': path},
        'StandardOutPath': '/var/local/btd.log', 'StandardErrorPath': '/var/local/btd.log'}
    fr = os.path.join(ROOT, 'phone/fastrpc/org.iosonpixel.fastrpcd.plist')
    j['/System/Library/LaunchDaemons/org.iosonpixel.fastrpcd.plist'] = plistlib.load(open(fr, 'rb'))
    for k, job in j.items():
        if job.get('Label') == 'com.apple.BlueTool':
            job['ProgramArguments'] = ['/var/local/bin/bluetool', '-R']
            job.pop('Program', None)
        if job.get('Label') == 'com.apple.bluetoothd':
            job.setdefault('EnvironmentVariables', {})['BT_HCI_TRANSPORT'] = 'H4BC:POSIX:com.apple.uart.bluetooth,3000000'
    return plist


def build(udir, launchd, out):
    b = Box()
    L = '/private/var/local'
    for d in (L, L + '/bin', L + '/fw', L + '/fw/modem', L + '/fw/rw', L + '/fw/rmtfs'):
        b.d(d)
    # launchd.plist first: the earlier it lands, the likelier this boot's launchd already reads it
    pl = jobs(plistlib.load(open(launchd, 'rb')))
    b.f('/System/Library/xpc/launchd.plist', plistlib.dumps(pl, fmt=plistlib.FMT_BINARY), 0o644)
    b.rm('/private/var/preferences/SystemConfiguration/preferences.plist')  # configd writes one with en0
    for n in ('wland', 'netsvc', 'btd', 'bluetool', 'fastrpcd', 'sensd', 'toybox', 'psx', 'oslog', 'lsreg'):
        p = os.path.join(udir, n)
        if os.path.isfile(p):
            b.f(f'{L}/bin/{n}', open(p, 'rb').read(), 0o755)
        elif n in ('wland', 'btd', 'bluetool', 'fastrpcd'):
            sys.exit(f'missing {p}')
    drv = os.path.join(udir, 'RedwoodAudio.driver')
    H = '/System/Library/Audio/Plug-Ins/HAL'
    for d in ('/System/Library/Audio', '/System/Library/Audio/Plug-Ins', H, H + '/RedwoodAudio.driver'):
        b.d(d)
    for rel in ('Info.plist', 'RedwoodAudio', '_CodeSignature/CodeResources'):
        p = os.path.join(drv, rel)
        if os.path.isfile(p):
            if rel.startswith('_'):
                b.d(H + '/RedwoodAudio.driver/_CodeSignature')
            b.f(f'{H}/RedwoodAudio.driver/{rel}', open(p, 'rb').read(), 0o755 if rel == 'RedwoodAudio' else 0o644)
        elif rel != '_CodeSignature/CodeResources':
            sys.exit(f'missing {p}')
    for n in sorted(os.listdir(FW)):
        p = os.path.join(FW, n)
        if os.path.isfile(p) and not n.startswith(('a6', 'a620')):
            b.f(f'{L}/fw/{n}', open(p, 'rb').read())
    for n in sorted(os.listdir(os.path.join(FW, 'modem'))):
        data = open(os.path.join(FW, 'modem', n), 'rb').read()
        b.f(f'{L}/fw/modem/{n}', data)
        if n in ('bdwlan-bramble.bin', 'bdwlan-u-bramble.bin'):   # wlfw.c loads the redfin names
            b.f(f'{L}/fw/modem/{n.replace("bramble", "redfin")}', data)
    for n in ('modemst1', 'modemst2', 'fsg', 'fsc'):
        b.f(f'{L}/fw/rmtfs/{n}.img', open(os.path.join(BACKUP, n + '.img'), 'rb').read(), 0o600)
    blob, seq = b.blob()
    open(out, 'wb').write(blob)
    print(f'{out}: seq {seq}, {len(b.ents)} entries, {len(blob) >> 20} MiB, sha256 {hashlib.sha256(blob).hexdigest()[:16]}')


def build_hexagon(src, out):
    """Second box: fastrpcd's tree /private/var/local/hexagon (as tools/redfin-install-hexagon-wsl.sh stages it)
    from SRC/vendor.tar (dsp, lib/rfsa, etc/acdbdata, etc/sensors of bramble's vendor), SRC/persist.tar
    (sensors/ of the persist partition) and SRC/soc0.txt (name=value of /sys/devices/soc0)."""
    import tarfile
    H = '/private/var/local/hexagon'
    files = {}
    with tarfile.open(os.path.join(src, 'vendor.tar')) as t:
        for m in t:
            parts = [p for p in m.name.split('/') if p not in ('', '.')]
            if not m.isreg() or '..' in parts:
                continue
            data = t.extractfile(m).read()
            files['vendor/' + '/'.join(parts)] = data
            if parts[:2] == ['dsp', 'adsp']:
                files['usr/lib/qcom/adsp/' + '/'.join(parts[2:])] = data
    with tarfile.open(os.path.join(src, 'persist.tar')) as t:
        for m in t:
            parts = [p for p in m.name.split('/') if p not in ('', '.')]
            if m.isreg() and '..' not in parts and parts[:1] == ['sensors']:
                files['persist/' + '/'.join(parts)] = t.extractfile(m).read()
    for line in open(os.path.join(src, 'soc0.txt'), encoding='utf-8'):
        k, _, v = line.rstrip('\n').partition('=')
        if k and '/' not in k:
            files['sys/devices/soc0/' + k] = (v + '\n').encode()
    b = Box()
    dirs = {'/private/var/local', H}
    for rel in files:
        p = rel.split('/')[:-1]
        for i in range(1, len(p) + 1):
            dirs.add(H + '/' + '/'.join(p[:i]))
    for d in sorted(dirs, key=lambda x: (x.count('/'), x)):
        b.d(d)
    for rel in sorted(files):
        b.f(f'{H}/{rel}', files[rel])
    blob, seq = b.blob()
    open(out, 'wb').write(blob)
    print(f'{out}: seq {seq}, {len(files)} files, {len(dirs)} dirs, {len(blob) >> 20} MiB')


def write(box):
    data = open(box, 'rb').read()
    size = int(subprocess.run(['adb', 'shell', f'blockdev --getsize64 {DEV}'], capture_output=True, env=ENV,
                              stdin=subprocess.DEVNULL, check=True).stdout.strip())
    hdr = subprocess.run(['adb', 'exec-out', f'dd if={DEV} bs=512 skip=2 count=1 2>/dev/null'], capture_output=True,
                         env=ENV, stdin=subprocess.DEVNULL, check=True).stdout
    vol = struct.unpack('>I', hdr[40:44])[0] * struct.unpack('>I', hdr[44:48])[0]
    if hdr[:2] not in (b'H+', b'HX') or vol > OFF or OFF + len(data) > size - (32 << 20):
        sys.exit(f'refused: volume {vol >> 30} GiB, partition {size >> 30} GiB, box {len(data) >> 20} MiB at 32 GiB')
    # adb exec-in from Windows delivered nothing to dd (2026-11-25): push to TWRP's RAM /tmp, then dd from there
    subprocess.run(['adb', 'push', box, '/tmp/sweetbox.bin'], env=ENV, stdin=subprocess.DEVNULL, check=True)
    r = subprocess.run(['adb', 'shell', f'dd if=/tmp/sweetbox.bin of={DEV} bs=65536 seek={OFF // 65536} '
                        f'conv=notrunc && sync; rm -f /tmp/sweetbox.bin'], env=ENV, stdin=subprocess.DEVNULL)
    if r.returncode:
        sys.exit('dd on the phone failed')
    check(box)


def check(box):
    data = open(box, 'rb').read()
    cmd = f'dd if={DEV} bs=65536 skip={OFF // 65536} count={len(data) // 65536} 2>/dev/null | sha256sum'
    got = subprocess.run(['adb', 'shell', cmd], capture_output=True, env=ENV, stdin=subprocess.DEVNULL,
                         check=True).stdout.split()[0].decode()
    want = hashlib.sha256(data).hexdigest()
    print('box on the phone', 'matches' if got == want else f'DIFFERS ({got[:16]} vs {want[:16]})')
    if got != want:
        sys.exit(1)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['build'] and len(a) == 4:
        build(*a[1:])
    elif a[:1] == ['hexagon'] and len(a) == 3:
        build_hexagon(*a[1:])
    elif a[:1] == ['write'] and len(a) == 2:
        write(a[1])
    elif a[:1] == ['check'] and len(a) == 2:
        check(a[1])
    else:
        sys.exit(__doc__)
