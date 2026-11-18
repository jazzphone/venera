// vv_encode.h (Venera video, 0.1.2): hardware encoding for the guest's VideoToolbox. Included by venera-videod.c after
// its decode engine; uses its message helpers, slots and VA-API device.
//
// Apple's paravirtualized encoder, as this host answers it (learned from Apple's own host session on a Mac and the
// guest's code; notes/PLAN.md, round 14):
//   encs           -> the encoders (H.264, HEVC: the ones the GPU's VA-API driver encodes)
//   +enc cod cid   -> err 0, ver, hin
//   esta vdi       -> Epba (a request: the pixel buffers the guest should make), then err 0
//   esup           -> err 0, sup (the properties this encoder takes)
//   epfr           -> err 0
//   efrm frm pts dur uui (+ the frame's IOSurface): the frame is pulled from the guest's IOSurface into a slot
//                     (VV_H_PULL / VV_G_PULLDONE), uploaded and encoded; its sample goes back as
//   Efds           (a request, before the first sample) cod wdt hgt ext: the guest makes the format description
//   Eemt           frm err efl sbf: the sample, serialized as CoreMedia's paravirtualized sample-buffer
//                     atoms (sbuf: opts stia sdat nsmp ssiz sary), in messages of at most 16384 bytes (the
//                     guest's receive buffer): flags 0x10 (more) on all but the last, which is a plain
//                     message (0: Apple's host makes it a request, but the kext holds a request back until the
//                     held send's answer is in, and this one has to come before it)
//                  -> and then efrm's answer, err 0, inf 0 (inf 1, Asynchronous, when the encoder keeps the frame:
//                     send_eemt says why the sample goes first; the kext holds the guest's send until the answer is
//                     in, kext/VeneraVideo waitsForReply)
//   ecfr           -> err 0 once every frame sent before it is out
//   einv / -enc    -> the encoder / the session goes
// Encoded with FFmpeg's h264_vaapi / hevc_vaapi, no B-frames, one frame in flight, so each frame's sample comes out as
// soon as it's in.
#include <arpa/inet.h>
#include <libavutil/opt.h>

#define MAX_ENC 8
#define ENC_Q 32
#define kVTVideoEncoderMalfunctionErr (-12911)
#define kVTCouldNotFindVideoEncoderErr (-12908)

typedef struct {
    int64_t frm;
    uint8_t pts[24], dur[24];   // CMTimes as the guest sent them (the wire's big-endian value, timescale, flags, epoch)
    int slot;                   // its slot while it's pulled, -1 after
    int state;                  // 0: waiting for its pull, 1: in the encoder
    int key;                    // the guest asked for a key frame
    uint64_t req;               // its efrm
    int answered;
} enc_frame;

typedef struct {
    int used;
    uint8_t uuid[16];
    uint32_t codec;
    int w, h;
    AVCodecContext *c;
    AVBufferRef *frames;
    int failed;                          // the encoder wouldn't open: every frame answers an error
    int fds_sent;
    uint8_t *pset;                       // the avcC / hvcC record sent in Efds
    size_t pset_n;
    int fdsc_sent;                       // the format description went with a sample (the guest's sample reader
                                         // keeps the last one it saw; it starts with none)
    int64_t bitrate;                     // AverageBitRate, 0: constant quality
    int keyint;                          // MaxKeyFrameInterval, frames
    double fps;                          // ExpectedFrameRate
    double keyint_s;                     // MaxKeyFrameIntervalDuration, seconds
    enc_frame q[ENC_Q];                  // in order: waiting for a pull, or in the encoder
    int nq;
    int64_t sent;
    uint64_t cfr_req;                    // an ecfr waiting for the frames before it
    int cfr_wait;
} encsession;
static encsession encs[MAX_ENC];
static int enc_h264, enc_hevc;           // what the GPU's driver encodes (found when the device opens)

static encsession *find_enc(const uint8_t *uuid) {
    for (int i = 0; i < MAX_ENC; i++) {
        if (encs[i].used && !memcmp(encs[i].uuid, uuid, 16)) {
            return &encs[i];
        }
    }
    return NULL;
}

static void enc_answer_frame(encsession *s, enc_frame *f, uint32_t inf);
static void enc_close(encsession *s) {
    avcodec_free_context(&s->c);
    av_buffer_unref(&s->frames);
    for (int i = 0; i < s->nq; i++) {
        if (s->q[i].slot >= 0) {
            slot_busy[s->q[i].slot] = 0;
        }
        enc_answer_frame(s, &s->q[i], 2);   // a frame the guest still waits on: dropped (once: answered says)
    }
    s->nq = 0;
    s->fds_sent = 0;
    s->fdsc_sent = 0;
    s->failed = 0;
    free(s->pset);
    s->pset = NULL;
    s->pset_n = 0;
}
static void enc_free(encsession *s) {
    enc_close(s);
    memset(s, 0, sizeof(*s));
}

