// A CPU lock that waits for the GPU, as on a Mac (round 23).
//
// A normal IOSurfaceLock waits for GPU work still in flight on the surface (only kIOSurfaceLockAvoidSync skips that),
// and Screen Sharing relies on it: SkyLight hands ScreensharingAgent each display-stream frame as soon as WindowServer's
// command buffer is scheduled, and the agent locks the surface and reads it. Here the GPU's pixels reach the surface's
// CPU memory only at the write-back after completion, so 0.1.12 made WindowServer wait for that before handing the
// frame over (the trails fix) -- and while someone shares the screen, that wait costs WindowServer up to half its
// frames (VM 109: 17.5 ms frame gaps alone, 31-33 ms sharing).
//
// Now the reader waits instead, as on a Mac:
// - In the processes the flag file VirtioGPUMetal-lockwait names (ScreensharingAgent; off when there is no file),
//   IOSurfaceLock is replaced by a copy of itself that first waits while the surface is marked "write pending". The
//   exported IOSurfaceLock is a stub (NULL check, the surface's client object, a tail jump to the real lock), so the
//   replacement re-does it exactly, after checking its bytes; another macOS build's stub is left alone.
// - The first time such a reader locks a display-stream surface (its name has "DisplayStream"), it tags the surface
//   (VeneraReaderWaits). Only for tagged surfaces does WindowServer mark "write pending" (VeneraPending) when it
//   records the write-back, clear it once the write-back is in, and skip its own wait. Every other surface -- one
//   another capture app reads, a screenshot's -- keeps the writer's wait.
//
// Off by default. Measured on VM 109 with the owner connected over Screen Sharing: with a moderate drag WindowServer
// went from 25.2 ms frame gaps (waiting) to 17.6 ms (as without sharing) and the agent's frames came more evenly; with
// fast sweeps of a large window both ways gave ~33 ms and the same stalls (WindowServer's own frame time is the limit
// there). The owner felt no improvement, and once more pauses during fast drags (the agent's thread blocked up to
// ~50 ms in a lock). The flag file lockwaitmeasure times the agent's display-stream locks without waiting (every 5 s:
// frames, gaps, waits).
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <string.h>
#import "objects.h"

BOOL vg_debug_flag(const char *name);

static CFStringRef const kVgPending = CFSTR("VeneraPending");
static CFStringRef const kVgReaderWaits = CFSTR("VeneraReaderWaits");

// ---- the writer's side -----------------------------------------------------------------------------------------------

// YES when a reader that waits has tagged t's surface (looked up again now and then until it has).
BOOL vg_reader_waits(VGMTLTexture *t) {
    while (t && t->_parent) {
        t = t->_parent;
    }
    if (!t || !t->_surface) {
        return NO;
    }
    if (t->_readerWaits) {
        return t->_readerWaits > 0;
    }
    if (t->_readerChecks++ % 30) {   // an IPC each: every 30th write until a reader tags it
        return NO;
    }
    CFTypeRef v = IOSurfaceCopyValue(t->_surface, kVgReaderWaits);
    if (v) {
        CFRelease(v);
        t->_readerWaits = 1;
        static int said;
        if (said++ < 8) {
            vglog("lockwait: surface %u %lux%lu is read by a reader that waits: marked pending at its writes, not waited "
                  "for", IOSurfaceGetID(t->_surface), (unsigned long)t->_width, (unsigned long)t->_height);
        }
        return YES;
    }
    return NO;
}

void vg_lockwait_mark(VGMTLTexture *t, BOOL pending) {
    while (t && t->_parent) {
        t = t->_parent;
    }
    if (!t || !t->_surface) {
        return;
    }
    if (pending) {
        IOSurfaceSetValue(t->_surface, kVgPending, kCFBooleanTrue);
    } else {
        IOSurfaceRemoveValue(t->_surface, kVgPending);
    }
}

// ---- the reader's side -----------------------------------------------------------------------------------------------

typedef kern_return_t (*vg_lock_inner_fn)(void *client, IOSurfaceLockOptions options, uint32_t *seed);
static vg_lock_inner_fn gInner;          // the real lock, where the stub jumps
static const intptr_t *gClientOffset;    // the stub's ivar offset (of the surface's client object)
static os_unfair_lock gSeenLock = OS_UNFAIR_LOCK_INIT;
enum { kSeen = 64 };
static uint32_t gSeenId[kSeen];
static int8_t gSeenStream[kSeen];   // 1 a display stream's surface (tagged), 0 not
static int gSeenN;
static _Atomic uint64_t gWaits, gWaitNs, gTimeouts;

