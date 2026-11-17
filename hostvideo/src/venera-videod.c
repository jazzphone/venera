// venera-videod (Venera video, runs on the Proxmox host): the host side of Apple's paravirtualized VideoToolbox for
// VM 108, decoding on the host GPU.
//
// macOS's VideoToolbox, in a guest, sends a host "messages" (a 48-byte 'vtpv' header and 'para,KEY=TYPE' fields)
// through a driver, AppleVideoToolboxParavirtualizationDriver, that Intel macOS ships no code for; Venera's kext
// (kext/VeneraVideo) provides it and passes the messages through QEMU's ivshmem-doorbell device to this program,
// which answers them as Apple's own host session would (tools/pvhost.m on a Mac was the reference): the decoders it
// has, sessions, and for each compressed frame a decoded one -- FFmpeg over VA-API on the Iris Xe -- written into the
// guest's own IOSurface (the guest copies it out of a shared-memory slot).
//
//   venera-videod [-v] SOCKET            serve the VM (QEMU's chardev for ivshmem-doorbell connects to SOCKET)
//   venera-videod [-v] -replay MSG...    play messages a guest sent (tools/pvshim.c saves them) against the engine,
//                                        acting as the guest: output buffers are made up, frames' pixels printed
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <va/va.h>
#include <va/va_vpp.h>
#include <libavutil/pixdesc.h>

#include "vv_bplist.h"
#include "vv_shm.h"
#include "vv_static.h"

static int verbose;
static void logf_(const char *fmt, ...) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    struct tm tm;
    localtime_r(&t.tv_sec, &tm);
    char ts[32];
    strftime(ts, sizeof(ts), "%F %T", &tm);
    fprintf(stderr, "%s.%03ld ", ts, t.tv_nsec / 1000000);
    va_list a;
    va_start(a, fmt);
    vfprintf(stderr, fmt, a);
    va_end(a);
    fputc('\n', stderr);
}
#define LOG(...) logf_(__VA_ARGS__)
#define VLOG(...)               \
    do {                        \
        if (verbose) {          \
            logf_(__VA_ARGS__); \
        }                       \
    } while (0)

// VideoToolbox's errors and flags this speaks
#define kVTPropertyNotSupportedErr (-12900)
#define kVTCouldNotFindVideoDecoderErr (-12906)
#define kVTVideoDecoderBadDataErr (-12909)
#define kVTVideoDecoderMalfunctionErr (-12911)
#define kVTInvalidSessionErr (-12903)
#define kVTDecodeFrame_DoNotOutputFrame (1u << 1)
#define kVTDecodeInfo_Asynchronous (1u << 0)
#define kVTDecodeInfo_FrameDropped (1u << 1)
#define FOURCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))

// ---- messages ------------------------------------------------------------------------------------------------------

typedef struct {
    uint8_t *p;
    size_t n, cap;
} buf;
static void put(buf *b, const void *d, size_t n) {
    if (b->n + n > b->cap) {
        b->cap = (b->n + n) * 2 + 256;
        b->p = realloc(b->p, b->cap);
    }
    memcpy(b->p + b->n, d, n);
    b->n += n;
}
static void put_be(buf *b, uint64_t v, int size) {
    uint8_t x[8];
    for (int i = 0; i < size; i++) {
        x[i] = (uint8_t)(v >> (8 * (size - 1 - i)));
    }
    put(b, x, (size_t)size);
}
static uint64_t get_be(const uint8_t *p, int size) {
    uint64_t v = 0;
    for (int i = 0; i < size; i++) {
        v = v << 8 | p[i];
    }
    return v;
}

// The 48-byte header: size, 'vtpv', type, flags (1 request, 2 host request, 4 reply, 8 reply to a host request), the
// guest object's UUID, the request number.
static void msg_header(buf *m, const char *type, uint32_t flags, const uint8_t *uuid, uint64_t req) {
    m->n = 0;
    put_be(m, 48, 4);
    put(m, "vtpv", 4);
    put(m, type, 4);
    put_be(m, flags, 4);
    put(m, uuid, 16);
    put_be(m, req, 8);
    put_be(m, 0, 8);
}
static void field(buf *m, const char *name, const char *type, const void *v, size_t n) {
    size_t hl = 5 + strlen(name) + 1 + strlen(type);
    put_be(m, 4 + hl + n, 4);
    put(m, "para,", 5);
    put(m, name, strlen(name));
    put(m, "=", 1);
    put(m, type, strlen(type));
    put(m, v, n);
}
static void field_s32(buf *m, const char *name, int32_t v) {
    uint8_t x[4] = {(uint8_t)((uint32_t)v >> 24), (uint8_t)((uint32_t)v >> 16), (uint8_t)((uint32_t)v >> 8), (uint8_t)v};
    field(m, name, "s32", x, 4);
}
static void field_u32(buf *m, const char *name, uint32_t v) {
    uint8_t x[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    field(m, name, "u32", x, 4);
}
static void field_s64(buf *m, const char *name, int64_t v) {
    uint8_t x[8];
    for (int i = 0; i < 8; i++) {
        x[i] = (uint8_t)((uint64_t)v >> (56 - 8 * i));
    }
    field(m, name, "s64", x, 8);
}

typedef struct {
    const uint8_t *p;
    size_t n;
    char type[5];
    uint32_t flags;
    const uint8_t *uuid;
    uint64_t req;
} msg;
static int msg_parse(const uint8_t *p, size_t n, msg *m) {
    if (n < 48 || get_be(p, 4) != 48 || memcmp(p + 4, "vtpv", 4)) {
        return -1;
    }
    m->p = p, m->n = n;
    memcpy(m->type, p + 8, 4);
    m->type[4] = 0;
    m->flags = (uint32_t)get_be(p + 12, 4);
    m->uuid = p + 16;
    m->req = get_be(p + 32, 8);
    return 0;
}
// The value of field "para,NAME=TYPE", or NULL.
static const uint8_t *msg_field(const msg *m, const char *name, const char *type, size_t *len) {
    char key[64];
    int kl = snprintf(key, sizeof(key), "para,%s=%s", name, type);
    size_t i = 48;
    while (i + 8 <= m->n) {
        uint32_t size = (uint32_t)get_be(m->p + i, 4);
        if (size < 8 || i + size > m->n) {
            break;
        }
        if (size >= 4 + (uint32_t)kl && !memcmp(m->p + i + 4, key, (size_t)kl)) {
            *len = size - 4 - (size_t)kl;
            return m->p + i + 4 + kl;
        }
        i += size;
    }
    return NULL;
}
static int64_t field_int(const msg *m, const char *name, const char *type, int64_t dflt) {
    size_t n = 0;
    const uint8_t *v = msg_field(m, name, type, &n);
    if (!v || (n != 4 && n != 8)) {
        return dflt;
    }
    uint64_t u = get_be(v, (int)n);
    if (n == 4 && type[0] == 's') {
        return (int32_t)(uint32_t)u;
    }
    return (int64_t)u;
}

// ---- the engine's output (the guest, or the replay's stand-in) -----------------------------------------------------

typedef struct {
    void (*msg)(const buf *m);
    // copy slot `slot` (packed rows: luma `stride` x h, chroma after it) into the guest's IOSurface `surf`
    void (*fill)(uint32_t surf, int slot, int w, int h, int stride, int bps);
} sink;
static sink out;
static uint8_t *shm;   // the shared memory (or the replay's copy of it)
static int slot_busy[VV_NSLOTS];
static uint64_t host_req = 100;

// ---- sessions ------------------------------------------------------------------------------------------------------

typedef struct frame_out {
    int64_t frm;
    int dropped;   // decoded, not to be shown (DoNotOutputFrame)
    AVFrame *f;    // the decoded frame on the GPU, until it is copied into a slot
    int slot;      // the slot holding its pixels, or -1
    int w, h, stride, bps;
    int32_t err;
    uint64_t dbuf_req;   // 0 until the Dbuf request went out
    uint32_t surf;       // the guest's buffer, once it answered
    uint8_t uui[16];
    int answered;
    struct frame_out *next;
} frame_out;

typedef struct {
    int used;
    uint8_t uuid[16];
    uint32_t codec;
    AVCodecContext *c;
    int w, h;
    int bits;                 // 8, or 10 (P010 frames into 'x420' buffers)
    frame_out *head, *tail;   // decoded frames on their way out, in output order
    int64_t pending[256];     // frames sent to the decoder and not yet out
    uint32_t pending_dfl[256];
    frame_out *pending_fo[256];   // their output buffers, asked for as each frame arrived (as Apple's host does)
    int npending;
    int finishing;   // a dfin waits for the queue to empty
    uint64_t fin_req;
    // A dfin (VTDecompressionSessionFinishDelayedFrames) must put out every frame the decoder holds and keep its
    // references, as Apple's decoders do; FFmpeg can only drain to the end and start over. So the packets since the
    // last key frame are kept, and after a drain they go through the decoder again with their output thrown away.
    // (AVPlayer's preroll is "frame 1, finish, then the rest": a plain flush lost frame 1 as a reference, and FFmpeg
    // then held every frame until the next key frame.)
    AVPacket **saved;
    int nsaved, capsaved;
    int64_t suppress[64];   // replayed frames whose output is not owed to VideoToolbox
    int nsuppress;
    uint64_t frames_in, frames_out;
} session;
#define MAX_SESSIONS 32
static session sessions[MAX_SESSIONS];
static AVBufferRef *hwdev;

static session *find_session(const uint8_t *uuid) {
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].used && !memcmp(sessions[i].uuid, uuid, 16)) {
            return &sessions[i];
        }
    }
    return NULL;
}
static void free_session(session *s) {
    for (int i = 0; i < s->nsaved; i++) {
        av_packet_free(&s->saved[i]);
    }
    free(s->saved);
    for (int i = 0; i < s->npending; i++) {
        free(s->pending_fo[i]);
    }
    while (s->head) {
        frame_out *f = s->head;
        s->head = f->next;
        if (f->slot >= 0) {
            slot_busy[f->slot] = 0;
        }
        av_frame_free(&f->f);
        free(f);
    }
    avcodec_free_context(&s->c);
    if (s->used) {
        LOG("session %02x%02x%02x%02x closed: %llu frames in, %llu out", s->uuid[0], s->uuid[1], s->uuid[2], s->uuid[3],
            (unsigned long long)s->frames_in, (unsigned long long)s->frames_out);
    }
    memset(s, 0, sizeof(*s));
}

