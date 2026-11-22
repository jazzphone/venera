// streamprobe: a display-stream reader that keeps a Screen Sharing client's picture, to look for trails with nobody
// connected (round 23).
//
// Screen Sharing's agent takes the screen from ScreenCaptureKit (an SCStream of the display with a queue depth and a
// minimum frame interval; each frame's SCStreamFrameInfoDirtyRects; IOSurfaceLock and IOSurfaceGetBaseAddress to read
// it) and sends what the dirty rectangles say changed. A region read wrong stays wrong on the client until something
// redraws it: the trails the owner saw behind a dragged window when the stream's surfaces had no twin. This keeps a
// "client" image the same way, copying each frame's dirty rectangles out of its surface, and when the stream stops
// compares it with the last frame, whole, in 8x8 tiles: a tile that differs is a trail (with how far apart, as a faint
// glass edge differs by a few levels). It also checks each read against WindowServer's stamp of the write-back (the
// flag file streamsum, VGMTLLockWait.m) and whether the surface changed while it was read.
//
// Only Screen Sharing's agent may read the screen (Screen Recording), and launch constraints let only Apple's own job
// start it, so tools/streamprobe.sh gives that job's next launch this library (launchctl debug --environment
// DYLD_INSERT_LIBRARIES=..., AMFI being off in these VMs) and kickstarts it, with nobody connected. The constructor
// never returns to the agent's main: it reads the stream for VG_SP_SECS seconds, writes its report and images to
// VG_SP_OUT, and exits. It loads the GPU bundle first, so the lock hook is in place and its locks wait as the agent's
// do. Environment:
//   VG_SP_SECS      seconds to read (default 10)
//   VG_SP_OUT       output prefix (default /var/tmp/vgpu/sp/sp; the agent runs as the user, who must be able to write)
//   VG_SP_LOCKOPTS  IOSurfaceLock options (default 1, read-only; the agent's are 1)
//   VG_SP_HOLD      ms to hold each frame before reading it, as a slower client would (default 0)
//   VG_SP_ASYNC     1: read each frame later on another queue (the frame kept meanwhile), as the agent's encoder
//                   does; with VG_SP_HOLD, that much later
//   VG_SP_QUEUE     the stream's queue depth (default 8, the agent's)
//   VG_SP_SIZE      WxH: ask ScreenCaptureKit for a capture of that size instead of the display's pixels (Screen
//                   Sharing's agent picks its own; this is the probe's only)
//   VG_SP_EVERY     1: also compare the client image with each whole frame as it comes (8x8 tiles), so a region that
//                   a frame's dirty rectangles left wrong is seen even if a later frame redraws it; counts, the
//                   largest difference, and the first frames that differ with their regions
//   VG_SP_EVERY=2   also each frame's surface against its own picture when it was last handed out, to tell which
//                   side is off where the client is: a surface that kept its old pixels where frames since had dirty
//                   rectangles ("stale": that surface missed an update), or one that changed where no dirty rectangle
//                   since said so ("undamaged": the damage left it out); per frame with a big difference, and totals;
//                   and whether the pixels a frame got wrong outside its dirty rectangles are already the next frame's
//                   ("ahead": the frame held what the next frame's damage reports); each bad frame (more than 32 off,
//                   VG_SP_SAVE of them, default 8) saved as OUT-fN-client/frame/prev/next.png
//   VG_SP_TRACE     1: every frame's surface, seed, wall-clock time and dirty rectangles to OUT-trace.txt, to set
//                   beside WindowServer's synclog and drawdiff lines; with the flag file streamsum on, the write-back's
//                   stamp (seed, generation: synclog's "stamped" line names its command buffer) and how long before
//                   the callback ScreenCaptureKit's display time was
//   VG_SP_RAW       1: also the last frame as OUT-last.raw (BGRA, rows packed), to check against what the display
//                   shows (QEMU's VNC: vncgrab.py on the host)
//   VG_SP_SCALE     dirty rectangles' scale to pixels (default 1: they are in the stream's pixels)
//   VG_SP_NOHOOK    1: don't load the GPU bundle here (Metal may load it anyway)
//   VG_SP_CG        1: a CGDisplayStream instead
//   VG_SP_MOVES     1 or 2 (CGDisplayStream only): apply moved rectangles as copies inside the client image (VNC's
//                   CopyRect) and read only the refreshed ones; 1 takes them as where they came from, 2 as where they
//                   went
// Build: tools/build-tools.sh (build/streamprobe.dylib).
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

enum { kBands = 16 };
typedef struct {
    uint32_t seed, frame;
    uint64_t band[kBands];
} stamp_t;   // VGMTLLockWait.m's vg_stream_stamp

static void sums(const uint8_t *base, size_t w, size_t h, size_t bpr, uint64_t band[kBands]) {   // vg_stream_sums
    for (int b = 0; b < kBands; b++) {
        uint64_t x = 1469598103934665603ull;
        for (size_t y = h * b / kBands & ~(size_t)3; y < h * (b + 1) / kBands; y += 4) {
            const uint32_t *row = (const uint32_t *)(base + y * bpr);
            for (size_t i = 0; i < w; i += 4) {
                x = (x ^ row[i]) * 1099511628211ull;
            }
        }
        band[b] = x;
    }
}

static void png_chunk(FILE *f, const char *type, const uint8_t *data, uint32_t len) {
    uint8_t be[4] = {len >> 24, len >> 16, len >> 8, len};
    fwrite(be, 1, 4, f);
    fwrite(type, 1, 4, f);
    if (len) {
        fwrite(data, 1, len, f);
    }
    uLong crc = crc32(0, (const Bytef *)type, 4);
    crc = crc32(crc, data, len);
    uint8_t c[4] = {crc >> 24, crc >> 16, crc >> 8, crc};
    fwrite(c, 1, 4, f);
}