// Every 5 s while a display stream is read: how many of its frames were locked, the gaps between them (a histogram)
// and how long the locks waited (round 23, measuring Screen Sharing's smoothness).
static os_unfair_lock gStatLock = OS_UNFAIR_LOCK_INIT;
static uint64_t gStatStart, gLastLock, gStatN, gStatWaitNs, gStatWaitMax, gStatGapMax, gStatGapSum;
static uint32_t gGapHist[7];   // <20 <30 <40 <60 <100 <200 more ms
static void vg_lockwait_stat(uint64_t now, uint64_t waited) {
    os_unfair_lock_lock(&gStatLock);
    if (!gStatStart) {
        gStatStart = now;
    }
    if (gLastLock && now - gLastLock < 1000000000ull) {
        uint64_t gap = now - gLastLock, ms = gap / 1000000;
        gGapHist[ms < 20 ? 0 : ms < 30 ? 1 : ms < 40 ? 2 : ms < 60 ? 3 : ms < 100 ? 4 : ms < 200 ? 5 : 6]++;
        gStatGapSum += gap;
        gStatGapMax = gap > gStatGapMax ? gap : gStatGapMax;
    }
    gLastLock = now;
    gStatN++;
    gStatWaitNs += waited;
    gStatWaitMax = waited > gStatWaitMax ? waited : gStatWaitMax;
    if (now - gStatStart >= 5000000000ull) {
        uint32_t gaps = 0;
        for (int i = 0; i < 7; i++) {
            gaps += gGapHist[i];
        }
        vglog("lockwait 5 s: %llu stream frames locked, gaps ms <20:%u <30:%u <40:%u <60:%u <100:%u <200:%u more:%u "
              "mean %.1f max %.1f; waits mean %.2f max %.2f ms",
              (unsigned long long)gStatN, gGapHist[0], gGapHist[1], gGapHist[2], gGapHist[3], gGapHist[4], gGapHist[5],
              gGapHist[6], gaps ? gStatGapSum / 1e6 / gaps : 0, gStatGapMax / 1e6, gStatWaitNs / 1e6 / gStatN,
              gStatWaitMax / 1e6);
        gStatStart = now, gStatN = gStatWaitNs = gStatWaitMax = gStatGapMax = gStatGapSum = 0;
        memset(gGapHist, 0, sizeof(gGapHist));
    }
    os_unfair_lock_unlock(&gStatLock);
}

static BOOL gMeasureOnly;   // the flag file lockwaitmeasure: time the stream's frames, but neither tag nor wait

static BOOL vg_is_stream_surface(IOSurfaceRef s) {
    uint32_t sid = IOSurfaceGetID(s);
    os_unfair_lock_lock(&gSeenLock);
    for (int i = 0; i < gSeenN; i++) {
        if (gSeenId[i] == sid) {
            BOOL r = gSeenStream[i];
            os_unfair_lock_unlock(&gSeenLock);
            return r;
        }
    }
    os_unfair_lock_unlock(&gSeenLock);
    BOOL stream = NO;
    CFTypeRef name = IOSurfaceCopyValue(s, kIOSurfaceName);
    if (name) {
        stream = CFGetTypeID(name) == CFStringGetTypeID() &&
                 CFStringFind((CFStringRef)name, CFSTR("DisplayStream"), 0).location != kCFNotFound;
        CFRelease(name);
    }
    if (stream && !gMeasureOnly) {
        IOSurfaceSetValue(s, kVgReaderWaits, kCFBooleanTrue);
    }
    os_unfair_lock_lock(&gSeenLock);
    int slot = gSeenN < kSeen ? gSeenN++ : (int)(sid % kSeen);   // ids are reused only once a surface is gone
    gSeenId[slot] = sid;
    gSeenStream[slot] = stream;
    os_unfair_lock_unlock(&gSeenLock);
    if (stream) {
        static int said;
        if (said++ < 8) {
            vglog("lockwait: surface %u is a display stream's: tagged, its locks wait for its pending writes", sid);
        }
    }
    return stream;
}