static void reply_err(const msg *m, int32_t err) {
    buf r = {0};
    msg_header(&r, m->type, 4, m->uuid, m->req);
    field_s32(&r, "err", err);
    out.msg(&r);
    free(r.p);
}

static enum AVPixelFormat pick_vaapi(AVCodecContext *c, const enum AVPixelFormat *f) {
    for (; *f != AV_PIX_FMT_NONE; f++) {
        if (*f == AV_PIX_FMT_VAAPI) {
            return *f;
        }
    }
    LOG("decoder offers no VA-API format");
    return AV_PIX_FMT_NONE;
}

// dsta's 'fds': an MP4 sample description entry ('avc1' + avcC, 'hvc1' + hvcC, 'av01' + av1C, 'vp09' + vpcC).
static int open_decoder(session *s, const uint8_t *fds, size_t n) {
    if (n < 8 + 78) {
        return -1;
    }
    uint32_t fourcc = (uint32_t)get_be(fds + 4, 4);
    enum AVCodecID id = AV_CODEC_ID_NONE;
    const char *cfg = NULL;
    switch (fourcc) {
    case FOURCC('a', 'v', 'c', '1'):
    case FOURCC('a', 'v', 'c', '3'):
        id = AV_CODEC_ID_H264, cfg = "avcC";
        break;
    case FOURCC('h', 'v', 'c', '1'):
    case FOURCC('h', 'e', 'v', '1'):
        id = AV_CODEC_ID_HEVC, cfg = "hvcC";
        break;
    case FOURCC('a', 'v', '0', '1'):
        id = AV_CODEC_ID_AV1, cfg = "av1C";
        break;
    case FOURCC('v', 'p', '0', '9'):
        id = AV_CODEC_ID_VP9, cfg = "vpcC";
        break;
    default:
        LOG("dsta: codec %.4s not decoded here", (const char *)fds + 4);
        return -1;
    }
    s->w = (int)get_be(fds + 32, 2), s->h = (int)get_be(fds + 34, 2);
    const AVCodec *codec = avcodec_find_decoder(id);
    s->c = avcodec_alloc_context3(codec);
    s->c->width = s->w, s->c->height = s->h;
    // the configuration box, as FFmpeg's extradata
    size_t entry = get_be(fds, 4) < n ? get_be(fds, 4) : n;
    for (size_t i = 8 + 78; i + 8 <= entry;) {
        size_t bs = get_be(fds + i, 4);
        if (bs < 8 || i + bs > entry) {
            break;
        }
        if (!memcmp(fds + i + 4, cfg, 4)) {
            const uint8_t *c = fds + i + 8;
            size_t cn = bs - 8;
            // the bit depth, so the guest makes buffers of the right format before the first frame
            if (id == AV_CODEC_ID_HEVC && cn > 17) {
                s->bits = 8 + (c[17] & 7);   // HEVCDecoderConfigurationRecord: bitDepthLumaMinus8
            } else if (id == AV_CODEC_ID_AV1 && cn > 2) {
                s->bits = (c[2] & 0x40) ? ((c[2] & 0x20) ? 12 : 10) : 8;   // av1C: high_bitdepth, twelve_bit
            } else if (id == AV_CODEC_ID_VP9 && cn > 6) {
                s->bits = c[6] >> 4;   // vpcC (version 1): bitDepth
            } else if (id == AV_CODEC_ID_H264 && cn > 1 && (c[1] == 110 || c[1] == 122 || c[1] == 244)) {
                s->bits = 8;   // High 10 and up would need the SPS; 8 assumed
            }
            if (id != AV_CODEC_ID_VP9) {
                s->c->extradata = av_mallocz(cn + AV_INPUT_BUFFER_PADDING_SIZE);
                memcpy(s->c->extradata, c, cn);
                s->c->extradata_size = (int)cn;
            }
        }
        i += bs;
    }
    s->c->hw_device_ctx = av_buffer_ref(hwdev);
    s->c->get_format = pick_vaapi;
    s->c->extra_hw_frames = 16;   // headroom; decoded frames leave their GPU surfaces as soon as a slot is free
    s->c->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
    int rc = avcodec_open2(s->c, codec, NULL);
    if (rc < 0) {
        LOG("dsta: opening %s: %s", codec->name, av_err2str(rc));
        avcodec_free_context(&s->c);
        return -1;
    }
    s->codec = fourcc;
    if (s->bits != 10) {
        s->bits = 8;
    }
    LOG("session %02x%02x%02x%02x: %.4s %dx%d, %d-bit, %d bytes of configuration", s->uuid[0], s->uuid[1], s->uuid[2],
        s->uuid[3], (const char *)fds + 4, s->w, s->h, s->bits, s->c->extradata_size);
    return 0;
}

