#!/usr/bin/env python3
# vncgrab (round 17): a VM's screen as QEMU's VNC server shows it (what Proxmox's console shows: the GL display read
# back by egl-headless), frame by frame, for seeing what a gesture leaves on the screen. Runs on the Proxmox host; no
# Python packages (VNC's DES challenge goes through openssl).
#   vncgrab.py VMID SECONDS OUTDIR        frames as OUTDIR/NNNN-MS.ppm (MS: milliseconds since the start)
#   VNCGRAB_CURSOR=1 vncgrab.py ...       also the cursor as the console gets it (VNC's rich cursor: its pixels, and
#                                         the 1-bit mask QEMU makes from its alpha) as OUTDIR/cursor-NNN-MS.ppm, the
#                                         masked-out pixels drawn magenta
# It connects as Proxmox's console does: `qm vncproxy` with a one-time ticket in LC_PVE_TICKET, which becomes the VNC
# password for that connection.
import os, secrets, struct, subprocess, sys, time

vmid, secs, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
os.makedirs(out, exist_ok=True)
ticket = secrets.token_hex(4)   # 8 characters: VNC passwords are 8 bytes
p = subprocess.Popen(['qm', 'vncproxy', vmid], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     env=dict(os.environ, LC_PVE_TICKET=ticket))
r, w = p.stdout, p.stdin

def rd(n):
    b = b''
    while len(b) < n:
        c = r.read(n - len(b))
        if not c:
            raise EOFError('VNC connection closed')
        b += c
    return b

def wr(b):
    w.write(b)
    w.flush()

ver = rd(12)
wr(b'RFB 003.008\n')
n = rd(1)[0]
types = rd(n)
if 2 not in types:
    sys.exit(f'no VNC authentication offered: {list(types)}')
wr(bytes([2]))
chal = rd(16)
key = bytes(int(f'{b:08b}'[::-1], 2) for b in ticket.encode()[:8].ljust(8, b'\0'))   # VNC reverses each key byte
resp = subprocess.run(['openssl', 'enc', '-des-ecb', '-nopad', '-provider', 'legacy', '-provider', 'default',
                       '-K', key.hex()], input=chal, capture_output=True, check=True).stdout
wr(resp)
if struct.unpack('>I', rd(4))[0] != 0:
    sys.exit('VNC authentication failed')
wr(bytes([1]))   # shared
W, H = struct.unpack('>HH', rd(4))
rd(16)
rd(struct.unpack('>I', rd(4))[0])   # name
# 32-bit little-endian BGRX, raw encoding only
wr(struct.pack('>BxxxBBBBHHHBBBxxx', 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
CURSOR = os.environ.get('VNCGRAB_CURSOR') == '1'
if CURSOR:
    wr(struct.pack('>BxH ii', 2, 2, 0, -239))
else:
    wr(struct.pack('>BxH i', 2, 1, 0))
nc = 0
fb = bytearray(W * H * 4)
wr(struct.pack('>BBHHHH', 3, 0, 0, 0, W, H))
t0 = time.time()
k = 0
while time.time() - t0 < secs:
    if rd(1)[0] != 0:   # only FramebufferUpdate is asked for
        sys.exit('unexpected VNC message')
    rd(1)
    for _ in range(struct.unpack('>H', rd(2))[0]):
        x, y, rw, rh, enc = struct.unpack('>HHHHi', rd(12))
        if enc == -239:   # rich cursor: pixels (BGRX), then a 1-bit mask a row at a time; x, y the hot spot
            cpx = rd(rw * rh * 4)
            mask = rd((rw + 7) // 8 * rh)
            img = bytearray(rw * rh * 3)
            for j in range(rh):
                for i in range(rw):
                    on = mask[j * ((rw + 7) // 8) + i // 8] >> (7 - i % 8) & 1
                    q = (j * rw + i) * 4
                    img[(j * rw + i) * 3:(j * rw + i) * 3 + 3] = bytes([cpx[q + 2], cpx[q + 1], cpx[q]]) if on else b'\xff\x00\xff'
            with open(f'{out}/cursor-{nc:03d}-{int((time.time() - t0) * 1000):05d}.ppm', 'wb') as f:
                f.write(b'P6 %d %d 255\n' % (rw, rh) + img)
            print(f'cursor {nc}: {rw}x{rh}, hot spot {x},{y}')
            nc += 1
            continue
        if enc != 0:
            sys.exit(f'unexpected encoding {enc}')
        data = rd(rw * rh * 4)
        for j in range(rh):
            o = ((y + j) * W + x) * 4
            fb[o:o + rw * 4] = data[j * rw * 4:(j + 1) * rw * 4]
    ms = int((time.time() - t0) * 1000)
    with open(f'{out}/{k:04d}-{ms:05d}.ppm', 'wb') as f:
        f.write(b'P6 %d %d 255\n' % (W, H))
        px = memoryview(fb)
        rgb = bytearray(W * H * 3)
        rgb[0::3], rgb[1::3], rgb[2::3] = px[2::4], px[1::4], px[0::4]
        f.write(rgb)
    k += 1
    wr(struct.pack('>BBHHHH', 3, 1, 0, 0, W, H))
p.terminate()
print(f'{k} frames, {W}x{H}, in {out}')