// The GPU's encode entry points, once the device is open.
static void enc_probe(VADisplay d) {
    VAEntrypoint e[32];
    int n = 0;
    enc_h264 = enc_hevc = 0;
    if (vaQueryConfigEntrypoints(d, VAProfileH264High, e, &n) == VA_STATUS_SUCCESS) {
        for (int i = 0; i < n; i++) {
            enc_h264 |= e[i] == VAEntrypointEncSlice || e[i] == VAEntrypointEncSliceLP;
        }
    }
    n = 0;
    if (vaQueryConfigEntrypoints(d, VAProfileHEVCMain, e, &n) == VA_STATUS_SUCCESS) {
        for (int i = 0; i < n; i++) {
            enc_hevc |= e[i] == VAEntrypointEncSlice || e[i] == VAEntrypointEncSliceLP;
        }
    }
    LOG("encoding: H.264 %s, HEVC %s", enc_h264 ? "yes" : "no", enc_hevc ? "yes" : "no");
}

// ---- the sample the guest gets: CoreMedia's paravirtualized sample-buffer atoms ------------------------------------

static void atom_begin(buf *b, size_t *at, const char *type) {
    *at = b->n;
    put(b, "\0\0\0\0", 4);
    put(b, type, 4);
}
static void atom_end(buf *b, size_t at) {
    uint32_t n = (uint32_t)(b->n - at);
    b->p[at] = (uint8_t)(n >> 24), b->p[at + 1] = (uint8_t)(n >> 16), b->p[at + 2] = (uint8_t)(n >> 8), b->p[at + 3] = (uint8_t)n;
}
static void put_le(buf *b, uint64_t v, int size) {
    for (int i = 0; i < size; i++) {
        uint8_t x = (uint8_t)(v >> (8 * i));
        put(b, &x, 1);
    }
}
// A CMTime from the wire (big-endian) as the atoms carry it (little-endian), or an invalid one.
static void put_cmtime(buf *b, const uint8_t *wire) {
    if (!wire) {
        put_le(b, 0, 8), put_le(b, 0, 4), put_le(b, 0, 4), put_le(b, 0, 8);
        return;
    }
    put_le(b, get_be(wire, 8), 8);
    put_le(b, get_be(wire + 8, 4), 4);
    put_le(b, get_be(wire + 12, 4), 4);
    put_le(b, get_be(wire + 16, 8), 8);
}
// keyv: a numbered sample attachment (0 NotSync, 3 IsDependedOnByOthers, 4 DependsOnOthers) and a boolean, as a
// one-object binary plist
static void put_bool_attachment(buf *b, uint16_t key, int v) {
    size_t kv, a;
    atom_begin(b, &kv, "keyv");
    atom_begin(b, &a, "idxk");
    put_le(b, key, 2);
    atom_end(b, a);
    atom_begin(b, &a, "bulv");
    static const uint8_t head[8] = {'b', 'p', 'l', 'i', 's', 't', '0', '0'};
    put(b, head, 8);
    uint8_t obj = v ? 0x09 : 0x08, off = 8;
    put(b, &obj, 1);
    put(b, &off, 1);
    static const uint8_t trailer[32] = {0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1,
                                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9};
    put(b, trailer, 32);
    atom_end(b, a);
    atom_end(b, kv);
}
// keyv: a numbered key and a value, as a one-object binary plist in an atom of its type (nmbv, strk, datv)
static void put_keyv(buf *b, uint16_t key, const char *type, bp *value) {
    size_t kv, a;
    atom_begin(b, &kv, "keyv");
    atom_begin(b, &a, "idxk");
    put_le(b, key, 2);
    atom_end(b, a);
    atom_begin(b, &a, type);
    size_t pn;
    uint8_t *pl = bp_encode(value, &pn);
    put(b, pl, pn);
    free(pl);
    bp_free(value);
    atom_end(b, a);
    atom_end(b, kv);
}
// fdsc: the format description, as CoreMedia's paravirtualized serialization carries one (mdia, vdim, codc, extn of
// numbered extension keys: 49 SampleDescriptionExtensionAtoms {105 avcC | 112 hvcC}, 52 FormatName, 53 Depth,
// 62 FieldCount, 122 BitsPerComponent), learned from Apple's own serializer on a Mac
static void put_fdsc(buf *b, const encsession *s) {
    int hevc = s->codec == FOURCC('h', 'v', 'c', '1');
    size_t fd, a, ex, d, kv, d2;
    atom_begin(b, &fd, "fdsc");
    atom_begin(b, &a, "mdia");
    put_le(b, FOURCC('v', 'i', 'd', 'e'), 4);
    atom_end(b, a);
    atom_begin(b, &a, "vdim");
    put_le(b, (uint32_t)s->w, 4);
    put_le(b, (uint32_t)s->h, 4);
    atom_end(b, a);
    atom_begin(b, &a, "codc");
    put_le(b, s->codec, 4);
    atom_end(b, a);
    atom_begin(b, &ex, "extn");
    atom_begin(b, &d, "dict");
    atom_begin(b, &kv, "keyv");   // 49: the sample description's atoms, a dictionary of its own
    atom_begin(b, &a, "idxk");
    put_le(b, 49, 2);
    atom_end(b, a);
    atom_begin(b, &d2, "dict");
    put_keyv(b, hevc ? 112 : 105, "datv", bp_data(s->pset, s->pset_n));
    atom_end(b, d2);
    atom_end(b, kv);
    put_keyv(b, 52, "strk", bp_str(hevc ? "HEVC" : "H.264"));
    put_keyv(b, 53, "nmbv", bp_int(24));
    put_keyv(b, 62, "nmbv", bp_int(1));
    if (hevc) {
        put_keyv(b, 122, "nmbv", bp_int(8));
    }
    atom_end(b, d);
    atom_end(b, ex);
    atom_end(b, fd);
}