// The pixel buffers the guest should make for this session's frames (sent before dsta's reply).
static void send_pba(session *s) {
    bp *d = bp_dict();
    bp_set(d, "Width", bp_int(s->w));
    bp_set(d, "Height", bp_int(s->h));
    bp *pf = bp_array();
    bp_push(pf, bp_int(s->bits == 10 ? FOURCC('x', '4', '2', '0') : FOURCC('4', '2', '0', 'v')));
    bp_set(d, "PixelFormatType", pf);
    bp_set(d, "IOSurfaceProperties", bp_dict());
    bp_set(d, "BytesPerRowAlignment", bp_int(64));
    bp_set(d, "PlaneAlignment", bp_int(256));
    bp_set(d, "PreferRealTimeCacheModeIfEveryoneDoes", bp_bool(1));
    size_t n;
    uint8_t *p = bp_encode(d, &n);
    bp_free(d);
    buf m = {0};
    msg_header(&m, "Dpba", 0, s->uuid, 0);
    field(&m, "pba", "pls", p, n);
    out.msg(&m);
    free(m.p);
    free(p);
}

static void send_demt(session *s, frame_out *f, uint32_t inf) {
    buf m = {0};
    msg_header(&m, "Demt", 2, s->uuid, ++host_req);
    field_s64(&m, "frm", f->frm);
    field_s32(&m, "err", f->err);
    field_u32(&m, "inf", inf);
    if (!f->dropped && !f->err && f->answered) {   // the guest's buffer the frame is in (its pixels may already have left
        field(&m, "uui", "uui", f->uui, 16);          // the GPU: f->f is gone once a slot holds them)
    }
    out.msg(&m);
    free(m.p);
    s->frames_out++;
}

static int free_slot(void) {
    for (int i = 0; i < VV_NSLOTS; i++) {
        if (!slot_busy[i]) {
            return i;
        }
    }
    return -1;
}

// Copy a decoded frame off the GPU into a free slot (packed rows: luma at `stride`, chroma after it), which frees
// its GPU surface at once: frames waiting for the guest's buffers must not hold the decoder's surfaces (with AVPlayer
// reading ahead they ran out and the decoder stopped). 0 when copied, 1 when no slot is free, -1 on failure.
static void collect(session *s);
static void slot_buffer_free(void *opaque, uint8_t *data) {}

// The GPU's own copy into a slot (VA-API video processing into a linear surface over the slot's memory): no CPU
// touches the pixels, ~5 ms for a 4K frame where FFmpeg's read through an uncached mapping took ~21 ms.
static VADisplay dpy;
static VAContextID vpp = VA_INVALID_ID;
static int vpp_broken;
static struct {
    VASurfaceID s;
    int w, h, stride, fourcc;
} slot_va[VV_NSLOTS];
static VASurfaceID slot_surface(int slot, int w, int h, int stride, int fourcc) {
    if (slot_va[slot].s != VA_INVALID_SURFACE && slot_va[slot].s != 0 && slot_va[slot].w == w && slot_va[slot].h == h &&
        slot_va[slot].stride == stride && slot_va[slot].fourcc == fourcc) {
        return slot_va[slot].s;
    }
    if (slot_va[slot].s != VA_INVALID_SURFACE && slot_va[slot].s != 0) {
        vaDestroySurfaces(dpy, &slot_va[slot].s, 1);
    }
    slot_va[slot].s = VA_INVALID_SURFACE;
    uintptr_t ptr = (uintptr_t)(shm + VV_SLOT_OFF + (size_t)slot * VV_SLOT_SIZE);
    int bps = fourcc == VA_FOURCC_P010 ? 2 : 1;
    (void)bps;
    VASurfaceAttribExternalBuffers ext = {0};
    ext.pixel_format = (uint32_t)fourcc;
    ext.width = (uint32_t)w, ext.height = (uint32_t)h;
    ext.data_size = (uint32_t)(((size_t)stride * h * 3 / 2 + 4095) & ~(size_t)4095);   // whole pages, or the driver refuses
    ext.num_planes = 2;
    ext.pitches[0] = ext.pitches[1] = (uint32_t)stride;
    ext.offsets[1] = (uint32_t)((size_t)stride * h);
    ext.buffers = &ptr;
    ext.num_buffers = 1;
    VASurfaceAttrib a[2] = {
        {VASurfaceAttribMemoryType, VA_SURFACE_ATTRIB_SETTABLE, {VAGenericValueTypeInteger, {.i = VA_SURFACE_ATTRIB_MEM_TYPE_USER_PTR}}},
        {VASurfaceAttribExternalBufferDescriptor, VA_SURFACE_ATTRIB_SETTABLE, {VAGenericValueTypePointer, {.p = &ext}}}};
    VASurfaceID sid;
    VAStatus st = vaCreateSurfaces(dpy, fourcc == VA_FOURCC_P010 ? VA_RT_FORMAT_YUV420_10 : VA_RT_FORMAT_YUV420, (unsigned)w,
                                   (unsigned)h, &sid, 1, a, 2);
    if (st != VA_STATUS_SUCCESS) {
        LOG("slot %d: a surface over its memory: %s; copying frames with the CPU", slot, vaErrorStr(st));
        vpp_broken = 1;
        return VA_INVALID_SURFACE;
    }
    slot_va[slot].s = sid, slot_va[slot].w = w, slot_va[slot].h = h, slot_va[slot].stride = stride, slot_va[slot].fourcc = fourcc;
    return sid;
}
static int vpp_copy(VASurfaceID from, VASurfaceID to) {
    if (vpp == VA_INVALID_ID) {
        VAConfigID cfg;
        if (vaCreateConfig(dpy, VAProfileNone, VAEntrypointVideoProc, NULL, 0, &cfg) != VA_STATUS_SUCCESS ||
            vaCreateContext(dpy, cfg, 4096, 4096, VA_PROGRESSIVE, NULL, 0, &vpp) != VA_STATUS_SUCCESS) {
            LOG("no VA-API video processing; copying frames with the CPU");
            vpp_broken = 1;
            return -1;
        }
    }
    VAProcPipelineParameterBuffer pp = {0};
    pp.surface = from;
    VABufferID b;
    if (vaCreateBuffer(dpy, vpp, VAProcPipelineParameterBufferType, sizeof(pp), 1, &pp, &b) != VA_STATUS_SUCCESS) {
        return -1;
    }
    VAStatus st = vaBeginPicture(dpy, vpp, to);
    if (st == VA_STATUS_SUCCESS) {
        st = vaRenderPicture(dpy, vpp, &b, 1);
    }
    if (st == VA_STATUS_SUCCESS) {
        st = vaEndPicture(dpy, vpp);
    }
    if (st == VA_STATUS_SUCCESS) {
        st = vaSyncSurface(dpy, to);
    }
    vaDestroyBuffer(dpy, b);
    return st == VA_STATUS_SUCCESS ? 0 : -1;
}   // the slot's memory is the shared region's
static int download(frame_out *f) {
    int slot = free_slot();
    if (slot < 0) {
        return 1;
    }
    AVHWFramesContext *fc = (AVHWFramesContext *)f->f->hw_frames_ctx->data;
    int bps = fc->sw_format == AV_PIX_FMT_P010 ? 2 : 1;
    int w = f->f->width, h = f->f->height, stride = (w * bps + 127) & ~127;
    if ((((size_t)stride * h * 3 / 2 + 4095) & ~(size_t)4095) > VV_SLOT_SIZE) {
        return -1;
    }
    uint8_t *dst = shm + VV_SLOT_OFF + (size_t)slot * VV_SLOT_SIZE;
    if (!vpp_broken && dpy) {
        VASurfaceID to = slot_surface(slot, w, h, stride, bps == 2 ? VA_FOURCC_P010 : VA_FOURCC_NV12);
        if (to != VA_INVALID_SURFACE && !vpp_copy((VASurfaceID)(uintptr_t)f->f->data[3], to)) {
            slot_busy[slot] = 1;
            f->slot = slot, f->w = w, f->h = h, f->stride = stride, f->bps = bps;
            av_frame_free(&f->f);
            return 0;
        }
    }
    AVFrame *sw = av_frame_alloc();
    sw->format = fc->sw_format;
    sw->width = w, sw->height = h;
    sw->data[0] = dst, sw->linesize[0] = stride;
    sw->data[1] = dst + (size_t)stride * h, sw->linesize[1] = stride;
    sw->buf[0] = av_buffer_create(dst, (size_t)stride * h * 3 / 2, slot_buffer_free, NULL, 0);
    int rc = av_hwframe_transfer_data(sw, f->f, 0);
    av_frame_free(&sw);
    if (rc < 0) {
        LOG("frame %lld: copying it off the GPU: %s", (long long)f->frm, av_err2str(rc));
        return -1;
    }
    slot_busy[slot] = 1;
    f->slot = slot, f->w = w, f->h = h, f->stride = stride, f->bps = bps;
    av_frame_free(&f->f);
    return 0;
}

