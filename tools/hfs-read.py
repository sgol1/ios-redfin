#!/usr/bin/env python3
"""Read-only HFS+/HFSX reader for the iOS root on the phone's userdata, through RAM TWRP (adb root).

  python tools/hfs-read.py get /System/Library/xpc/launchd.plist OUT
  python tools/hfs-read.py ls /private/var/local

Only reads: every block comes from `adb exec-out dd if=/dev/block/sda19` (no write path exists here).
TWRP's kernel has no hfsplus, and Windows has no CDC-ECM driver for the phone's USB network, so this is
how the PC reads files from the root; writes go through the sweetbox (tools/sweetbox.py, xnu 1205).
Plain data forks only (no decmpfs): the root is built by Linux hfsplus, which writes no compressed files.
"""
import os
import struct
import subprocess
import sys

DEV = os.environ.get('HFS_DEV', '/dev/block/sda19')
ADB = os.environ.get('ADB', 'adb')
_cache = {}


def raw(off, n):
    """n bytes at byte offset off of the partition, read in 64 KiB pieces (cached)."""
    out = b''
    while n > 0:
        base = off & ~0xffff
        if base not in _cache:
            env = dict(os.environ, MSYS_NO_PATHCONV='1')
            data = subprocess.run([ADB, 'exec-out', f'dd if={DEV} bs=65536 skip={base // 65536} count=1 2>/dev/null'],
                                  stdin=subprocess.DEVNULL, capture_output=True, env=env, check=True).stdout
            if len(data) != 65536:
                sys.exit(f'short read at {base}: {len(data)}')
            _cache[base] = data
        k = off - base
        take = min(n, 65536 - k)
        out += _cache[base][k:k + take]
        off += take
        n -= take
    return out


class Vol:
    def __init__(self):
        h = raw(1024, 512)
        if h[:2] not in (b'H+', b'HX'):
            sys.exit(f'no HFS+ volume header ({h[:2]!r})')
        self.bs = struct.unpack('>I', h[40:44])[0]
        self.cat = self.fork(h[272:352])
        node0 = self.read_fork(self.cat, 0, 512)
        (self.depth, self.root, _, _, _, self.nsize) = struct.unpack('>HIIIIH', node0[14:14 + 20])

    @staticmethod
    def fork(b):
        size = struct.unpack('>Q', b[0:8])[0]
        ext = [struct.unpack('>II', b[16 + 8 * i:24 + 8 * i]) for i in range(8)]
        return size, [e for e in ext if e[1]]

    def read_fork(self, fork, off, n):
        size, ext = fork
        n = min(n, size - off)
        out = b''
        pos = 0
        for start, count in ext:
            elen = count * self.bs
            if off < pos + elen and n > len(out):
                k = max(0, off - pos)
                take = min(elen - k, n - len(out))
                out += raw(start * self.bs + k, take)
            pos += elen
        if len(out) != n:
            sys.exit('fork needs the extents overflow file (not supported)')
        return out

    def node(self, i):
        return self.read_fork(self.cat, i * self.nsize, self.nsize)

    def records(self, nd):
        n = struct.unpack('>H', nd[10:12])[0]
        offs = [struct.unpack('>H', nd[self.nsize - 2 * (j + 1):self.nsize - 2 * j])[0] for j in range(n + 1)]
        return nd[8], [nd[offs[j]:offs[j + 1]] for j in range(n)]

    @staticmethod
    def key(rec):
        klen = struct.unpack('>H', rec[0:2])[0]
        parent = struct.unpack('>I', rec[2:6])[0]
        nlen = struct.unpack('>H', rec[6:8])[0]
        return (parent, rec[8:8 + 2 * nlen]), rec[2 + klen:]

    def lookup(self, parent, name):
        want = (parent, name.encode('utf-16-be'))
        i = self.root
        while True:
            kind, recs = self.records(self.node(i))
            if kind == 0xff:  # leaf (kBTLeafNode = -1)
                for r in recs:
                    k, body = self.key(r)
                    if k == want:
                        return body
                return None
            child = None
            for r in recs:
                k, body = self.key(r)
                if k <= want:
                    child = struct.unpack('>I', body[:4])[0]
                else:
                    break
            if child is None:
                return None
            i = child

    def resolve(self, path):
        cnid, body = 2, None
        for part in [p for p in path.split('/') if p]:
            body = self.lookup(cnid, part)
            if body is None:
                sys.exit(f'not found: {path} (at {part})')
            rtype = struct.unpack('>h', body[0:2])[0]
            cnid = struct.unpack('>I', body[8:12])[0]
            if rtype not in (1, 2):
                sys.exit(f'{part}: record type {rtype}')
        return cnid, body

    def listdir(self, cnid):
        """Leaf records whose parent is cnid (walks leaves from the first one >= (cnid, ''))."""
        i = self.root
        while True:
            kind, recs = self.records(self.node(i))
            if kind == 0xff:
                break
            child = struct.unpack('>I', self.key(recs[0])[1][:4])[0]
            for r in recs:
                k, body = self.key(r)
                if k < (cnid, b'') or k == (cnid, b''):
                    child = struct.unpack('>I', body[:4])[0]
            i = child
        names = []
        while i:
            nd = self.node(i)
            for r in self.records(nd)[1]:
                k, body = self.key(r)
                if k[0] == cnid and struct.unpack('>h', body[0:2])[0] in (1, 2):
                    names.append((k[1].decode('utf-16-be'), struct.unpack('>h', body[0:2])[0]))
                elif k[0] > cnid:
                    return names
            i = struct.unpack('>I', nd[0:4])[0]
        return names


def main(a):
    v = Vol()
    if a[0] == 'get':
        _, body = v.resolve(a[1])
        if struct.unpack('>h', body[0:2])[0] != 2:
            sys.exit('not a file')
        mode = struct.unpack('>H', body[42:44])[0]
        fork = v.fork(body[88:168])
        data = v.read_fork(fork, 0, fork[0])
        open(a[2], 'wb').write(data)
        print(f'{a[1]}: {len(data)} bytes, mode {mode:o}, uid {struct.unpack(">I", body[32:36])[0]}')
    elif a[0] == 'ls':
        cnid, _ = v.resolve(a[1]) if a[1] != '/' else (2, None)
        for name, t in v.listdir(cnid):
            print(('d ' if t == 1 else '- ') + name)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:] or ['help'])
