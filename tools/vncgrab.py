#!/usr/bin/env python3
# vncgrab (round 17): a VM's screen as QEMU's VNC server shows it (what Proxmox's console shows: the GL display read
# back by egl-headless), frame by frame, for seeing what a gesture leaves on the screen. Runs on the Proxmox host; no
# Python packages (VNC's DES challenge goes through openssl).
#   vncgrab.py VMID SECONDS OUTDIR        frames as OUTDIR/NNNN-MS.ppm (MS: milliseconds since the start)
#   vncgrab.py VMID SECONDS --timings     JSON timing summary, no image conversion or file writes
#   VNCGRAB_CURSOR=1 vncgrab.py ...       also the cursor as the console gets it (VNC's rich cursor: its pixels, and
#                                         the 1-bit mask QEMU makes from its alpha) as OUTDIR/cursor-NNN-MS.ppm, the
#                                         masked-out pixels drawn magenta
# It connects as Proxmox's console does: `qm vncproxy` with a one-time ticket in LC_PVE_TICKET, which becomes the VNC
# password for that connection.
import argparse
import json
import math
import os
import secrets
import select
import statistics
import struct
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description="Capture or time updates from a Proxmox VM's VNC server.")
parser.add_argument("vmid")
parser.add_argument("seconds", type=float)
parser.add_argument("outdir", nargs="?")
parser.add_argument("--timings", action="store_true", help="report raw update timings instead of writing PPM images")
args = parser.parse_args()
if not math.isfinite(args.seconds) or args.seconds <= 0:
    parser.error("seconds must be finite and positive")
if args.timings == (args.outdir is not None):
    parser.error("provide either OUTDIR or --timings")
if args.outdir:
    os.makedirs(args.outdir, exist_ok=True)
ticket = secrets.token_hex(4)   # 8 characters: VNC passwords are 8 bytes
p = subprocess.Popen(['qm', 'vncproxy', args.vmid], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     bufsize=0 if args.timings else -1, env=dict(os.environ, LC_PVE_TICKET=ticket))
r, w = p.stdout, p.stdin
deadline = None


def read_chunk(n):
    if deadline is not None:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([r], [], [], remaining)[0]:
            raise TimeoutError
    chunk = r.read(n)
    if not chunk:
        raise EOFError("VNC connection closed")
    return chunk


def rd(n):
    data = bytearray()
    while len(data) < n:
        data.extend(read_chunk(n - len(data)))
    return data


def skip(n):
    while n:
        n -= len(read_chunk(min(n, 65536)))


def wr(b):
    w.write(b)
    w.flush()

def summarize_ms(samples):
    if not samples:
        return None
    ordered = sorted(samples)
    return {
        "median": round(statistics.median(ordered), 2),
        "p95": round(ordered[math.ceil(0.95 * len(ordered)) - 1], 2),
        "max": round(ordered[-1], 2),
    }


def measure_updates(width, height):
    global deadline
    start = time.monotonic()
    deadline = start + args.seconds
    first_update_ms = None
    ends, receive_ms = [], []
    pixels = 0
    wr(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))
    try:
        while True:
            if rd(1)[0] != 0:
                sys.exit("unexpected VNC message")
            began = time.monotonic()
            _, count = struct.unpack(">BH", rd(3))
            received = 0
            for _ in range(count):
                _, _, rect_width, rect_height, encoding = struct.unpack(">HHHHi", rd(12))
                if encoding != 0:
                    sys.exit(f"unexpected encoding {encoding}")
                size = rect_width * rect_height * 4
                skip(size)
                received += size
            finished = time.monotonic()
            if first_update_ms is None:
                first_update_ms = round((finished - start) * 1000, 2)
            else:
                ends.append(finished)
                receive_ms.append((finished - began) * 1000)
                pixels += received
            wr(struct.pack(">BBHHHH", 3, 1, 0, 0, width, height))
    except TimeoutError:
        pass
    finally:
        p.terminate()
        p.wait()
    gaps_ms = [(after - before) * 1000 for before, after in zip(ends, ends[1:])]
    print(json.dumps({
        "width": width,
        "height": height,
        "duration_s": args.seconds,
        "first_full_update_ms": first_update_ms,
        "incremental_updates": len(ends),
        "incremental_updates_per_s": round(1000 / statistics.mean(gaps_ms), 2) if gaps_ms else None,
        "update_gap_ms": summarize_ms(gaps_ms),
        "receive_ms": summarize_ms(receive_ms),
        "raw_pixel_bytes": pixels,
    }))


rd(12)
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
CURSOR = not args.timings and os.environ.get('VNCGRAB_CURSOR') == '1'
if CURSOR:
    wr(struct.pack('>BxH ii', 2, 2, 0, -239))
else:
    wr(struct.pack('>BxH i', 2, 1, 0))
if args.timings:
    measure_updates(W, H)
    sys.exit(0)

out = args.outdir
nc = 0
fb = bytearray(W * H * 4)
wr(struct.pack('>BBHHHH', 3, 0, 0, 0, W, H))
t0 = time.time()
k = 0
while time.time() - t0 < args.seconds:
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
