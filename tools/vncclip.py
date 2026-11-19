#!/usr/bin/env python3
# (round 18) Runs on the Proxmox host; needs no Python packages. For checking venera-clipboard: python3 vncclip.py 108 "text"
# vncclip VMID TEXT: as a VNC client of the VM (qm vncproxy, as Proxmox's console), sends TEXT as the client's
# clipboard, then prints any clipboard the VM sends for 15 s (run a copy in the VM meanwhile).
import os, secrets, struct, subprocess, sys, time, select, zlib
vmid, text = sys.argv[1], sys.argv[2]
ticket = secrets.token_hex(4)
p = subprocess.Popen(['qm', 'vncproxy', vmid], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=dict(os.environ, LC_PVE_TICKET=ticket))
r, w = p.stdout, p.stdin
def rd(n):
    b = b''
    while len(b) < n:
        c = r.read(n - len(b))
        if not c: raise EOFError
        b += c
    return b
def wr(b): w.write(b); w.flush()
rd(12); wr(b'RFB 003.008\n'); n = rd(1)[0]; rd(n); wr(bytes([2])); chal = rd(16)
key = bytes(int(f'{b:08b}'[::-1], 2) for b in ticket.encode()[:8].ljust(8, b'\0'))
wr(subprocess.run(['openssl', 'enc', '-des-ecb', '-nopad', '-provider', 'legacy', '-provider', 'default', '-K', key.hex()], input=chal, capture_output=True, check=True).stdout)
assert struct.unpack('>I', rd(4))[0] == 0
wr(bytes([1])); W, H = struct.unpack('>HH', rd(4)); rd(16); rd(struct.unpack('>I', rd(4))[0])
wr(struct.pack('>BxxxBBBBHHHBBBxxx', 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
wr(struct.pack('>BxH ii', 2, 2, 0, -1063131698))   # raw, and the extended clipboard (as noVNC)
t = text.encode('latin-1')
wr(struct.pack('>BxxxI', 6, len(t)) + t)
print('sent the client clipboard:', repr(text), flush=True)
end = time.time() + 15
fd = r.fileno()
while time.time() < end:
    if not select.select([fd], [], [], 0.5)[0]:
        continue
    t0 = rd(1)[0]
    if t0 == 3:
        rd(3); n = struct.unpack('>i', rd(4))[0]
        if n >= 0:
            print('the VM sent its clipboard:', repr(rd(n).decode('latin-1')), flush=True); continue
        body = rd(-n); flags = struct.unpack('>I', body[:4])[0]
        if flags & (1 << 27):   # NOTIFY: the VM has text: ask for it
            print('the VM says it has a new clipboard (flags 0x%x): asking' % flags, flush=True)
            wr(struct.pack('>BxxxiI', 6, -4, (1 << 25) | 1))
        elif flags & (1 << 28):   # PROVIDE
            z = zlib.decompress(body[4:]); ln = struct.unpack('>I', z[:4])[0]
            print('the VM sent its clipboard:', repr(z[4:4 + ln].decode('utf-8', 'replace')), flush=True)
    elif t0 == 0:
        rd(1)
        for _ in range(struct.unpack('>H', rd(2))[0]):
            x, y, rw, rh, enc = struct.unpack('>HHHHi', rd(12))
            rd(rw * rh * 4)
    elif t0 == 2:
        pass
    else:
        print('message', t0); break
p.terminate()
