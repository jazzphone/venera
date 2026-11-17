#!/usr/bin/env python3
"""Builds the fuzz seed corpora under fuzz/seeds/ from the message formats in venera-videod.c and (when ffmpeg + libx264
/ libx265 are on the Mac) real H.264 / HEVC streams.  Usage: gen_seeds.py [--ffmpeg]   (run on the Mac, not in Docker)"""
import os, struct, subprocess, sys, plistlib, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SEEDS = os.path.join(HERE, 'seeds')
DATA = os.path.join(HERE, '..', 'data')
UUID = bytes(range(0xA0, 0xB0))


def be(v, n):
    return v.to_bytes(n, 'big', signed=v < 0)


def header(typ, flags=1, req=1, uuid=UUID):
    return be(48, 4) + b'vtpv' + typ.encode() + be(flags, 4) + uuid + be(req, 8) + be(0, 8)


def field(name, typ, val):
    k = f'para,{name}={typ}'.encode()
    return be(4 + len(k) + len(val), 4) + k + val


def msg(typ, fields=b'', **kw):
    return header(typ, **kw) + fields


def bplist_str(s):
    return plistlib.dumps(s, fmt=plistlib.FMT_BINARY)


def box(t, body):
    return be(8 + len(body), 4) + t + body


def sample_entry(fourcc, w, h, cfg_type, cfg):
    # 78 bytes after the 8-byte header: 6 reserved, dref index, 16 predefined, w, h, 2 resolutions, reserved, frame count,
    # 32-byte compressor name, depth, predefined -1  (6+2+16+2+2+4+4+4+2+32+2+2 = 78)
    body = bytes(6) + be(1, 2) + bytes(16) + be(w, 2) + be(h, 2) + be(0x480000, 4) + be(0x480000, 4) + bytes(4) + be(1, 2) + bytes(32) + be(0x18, 2) + b'\xff\xff'
    assert len(body) == 78, len(body)
    return box(fourcc, body + box(cfg_type, cfg))


def sbuf(sample):
    return box(b'sbuf', box(b'opts', b'') + box(b'sdat', sample) + box(b'nsmp', be(1, 4)) + box(b'ssiz', be(len(sample), 4)))


def nals(annexb):
    out, i = [], 0
    starts = []
    while i + 3 <= len(annexb):
        if annexb[i:i + 3] == b'\x00\x00\x01':
            starts.append(i + 3)
            i += 3
        else:
            i += 1
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else len(annexb)
        n = annexb[s:e]
        while n.endswith(b'\x00'):
            n = n[:-1]
        out.append(n)
    return out


def avcc_from(annexb):
    sps = [n for n in nals(annexb) if n[0] & 31 == 7]
    pps = [n for n in nals(annexb) if n[0] & 31 == 8]
    c = bytes([1, sps[0][1], sps[0][2], sps[0][3], 0xFF, 0xE0 | len(sps)])
    for n in sps:
        c += be(len(n), 2) + n
    c += bytes([len(pps)])
    for n in pps:
        c += be(len(n), 2) + n
    samples, cur = [], b''
    for n in nals(annexb):
        t = n[0] & 31
        if t in (7, 8):
            continue
        cur += be(len(n), 4) + n
        if t in (1, 5):
            samples.append(cur)
            cur = b''
    return c, samples


def hvcc_from(annex):
    ns = nals(annex)
    arrays = {}
    samples, cur = [], b''
    for n in ns:
        t = (n[0] >> 1) & 63
        if t in (32, 33, 34):
            arrays.setdefault(t, []).append(n)
            continue
        cur += be(len(n), 4) + n
        if t < 32:
            samples.append(cur)
            cur = b''
    c = bytearray(23)
    c[0] = 1
    c[1] = 1       # profile idc: Main
    c[17] = 0xFC   # chroma etc, bit depth fields live at 17/18 in this code's reading
    c[17] = 0      # bitDepthLumaMinus8 (low 3 bits)
    c[21] = 3      # lengthSizeMinusOne
    c[22] = len(arrays)
    for t, lst in sorted(arrays.items()):
        c += bytes([t]) + be(len(lst), 2)
        for n in lst:
            c += be(len(n), 2) + n
    return bytes(c), samples


def w(sub, name, data):
    d = os.path.join(SEEDS, sub)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), 'wb') as f:
        f.write(data)


def op(code, data=b''):
    return bytes([code]) + be(len(data), 2) + data