// Move this session's output along: frames off the GPU into slots, ask for buffers, fill the answered ones and emit
// them in order, and finish a dfin when done.
static void pump(session *s) {
    for (frame_out *f = s->head; f; f = f->next) {
        if (f->f && !f->err && download(f) < 0) {
            f->err = kVTVideoDecoderMalfunctionErr;
            av_frame_free(&f->f);
        }
        if (!f->dropped && !f->err && !f->dbuf_req) {
            buf m = {0};
            f->dbuf_req = ++host_req;
            msg_header(&m, "Dbuf", 2, s->uuid, f->dbuf_req);
            field_s64(&m, "frm", f->frm);
            out.msg(&m);
            free(m.p);
        }
    }
    while (s->head) {
        frame_out *f = s->head;
        if (f->dropped) {
            send_demt(s, f, kVTDecodeInfo_Asynchronous | kVTDecodeInfo_FrameDropped);
        } else if (f->err) {
            send_demt(s, f, kVTDecodeInfo_Asynchronous);
        } else {
            if (!f->answered || f->slot < 0) {
                break;   // in output order: wait for this one's buffer (or a free slot; VV_G_SLOTDONE pumps again)
            }
            out.fill(f->surf, f->slot, f->w, f->h, f->stride, f->bps);
            f->slot = -1;   // the guest frees it (VV_G_SLOTDONE)
            send_demt(s, f, kVTDecodeInfo_Asynchronous);
        }
        s->head = f->next;
        if (!s->head) {
            s->tail = NULL;
        }
        if (f->slot >= 0) {
            slot_busy[f->slot] = 0;
        }
        av_frame_free(&f->f);
        free(f);
    }
    if (s->finishing && !s->head) {
        // frames the decoder never put out (dropped by it) are reported dropped
        for (int i = 0; i < s->npending; i++) {
            frame_out f = {.frm = s->pending[i]};
            send_demt(s, &f, kVTDecodeInfo_Asynchronous | kVTDecodeInfo_FrameDropped);
            free(s->pending_fo[i]);
            s->pending_fo[i] = NULL;
        }
        s->npending = 0;
        buf r = {0};
        msg_header(&r, "dfin", 4, s->uuid, s->fin_req);
        field_s32(&r, "err", 0);
        out.msg(&r);
        free(r.p);
        s->finishing = 0;
        avcodec_flush_buffers(s->c);
        s->nsuppress = 0;
        for (int i = 0; i < s->nsaved; i++) {
            if (s->nsuppress < 64) {
                s->suppress[s->nsuppress++] = (int64_t)(intptr_t)s->saved[i]->opaque;
            }
            AVPacket *p = av_packet_clone(s->saved[i]);
            int rc = avcodec_send_packet(s->c, p);
            for (int tries = 0; rc == AVERROR(EAGAIN) && tries < 3; tries++) {
                collect(s);
                rc = avcodec_send_packet(s->c, p);
            }
            av_packet_free(&p);
        }
        if (s->nsaved) {
            VLOG("session %02x%02x%02x%02x: %d packets replayed after a finish", s->uuid[0], s->uuid[1], s->uuid[2], s->uuid[3],
                 s->nsaved);
            collect(s);
        }
    }
}

// Frames the decoder has ready go to the queue.
static void collect(session *s) {
    AVFrame *fr = av_frame_alloc();
    int rc;
    while ((rc = avcodec_receive_frame(s->c, fr)) >= 0) {
        int64_t frm = (int64_t)(intptr_t)fr->opaque;
        if (fr->flags & AV_FRAME_FLAG_KEY) {   // packets before a key frame are no longer needed for a replay
            int k = 0;
            for (int i = 0; i < s->nsaved; i++) {
                if ((int64_t)(intptr_t)s->saved[i]->opaque < frm) {
                    av_packet_free(&s->saved[i]);
                } else {
                    s->saved[k++] = s->saved[i];
                }
            }
            s->nsaved = k;
        }
        int replayed = 0;
        for (int i = 0; i < s->nsuppress; i++) {
            if (s->suppress[i] == frm) {
                s->suppress[i] = s->suppress[--s->nsuppress];
                replayed = 1;
                break;
            }
        }
        if (replayed) {
            av_frame_unref(fr);
            continue;
        }
        frame_out *f = calloc(1, sizeof(*f));
        f->slot = -1;
        f->frm = frm;
        int dropped = 0;
        for (int i = 0; i < s->npending; i++) {
            if (s->pending[i] == f->frm) {
                dropped = (s->pending_dfl[i] & kVTDecodeFrame_DoNotOutputFrame) != 0;
                if (s->pending_fo[i]) {   // its buffer was asked for already: carry that over
                    frame_out *e = s->pending_fo[i];
                    f->dbuf_req = e->dbuf_req, f->answered = e->answered, f->surf = e->surf, f->err = e->err;
                    memcpy(f->uui, e->uui, 16);
                    free(e);
                }
                s->npending--;
                s->pending[i] = s->pending[s->npending];
                s->pending_dfl[i] = s->pending_dfl[s->npending];
                s->pending_fo[i] = s->pending_fo[s->npending];
                break;
            }
        }
        f->dropped = dropped;
        if (!dropped) {
            f->f = av_frame_clone(fr);
            if (download(f) < 0) {
                f->err = kVTVideoDecoderMalfunctionErr;
                av_frame_free(&f->f);
            }
        }
        if (s->tail) {
            s->tail->next = f;
        } else {
            s->head = f;
        }
        s->tail = f;
        av_frame_unref(fr);
    }
    if (rc != AVERROR(EAGAIN) && rc != AVERROR_EOF) {
        LOG("session %02x%02x%02x%02x: the decoder: %s", s->uuid[0], s->uuid[1], s->uuid[2], s->uuid[3], av_err2str(rc));
    }
    av_frame_free(&fr);
}

