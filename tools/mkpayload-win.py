"""Run tools/mkpayload.py on Windows: replace its `nm` call with a pure-Python Mach-O symbol table read.

    python -I tools/mkpayload-win.py REPO_TOOLS_DIR <mkpayload.py args...>
"""
import runpy
import struct
import sys

LC_SYMTAB = 0x2


def macho_symbols(path, *names):
    d = open(path, 'rb').read()
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<8I', d, 0)
    assert magic == 0xfeedfacf, 'not a 64-bit Mach-O'
    off = 32
    found = dict.fromkeys(names, 0)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<2I', d, off)
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, _ = struct.unpack_from('<4I', d, off + 8)
            for i in range(nsyms):
                strx, ntype, _, _, value = struct.unpack_from('<IBBHQ', d, symoff + 16 * i)
                end = d.index(b'\0', stroff + strx)
                name = d[stroff + strx:end].decode('latin-1')
                if name in found and (ntype & 0x0e) != 0:  # defined (not N_UNDF)
                    found[name] = value
        off += size
    return [found[n] for n in names]


tools = sys.argv[1]
sys.path.insert(0, tools)
src = open(tools + '/mkpayload.py', encoding='utf-8').read()
g = {'__name__': 'mkpayload_lib', '__file__': tools + '/mkpayload.py'}
exec(compile(src, tools + '/mkpayload.py', 'exec'), g)   # defines build() etc., skips its __main__ block
g['kernel_symbols'] = macho_symbols                    # build() looks it up in this namespace
sys.argv = [tools + '/mkpayload.py'] + sys.argv[2:]
main = src[src.index("if __name__ == '__main__':"):].split('\n', 1)[1]
exec(compile('if True:\n' + main, 'mkpayload-main', 'exec'), g)