def main():
    want_ffmpeg = '--ffmpeg' in sys.argv or True
    # ---- plain messages (fuzz_msg: first byte = number of surfaces) ----
    key = bplist_str('UsingHardwareAcceleratedVideoDecoder')
    msgs = {
        'dcap_hvc1': msg('dcap', field('cod', 's32', b'hvc1')),
        'dcap_avc1': msg('dcap', field('cod', 's32', b'avc1')),
        'decs': msg('decs'),
        'plusdec': msg('+dec', field('cod', 's32', b'avc1')),
        'dsta_garbage': msg('dsta', field('fds', 'fds', sample_entry(b'avc1', 64, 48, b'avcC', bytes(20)))),
        'dsup': msg('dsup'),
        'dcop_hw': msg('dcop', field('key', 'pls', key)),
        'dcop_qos': msg('dcop', field('key', 'pls', bplist_str('SuggestedQualityOfServiceTiers'))),
        'dset_rt': msg('dset', field('key', 'pls', bplist_str('RealTime')) + field('val', 'pls', plistlib.dumps(True, fmt=plistlib.FMT_BINARY))),
        'dset_dso': msg('dset', field('key', 'pls', bplist_str('DecompressionSessionOptions'))),
        'dfrm': msg('dfrm', field('frm', 's64', be(1, 8)) + field('dfl', 'u32', be(0, 4)) + field('sbf', 'sbf', sbuf(b'\x00\x00\x00\x02\x09\xf0'))),
        'dfin': msg('dfin'),
        'dinv': msg('dinv'),
        'minusdec': msg('-dec'),
        'unknown': msg('zzzz'),
        'dbuf_answer': msg('Dbuf', field('uui', 'uui', bytes(16)) + field('err', 's32', be(0, 4)), flags=8, req=101),
    }
    for n in ('apple-decs-reply.bin', 'apple-dsup-reply.bin'):
        p = os.path.join(DATA, n)
        if os.path.exists(p):
            msgs['real_' + n] = open(p, 'rb').read()
    for k, v in msgs.items():
        w('msg', k, bytes([1]) + v)
        w('msg', k + '_sess', bytes([0x41]) + v)   # bit 0x40: a session with this message's UUID exists
    # ---- bplists (bp_read_string) ----
    w('bplist', 'key_hw', key)
    w('bplist', 'key_short', bplist_str('a'))
    w('bplist', 'key_long_15', bplist_str('0123456789abcdef'))     # marker 0x5F + int object
    w('bplist', 'key_long_100', bplist_str('x' * 100))
    # ---- the crash in bp_read_string: 0x5F, int object of 8 bytes of 0xFF: len = 2^64-1, at+len wraps, len+1 == 0
    t = bytearray(bplist_str('x' * 100))
    w('bplist', 'plain_100_template', bytes(t))
    # ---- fds / sbuf / rings ----
    for typ in (b'avc1', b'hvc1', b'av01', b'vp09'):
        w('fds', typ.decode(), sample_entry(typ, 64, 48, {b'avc1': b'avcC', b'hvc1': b'hvcC', b'av01': b'av1C', b'vp09': b'vpcC'}[typ], bytes(24)))
    w('sbuf', 'one', sbuf(b'\x00\x00\x00\x02\x09\xf0'))
    # ring: head u32, tail u32, then records (struct vv_rec: len u32, kind u16, flags u16, arg[6] u32, little endian)
    def rec(kind, payload=b'', args=(0,) * 6):
        r = struct.pack('<IHH6I', len(payload), kind, 0, *args) + payload
        return r + bytes(-len(r) % 32)
    surf = struct.pack('<9I', 7, 0x34323076, 64, 48, 2, 64, 64, 0, 0)
    m = msgs['dcop_hw']
    r = rec(2, surf + m, (1, len(m)) + (0,) * 4) + rec(3, b'', (2, 0, 0, 0, 0, 0)) + rec(1, b'', (5, 0, 0, 0, 0, 0)) + rec(4, UUID)
    w('ring', 'basic', struct.pack('<II', len(r), 0) + r)
    r2 = rec(2, msgs['plusdec'], (0, len(msgs['plusdec'])) + (0,) * 4) + rec(2, msgs['dcap_hvc1'], (0, len(msgs['dcap_hvc1'])) + (0,) * 4)
    w('ring', 'two_msgs', struct.pack('<II', len(r2), 0) + r2)
    # ---- a real-stream session (fuzz_session; ops: 0 message, 1 slotdone, 2 Dbuf answer, 3 uuid gone, 4 reset, 5 pump)
    if want_ffmpeg:
        tmp = tempfile.mkdtemp()
        try:
            for codec, ext, fcc, cfgt, build, args in (
                    ('libx264', '264', b'avc1', b'avcC', avcc_from, ['-bf', '0', '-g', '6', '-bsf:v', 'h264_mp4toannexb', '-f', 'h264']),
                    ('libx265', '265', b'hvc1', b'hvcC', hvcc_from, ['-x265-params', 'log-level=none:keyint=3:bframes=0', '-f', 'hevc'])):
                out = os.path.join(tmp, 't.' + ext)
                rc = subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=size=64x48:rate=10',
                                     '-frames:v', '10', '-c:v', codec] + args + [out]).returncode
                if rc:
                    print('skipped', codec)
                    continue
                cfg, samples = build(open(out, 'rb').read())
                seq = op(0, msg('+dec', field('cod', 's32', fcc)))
                seq += op(0, msg('dsta', field('fds', 'fds', sample_entry(fcc, 64, 48, cfgt, cfg))))
                for i, s in enumerate(samples):
                    seq += op(0, msg('dfrm', field('frm', 's64', be(i + 1, 8)) + field('dfl', 'u32', be(0, 4)) + field('sbf', 'sbf', sbuf(s))))
                    seq += op(2, b'\x00') + op(2, b'\x00') + op(1, b'\x00')
                seq += op(0, msg('dfin'))
                seq += op(2, b'\x00') + op(2, b'\x01') + op(1, b'\x00') + op(1, b'\x01') + op(5)
                w('session', 'real_' + ext, seq)
                w('fds', 'real_' + ext, sample_entry(fcc, 64, 48, cfgt, cfg))
                w('sbuf', 'real_' + ext, sbuf(samples[0]))
        finally:
            pass
    print('seeds written to', SEEDS)


main()