static void sample_atoms(buf *b, encsession *s, const enc_frame *f, const uint8_t *data, size_t n, int key) {
    size_t sb, a;
    atom_begin(b, &sb, "sbuf");
    atom_begin(b, &a, "opts");   // the output presentation time
    put_cmtime(b, f->pts);
    atom_end(b, a);
    atom_begin(b, &a, "stia");   // timing: duration, presentation, decode (none)
    put_cmtime(b, f->dur);
    put_cmtime(b, f->pts);
    put_cmtime(b, NULL);
    atom_end(b, a);
    atom_begin(b, &a, "sdat");
    put(b, data, n);
    atom_end(b, a);
    atom_begin(b, &a, "nsmp");
    put_le(b, 1, 4);
    atom_end(b, a);
    atom_begin(b, &a, "ssiz");
    put_le(b, n, 4);
    atom_end(b, a);
    if (!s->fdsc_sent && s->pset) {   // the first sample carries the format description; the guest keeps it
        put_fdsc(b, s);
        s->fdsc_sent = 1;
    }
    size_t sa, ar, d;
    atom_begin(b, &sa, "sary");
    atom_begin(b, &ar, "aray");
    atom_begin(b, &d, "dict");
    if (key) {
        put_bool_attachment(b, 4, 0);   // DependsOnOthers false
    } else {
        put_bool_attachment(b, 0, 1);   // NotSync
        put_bool_attachment(b, 4, 1);   // DependsOnOthers
    }
    atom_end(b, d);
    atom_end(b, ar);
    atom_end(b, sa);
    atom_end(b, sb);
}

// ---- parameter sets and samples ------------------------------------------------------------------------------------

// The NAL units of Annex B bytes, one call each (start codes 00 00 01 or 00 00 00 01).
typedef void (*nal_fn)(void *ctx, const uint8_t *nal, size_t n);
static void annexb_nals(const uint8_t *p, size_t n, nal_fn fn, void *ctx) {
    size_t i = 0, start = (size_t)-1;
    while (i + 3 <= n) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
            if (start != (size_t)-1) {
                size_t end = i;
                while (end > start && p[end - 1] == 0) {
                    end--;
                }
                fn(ctx, p + start, end - start);
            }
            i += 3;
            start = i;
        } else {
            i++;
        }
    }
    if (start != (size_t)-1 && start < n) {
        fn(ctx, p + start, n - start);
    }
}
static int nal_type(uint32_t codec, const uint8_t *nal) {
    return codec == FOURCC('h', 'v', 'c', '1') ? (nal[0] >> 1) & 0x3f : nal[0] & 0x1f;
}
typedef struct {
    uint32_t codec;
    buf *out;
    const uint8_t *ps[3];
    size_t psn[3];   // H.264: SPS, PPS; HEVC: VPS, SPS, PPS
} nal_ctx;
// A sample's NAL units with 4-byte lengths, parameter sets and access unit delimiters left out (the format description
// carries the sets).
static void nal_to_sample(void *v, const uint8_t *nal, size_t n) {
    nal_ctx *x = v;
    if (!n) {
        return;
    }
    int t = nal_type(x->codec, nal);
    if (x->codec == FOURCC('h', 'v', 'c', '1') ? (t >= 32 && t <= 35) : (t == 7 || t == 8 || t == 9)) {
        return;
    }
    put_be(x->out, n, 4);
    put(x->out, nal, n);
}
static void nal_find_ps(void *v, const uint8_t *nal, size_t n) {
    nal_ctx *x = v;
    if (!n) {
        return;
    }
    int t = nal_type(x->codec, nal), k = -1;
    if (x->codec == FOURCC('h', 'v', 'c', '1')) {
        k = t == 32 ? 0 : t == 33 ? 1 : t == 34 ? 2 : -1;
    } else {
        k = t == 7 ? 0 : t == 8 ? 1 : -1;
    }
    if (k >= 0 && !x->ps[k]) {
        x->ps[k] = nal, x->psn[k] = n;
    }
}