// dfrm's 'sbf': a serialized CMSampleBuffer ('sbuf' holding 'opts', 'stia', 'sdat' -- the sample's bytes -- 'nsmp',
// 'ssiz', 'fdsc', 'satt', 'sary').
static const uint8_t *sample_data(const uint8_t *sbf, size_t n, size_t *len) {
    if (n < 8 || memcmp(sbf + 4, "sbuf", 4)) {
        return NULL;
    }
    size_t end = get_be(sbf, 4) < n ? get_be(sbf, 4) : n;
    for (size_t i = 8; i + 8 <= end;) {
        size_t bs = get_be(sbf + i, 4);
        if (bs < 8 || i + bs > end) {
            break;
        }
        if (!memcmp(sbf + i + 4, "sdat", 4)) {
            *len = bs - 8;
            return sbf + i + 8;
        }
        i += bs;
    }
    return NULL;
}

static void on_dfrm(session *s, const msg *m) {
    int64_t frm = field_int(m, "frm", "s64", -1);
    uint32_t dfl = (uint32_t)field_int(m, "dfl", "u32", 0);
    size_t sn = 0, dn = 0;
    const uint8_t *sbf = msg_field(m, "sbf", "sbf", &sn);
    const uint8_t *data = sbf ? sample_data(sbf, sn, &dn) : NULL;
    buf r = {0};
    msg_header(&r, "dfrm", 4, m->uuid, m->req);
    if (!s->c || !data) {
        field_s32(&r, "err", s->c ? kVTVideoDecoderBadDataErr : kVTInvalidSessionErr);
        out.msg(&r);
        free(r.p);
        return;
    }
    AVPacket *p = av_packet_alloc();
    av_new_packet(p, (int)dn);
    memcpy(p->data, data, dn);
    p->opaque = (void *)(intptr_t)frm;
    p->pts = frm;
    if (s->nsaved == s->capsaved) {
        s->capsaved = s->capsaved ? s->capsaved * 2 : 64;
        s->saved = realloc(s->saved, sizeof(AVPacket *) * (size_t)s->capsaved);
    }
    s->saved[s->nsaved++] = av_packet_clone(p);
    // never drop a packet: when the decoder has frames to hand out first, take them and send it again
    int rc = avcodec_send_packet(s->c, p);
    for (int tries = 0; rc == AVERROR(EAGAIN) && tries < 3; tries++) {
        collect(s);
        pump(s);
        rc = avcodec_send_packet(s->c, p);
    }
    av_packet_free(&p);
    s->frames_in++;
    if (rc < 0) {
        LOG("frame %lld: the decoder refused it: %s", (long long)frm, av_err2str(rc));
        field_s32(&r, "err", 0);
        field_u32(&r, "inf", kVTDecodeInfo_Asynchronous);
        out.msg(&r);
        free(r.p);
        frame_out f = {.frm = frm, .err = kVTVideoDecoderBadDataErr};
        send_demt(s, &f, kVTDecodeInfo_Asynchronous);
        return;
    }
    if (s->npending < 256) {
        frame_out *e = NULL;
        if (!(dfl & kVTDecodeFrame_DoNotOutputFrame)) {
            e = calloc(1, sizeof(*e));
            e->frm = frm, e->slot = -1;
            e->dbuf_req = ++host_req;
            buf m = {0};
            msg_header(&m, "Dbuf", 2, s->uuid, e->dbuf_req);
            field_s64(&m, "frm", frm);
            out.msg(&m);
            free(m.p);
        }
        s->pending[s->npending] = frm;
        s->pending_dfl[s->npending] = dfl;
        s->pending_fo[s->npending++] = e;
    }
    field_s32(&r, "err", 0);
    field_u32(&r, "inf", kVTDecodeInfo_Asynchronous);
    out.msg(&r);
    free(r.p);
    collect(s);
    pump(s);
}