// BGRA to an RGB PNG, every `step`th pixel (2: half size)
static void write_png(const char *path, const uint8_t *bgra, size_t w, size_t h, size_t stride, size_t step) {
    size_t ow = w / step, oh = h / step, rowBytes = 1 + ow * 3, rawLen = rowBytes * oh;
    uint8_t *raw = malloc(rawLen);
    uLongf zlen = compressBound(rawLen);
    uint8_t *z = malloc(zlen);
    if (!raw || !z) {
        free(raw), free(z);
        return;
    }
    for (size_t y = 0; y < oh; y++) {
        uint8_t *o = raw + y * rowBytes;
        const uint8_t *in = bgra + y * step * stride;
        *o++ = 0;
        for (size_t x = 0; x < ow; x++, in += 4 * step) {
            *o++ = in[2], *o++ = in[1], *o++ = in[0];
        }
    }
    FILE *f = compress2(z, &zlen, raw, rawLen, 3) == Z_OK ? fopen(path, "wb") : NULL;
    if (f) {
        static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a};
        fwrite(sig, 1, 8, f);
        uint8_t ihdr[13] = {ow >> 24, ow >> 16, ow >> 8, ow, oh >> 24, oh >> 16, oh >> 8, oh, 8, 2, 0, 0, 0};
        png_chunk(f, "IHDR", ihdr, 13);
        png_chunk(f, "IDAT", z, (uint32_t)zlen);
        png_chunk(f, "IEND", NULL, 0);
        fclose(f);
    }
    free(z), free(raw);
}

// CGDisplayStream is obsoleted in the macOS 15+ SDKs but still in CoreGraphics (Screen Sharing uses it): by name.
typedef const CGRect *(*get_rects_fn)(CGDisplayStreamUpdateRef, CGDisplayStreamUpdateRectType, size_t *);
typedef CGDisplayStreamRef (*create_fn)(CGDirectDisplayID, size_t, size_t, int32_t, CFDictionaryRef, dispatch_queue_t,
                                        CGDisplayStreamFrameAvailableHandler);