// HEVC's SPS read far enough for hvcC: profile_tier_level, chroma format, bit depths (Rec. ITU-T H.265 7.3.2.2).
typedef struct {
    const uint8_t *p;
    size_t n, bit;   // over the NAL with emulation prevention bytes removed
} bits;
static uint32_t rd(bits *b, int k) {
    uint32_t v = 0;
    while (k--) {
        v = v << 1 | (b->bit / 8 < b->n ? (b->p[b->bit / 8] >> (7 - b->bit % 8)) & 1 : 0);
        b->bit++;
    }
    return v;
}
static uint32_t ue(bits *b) {
    int z = 0;
    while (!rd(b, 1) && z < 32) {
        z++;
    }
    return (1u << z) - 1 + rd(b, z);
}
static size_t unescape(const uint8_t *in, size_t n, uint8_t *out) {
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        if (i >= 2 && in[i] == 3 && in[i - 1] == 0 && in[i - 2] == 0) {
            continue;
        }
        out[o++] = in[i];
    }
    return o;
}
static void hvcc(buf *b, const nal_ctx *x) {
    uint8_t sps[512];
    size_t sn = unescape(x->ps[1], x->psn[1] < sizeof(sps) ? x->psn[1] : sizeof(sps), sps);
    bits r = {sps, sn, 16};   // after the 2-byte NAL header
    rd(&r, 4);                // sps_video_parameter_set_id
    int max_sub = rd(&r, 3);
    rd(&r, 1);                // temporal_id_nesting
    uint8_t ptl[12];          // general profile_space..level_idc: 12 bytes, copied as they are
    for (int i = 0; i < 12; i++) {
        ptl[i] = (uint8_t)rd(&r, 8);
    }
    int sub_profile[8] = {0}, sub_level[8] = {0};
    for (int i = 0; i < max_sub; i++) {
        sub_profile[i] = rd(&r, 1), sub_level[i] = rd(&r, 1);
    }
    if (max_sub > 0) {
        for (int i = max_sub; i < 8; i++) {
            rd(&r, 2);
        }
    }
    for (int i = 0; i < max_sub; i++) {
        if (sub_profile[i]) {
            rd(&r, 32), rd(&r, 32), rd(&r, 24);
        }
        if (sub_level[i]) {
            rd(&r, 8);
        }
    }
    ue(&r);   // sps_seq_parameter_set_id
    uint32_t chroma = ue(&r);
    if (chroma == 3) {
        rd(&r, 1);
    }
    ue(&r), ue(&r);   // width, height
    if (rd(&r, 1)) {   // conformance window
        ue(&r), ue(&r), ue(&r), ue(&r);
    }
    uint32_t luma8 = ue(&r), chroma8 = ue(&r);
    uint8_t h[23] = {1};
    memcpy(h + 1, ptl, 12);          // profile_space/tier/idc, compatibility flags, constraint flags, level_idc
    h[13] = 0xf0, h[14] = 0x00;      // min_spatial_segmentation_idc 0
    h[15] = 0xfc;                    // parallelismType 0
    h[16] = (uint8_t)(0xfc | (chroma & 3));
    h[17] = (uint8_t)(0xf8 | (luma8 & 7));
    h[18] = (uint8_t)(0xf8 | (chroma8 & 7));
    h[19] = h[20] = 0;               // avgFrameRate
    h[21] = (uint8_t)(((max_sub + 1) & 7) << 3 | 1 << 2 | 3);   // numTemporalLayers, temporalIdNested, length 4
    h[22] = 3;                       // arrays: VPS, SPS, PPS
    put(b, h, 23);
    static const int types[3] = {32, 33, 34};
    for (int i = 0; i < 3; i++) {
        uint8_t t = (uint8_t)(0x80 | types[i]);   // array_completeness
        put(b, &t, 1);
        put_be(b, 1, 2);
        put_be(b, x->psn[i], 2);
        put(b, x->ps[i], x->psn[i]);
    }
}
static void avcc(buf *b, const nal_ctx *x) {
    const uint8_t *sps = x->ps[0];
    uint8_t h[6] = {1, sps[1], sps[2], sps[3], 0xff, 0xe1};
    put(b, h, 6);
    put_be(b, x->psn[0], 2);
    put(b, sps, x->psn[0]);
    uint8_t one = 1;
    put(b, &one, 1);
    put_be(b, x->psn[1], 2);
    put(b, x->ps[1], x->psn[1]);
}

// Efds: the format description the guest makes before the first sample (a request; its answer isn't needed here).
static int send_efds(encsession *s, const uint8_t *headers, size_t hn) {
    nal_ctx x = {s->codec, NULL, {0}, {0}};
    annexb_nals(headers, hn, nal_find_ps, &x);
    int hevc = s->codec == FOURCC('h', 'v', 'c', '1');
    if (!x.ps[0] || !x.ps[1] || (hevc && !x.ps[2])) {
        LOG("encoder %02x%02x: no parameter sets in its output", s->uuid[0], s->uuid[1]);
        return -1;
    }
    buf rec = {0};
    if (hevc) {
        hvcc(&rec, &x);
    } else {
        avcc(&rec, &x);
    }
    free(s->pset);
    s->pset = malloc(rec.n);
    memcpy(s->pset, rec.p, rec.n);
    s->pset_n = rec.n;
    bp *atoms = bp_dict();
    bp_set(atoms, hevc ? "hvcC" : "avcC", bp_data(rec.p, rec.n));
    bp *ext = bp_dict();
    bp_set(ext, "FormatName", bp_str(hevc ? "HEVC" : "H.264"));
    bp_set(ext, "SampleDescriptionExtensionAtoms", atoms);
    size_t pn;
    uint8_t *pl = bp_encode(ext, &pn);
    bp_free(ext);
    free(rec.p);
    buf m = {0};
    msg_header(&m, "Efds", 2, s->uuid, ++host_req);
    field_s32(&m, "cod", (int32_t)s->codec);
    field_s32(&m, "wdt", s->w);
    field_s32(&m, "hgt", s->h);
    field(&m, "ext", "pls", pl, pn);
    out.msg(&m);
    free(m.p);
    free(pl);
    s->fds_sent = 1;
    return 0;
}