// One message from the guest, with the IOSurfaces it carries.
static void engine_msg(const uint8_t *p, size_t n, const struct vv_surf *surfs, int nsurf) {
    msg m;
    if (msg_parse(p, n, &m)) {
        LOG("not a message (%zu bytes)", n);
        return;
    }
    session *s = find_session(m.uuid);
    VLOG("<- %s flags %u req %llu (%zu bytes, %d surfaces)", m.type, m.flags, (unsigned long long)m.req, n, nsurf);
    static int ndump;
    if (verbose && ndump < 400) {   // debugging: the messages themselves, for tools/pvdump.py
        char path[128];
        snprintf(path, sizeof(path), "/root/vgpu/video/dump/%04d-%02x%02x-%s.bin", ndump++, m.uuid[0], m.uuid[1],
                 m.type[0] == '+' ? "_dec" : m.type[0] == '-' ? "=dec" : m.type);
        FILE *f = fopen(path, "wb");
        if (f) {
            fwrite(p, 1, n, f);
            fclose(f);
        }
    }
    if (m.flags & 8) {   // the guest answering one of ours
        if (!strcmp(m.type, "Dbuf") && s) {
            frame_out *hit = NULL;
            for (frame_out *f = s->head; f && !hit; f = f->next) {
                hit = f->dbuf_req == m.req ? f : NULL;
            }
            for (int i = 0; i < s->npending && !hit; i++) {
                hit = s->pending_fo[i] && s->pending_fo[i]->dbuf_req == m.req ? s->pending_fo[i] : NULL;
            }
            if (hit) {
                frame_out *f = hit;
                size_t un = 0;
                const uint8_t *u = msg_field(&m, "uui", "uui", &un);
                int32_t err = (int32_t)field_int(&m, "err", "s32", 0);
                if (err || !u || un != 16 || nsurf < 1) {
                    f->err = err ? err : kVTVideoDecoderMalfunctionErr;
                } else {
                    memcpy(f->uui, u, 16);
                    f->surf = surfs[0].id;
                }
                f->answered = 1;
            }
            pump(s);
        }
        return;
    }
    const char *t = m.type;
    if (!strcmp(t, "dcap")) {   // a codec's capabilities (VTCopyHEVCDecoderCapabilitiesDictionary; Safari checks it)
        uint32_t cod = (uint32_t)field_int(&m, "cod", "s32", 0);
        buf r = {0};
        msg_header(&r, "dcap", 4, m.uuid, m.req);
        // what the host decodes and the guest can be given (8- and 10-bit 4:2:0): HEVC Main, Main 10, Main Still
        // Picture; H.264 Constrained Baseline, Main, High. Anything else, nothing (as Apple's host answers VP9).
        static const int hevc[] = {1, 2, 3}, avc[] = {66, 77, 100};
        const int *profiles = NULL;
        int np = 0, level = 0;
        if (cod == FOURCC('h', 'v', 'c', '1')) {
            profiles = hevc, np = 3, level = 186;   // level 6.2
        } else if (cod == FOURCC('a', 'v', 'c', '1')) {
            profiles = avc, np = 3, level = 52;     // level 5.2
        }
        if (profiles) {
            bp *d = bp_dict(), *per = bp_dict(), *list = bp_array();
            bp_set(d, "VTIsHDRAllowedOnDevice", bp_bool(cod == FOURCC('h', 'v', 'c', '1')));
            for (int i = 0; i < np; i++) {
                char k[16];
                snprintf(k, sizeof(k), "%d", profiles[i]);
                bp *e = bp_dict();
                bp_set(e, "VTIsHardwareAccelerated", bp_bool(1));
                bp_set(e, "VTMaxDecodeLevel", bp_int(level));
                bp_set(e, "VTMaxPlaybackLevel", bp_int(level));
                bp_set(per, k, e);
                bp_push(list, bp_int(profiles[i]));
            }
            bp_set(d, "VTPerProfileSupport", per);
            bp_set(d, "VTSupportedProfiles", list);
            size_t n2;
            uint8_t *pl = bp_encode(d, &n2);
            bp_free(d);
            field(&r, "dca", "pls", pl, n2);
            free(pl);
        } else {
            field(&r, "dca", "pls", "", 0);
        }
        field_u32(&r, "ver", 6);
        out.msg(&r);
        free(r.p);
        return;
    }
    if (!strcmp(t, "decs")) {
        buf r = {0};
        msg_header(&r, "decs", 4, m.uuid, m.req);
        field(&r, "dec", "pls", vv_decs_plist, sizeof(vv_decs_plist));
        field_u32(&r, "ver", 6);
        out.msg(&r);
        free(r.p);
    } else if (!strcmp(t, "+dec")) {
        uint32_t cod = (uint32_t)field_int(&m, "cod", "s32", 0);
        int ok = cod == FOURCC('a', 'v', 'c', '1') || cod == FOURCC('h', 'v', 'c', '1') ||
                 cod == FOURCC('v', 'p', '0', '9');
        buf r = {0};
        msg_header(&r, "+dec", 4, m.uuid, m.req);
        if (!s && ok) {
            for (int i = 0; i < MAX_SESSIONS; i++) {
                if (!sessions[i].used) {
                    s = &sessions[i];
                    s->used = 1;
                    memcpy(s->uuid, m.uuid, 16);
                    s->codec = cod;
                    break;
                }
            }
        }
        field_s32(&r, "err", ok && s ? 0 : kVTCouldNotFindVideoDecoderErr);
        field_u32(&r, "ver", 6);
        field(&r, "hin", "pls", vv_hin_plist, sizeof(vv_hin_plist));
        out.msg(&r);
        free(r.p);
    } else if (!s) {
        if (m.flags & 1) {
            reply_err(&m, kVTInvalidSessionErr);
        }
        VLOG("%s for no session", t);
    } else if (!strcmp(t, "dsta")) {
        size_t fn = 0;
        const uint8_t *fds = msg_field(&m, "fds", "fds", &fn);
        if (!fds || open_decoder(s, fds, fn)) {
            reply_err(&m, kVTVideoDecoderMalfunctionErr);
        } else {
            send_pba(s);
            reply_err(&m, 0);
        }
    } else if (!strcmp(t, "dsup")) {
        buf r = {0};
        msg_header(&r, "dsup", 4, m.uuid, m.req);
        field_s32(&r, "err", 0);
        field(&r, "sup", "pls", vv_sup_plist, sizeof(vv_sup_plist));
        out.msg(&r);
        free(r.p);
    } else if (!strcmp(t, "dcop")) {
        size_t kn = 0;
        const uint8_t *k = msg_field(&m, "key", "pls", &kn);
        char key[128] = "";
        if (k) {
            bp_read_string(k, kn, key, sizeof(key));
        }
        buf r = {0};
        msg_header(&r, "dcop", 4, m.uuid, m.req);
        if (!strcmp(key, "UsingHardwareAcceleratedVideoDecoder")) {
            field_s32(&r, "err", 0);
            field(&r, "val", "pls", vv_true_plist, sizeof(vv_true_plist));
        } else if (!strcmp(key, "SuggestedQualityOfServiceTiers")) {
            field_s32(&r, "err", 0);
            field(&r, "val", "pls", vv_qos_plist, sizeof(vv_qos_plist));
        } else {
            VLOG("dcop %s: not supported", key);
            field_s32(&r, "err", kVTPropertyNotSupportedErr);
        }
        out.msg(&r);
        free(r.p);
    } else if (!strcmp(t, "dfrm")) {
        on_dfrm(s, &m);
    } else if (!strcmp(t, "dfin")) {
        if (s->c) {
            avcodec_send_packet(s->c, NULL);
            collect(s);
            s->finishing = 1;
            s->fin_req = m.req;
            pump(s);
        } else {
            reply_err(&m, 0);
        }
    } else if (!strcmp(t, "dset")) {   // RealTime is accepted; DecompressionSessionOptions refused, as Apple's host does
        size_t kn = 0;
        const uint8_t *k = msg_field(&m, "key", "pls", &kn);
        char key[128] = "";
        if (k) {
            bp_read_string(k, kn, key, sizeof(key));
        }
        reply_err(&m, !strcmp(key, "DecompressionSessionOptions") ? kVTPropertyNotSupportedErr : 0);
    } else if (!strcmp(t, "dinv")) {
        reply_err(&m, 0);
    } else if (!strcmp(t, "-dec")) {
        free_session(s);
    } else {
        static char seen[64][5];
        static int nseen;
        int known = 0;
        for (int i = 0; i < nseen; i++) {
            known |= !strcmp(seen[i], t);
        }
        if (!known && nseen < 64) {
            strcpy(seen[nseen++], t);
            char path[96];
            snprintf(path, sizeof(path), "/root/vgpu/video/unhandled-%s.bin", t);
            FILE *f = fopen(path, "wb");
            if (f) {
                fwrite(p, 1, n, f);
                fclose(f);
            }
        }
        LOG("%s (flags %u): not handled%s", t, m.flags, m.flags & 1 ? "; answered with no error" : "");
        if (m.flags & 1) {
            reply_err(&m, 0);
        }
    }
}

static void engine_slotdone(int slot, int err) {
    if (slot >= 0 && slot < VV_NSLOTS) {
        slot_busy[slot] = 0;
    }
    if (err) {
        VLOG("slot %d: the guest couldn't copy it (%d)", slot, err);
    }
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].used) {
            pump(&sessions[i]);
        }
    }
}
static void engine_uuid_gone(const uint8_t *uuid) {
    session *s = find_session(uuid);
    if (s) {
        free_session(s);
    }
}
static void engine_reset(void) {
    for (int i = 0; i < MAX_SESSIONS; i++) {
        free_session(&sessions[i]);
    }
    memset(slot_busy, 0, sizeof(slot_busy));
}

// ---- the rings -----------------------------------------------------------------------------------------------------