typedef CGError (*start_fn)(CGDisplayStreamRef);
static get_rects_fn gGetRects;
typedef void (*get_delta_fn)(CGDisplayStreamUpdateRef, CGFloat *, CGFloat *);
static get_delta_fn gGetDelta;
static int gMoves, gAsync;
static uint64_t gMovedRects, gMovedPixels;
static CFStringRef cg_key(const char *name) {
    CFStringRef *k = dlsym(RTLD_DEFAULT, name);
    return k ? *k : CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static FILE *gOut;
static uint8_t *gShadow;
static size_t gW, gH, gBpr;
static double gScale;
static IOSurfaceLockOptions gOpts;
static int gHoldMs;
static IOSurfaceRef gLast;
static uint64_t gFrames, gRects, gPixels, gIdle, gLockNs, gLockMax, gSame, gDiffer, gSeedMoved, gNoStamp, gTorn;
static int gEvery;
static const char *gOutPrefix;
static uint64_t gEveryFrames, gEveryBig, gEveryTiles;
static int gEveryMaxDiff;

// The client image against the whole frame in 8x8 tiles (VG_SP_EVERY): tiles that differ, their bounding box and
// the largest channel difference.
static size_t compare_tiles(const uint8_t *base, size_t bpr, size_t w, size_t h, int *maxDiff, size_t box[4]) {
    size_t tiles = 0;
    box[0] = w, box[1] = h, box[2] = 0, box[3] = 0;
    *maxDiff = 0;
    for (size_t ty = 0; ty < h; ty += 8) {
        for (size_t tx = 0; tx < w; tx += 8) {
            const size_t len = (tx + 8 <= w ? 8 : w - tx) * 4;
            BOOL d = NO;
            for (size_t y = ty; y < ty + 8 && y < h; y++) {
                const uint8_t *a = gShadow + y * gBpr + tx * 4, *b = base + y * bpr + tx * 4;
                if (memcmp(a, b, len)) {
                    d = YES;
                    for (size_t i = 0; i < len; i++) {
                        int diff = abs((int)a[i] - (int)b[i]);
                        *maxDiff = diff > *maxDiff ? diff : *maxDiff;
                    }
                }
            }
            if (d) {
                tiles++;
                box[0] = MIN(box[0], tx), box[1] = MIN(box[1], ty), box[2] = MAX(box[2], tx + 8), box[3] = MAX(box[3], ty + 8);
            }
        }
    }
    return tiles;
}
// VG_SP_EVERY=2: each stream surface's picture when it was last handed out, and the frame each pixel was last in a
// dirty rectangle (frame + 1; 0 never)
enum { kSurfs = 16 };
typedef struct {
    uint32_t id, seed;
    uint64_t frame;
    uint8_t *pic;
} surf_t;
static surf_t gSurf[kSurfs];
static uint32_t *gDamagedAt;
typedef struct {
    uint64_t px, frames;
    int maxDiff;
    size_t box[4];
} cls_t;
enum { kStale, kUndamaged, kOther, kClasses };
static const char *kClassName[kClasses] = {"stale", "undamaged", "other"};
static cls_t gCls[kClasses], gSurfUndamaged;   // where the client was off, by class; a surface's undamaged changes
static uint64_t gSurfTurns, gSurfUndamagedTurns, gSurfUndamagedBig;
static FILE *gTrace;
static uint64_t gDisplayTime;   // the frame's SCStreamFrameInfoDisplayTime (mach absolute time), 0 when none
static int gSaveLeft = -1;      // VG_SP_SAVE: how many bad frames to save as pictures (EVERY=2)
// the last frame's pixels where the client was off, outside that frame's dirty rectangles (undamaged or other): at the
// next frame, whether they already showed it ("ahead": the frame held the next frame's pixels, damage a frame late)
static uint8_t *gPrevOff;
static const uint8_t *gPrevPic;
static uint64_t gAhead, gAheadDamaged, gNotAhead, gAheadFrames, gNotAheadFrames;
static void cls_add(cls_t *c, size_t x, size_t y, int diff) {
    if (!c->px++) {
        c->box[0] = x, c->box[1] = y, c->box[2] = x + 1, c->box[3] = y + 1;
    }
    c->maxDiff = diff > c->maxDiff ? diff : c->maxDiff;
    c->box[0] = MIN(c->box[0], x), c->box[1] = MIN(c->box[1], y);
    c->box[2] = MAX(c->box[2], x + 1), c->box[3] = MAX(c->box[3], y + 1);
}
static int px_diff(const uint8_t *a, const uint8_t *b) {
    int d = 0;
    for (int i = 0; i < 4; i++) {
        int x = abs((int)a[i] - (int)b[i]);
        d = x > d ? x : d;
    }
    return d;
}
// This frame (number `frame`, on surface s) against the client image and the surface's own last picture.
static void surf_check(IOSurfaceRef s, uint32_t seed, const uint8_t *base, size_t bpr, size_t w, size_t h, uint64_t frame,
                       int clientMax) {
    const uint32_t id = IOSurfaceGetID(s);
    surf_t *sf = NULL;
    for (int i = 0; i < kSurfs && !sf; i++) {
        if (gSurf[i].pic && gSurf[i].id == id) {
            sf = &gSurf[i];
        }
    }
    BOOL first = NO;
    for (int i = 0; i < kSurfs && !sf; i++) {
        if (!gSurf[i].pic && (gSurf[i].pic = malloc(w * h * 4))) {
            sf = &gSurf[i], sf->id = id, first = YES;
        }
    }
    if (!sf) {
        return;
    }
    if (gPrevPic && gPrevOff) {   // the last frame's off pixels against this frame
        uint64_t ahead = 0, aheadDamaged = 0, not = 0;
        for (size_t y = 0; y < h; y++) {
            const uint8_t *off = gPrevOff + y * w, *cur = base + y * bpr, *prev = gPrevPic + y * w * 4;
            const uint32_t *dmg = gDamagedAt + y * w;
            for (size_t x = 0; x < w; x++) {
                if (!off[x]) {
                    continue;
                }
                if (!memcmp(cur + 4 * x, prev + 4 * x, 4)) {
                    ahead++;
                    aheadDamaged += dmg[x] == frame + 1;
                } else {
                    not++;
                }
            }
        }
        gAhead += ahead, gAheadDamaged += aheadDamaged, gNotAhead += not;
        gAheadFrames += ahead > not, gNotAheadFrames += not >= ahead && not;
        static int said;
        if ((ahead || not) && said++ < 40) {
            fprintf(gOut, "  frame %llu: of the last frame's off pixels, %llu already as this frame (%llu in its dirty "
                    "rectangles), %llu not\n", (unsigned long long)frame, (unsigned long long)ahead,
                    (unsigned long long)aheadDamaged, (unsigned long long)not);
        }
        memset(gPrevOff, 0, w * h);
        gPrevPic = NULL;
    }
    if (!gPrevOff) {
        gPrevOff = calloc(w * h, 1);
    }
    if (!first) {
        cls_t c[kClasses] = {{0}}, u = {0};
        const uint64_t since = sf->frame + 1;   // dirty rectangles of frames after the surface's last turn
        for (size_t y = 0; y < h; y++) {
            const uint8_t *cur = base + y * bpr, *pic = sf->pic + y * w * 4, *cli = gShadow + y * gBpr;
            const BOOL picSame = !memcmp(cur, pic, w * 4), cliSame = !memcmp(cur, cli, w * 4);
            if (picSame && cliSame) {
                continue;
            }
            const uint32_t *dmg = gDamagedAt + y * w;
            for (size_t x = 0; x < w; x++) {
                const BOOL changed = !picSame && memcmp(cur + 4 * x, pic + 4 * x, 4);
                const BOOL damaged = dmg[x] > since;
                if (changed && !damaged) {
                    cls_add(&u, x, y, px_diff(cur + 4 * x, pic + 4 * x));
                }
                if (!cliSame && memcmp(cur + 4 * x, cli + 4 * x, 4)) {
                    int k = !changed && damaged ? kStale : changed && !damaged ? kUndamaged : kOther;
                    const int d = px_diff(cur + 4 * x, cli + 4 * x);
                    cls_add(&c[k], x, y, d);
                    if (gPrevOff && k != kStale && d > 32 && gDamagedAt[y * w + x] != frame + 1) {
                        gPrevOff[y * w + x] = 1;
                    }
                }
            }
        }
        gSurfTurns++;
        if (u.px) {
            gSurfUndamagedTurns++;
            gSurfUndamagedBig += u.maxDiff > 32;
            gSurfUndamaged.px += u.px;
            gSurfUndamaged.maxDiff = MAX(gSurfUndamaged.maxDiff, u.maxDiff);
        }
        for (int k = 0; k < kClasses; k++) {
            if (c[k].px) {
                gCls[k].frames++, gCls[k].px += c[k].px, gCls[k].maxDiff = MAX(gCls[k].maxDiff, c[k].maxDiff);
            }
        }
        static int said;
        if ((clientMax > 32 || u.maxDiff > 32) && said++ < 40) {
            fprintf(gOut, "  frame %llu surface %u (seed %u, its last turn frame %llu seed %u):", (unsigned long long)frame,
                    id, seed, (unsigned long long)sf->frame, sf->seed);
            for (int k = 0; k < kClasses; k++) {
                if (c[k].px) {
                    fprintf(gOut, " %s %llu px up to %d in %zu,%zu-%zu,%zu;", kClassName[k], (unsigned long long)c[k].px,
                            c[k].maxDiff, c[k].box[0], c[k].box[1], c[k].box[2], c[k].box[3]);
                }
            }
            if (u.px) {
                fprintf(gOut, " surface changed undamaged %llu px up to %d in %zu,%zu-%zu,%zu", (unsigned long long)u.px,
                        u.maxDiff, u.box[0], u.box[1], u.box[2], u.box[3]);
            }
            fprintf(gOut, "\n");
        }
    }
    for (size_t y = 0; y < h; y++) {
        memcpy(sf->pic + y * w * 4, base + y * bpr, w * 4);
    }
    sf->frame = frame, sf->seed = seed;
    gPrevPic = sf->pic;
}
static uint64_t gFirst, gLastAt;
static double gMaxX, gMaxY;

static void process(IOSurfaceRef s, const CGRect *r, size_t n, const CGRect *mr, size_t nm, CGFloat dx, CGFloat dy) {
    if (gHoldMs) {
        usleep(gHoldMs * 1000);
    }
    uint64_t t0 = now_ns();
    uint32_t seed = 0;
    if (IOSurfaceLock(s, gOpts, &seed) != KERN_SUCCESS) {
        fprintf(gOut, "lock failed on surface %u\n", IOSurfaceGetID(s));
        return;
    }
    uint64_t locked = now_ns() - t0;
    gLockNs += locked;
    gLockMax = locked > gLockMax ? locked : gLockMax;
    const uint8_t *base = IOSurfaceGetBaseAddress(s);
    const size_t bpr = IOSurfaceGetBytesPerRow(s), w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s);
    // what we read against WindowServer's stamp of its write-back (the flag file streamsum)
    uint64_t band[kBands], after[kBands];
    sums(base, w, h, bpr, band);
    stamp_t st;
    CFTypeRef v = IOSurfaceCopyValue(s, CFSTR("VeneraWriteBackSums"));
    BOOL have = v && CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength(v) == sizeof(st);
    if (have) {
        memcpy(&st, CFDataGetBytePtr(v), sizeof(st));
    }
    if (v) {
        CFRelease(v);
    }
    uint32_t differ = 0;
    for (int b = 0; have && b < kBands; b++) {
        differ |= (band[b] != st.band[b]) << b;
    }
    if (!have) {
        gNoStamp++;
    } else if (differ) {
        if (gDiffer++ < 30) {
            fprintf(gOut, "frame %llu surface %u: read differs from write-back %u in bands 0x%04x "
                    "(seed %u, stamped %u, "
                    "lock %.2f ms)\n", (unsigned long long)gFrames, IOSurfaceGetID(s), st.frame, differ,
                    IOSurfaceGetSeed(s), st.seed, locked / 1e6);
        }
    } else {
        gSame++;
    }
    if (have && IOSurfaceGetSeed(s) != st.seed) {
        gSeedMoved++;
    }
    if (!gShadow || w != gW || h != gH) {   // the first frame: all of it
        free(gShadow);
        gW = w, gH = h, gBpr = w * 4;
        gShadow = malloc(gBpr * h);
        for (size_t y = 0; y < h; y++) {
            memcpy(gShadow + y * gBpr, base + y * bpr, w * 4);
        }
        if (gEvery >= 2) {
            free(gDamagedAt);
            gDamagedAt = calloc(w * h, sizeof(uint32_t));
        }
    } else {
        for (size_t i = 0; i < nm; i++) {   // a move: the client copies what it has (VG_SP_MOVES)
            CGRect src = gMoves == 1 ? mr[i] : CGRectOffset(mr[i], -dx, -dy);
            CGRect dst = CGRectOffset(src, dx, dy);
            CGRect all = CGRectMake(0, 0, w, h);
            src = CGRectIntersection(CGRectOffset(CGRectIntersection(dst, all), -dx, -dy), all);
            dst = CGRectOffset(src, dx, dy);
            if (CGRectIsEmpty(src)) {
                continue;
            }
            size_t sx = (size_t)src.origin.x, sy = (size_t)src.origin.y, cw = (size_t)src.size.width,
                   ch = (size_t)src.size.height, tx = (size_t)dst.origin.x, ty = (size_t)dst.origin.y;
            uint8_t *tmp = malloc(cw * ch * 4);
            for (size_t y = 0; tmp && y < ch; y++) {
                memcpy(tmp + y * cw * 4, gShadow + (sy + y) * gBpr + sx * 4, cw * 4);
            }
            for (size_t y = 0; tmp && y < ch; y++) {
                memcpy(gShadow + (ty + y) * gBpr + tx * 4, tmp + y * cw * 4, cw * 4);
            }
            free(tmp);
            gMovedRects++, gMovedPixels += cw * ch;
        }
        for (size_t i = 0; i < n; i++) {
            gMaxX = fmax(gMaxX, CGRectGetMaxX(r[i])), gMaxY = fmax(gMaxY, CGRectGetMaxY(r[i]));
            size_t x0 = (size_t)fmax(0, floor(CGRectGetMinX(r[i]) * gScale));
            size_t y0 = (size_t)fmax(0, floor(CGRectGetMinY(r[i]) * gScale));
            size_t x1 = (size_t)fmin(w, ceil(CGRectGetMaxX(r[i]) * gScale));
            size_t y1 = (size_t)fmin(h, ceil(CGRectGetMaxY(r[i]) * gScale));
            for (size_t y = y0; y < y1 && x1 > x0; y++) {
                memcpy(gShadow + y * gBpr + x0 * 4, base + y * bpr + x0 * 4, (x1 - x0) * 4);
                for (size_t x = x0; gDamagedAt && x < x1; x++) {
                    gDamagedAt[y * w + x] = (uint32_t)gFrames + 1;
                }
            }
            gPixels += x1 > x0 && y1 > y0 ? (x1 - x0) * (y1 - y0) : 0;
        }
        gRects += n;
    }
    if (gTrace) {
        double bx0 = 1e9, by0 = 1e9, bx1 = 0, by1 = 0;
        for (size_t i = 0; i < n; i++) {
            bx0 = fmin(bx0, CGRectGetMinX(r[i])), by0 = fmin(by0, CGRectGetMinY(r[i]));
            bx1 = fmax(bx1, CGRectGetMaxX(r[i])), by1 = fmax(by1, CGRectGetMaxY(r[i]));
        }
        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tm;
        localtime_r(&tv.tv_sec, &tm);
        static mach_timebase_info_data_t tb;
        if (!tb.denom) {
            mach_timebase_info(&tb);
        }
        fprintf(gTrace, "%llu %.3f %02d:%02d:%02d.%03d surface %u seed %u rects %zu", (unsigned long long)gFrames,
                now_ns() / 1e6, tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000), IOSurfaceGetID(s), seed, n);
        // the write-back's stamp (flag file streamsum): its seed and generation, which synclog's "stamped" line ties
        // to the command buffer that wrote it; and when ScreenCaptureKit says the frame was shown, against now
        if (have) {
            fprintf(gTrace, " stamp seed %u gen %u%s", st.seed, st.frame, st.seed == seed ? "" : " (not this seed)");
        } else {
            fprintf(gTrace, " no stamp");
        }
        if (gDisplayTime) {
            fprintf(gTrace, " display %.3f ms before the callback",
                    ((double)mach_absolute_time() - (double)gDisplayTime) * tb.numer / tb.denom / 1e6);
        }
        if (n) {
            fprintf(gTrace, " bounds %.0f,%.0f-%.0f,%.0f", bx0, by0, bx1, by1);
        }
        for (size_t i = 0; i < n; i++) {
            fprintf(gTrace, " [%.0f,%.0f %.0fx%.0f]", r[i].origin.x, r[i].origin.y, r[i].size.width, r[i].size.height);
        }
        fprintf(gTrace, "\n");
    }
    if (gEvery && gShadow && w == gW && h == gH) {   // the client image against this whole frame
        int maxDiff = 0;
        size_t box[4];
        size_t tiles = compare_tiles(base, bpr, w, h, &maxDiff, box);
        const uint8_t *prevPic = gPrevPic;   // the frame before, for the pictures below
        static int saveNext;
        static uint64_t saveNextOf;
        if (saveNext) {   // the frame after a saved one
            saveNext = 0;
            char path[512];
            if (gEvery >= 2) {
                snprintf(path, sizeof(path), "%s-f%llu-next.png", gOutPrefix, (unsigned long long)saveNextOf);
            } else {
                snprintf(path, sizeof(path), "%s-big-next.png", gOutPrefix);
            }
            write_png(path, base, w, h, bpr, 1);
        }
        if (gEvery >= 2 && maxDiff > 32 && gSaveLeft != 0) {
            // each bad frame (VG_SP_SAVE of them, default 8): the client as it stands, the frame, the frames before
            // and after; the one before saved now, before the surface check below takes its picture's place
            gSaveLeft = gSaveLeft < 0 ? (getenv("VG_SP_SAVE") ? atoi(getenv("VG_SP_SAVE")) : 8) : gSaveLeft;
            if (gSaveLeft > 0) {
                gSaveLeft--;
                char path[512];
                const unsigned long long f = (unsigned long long)gFrames;
                snprintf(path, sizeof(path), "%s-f%llu-client.png", gOutPrefix, f);
                write_png(path, gShadow, gW, gH, gBpr, 1);
                snprintf(path, sizeof(path), "%s-f%llu-frame.png", gOutPrefix, f);
                write_png(path, base, w, h, bpr, 1);
                if (prevPic) {
                    snprintf(path, sizeof(path), "%s-f%llu-prev.png", gOutPrefix, f);
                    write_png(path, prevPic, w, h, w * 4, 1);
                }
                saveNext = 1, saveNextOf = gFrames;
                fprintf(gOut, "    (saved as %s-f%llu-*.png)\n", gOutPrefix, f);
            }
        }
        if (gEvery >= 2 && gDamagedAt) {
            surf_check(s, seed, base, bpr, w, h, gFrames, tiles ? maxDiff : 0);
        }
        if (tiles) {
            gEveryFrames++, gEveryTiles += tiles;
            gEveryBig += maxDiff > 32;
            gEveryMaxDiff = maxDiff > gEveryMaxDiff ? maxDiff : gEveryMaxDiff;
            if (gEveryFrames <= 3 || (maxDiff > 32 && gEveryBig <= 20)) {   // the first few, and every big one
                fprintf(gOut, "frame %llu: client differs in %zu tiles within %zu,%zu-%zu,%zu, up to %d apart (%zu dirty "
                        "rects)\n", (unsigned long long)gFrames, tiles, box[0], box[1], box[2], box[3], maxDiff, n);
                for (size_t i = 0; maxDiff > 32 && i < n && i < 8; i++) {
                    fprintf(gOut, "    dirty rect %.0f,%.0f %.0fx%.0f\n", r[i].origin.x, r[i].origin.y, r[i].size.width,
                            r[i].size.height);
                }
            }
            static int saved;
            if (gEvery < 2 && maxDiff > 32 && maxDiff > saved) {   // the worst so far, as pictures (EVERY=1)
                saved = maxDiff;
                char path[512];
                snprintf(path, sizeof(path), "%s-big-client.png", gOutPrefix);
                write_png(path, gShadow, gW, gH, gBpr, 1);
                snprintf(path, sizeof(path), "%s-big-frame.png", gOutPrefix);
                write_png(path, base, w, h, bpr, 1);
                if (prevPic) {
                    snprintf(path, sizeof(path), "%s-big-prev.png", gOutPrefix);
                    write_png(path, prevPic, w, h, w * 4, 1);
                    saveNext = 1;
                }
                fprintf(gOut, "    (saved as the worst so far: frame %llu)\n", (unsigned long long)gFrames);
            }
        }
    }
    sums(base, w, h, bpr, after);   // did it change while we read it?
    if (memcmp(band, after, sizeof(band))) {
        if (gTorn++ < 30) {
            fprintf(gOut, "frame %llu surface %u changed while read\n", (unsigned long long)gFrames, IOSurfaceGetID(s));
        }
    }
    IOSurfaceUnlock(s, gOpts, NULL);
    gFrames++;
    gLastAt = now_ns();
    gFirst = gFirst ? gFirst : gLastAt;
    CFRetain(s);
    if (gLast) {
        CFRelease(gLast);
    }
    gLast = s;
}