// Eemt: one frame's sample (or its error), 16 KB of the serialized sample a message, as Apple's host splits it.
static void send_eemt(encsession *s, enc_frame *f, int32_t err, const uint8_t *data, size_t n, int key) {
    buf sb = {0};
    if (!err) {
        sample_atoms(&sb, s, f, data, n, key);
    }
    size_t at = 0;
    int first = 1;
    do {
        // a whole message fits the guest's 16384-byte receive buffer (VideoToolboxParavirtualizationSupport dequeues
        // into one; a bigger message never leaves the queue): 48 bytes of header, the first part's frm/err/efl boxes
        // (64), the sbf box's own 16
        size_t room = 16384 - 48 - 16 - (first ? 64 : 0);
        size_t k = sb.n - at > room ? room : sb.n - at;
        buf m = {0};
        // every message but the last says "more follows" (0x10), as Apple's host does
        // (VTParavirtualizationMessageChangeMessageFlags(msg, 0x10, mask 0x12)). Apple's last is a request (2) the
        // guest answers; here it's a plain message (0), which the guest takes the same way and doesn't answer: an
        // answer is a send, which waits while a send of the same process is held (VeneraVideo's Deferred says why),
        // and a request held back behind that send's answer would reach the app after the CompleteFrames it ends.
        int more = at + k < sb.n;
        msg_header(&m, "Eemt", more ? 0x10 : 0, s->uuid, more ? 0 : ++host_req);

        if (!more) {
            VLOG("encoder %02x%02x: Eemt frame %lld, err %d, %zu bytes", s->uuid[0], s->uuid[1], (long long)f->frm, err, sb.n);
        }
        if (first) {
            field_s64(&m, "frm", f->frm);
            field_s32(&m, "err", err);
            field_u32(&m, "efl", err ? 2 : 0);   // kVTEncodeInfo_FrameDropped when it failed
        }
        if (k) {
            field(&m, "sbf", "sbf", sb.p + at, k);
        }
        out.msg(&m);
        free(m.p);
        at += k;
        first = 0;
    } while (at < sb.n);
    free(sb.p);
    // Its efrm is answered after its sample, never before. The guest sends one message at a time (a lock around the
    // kext call), and while a send is held for its answer (VeneraVideo's hold) its paravirtualization queue can't
    // answer this Eemt; that queue hands the frame to the app first and then answers, one message after the other.
    // Answered before its sample, the last frame's Eemt came while CompleteFrames was held, behind the answer to the
    // one before, and reached the app after CompleteFrames returned: AVFoundation's exports lost their last frame.
    // Sent first, it reaches the app while EncodeFrame waits (the hold keeps no one from receiving).
    if (!f->answered) {
        enc_answer_frame(s, f, err ? 2 : 0);
    }
}

static void enc_answer_frame(encsession *s, enc_frame *f, uint32_t inf) {
    if (f->answered) {
        return;
    }
    f->answered = 1;
    buf r = {0};
    msg_header(&r, "efrm", 4, s->uuid, f->req);
    field_s32(&r, "err", 0);
    field_u32(&r, "inf", inf);
    out.msg(&r);
    free(r.p);
}

static void enc_answer_cfr(encsession *s) {
    if (s->cfr_wait && !s->nq) {
        buf r = {0};
        msg_header(&r, "ecfr", 4, s->uuid, s->cfr_req);
        field_s32(&r, "err", 0);
        out.msg(&r);
        free(r.p);
        s->cfr_wait = 0;
    }
}

// What the encoder has made, each packet to the oldest frame in it. When the guest asked for every frame (ecfr) and
// the rest are in the encoder, it's flushed (and closed: a later frame opens a new one).
static void enc_collect(encsession *s) {
    AVPacket *pkt = av_packet_alloc();
    int flushed = 0;
again:
    while (s->c && avcodec_receive_packet(s->c, pkt) == 0) {
        int i = 0;
        while (i < s->nq && s->q[i].state != 1) {
            i++;
        }
        if (i == s->nq) {
            av_packet_unref(pkt);
            continue;
        }
        enc_frame f = s->q[i];
        memmove(&s->q[i], &s->q[i + 1], (size_t)(s->nq - i - 1) * sizeof(enc_frame));
        s->nq--;
        if (!s->fds_sent) {
            const uint8_t *hdr = s->c->extradata;
            size_t hn = (size_t)s->c->extradata_size;
            if (!hn) {   // no global header: the key frame's own parameter sets
                hdr = pkt->data, hn = (size_t)pkt->size;
            }
            send_efds(s, hdr, hn);
        }
        buf smp = {0};
        nal_ctx x = {s->codec, &smp, {0}, {0}};
        annexb_nals(pkt->data, (size_t)pkt->size, nal_to_sample, &x);
        send_eemt(s, &f, smp.n ? 0 : kVTVideoEncoderMalfunctionErr, smp.p, smp.n, !!(pkt->flags & AV_PKT_FLAG_KEY));
        free(smp.p);
        av_packet_unref(pkt);
    }
    int waiting_pull = 0;
    for (int i = 0; i < s->nq; i++) {
        waiting_pull |= s->q[i].state == 0;
    }
    if (s->cfr_wait && s->nq && !waiting_pull && s->c && !flushed) {
        avcodec_send_frame(s->c, NULL);   // the end of this stream: what it holds comes out
        flushed = 1;
        goto again;
    }
    if (flushed) {
        avcodec_free_context(&s->c);
        av_buffer_unref(&s->frames);
        for (int i = 0; i < s->nq; i++) {   // frames that never came out
            send_eemt(s, &s->q[i], kVTVideoEncoderMalfunctionErr, NULL, 0, 0);
        }
        s->nq = 0;
    }
    av_packet_free(&pkt);
    enc_answer_cfr(s);
}