static struct vv_ctl *ctl;
static int ring_put(struct vv_ring *r, uint8_t *base, uint32_t size, uint16_t kind, const uint32_t *args, const void *a,
                    uint32_t na) {
    uint32_t need = VV_ALIGN((uint32_t)sizeof(struct vv_rec) + na);
    uint32_t head = r->head, tail = __atomic_load_n(&r->tail, __ATOMIC_ACQUIRE);
    uint32_t off = head % size, toend = size - off;
    if (toend < need) {
        if (size - (head - tail) < toend + need) {
            return -1;
        }
        struct vv_rec *pad = (struct vv_rec *)(base + off);
        memset(pad, 0, sizeof(*pad));
        pad->len = toend - (uint32_t)sizeof(struct vv_rec);
        pad->kind = VV_PAD;
        head += toend;
        off = 0;
    } else if (size - (head - tail) < need) {
        return -1;
    }
    struct vv_rec *rec = (struct vv_rec *)(base + off);
    memset(rec, 0, sizeof(*rec));
    rec->len = na, rec->kind = kind;
    if (args) {
        memcpy(rec->arg, args, sizeof(rec->arg));
    }
    if (na) {
        memcpy(rec + 1, a, na);
    }
    __atomic_store_n(&r->head, head + need, __ATOMIC_RELEASE);
    return 0;
}

// server state
static int vm_ev = -1, host_ev = -1, shm_fd = -1;
typedef struct ob {
    uint16_t kind;
    uint32_t args[6];
    uint8_t *p;
    uint32_t n;
    struct ob *next;
} ob;
static ob *outbox, *outbox_tail;   // records waiting for room in the host-to-guest ring
static int kicked;

static void h2g(uint16_t kind, const uint32_t *args, const void *p, uint32_t n) {
    if (!outbox && !ring_put(&ctl->h2g, shm + VV_H2G_OFF, VV_H2G_SIZE, kind, args, p, n)) {
        kicked = 1;
        return;
    }
    ob *o = calloc(1, sizeof(*o));
    o->kind = kind;
    if (args) {
        memcpy(o->args, args, sizeof(o->args));
    }
    o->p = malloc(n ? n : 1);
    memcpy(o->p, p, n);
    o->n = n;
    if (outbox_tail) {
        outbox_tail->next = o;
    } else {
        outbox = o;
    }
    outbox_tail = o;
}
static void flush_outbox(void) {
    while (outbox && !ring_put(&ctl->h2g, shm + VV_H2G_OFF, VV_H2G_SIZE, outbox->kind, outbox->args, outbox->p, outbox->n)) {
        ob *o = outbox;
        outbox = o->next;
        if (!outbox) {
            outbox_tail = NULL;
        }
        free(o->p);
        free(o);
        kicked = 1;
    }
}
static void kick_vm(void) {
    if (kicked && vm_ev >= 0) {
        uint64_t one = 1;
        if (write(vm_ev, &one, 8) != 8) {
            LOG("signaling the VM: %s", strerror(errno));
        }
    }
    kicked = 0;
}
static void srv_msg(const buf *m) {
    if (verbose) {
        msg mm;
        if (!msg_parse(m->p, m->n, &mm)) {
            VLOG("-> %s flags %u req %llu (%zu bytes)", mm.type, mm.flags, (unsigned long long)mm.req, m->n);
        }
    }
    h2g(VV_H_MSG, NULL, m->p, (uint32_t)m->n);
}
static void srv_fill(uint32_t surf, int slot, int w, int h, int stride, int bps) {
    uint32_t a[6] = {surf, (uint32_t)slot, (uint32_t)w, (uint32_t)h, (uint32_t)stride, (uint32_t)bps};
    h2g(VV_H_FILL, a, NULL, 0);
}

static void drain_g2h(void) {
    struct vv_ring *r = &ctl->g2h;
    uint8_t *base = shm + VV_G2H_OFF;
    for (;;) {
        uint32_t tail = r->tail, head = __atomic_load_n(&r->head, __ATOMIC_ACQUIRE);
        if (tail == head) {
            break;
        }
        struct vv_rec *rec = (struct vv_rec *)(base + tail % VV_G2H_SIZE);
        uint32_t step = VV_ALIGN((uint32_t)sizeof(struct vv_rec) + rec->len);
        if (rec->len > VV_G2H_SIZE) {
            LOG("guest ring corrupt (record of %u bytes); dropping everything", rec->len);
            __atomic_store_n(&r->tail, head, __ATOMIC_RELEASE);
            break;
        }
        const uint8_t *pay = (const uint8_t *)(rec + 1);
        switch (rec->kind) {
        case VV_PAD:
            break;
        case VV_G_HELLO:
            LOG("guest driver started (run %u)", rec->arg[0]);
            engine_reset();
            break;
        case VV_G_MSG: {
            uint32_t ns = rec->arg[0], ml = rec->arg[1];
            if (ns <= 5 && ns * sizeof(struct vv_surf) + ml <= rec->len) {
                engine_msg(pay + ns * sizeof(struct vv_surf), ml, (const struct vv_surf *)pay, (int)ns);
            }
            break;
        }
        case VV_G_SLOTDONE:
            engine_slotdone((int)rec->arg[0], (int)rec->arg[1]);
            break;
        case VV_G_UUIDGONE:
            if (rec->len >= 16) {
                engine_uuid_gone(pay);
            }
            break;
        default:
            LOG("guest record kind %u?", rec->kind);
        }
        __atomic_store_n(&r->tail, tail + step, __ATOMIC_RELEASE);
    }
}

// ---- the ivshmem server (docs/specs/ivshmem-spec.rst) ---------------------------------------------------------------

static int send_int(int sock, int64_t v, int fd) {
    struct iovec iov = {&v, sizeof(v)};
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct msghdr mh = {.msg_iov = &iov, .msg_iovlen = 1};
    if (fd >= 0) {
        memset(cbuf, 0, sizeof(cbuf));
        mh.msg_control = cbuf;
        mh.msg_controllen = sizeof(cbuf);
        struct cmsghdr *c = CMSG_FIRSTHDR(&mh);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &fd, sizeof(int));
    }
    return sendmsg(sock, &mh, 0) == sizeof(v) ? 0 : -1;
}
// QEMU (peer 1) learns: the protocol version, its id, the memory, peer 0's doorbell (this program) and its own
// interrupt.
static int handshake(int c) {
    return send_int(c, 0, -1) || send_int(c, VV_VM_PEER, -1) || send_int(c, -1, shm_fd) || send_int(c, VV_HOST_PEER, host_ev) ||
           send_int(c, VV_VM_PEER, vm_ev);
}

static volatile sig_atomic_t stop, dump_wanted;
static void on_signal(int s) { stop = 1; }
static void on_usr1(int s) {
    verbose = !verbose;
    av_log_set_level(verbose ? AV_LOG_VERBOSE : AV_LOG_INFO);
}
static void on_usr2(int s) { dump_wanted = 1; }
static void dump_state(void) {
    int busy = 0;
    for (int i = 0; i < VV_NSLOTS; i++) {
        busy += slot_busy[i];
    }
    LOG("state: %d of %d slots busy, outbox %s, g2h %u/%u h2g %u/%u", busy, VV_NSLOTS, outbox ? "waiting" : "empty",
        ctl->g2h.head, ctl->g2h.tail, ctl->h2g.head, ctl->h2g.tail);
    for (int i = 0; i < MAX_SESSIONS; i++) {
        session *s = &sessions[i];
        if (!s->used) {
            continue;
        }
        int q = 0, asked = 0, answered = 0;
        for (frame_out *f = s->head; f; f = f->next) {
            q++, asked += f->dbuf_req != 0, answered += f->answered;
        }
        LOG("  session %02x%02x%02x%02x %.4s %dx%d: %llu in, %llu out, %d pending in the decoder, %d queued (%d asked for a "
            "buffer, %d answered)%s",
            s->uuid[0], s->uuid[1], s->uuid[2], s->uuid[3], (const char *)&s->codec, s->w, s->h,
            (unsigned long long)s->frames_in, (unsigned long long)s->frames_out, s->npending, q, asked, answered,
            s->finishing ? ", finishing" : "");
    }
}