static void cg_frame(CGDisplayStreamFrameStatus status, IOSurfaceRef s, CGDisplayStreamUpdateRef update) {
    if (status != kCGDisplayStreamFrameStatusFrameComplete || !s) {
        gIdle += status == kCGDisplayStreamFrameStatusFrameIdle;
        return;
    }
    size_t n = 0, nm = 0;
    const CGRect *r = update && gGetRects ? gGetRects(update, gMoves ? kCGDisplayStreamUpdateRefreshedRects
                                                                       : kCGDisplayStreamUpdateDirtyRects, &n) : NULL;
    const CGRect *mr = update && gGetRects && gMoves ? gGetRects(update, kCGDisplayStreamUpdateMovedRects, &nm) : NULL;
    CGFloat dx = 0, dy = 0;
    if (nm && gGetDelta) {
        gGetDelta(update, &dx, &dy);
    }
    process(s, r, n, mr, nm, dx, dy);
}

// ScreenCaptureKit, as the agent: each complete frame's surface and dirty rectangles.
static void sck_frame(CMSampleBufferRef sb) {
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    NSDictionary *info = atts && CFArrayGetCount(atts) ? (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0) : nil;
    if ([info[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) {
        gIdle++;
        return;
    }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    IOSurfaceRef s = pb ? CVPixelBufferGetIOSurface(pb) : NULL;
    if (!s) {
        return;
    }
    gDisplayTime = [info[SCStreamFrameInfoDisplayTime] unsignedLongLongValue];
    NSArray *dirty = info[SCStreamFrameInfoDirtyRects];
    CGRect *r = calloc(dirty.count + 1, sizeof(CGRect));
    size_t n = 0;
    for (NSDictionary *d in dirty) {
        if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d, &r[n])) {
            n++;
        }
    }
    process(s, r, n, NULL, 0, 0, 0);
    free(r);
}