static int enc_open(encsession *s) {
    int hevc = s->codec == FOURCC('h', 'v', 'c', '1');
    const AVCodec *codec = avcodec_find_encoder_by_name(hevc ? "hevc_vaapi" : "h264_vaapi");
    if (!codec || (!hwdev && open_hw())) {
        return -1;
    }
    for (int lp = 0; lp < 2; lp++) {   // the driver's full entry point first, then its low-power one
        AVCodecContext *c = avcodec_alloc_context3(codec);
        AVBufferRef *fr = av_hwframe_ctx_alloc(hwdev);
        AVHWFramesContext *fc = (AVHWFramesContext *)fr->data;
        fc->format = AV_PIX_FMT_VAAPI;
        fc->sw_format = AV_PIX_FMT_NV12;
        fc->width = s->w;
        fc->height = s->h;
        fc->initial_pool_size = 8;
        int fps = s->fps > 0 ? (int)(s->fps + 0.5) : 30;
        c->width = s->w;
        c->height = s->h;
        c->pix_fmt = AV_PIX_FMT_VAAPI;
        c->time_base = (AVRational){1, fps};
        c->framerate = (AVRational){fps, 1};
        int gop = s->keyint > 0 ? s->keyint : 2 * fps;
        if (s->keyint_s > 0 && s->keyint_s * fps < gop) {
            gop = (int)(s->keyint_s * fps + 0.5);
        }
        c->gop_size = gop > 0 ? gop : 1;
        c->max_b_frames = 0;
        c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (s->bitrate > 0) {
            c->bit_rate = s->bitrate;
            c->rc_max_rate = s->bitrate * 3 / 2;
            c->rc_buffer_size = (int)(s->bitrate * 2);
            av_opt_set(c->priv_data, "rc_mode", "VBR", 0);
        } else {
            av_opt_set(c->priv_data, "rc_mode", "CQP", 0);
            c->global_quality = hevc ? 26 : 24;
        }
        if (!hevc) {
            av_opt_set(c->priv_data, "profile", "high", 0);
        }
        av_opt_set_int(c->priv_data, "async_depth", 1, 0);
        av_opt_set_int(c->priv_data, "low_power", lp, 0);
        int rc = av_hwframe_ctx_init(fr);
        if (!rc) {
            c->hw_frames_ctx = av_buffer_ref(fr);
            rc = avcodec_open2(c, codec, NULL);
        }
        if (!rc) {
            s->c = c, s->frames = fr;
            LOG("encoder %02x%02x: %s %dx%d, %s, %s%s", s->uuid[0], s->uuid[1], codec->name, s->w, s->h,
                s->bitrate > 0 ? "average bit rate" : "constant quality", lp ? "low power" : "full",
                s->keyint > 0 ? "" : ", key frames every 2 s");
            return 0;
        }
        avcodec_free_context(&c);
        av_buffer_unref(&fr);
        if (lp) {
            char e[128];
            av_strerror(rc, e, sizeof(e));
            LOG("encoder %02x%02x: %s %dx%d won't open: %s", s->uuid[0], s->uuid[1], codec->name, s->w, s->h, e);
        }
    }
    return -1;
}

// A frame's pull is done: up to the GPU and into the encoder (or its error back to the guest).
static void engine_pulldone(int slot, int err) {
    encsession *s = NULL;
    enc_frame *f = NULL;
    for (int i = 0; i < MAX_ENC && !f; i++) {
        for (int k = 0; encs[i].used && k < encs[i].nq && !f; k++) {
            if (encs[i].q[k].slot == slot && encs[i].q[k].state == 0) {
                s = &encs[i], f = &encs[i].q[k];
            }
        }
    }
    if (slot >= 0 && slot < VV_NSLOTS) {
        slot_busy[slot] = 0;
    }
    if (!f) {
        return;
    }
    f->slot = -1;
    int rc = err ? -1 : 0;
    if (!rc && !s->c && (s->failed || enc_open(s))) {
        s->failed = 1;
        rc = -1;
    }
    if (!rc) {
        uint8_t *p = shm + VV_SLOT_OFF + (size_t)slot * VV_SLOT_SIZE;
        int stride = (s->w + 63) & ~63;
        AVFrame *sw = av_frame_alloc(), *hw = av_frame_alloc();
        sw->format = AV_PIX_FMT_NV12;
        sw->width = s->w;
        sw->height = s->h;
        sw->data[0] = p, sw->linesize[0] = stride;
        sw->data[1] = p + (size_t)stride * s->h, sw->linesize[1] = stride;
        rc = av_hwframe_get_buffer(s->frames, hw, 0);
        if (!rc) {
            rc = av_hwframe_transfer_data(hw, sw, 0);
        }
        if (!rc) {
            hw->pts = s->sent++;
            hw->pict_type = f->key ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
            rc = avcodec_send_frame(s->c, hw);
        }
        av_frame_free(&sw);
        av_frame_free(&hw);
    }
    if (rc) {   // its error to the guest, in its place
        enc_frame g = *f;
        int i = (int)(f - s->q);
        memmove(&s->q[i], &s->q[i + 1], (size_t)(s->nq - i - 1) * sizeof(enc_frame));
        s->nq--;
        send_eemt(s, &g, kVTVideoEncoderMalfunctionErr, NULL, 0, 0);
        enc_answer_cfr(s);
        return;
    }
    f->state = 1;
    int64_t frm = f->frm;
    enc_collect(s);
    for (int i = 0; i < s->nq; i++) {   // still in the encoder (it holds frames back): answered now, its sample later
        if (s->q[i].frm == frm && !s->q[i].answered) {
            enc_answer_frame(s, &s->q[i], 1);
        }
    }
}