static kern_return_t vg_surface_lock_hook(IOSurfaceRef s, IOSurfaceLockOptions options, uint32_t *seed) {
    if (!s) {
        return (kern_return_t)0xe00002c2;   // kIOReturnBadArgument, as the stub answers
    }
    if (!(options & kIOSurfaceLockAvoidSync) && vg_is_stream_surface(s)) {
        uint64_t t0 = 0;
        for (int i = 0; !gMeasureOnly; i++) {
            CFTypeRef v = IOSurfaceCopyValue(s, kVgPending);
            if (!v) {
                break;
            }
            CFRelease(v);
            if (!t0) {
                t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            }
            if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0 > 100000000ull) {   // 100 ms: a writer that went away
                gTimeouts++;
                break;
            }
            usleep(i < 20 ? 100 : 500);
        }
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        vg_lockwait_stat(now, t0 ? now - t0 : 0);
        if (t0) {
            gWaits++;
            gWaitNs += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
            uint64_t n = gWaits;
            if (n == 1 || n % 1000 == 0) {
                vglog("lockwait: %llu waits for a pending write, %.2f ms each on average, %llu gave up at 100 ms",
                      (unsigned long long)n, gWaitNs / 1e6 / n, (unsigned long long)gTimeouts);
            }
        }
    }
    void *client = *(void **)((char *)s + *gClientOffset);
    return gInner(client, options, seed);
}

// The stub as Intel IOSurface (26.x) has it, with its ivar slot and jump target read out; NO when it's another one.
static BOOL vg_lockwait_install(void) {
    const uint8_t *p = dlsym(RTLD_DEFAULT, "IOSurfaceLock");
    // push rbp; mov rbp,rsp; test rdi,rdi; je +0x14; lea rax,[rip+X]; mov rax,[rax]; mov rdi,[rdi+rax]; pop rbp;
    // jmp REAL; mov eax,0xe00002c2; pop rbp; ret
    static const uint16_t stub[] = {0x55, 0x48, 0x89, 0xe5, 0x48, 0x85, 0xff, 0x74, 0x14, 0x48, 0x8d, 0x05,
                                    0x100, 0x100, 0x100, 0x100, 0x48, 0x8b, 0x00, 0x48, 0x8b, 0x3c, 0x07, 0x5d,
                                    0xe9, 0x100, 0x100, 0x100, 0x100, 0xb8, 0xc2, 0x02, 0x00, 0xe0, 0x5d, 0xc3};
    if (!p) {
        return NO;
    }
    for (size_t i = 0; i < sizeof(stub) / sizeof(*stub); i++) {
        if (stub[i] != 0x100 && p[i] != stub[i]) {
            vglog("lockwait: IOSurfaceLock isn't the stub it should be (another macOS build?): left as it is");
            return NO;
        }
    }
    int32_t lea, jmp;
    memcpy(&lea, p + 12, 4);
    memcpy(&jmp, p + 25, 4);
    gClientOffset = (const intptr_t *)(p + 16 + lea);
    gInner = (vg_lock_inner_fn)(p + 29 + jmp);
    // movabs rax, hook; jmp rax (12 bytes, inside the stub: nothing jumps into them but the stub itself)
    uint8_t patch[12] = {0x48, 0xb8};
    uintptr_t hook = (uintptr_t)vg_surface_lock_hook;
    memcpy(patch + 2, &hook, 8);
    patch[10] = 0xff, patch[11] = 0xe0;
    vm_address_t page = (vm_address_t)p & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t len = ((vm_address_t)p + sizeof(patch) - page + vm_page_size - 1) & ~(vm_size_t)(vm_page_size - 1);
    if (vm_protect(mach_task_self(), page, len, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        vglog("lockwait: IOSurfaceLock's page can't be made writable: left as it is");
        return NO;
    }
    memcpy((void *)p, patch, sizeof(patch));
    vm_protect(mach_task_self(), page, len, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return YES;
}

// The processes that read display streams and wait: the names in the flag file lockwait (none without it).
static BOOL vg_lockwait_wanted(void) {
    NSString *s = [NSString stringWithContentsOfFile:@"/Library/GPUBundles/VirtioGPUMetal-lockwait"
                                            encoding:NSUTF8StringEncoding error:NULL];
    if (!s) {
        return NO;
    }
    NSArray *names = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        componentsSeparatedByString:@"\n"];
    return [names containsObject:@(getprogname())];
}

__attribute__((constructor)) static void vg_lockwait_init(void) {
    @autoreleasepool {
        gMeasureOnly = vg_debug_flag("lockwaitmeasure");
        if (vg_lockwait_wanted() && vg_lockwait_install()) {
            vglog(gMeasureOnly ? "lockwait: this process's display-stream locks are timed, not made to wait (lockwaitmeasure)"
                               : "lockwait: this process's IOSurfaceLock waits for a display stream's pending writes");
        }
    }
}