static int serve(const char *path) {
    shm_fd = memfd_create("venera-video", MFD_CLOEXEC);
    if (shm_fd < 0 || ftruncate(shm_fd, VV_SHM_SIZE) < 0) {
        LOG("shared memory: %s", strerror(errno));
        return 1;
    }
    shm = mmap(NULL, VV_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if (shm == MAP_FAILED) {
        LOG("mapping the shared memory: %s", strerror(errno));
        return 1;
    }
    ctl = (struct vv_ctl *)shm;
    memset(ctl, 0, sizeof(*ctl));
    ctl->magic = VV_MAGIC;
    ctl->version = VV_VERSION;
    ctl->host_gen = (uint32_t)time(NULL);
    host_ev = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    vm_ev = eventfd(0, EFD_CLOEXEC);
    int ls = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof(a.sun_path), "%s", path);
    unlink(path);
    if (bind(ls, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(ls, 2) < 0) {
        LOG("listening on %s: %s", path, strerror(errno));
        return 1;
    }
    chmod(path, 0600);
    LOG("serving %s: %u MB shared, %d frame slots", path, VV_SHM_SIZE >> 20, VV_NSLOTS);
    int client = -1;
    while (!stop) {
        struct pollfd fds[3] = {{ls, POLLIN, 0}, {host_ev, POLLIN, 0}, {client, POLLIN, 0}};
        int rc = poll(fds, client >= 0 ? 3 : 2, 50);
        if (rc < 0 && errno != EINTR) {
            LOG("poll: %s", strerror(errno));
            break;
        }
        if (fds[0].revents & POLLIN) {
            int c = accept4(ls, NULL, NULL, SOCK_CLOEXEC);
            if (c >= 0) {
                if (client >= 0) {
                    LOG("a new VM connection replaces the old one");
                    close(client);
                }
                client = c;
                engine_reset();
                memset(&ctl->g2h, 0, sizeof(ctl->g2h));
                memset(&ctl->h2g, 0, sizeof(ctl->h2g));
                ctl->host_gen++;
                LOG(handshake(c) ? "handshake with QEMU failed" : "QEMU connected");
            }
        }
        if (client >= 0 && (fds[2].revents & (POLLIN | POLLHUP | POLLERR))) {
            char x[64];
            if (read(client, x, sizeof(x)) <= 0) {
                LOG("QEMU disconnected (the VM stopped)");
                close(client);
                client = -1;
                engine_reset();
            }
        }
        if (fds[1].revents & POLLIN) {
            uint64_t v;
            while (read(host_ev, &v, 8) == 8) {
            }
        }
        drain_g2h();
        flush_outbox();
        kick_vm();
        if (dump_wanted) {
            dump_wanted = 0;
            dump_state();
        }
    }
    unlink(path);
    return 0;
}

// ---- replay: recorded guest messages against the engine, this program acting as the guest -------------------------

typedef struct rq {
    buf m;
    struct vv_surf s;
    int ns;
    struct rq *next;
} rq;
static rq *rq_head, *rq_tail;
static uint32_t next_surface = 500;
static void rp_msg(const buf *m) {
    msg mm;
    if (msg_parse(m->p, m->n, &mm)) {
        return;
    }
    int32_t err = (int32_t)field_int(&mm, "err", "s32", 0);
    printf("  host -> %s flags %u req %llu, %zu bytes, err %d", mm.type, mm.flags, (unsigned long long)mm.req, m->n, err);
    if (!strcmp(mm.type, "Demt") || !strcmp(mm.type, "Dbuf")) {
        printf(", frame %lld, inf %lld", (long long)field_int(&mm, "frm", "s64", -1), (long long)field_int(&mm, "inf", "u32", -1));
    }
    printf("\n");
    if (!strcmp(mm.type, "Dbuf") && (mm.flags & 2)) {   // answer as the guest: a made-up surface
        rq *q = calloc(1, sizeof(*q));
        msg_header(&q->m, "Dbuf", 8, mm.uuid, mm.req);
        field_s32(&q->m, "err", 0);
        uint8_t u[16];
        for (int i = 0; i < 16; i++) {
            u[i] = (uint8_t)rand();
        }
        field(&q->m, "uui", "uui", u, 16);
        q->s.id = next_surface++;
        q->ns = 1;
        if (rq_tail) {
            rq_tail->next = q;
        } else {
            rq_head = q;
        }
        rq_tail = q;
    }
}
static void rp_fill(uint32_t surf, int slot, int w, int h, int stride, int bps) {
    const uint8_t *y = shm + VV_SLOT_OFF + (size_t)slot * VV_SLOT_SIZE;
    printf("  host fills surface %u from slot %d: %dx%d stride %d, luma %u %u %u %u\n", surf, slot, w, h, stride, y[0],
           y[w / 2 * bps], y[(size_t)(h / 2) * stride + (size_t)w / 2 * bps], y[(size_t)(h - 1) * stride + (size_t)(w - 1) * bps]);
    slot_busy[slot] = 0;   // copied at once
}
static void run_queue(void) {
    while (rq_head) {
        rq *q = rq_head;
        rq_head = q->next;
        if (!rq_head) {
            rq_tail = NULL;
        }
        engine_msg(q->m.p, q->m.n, &q->s, q->ns);
        free(q->m.p);
        free(q);
    }
}
static int replay(int argc, char **argv) {
    shm = mmap(NULL, VV_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);   // page-aligned, as the real one
    out.msg = rp_msg, out.fill = rp_fill;
    for (int i = 0; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) {
            continue;
        }
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        fseek(f, 0, SEEK_SET);
        uint8_t *p = malloc((size_t)n);
        if (fread(p, 1, (size_t)n, f) != (size_t)n) {
            n = 0;
        }
        fclose(f);
        msg m;
        if (!msg_parse(p, (size_t)n, &m)) {
            printf("guest -> %s (%s, %ld bytes)\n", m.type, argv[i], n);
            engine_msg(p, (size_t)n, NULL, 0);
            run_queue();
        }
        free(p);
    }
    return 0;
}

int main(int argc, char **argv) {
    int a = 1;
    if (a < argc && !strcmp(argv[a], "-v")) {
        verbose = 1, a++;
    }
    if (a >= argc) {
        fprintf(stderr, "venera-videod [-v] SOCKET | -replay MSG...\n");
        return 2;
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGUSR1, on_usr1);
    signal(SIGUSR2, on_usr2);
    setvbuf(stdout, NULL, _IOLBF, 0);
    int rc = av_hwdevice_ctx_create(&hwdev, AV_HWDEVICE_TYPE_VAAPI, "/dev/dri/renderD128", NULL, 0);
    if (rc < 0) {
        LOG("VA-API on /dev/dri/renderD128: %s", av_err2str(rc));
        return 1;
    }
    dpy = ((AVVAAPIDeviceContext *)((AVHWDeviceContext *)hwdev->data)->hwctx)->display;
    for (int i = 0; i < VV_NSLOTS; i++) {
        slot_va[i].s = VA_INVALID_SURFACE;
    }
    if (!strcmp(argv[a], "-replay")) {
        return replay(argc - a - 1, argv + a + 1);
    }
    out.msg = srv_msg, out.fill = srv_fill;
    return serve(argv[a]);
}