// A guest message for an encoder: 1 when it was one.
static int enc_msg(const msg *m, const char *t, const struct vv_surf *surfs, int nsurf) {
    if (t[0] != 'e' && strcmp(t, "+enc") && strcmp(t, "-enc") && strcmp(t, "Epba") && strcmp(t, "Efds") && strcmp(t, "Eemt")) {
        return 0;
    }
    encsession *s = find_enc(m->uuid);
    VLOG("encoder %02x%02x: %s flags %u req %llu frame %lld", m->uuid[0], m->uuid[1], t, m->flags, (unsigned long long)m->req,
         (long long)field_int(m, "frm", "s64", -1));
    if (m->flags & 8) {   // the guest answering an Epba, Efds or Eemt of ours: nothing to do
        return 1;
    }
    buf r = {0};
    if (!strcmp(t, "encs")) {
        if (!hwdev) {
            open_hw();
        }
        msg_header(&r, "encs", 4, m->uuid, m->req);
        if (!guest_encodes()) {
            field(&r, "enc", "pls", vv_empty_array_plist, sizeof(vv_empty_array_plist));
        } else if (enc_h264 && enc_hevc) {
            field(&r, "enc", "pls", vv_encs_plist, sizeof(vv_encs_plist));
        } else if (enc_h264) {
            field(&r, "enc", "pls", vv_encs_avc_plist, sizeof(vv_encs_avc_plist));
        } else if (enc_hevc) {
            field(&r, "enc", "pls", vv_encs_hevc_plist, sizeof(vv_encs_hevc_plist));
        } else {
            field(&r, "enc", "pls", vv_empty_array_plist, sizeof(vv_empty_array_plist));
        }
        field_u32(&r, "ver", 6);
    } else if (!strcmp(t, "+enc")) {
        uint32_t cod = (uint32_t)field_int(m, "cod", "s32", 0);
        int ok = (cod == FOURCC('a', 'v', 'c', '1') && enc_h264) || (cod == FOURCC('h', 'v', 'c', '1') && enc_hevc);
        if (ok && !s) {
            for (int i = 0; i < MAX_ENC && !s; i++) {
                if (!encs[i].used) {
                    s = &encs[i];
                    memset(s, 0, sizeof(*s));
                    s->used = 1;
                    memcpy(s->uuid, m->uuid, 16);
                }
            }
        }
        if (s) {
            s->codec = cod;
        }
        msg_header(&r, "+enc", 4, m->uuid, m->req);
        field_s32(&r, "err", s ? 0 : kVTCouldNotFindVideoEncoderErr);
        field_u32(&r, "ver", 6);
        field(&r, "hin", "pls", vv_hin_plist, sizeof(vv_hin_plist));
        LOG("encoder %02x%02x: %.4s %s", m->uuid[0], m->uuid[1], (const char *)&(uint32_t){htonl(cod)},
            s ? "opened" : "refused (the GPU doesn't encode it, or too many encoders)");
    } else if (!s) {
        if (!(m->flags & 1)) {
            return 1;
        }
        msg_header(&r, t, 4, m->uuid, m->req);
        field_s32(&r, "err", kVTVideoEncoderMalfunctionErr);
    } else if (!strcmp(t, "esta")) {
        size_t n = 0;
        const uint8_t *v = msg_field(m, "vdi", "wxh", &n);
        if (n == 8) {
            s->w = (int)get_be(v, 4), s->h = (int)get_be(v + 4, 4);
        }
        int ok = s->w >= 64 && s->h >= 64 && s->w <= 4096 && s->h <= 4096 &&
                 (size_t)((s->w + 63) & ~63) * s->h * 3 / 2 <= VV_SLOT_SIZE;
        if (ok) {
            bp *d = bp_dict();
            bp *pf = bp_array();
            bp_push(pf, bp_int(FOURCC('4', '2', '0', 'v')));
            bp_push(pf, bp_int(FOURCC('4', '2', '0', 'f')));
            bp_set(d, "PixelFormatType", pf);
            bp_set(d, "Width", bp_int(s->w));
            bp_set(d, "Height", bp_int(s->h));
            bp_set(d, "ExtendedPixelsRight", bp_int(0));
            bp_set(d, "ExtendedPixelsBottom", bp_int(0));
            size_t pn;
            uint8_t *pl = bp_encode(d, &pn);
            bp_free(d);
            buf e = {0};
            msg_header(&e, "Epba", 2, m->uuid, ++host_req);
            field(&e, "pba", "pls", pl, pn);
            out.msg(&e);
            free(e.p);
            free(pl);
        }
        msg_header(&r, "esta", 4, m->uuid, m->req);
        field_s32(&r, "err", ok ? 0 : kVTVideoEncoderMalfunctionErr);
    } else if (!strcmp(t, "esup")) {
        msg_header(&r, "esup", 4, m->uuid, m->req);
        field_s32(&r, "err", 0);
        if (s->codec == FOURCC('h', 'v', 'c', '1')) {
            field(&r, "sup", "pls", vv_esup_hevc_plist, sizeof(vv_esup_hevc_plist));
        } else {
            field(&r, "sup", "pls", vv_esup_plist, sizeof(vv_esup_plist));
        }
    } else if (!strcmp(t, "efrm")) {
        size_t un = 0, pn = 0, dn = 0;
        const uint8_t *pts = msg_field(m, "pts", "tim", &pn), *dur = msg_field(m, "dur", "tim", &dn);
        msg_field(m, "uui", "uui", &un);
        int slot = s->nq < ENC_Q && nsurf >= 1 && !s->failed ? free_slot() : -1;
        enc_frame f = {.frm = field_int(m, "frm", "s64", 0), .slot = slot, .state = 0, .req = m->req};
        if (pn == 24) {
            memcpy(f.pts, pts, 24);
        }
        if (dn == 24) {
            memcpy(f.dur, dur, 24);
        }
        if (slot < 0) {   // no room, no frame, or no encoder: dropped (kVTEncodeInfo_FrameDropped)
            send_eemt(s, &f, kVTVideoEncoderMalfunctionErr, NULL, 0, 0);
            return 1;
        }
        slot_busy[slot] = 1;
        // not answered yet: send_eemt answers it once its sample is out (it says why), or the pull's end does if the
        // encoder holds the frame back
        s->q[s->nq++] = f;
        out.pull(surfs[0].id, slot, s->w, s->h, (s->w + 63) & ~63, 1);
        return 1;
    } else if (!strcmp(t, "ecfr")) {
        s->cfr_req = m->req;
        s->cfr_wait = 1;
        enc_collect(s);   // answers when the frames before it are out
        return 1;
    } else if (!strcmp(t, "einv")) {
        enc_close(s);
        msg_header(&r, "einv", 4, m->uuid, m->req);
        field_s32(&r, "err", 0);
    } else if (!strcmp(t, "-enc")) {
        LOG("encoder %02x%02x: closed after %lld frames", s->uuid[0], s->uuid[1], (long long)s->sent);
        enc_free(s);
        return 1;
    } else if (!strcmp(t, "eset")) {   // a property: the ones the encoder honors are kept for when it opens
        char key[64] = "";
        size_t kn = 0, vn = 0;
        const uint8_t *k = msg_field(m, "key", "pls", &kn), *v = msg_field(m, "val", "pls", &vn);
        double val = 0;
        if (k && !bp_read_string(k, kn, key, sizeof(key)) && v && !bp_read_number(v, vn, &val)) {
            if (!strcmp(key, "AverageBitRate")) {
                s->bitrate = (int64_t)val;
            } else if (!strcmp(key, "MaxKeyFrameInterval")) {
                s->keyint = (int)val;
            } else if (!strcmp(key, "MaxKeyFrameIntervalDuration") && val > 0) {
                s->keyint_s = val;
            } else if (!strcmp(key, "ExpectedFrameRate")) {
                s->fps = val;
            }
        }
        VLOG("encoder %02x%02x: %s = %g", s->uuid[0], s->uuid[1], key, val);
        msg_header(&r, "eset", 4, m->uuid, m->req);
        field_s32(&r, "err", 0);
    } else if (!strcmp(t, "ecop")) {   // a property's value: the bit rate, when it was set; else none
        char key[64] = "";
        size_t kn = 0;
        const uint8_t *k = msg_field(m, "key", "pls", &kn);
        msg_header(&r, "ecop", 4, m->uuid, m->req);
        field_s32(&r, "err", 0);
        if (k && !bp_read_string(k, kn, key, sizeof(key)) && !strcmp(key, "AverageBitRate") && s->bitrate > 0) {
            bp *n = bp_int(s->bitrate);
            size_t pn;
            uint8_t *pl = bp_encode(n, &pn);
            bp_free(n);
            field(&r, "val", "pls", pl, pn);
            free(pl);
        }
    } else {   // epfr, and anything else an encoder asks: taken
        if (!(m->flags & 1)) {
            return 1;
        }
        VLOG("encoder %02x%02x: %s answered with no error", s->uuid[0], s->uuid[1], t);
        msg_header(&r, t, 4, m->uuid, m->req);
        field_s32(&r, "err", 0);
    }
    out.msg(&r);
    free(r.p);
    return 1;
}
