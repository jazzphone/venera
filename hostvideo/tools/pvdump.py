#!/usr/bin/env python3
"""pvdump: print paravirtualized-VideoToolbox messages (a 48-byte 'vtpv' header, then 'para,KEY=TYPE' fields).
   pvdump.py MSG.bin..."""
import plistlib, struct, sys

TYPES = ('pls', 'dat', 'uui', 'data', 'u32', 's32', 'u64', 's64', 'f32', 'f64', 'u16', 's16', 'u8', 's8', 'b8', 'uuid', 'str', 'cmsb',
         'cvpb', 'fmtd', 'tagc', 'surf', 'arr', 'dict')


def field(name, typ, val, ind):
    if typ == 'pls':
        try:
            v = plistlib.loads(val)
            s = repr(v)
            return s if len(s) < 600 else s[:600] + '...'
        except Exception as e:
            return f'(plist? {e}) {val[:32].hex()}'
    if typ in ('u32', 's32') and len(val) == 4:
        n = struct.unpack('>i' if typ == 's32' else '>I', val)[0]
        four = val.decode('latin1') if all(32 <= b < 127 for b in val) else ''
        return f'{n} (0x{n & 0xffffffff:x}){" " + repr(four) if four else ""}'
    if typ in ('u64', 's64') and len(val) == 8:
        return str(struct.unpack('>q' if typ == 's64' else '>Q', val)[0])
    if typ == 'f64' and len(val) == 8:
        return str(struct.unpack('>d', val)[0])
    return f'{len(val)} bytes: {val[:48].hex()}{"..." if len(val) > 48 else ""}'


def boxes(b, ind='  '):
    i = 0
    while i + 8 <= len(b):
        size = struct.unpack('>I', b[i:i + 4])[0]
        if size < 8 or i + size > len(b):
            print(f'{ind}(bad box size {size} at {i}; rest {b[i:i+32].hex()})')
            return
        body = b[i + 4:i + size]
        if body.startswith(b'para,'):
            eq = body.index(b'=')
            name = body[5:eq].decode()
            typ = None
            for t in TYPES:
                if body[eq + 1:eq + 1 + len(t)] == t.encode():
                    typ = t
                    break
            if typ is None:
                print(f'{ind}{name} = ? {body[eq+1:eq+40]!r}')
            else:
                val = body[eq + 1 + len(typ):]
                print(f'{ind}{name} ({typ}) = {field(name, typ, val, ind)}')
        else:
            print(f'{ind}box {body[:4]!r} {size} bytes: {body[4:52].hex()}')
        i += size


def dump(path):
    b = open(path, 'rb').read()
    hl, magic, typ, flags = struct.unpack('>I4s4sI', b[:16])
    uuid = b[16:32].hex()
    rest = b[32:hl]
    print(f'{path}: {len(b)} bytes, header {hl}, {magic.decode()} {typ.decode("latin1")!r} flags {flags} uuid {uuid} '
          f'tail {rest.hex()}')
    boxes(b[hl:])


for p in sys.argv[1:]:
    dump(p)