@interface VGSPOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property dispatch_queue_t work;
@end
@implementation VGSPOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) {
        return;
    }
    if (!gAsync) {
        sck_frame(sb);
        return;
    }
    CFRetain(sb);   // kept (its surface not handed out again) until read
    dispatch_async(self.work, ^{
        sck_frame(sb);
        CFRelease(sb);
    });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    fprintf(gOut, "stream stopped: %s\n", error.description.UTF8String);
}
@end

static void finish(const char *out) {
    fprintf(gOut, "frames %llu (idle %llu) over %.1f s, %llu dirty rects, %.1f Mpx copied, rects reach %.0f,%.0f "
            "(scale %.2f); locks %.3f ms mean, %.2f max\n", (unsigned long long)gFrames, (unsigned long long)gIdle,
            (gLastAt - gFirst) / 1e9, (unsigned long long)gRects, gPixels / 1e6, gMaxX, gMaxY, gScale,
            gFrames ? gLockNs / 1e6 / gFrames : 0, gLockMax / 1e6);
    if (gMoves) {
        fprintf(gOut, "moves (%s): %llu moved rects, %.1f Mpx moved\n", gMoves == 1 ? "from" : "to",
                (unsigned long long)gMovedRects, gMovedPixels / 1e6);
    }
    if (gEvery) {
        fprintf(gOut, "every frame: %llu of %llu frames left the client off (%llu by more than 32), %llu tiles in all, up to "
                "%d apart\n", (unsigned long long)gEveryFrames, (unsigned long long)gFrames, (unsigned long long)gEveryBig,
                (unsigned long long)gEveryTiles, gEveryMaxDiff);
    }
    if (gEvery >= 2) {
        fprintf(gOut, "by surface: %llu turns (a surface handed out again), %llu changed where no dirty rectangle since "
                "its last turn said (%llu by more than 32, %llu px, up to %d)\n", (unsigned long long)gSurfTurns,
                (unsigned long long)gSurfUndamagedTurns, (unsigned long long)gSurfUndamagedBig,
                (unsigned long long)gSurfUndamaged.px, gSurfUndamaged.maxDiff);
        fprintf(gOut, "  off by more than 32 outside a frame's dirty rectangles, at the next frame: %llu px already as "
                "it (%llu of them in its dirty rectangles; mostly so in %llu frames), %llu px not (%llu frames)\n",
                (unsigned long long)gAhead, (unsigned long long)gAheadDamaged, (unsigned long long)gAheadFrames,
                (unsigned long long)gNotAhead, (unsigned long long)gNotAheadFrames);
        for (int k = 0; k < kClasses; k++) {
            fprintf(gOut, "  client off, %s: %llu frames, %llu px, up to %d\n", kClassName[k],
                    (unsigned long long)gCls[k].frames, (unsigned long long)gCls[k].px, gCls[k].maxDiff);
        }
    }
    fprintf(gOut, "stamps: %llu same, %llu differ, %llu seed moved, %llu unstamped; %llu changed while read\n",
            (unsigned long long)gSame, (unsigned long long)gDiffer, (unsigned long long)gSeedMoved,
            (unsigned long long)gNoStamp, (unsigned long long)gTorn);
    if (!gLast || !gShadow) {
        fprintf(gOut, "no frames\n");
        return;
    }
    IOSurfaceLock(gLast, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = IOSurfaceGetBaseAddress(gLast);
    const size_t bpr = IOSurfaceGetBytesPerRow(gLast);
    size_t tiles = 0, x0 = gW, y0 = gH, x1 = 0, y1 = 0;
    int maxDiff = 0;
    uint8_t *mask = calloc(gBpr * gH, 1);   // the tiles that differ, white
    for (size_t ty = 0; ty < gH; ty += 8) {
        for (size_t tx = 0; tx < gW; tx += 8) {
            BOOL d = NO;
            for (size_t y = ty; y < ty + 8 && y < gH; y++) {
                size_t len = (tx + 8 <= gW ? 8 : gW - tx) * 4;
                const uint8_t *a = gShadow + y * gBpr + tx * 4, *b = base + y * bpr + tx * 4;
                if (memcmp(a, b, len)) {
                    d = YES;
                    for (size_t i = 0; i < len; i++) {   // how far apart: a faint edge, or a window's worth
                        int diff = abs((int)a[i] - (int)b[i]);
                        maxDiff = diff > maxDiff ? diff : maxDiff;
                    }
                }
            }
            if (d) {
                tiles++;
                x0 = MIN(x0, tx), y0 = MIN(y0, ty), x1 = MAX(x1, tx + 8), y1 = MAX(y1, ty + 8);
                for (size_t y = ty; y < ty + 8 && y < gH; y++) {
                    memset(mask + y * gBpr + tx * 4, 0xff, (tx + 8 <= gW ? 8 : gW - tx) * 4);
                }
            }
        }
    }
    fprintf(gOut, "TRAILS: %zu of %zu tiles differ from the last frame", tiles, ((gW + 7) / 8) * ((gH + 7) / 8));
    if (tiles) {
        fprintf(gOut, ", within %zu,%zu-%zu,%zu, channels up to %d apart", x0, y0, x1, y1, maxDiff);
    }
    fprintf(gOut, "\n");
    char path[512];
    snprintf(path, sizeof(path), "%s-client.png", out);
    write_png(path, gShadow, gW, gH, gBpr, 2);
    snprintf(path, sizeof(path), "%s-last.png", out);
    write_png(path, base, gW, gH, bpr, 2);
    if (getenv("VG_SP_RAW")) {
        snprintf(path, sizeof(path), "%s-last.raw", out);
        FILE *f = fopen(path, "wb");
        for (size_t y = 0; f && y < gH; y++) {
            fwrite(base + y * bpr, 1, gW * 4, f);
        }
        if (f) {
            fclose(f);
            fprintf(gOut, "last frame: %s (%zux%zu BGRA)\n", path, gW, gH);
        }
    }
    if (tiles) {
        snprintf(path, sizeof(path), "%s-mask.png", out);
        write_png(path, mask, gW, gH, gBpr, 2);
    }
    free(mask);
    IOSurfaceUnlock(gLast, kIOSurfaceLockReadOnly, NULL);
}

static void cg_run(CGDirectDisplayID d, size_t w, size_t h, dispatch_queue_t q, dispatch_queue_t work, double secs) {
    gGetRects = (get_rects_fn)dlsym(RTLD_DEFAULT, "CGDisplayStreamUpdateGetRects");
    gGetDelta = (get_delta_fn)dlsym(RTLD_DEFAULT, "CGDisplayStreamUpdateGetMovedRectsDelta");
    create_fn create = (create_fn)dlsym(RTLD_DEFAULT, "CGDisplayStreamCreateWithDispatchQueue");
    start_fn start = (start_fn)dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
    start_fn stop = (start_fn)dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
    if (!gGetRects || !create || !start || !stop) {
        fprintf(gOut, "no CGDisplayStream in this macOS\n");
        _exit(2);
    }
    NSDictionary *props = @{(__bridge NSString *)cg_key("kCGDisplayStreamQueueDepth") : @8,
                            (__bridge NSString *)cg_key("kCGDisplayStreamShowCursor") : @NO};
    CGDisplayStreamRef stream = create(d, w, h, 'BGRA', (__bridge CFDictionaryRef)props,
        q, ^(CGDisplayStreamFrameStatus status, uint64_t t, IOSurfaceRef s, CGDisplayStreamUpdateRef u) {
            if (!gAsync) {
                cg_frame(status, s, u);
                return;
            }
            if (s) {   // kept, and in use, until read
                CFRetain(s);
                IOSurfaceIncrementUseCount(s);
            }
            if (u) {
                CFRetain(u);
            }
            dispatch_async(work, ^{
                cg_frame(status, s, u);
                if (s) {
                    IOSurfaceDecrementUseCount(s);
                    CFRelease(s);
                }
                if (u) {
                    CFRelease(u);
                }
            });
        });
    CGError e = stream ? start(stream) : kCGErrorFailure;
    if (e != kCGErrorSuccess) {
        fprintf(gOut, "no display stream (error %d): is this ScreensharingAgent, with Screen Recording?\n", e);
        _exit(2);
    }
    usleep((useconds_t)(secs * 1e6));
    stop(stream);
}

static void sck_run(CGDirectDisplayID d, size_t w, size_t h, dispatch_queue_t q, dispatch_queue_t work, double secs) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block SCShareableContent *content = nil;
    __block NSError *err = nil;
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
        content = c, err = e;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    SCDisplay *display = nil;
    for (SCDisplay *x in content.displays) {
        display = x.displayID == d ? x : display;
    }
    if (!display) {
        fprintf(gOut, "no shareable display: %s\n", err.description.UTF8String ?: "timed out");
        _exit(2);
    }
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    SCStreamConfiguration *cfg = [SCStreamConfiguration new];
    cfg.width = w, cfg.height = h;
    const char *size = getenv("VG_SP_SIZE");   // a capture smaller than the display (WxH pixels), the probe's only
    unsigned sw = 0, sh = 0;
    if (size && sscanf(size, "%ux%u", &sw, &sh) == 2 && sw && sh) {
        cfg.width = sw, cfg.height = sh;
        fprintf(gOut, "capture requested at %ux%u (the display is %zux%zu)\n", sw, sh, w, h);
    }
    cfg.pixelFormat = 'BGRA';
    cfg.queueDepth = getenv("VG_SP_QUEUE") ? atoi(getenv("VG_SP_QUEUE")) : 8;
    cfg.minimumFrameInterval = CMTimeMake(1, 60);
    cfg.showsCursor = NO;
    VGSPOutput *o = [VGSPOutput new];
    o.work = work;
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:o];
    NSError *e = nil;
    if (![stream addStreamOutput:o type:SCStreamOutputTypeScreen sampleHandlerQueue:q error:&e]) {
        fprintf(gOut, "addStreamOutput: %s\n", e.description.UTF8String);
        _exit(2);
    }
    [stream startCaptureWithCompletionHandler:^(NSError *e2) {
        err = e2;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (err) {
        fprintf(gOut, "startCapture: %s\n", err.description.UTF8String);
        _exit(2);
    }
    fprintf(gOut, "ScreenCaptureKit stream %zux%zu, queue depth %ld\n", w, h, (long)cfg.queueDepth);
    usleep((useconds_t)(secs * 1e6));
    [stream stopCaptureWithCompletionHandler:^(NSError *e3) {
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

__attribute__((constructor)) static void streamprobe(void) {
    const char *secsEnv = getenv("VG_SP_SECS");
    if (!secsEnv) {
        return;   // inserted somewhere else by mistake: do nothing
    }
    @autoreleasepool {
        const char *out = getenv("VG_SP_OUT") ?: "/var/tmp/vgpu/sp/sp";
        gOutPrefix = out;
        char path[512];
        snprintf(path, sizeof(path), "%s.txt", out);
        gOut = fopen(path, "w") ?: stderr;
        setvbuf(gOut, NULL, _IOLBF, 0);
        const char *opts = getenv("VG_SP_LOCKOPTS");
        gOpts = opts ? (IOSurfaceLockOptions)atoi(opts) : kIOSurfaceLockReadOnly;
        gHoldMs = getenv("VG_SP_HOLD") ? atoi(getenv("VG_SP_HOLD")) : 0;
        gMoves = getenv("VG_SP_MOVES") ? atoi(getenv("VG_SP_MOVES")) : 0;
        gAsync = getenv("VG_SP_ASYNC") ? atoi(getenv("VG_SP_ASYNC")) : 0;
        gEvery = getenv("VG_SP_EVERY") ? atoi(getenv("VG_SP_EVERY")) : 0;
        if (getenv("VG_SP_TRACE") && atoi(getenv("VG_SP_TRACE"))) {
            snprintf(path, sizeof(path), "%s-trace.txt", out);
            gTrace = fopen(path, "w");
        }
        const char *hook = "none";
        if (!getenv("VG_SP_NOHOOK")) {   // the GPU bundle, and with it the lock hook
            void *b = dlopen("/Library/GPUBundles/VirtioGPUMetal.bundle/Contents/MacOS/VirtioGPUMetal", RTLD_NOW);
            hook = b ? "GPU bundle loaded" : dlerror();
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        CGDirectDisplayID d = CGMainDisplayID();
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(d);
        size_t w = CGDisplayModeGetPixelWidth(mode), h = CGDisplayModeGetPixelHeight(mode);
        gScale = getenv("VG_SP_SCALE") && atof(getenv("VG_SP_SCALE")) > 0 ? atof(getenv("VG_SP_SCALE")) : 1;
        CGDisplayModeRelease(mode);
        fprintf(gOut, "streamprobe in %s (pid %d), %s, Metal %s, display %ux%zu px, lock options 0x%x, "
                      "hold %d ms%s%s\n",
                getprogname(), getpid(), hook, dev.name.UTF8String ?: "none", (unsigned)w, h, (unsigned)gOpts, gHoldMs,
                gAsync ? ", read async" : "", gMoves ? ", moves applied" : "");
        dispatch_queue_t q = dispatch_queue_create("streamprobe", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_t work = gAsync ? dispatch_queue_create("streamprobe.read", DISPATCH_QUEUE_SERIAL) : q;
        if (getenv("VG_SP_CG")) {
            cg_run(d, w, h, q, work, atof(secsEnv));
        } else {
            sck_run(d, w, h, q, work, atof(secsEnv));
        }
        dispatch_sync(q, ^{});
        dispatch_sync(work, ^{
            finish(out);
        });
        fclose(gOut);
        if (gTrace) {
            fclose(gTrace);
        }
        _exit(0);
    }
}
