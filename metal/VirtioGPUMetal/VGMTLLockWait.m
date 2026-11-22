// A CPU lock that waits for the GPU, as on a Mac (round 23).
//
// A normal IOSurfaceLock waits for GPU work still in flight on the surface (only kIOSurfaceLockAvoidSync skips that),
// and Screen Sharing relies on it: SkyLight hands ScreensharingAgent each display-stream frame as soon as WindowServer's
// command buffer is scheduled, and the agent locks the surface and reads it. Here the GPU's pixels reach the surface's
// CPU memory only at the write-back after completion, so 0.1.12 made WindowServer wait for that before handing the
// frame over (the trails fix) -- and while someone shares the screen, that wait costs WindowServer up to half its
// frames (VM 109: 17.5 ms frame gaps alone, 31-33 ms sharing).
//
// An opted-in reader tags a display-stream surface after subscribing to Darwin notifications. The writer
// publishes a write's generation before handing the surface over, then clears it and wakes readers after
// writing the CPU pixels. Only one asynchronous write can be pending per surface. A second submit uses the
// writer's normal wait so an earlier completion cannot clear a later pending write.
//
// A reader pins the generation it sees when it enters IOSurfaceLock. Wakes prompt it to check the
// surface's metadata; a subsequent generation does not extend that lock's wait. The hook cannot see
// SkyLight's frame identity before the lock.
//
// On by default since round 23 (the owner's call after an A/B on VM 109: no trails either way, fast sweeps 17.4-17.6
// ms frame gaps against 19.9-23.3 ms with the writer waiting, "slightly smoother"): WindowServer offers deferred
// write-backs and ScreensharingAgent waits for them. The flag file VirtioGPUMetal-lockwait names other reader
// processes instead (WindowServer always writes); VirtioGPUMetal-nolockwait turns it all off (the 0.1.12 behavior).
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <notify.h>
#include <os/lock.h>
#include <os/os_sync_wait_on_address.h>
#include <stdatomic.h>
#include <string.h>
#import "objects.h"

static CFStringRef const kVgPending = CFSTR("VeneraPendingGeneration");
static CFStringRef const kVgReaderWaits = CFSTR("VeneraReaderWakeEnabled");
static const char kVgWriteBackNotification[] = "org.venera.metal.display-stream-writeback";
static _Atomic uint32_t gWakeSequence;
static os_unfair_lock gWriterLock = OS_UNFAIR_LOCK_INIT;
static int64_t gNextGeneration;

static int64_t vg_pending_generation(IOSurfaceRef surface) {
    int64_t generation = 0;
    CFTypeRef value = IOSurfaceCopyValue(surface, kVgPending);
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &generation);
        }
        CFRelease(value);
    }
    return generation;
}

static VGMTLTexture *vg_lockwait_root(VGMTLTexture *t) {
    while (t && t->_parent) {
        t = t->_parent;
    }
    return t;
}

BOOL vg_lockwait_begin(VGMTLTexture *t) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        enabled = access("/Library/GPUBundles/VirtioGPUMetal-nolockwait", F_OK) != 0 &&
                  (!strcmp(getprogname(), "WindowServer") || !strcmp(getprogname(), "mtllockwait"));
    });
    if (!enabled || !(t = vg_lockwait_root(t)) || !t->_surface) {
        return NO;
    }

    BOOL published = NO;
    os_unfair_lock_lock(&gWriterLock);
    if (!t->_readerWaits && t->_readerChecks++ % 30 == 0) {
        CFTypeRef tag = IOSurfaceCopyValue(t->_surface, kVgReaderWaits);
        if (tag) {
            CFRelease(tag);
            t->_readerWaits = notify_post(kVgWriteBackNotification) == NOTIFY_STATUS_OK;
        }
    }
    if (t->_readerWaits && vg_pending_generation(t->_surface) <= 0) {
        int64_t generation = ++gNextGeneration;
        CFNumberRef value = CFNumberCreate(NULL, kCFNumberSInt64Type, &generation);
        if (value) {
            IOSurfaceSetValue(t->_surface, kVgPending, value);
            CFRelease(value);
            published = vg_pending_generation(t->_surface) == generation;
        }
    }
    os_unfair_lock_unlock(&gWriterLock);
    return published;
}

void vg_lockwait_end(VGMTLTexture *t, BOOL written) {
    t = vg_lockwait_root(t);
    os_unfair_lock_lock(&gWriterLock);
    if (written) {
        IOSurfaceRemoveValue(t->_surface, kVgPending);
    } else {
        int64_t generation = -vg_pending_generation(t->_surface);
        CFNumberRef value = CFNumberCreate(NULL, kCFNumberSInt64Type, &generation);
        if (value) {
            IOSurfaceSetValue(t->_surface, kVgPending, value);
            CFRelease(value);
        }
    }
    os_unfair_lock_unlock(&gWriterLock);
    notify_post(kVgWriteBackNotification);
}

// ---- stream sums (round 23: why the display stream's twin keeps trails out of Screen Sharing) ------------------------
// The flag file VirtioGPUMetal-streamsum (empty, or naming WindowServer and the reader): WindowServer stamps each
// deferred display-stream write-back with the surface's seed after it and a sum of each of 16 bands of rows (every
// 4th pixel of every 4th row), and the reader's lock checks what it is about to read against that stamp. tools/
// streamprobe.m (a reader of its own) uses the same sums and stamp.
static CFStringRef const kVgStamp = CFSTR("VeneraWriteBackSums");
enum { kVgBands = 16 };
typedef struct {
    uint32_t seed, frame;
    uint64_t band[kVgBands];
} vg_stream_stamp;

static void vg_stream_sums(const uint8_t *base, size_t w, size_t h, size_t bpr, uint64_t band[kVgBands]) {
    for (int b = 0; b < kVgBands; b++) {
        uint64_t x = 1469598103934665603ull;
        for (size_t y = h * b / kVgBands & ~(size_t)3; y < h * (b + 1) / kVgBands; y += 4) {
            const uint32_t *row = (const uint32_t *)(base + y * bpr);
            for (size_t i = 0; i < w; i += 4) {
                x = (x ^ row[i]) * 1099511628211ull;
            }
        }
        band[b] = x;
    }
}

static BOOL vg_streamsum_on(void) {
    static int on = -1;
    static uint64_t checked;
    const uint64_t now = vg_now();
    if (on < 0 || now - checked > 2000000000ull) {
        on = vg_debug_flag("streamsum");
        checked = now;
    }
    return on == 1;
}

uint32_t vg_streamsum_stamp(VGMTLTexture *t, uint32_t seed) {
    if (!(t = vg_lockwait_root(t)) || !t->_readerWaits || !vg_streamsum_on()) {
        return 0;
    }
    static _Atomic uint32_t frames;
    vg_stream_stamp st = {seed, ++frames, {0}};
    IOSurfaceLock(t->_surface, kIOSurfaceLockAvoidSync | kIOSurfaceLockReadOnly, NULL);
    IOSurfaceRef s = t->_surface;
    vg_stream_sums(IOSurfaceGetBaseAddress(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), IOSurfaceGetBytesPerRow(s),
                   st.band);
    IOSurfaceUnlock(t->_surface, kIOSurfaceLockAvoidSync | kIOSurfaceLockReadOnly, NULL);
    CFDataRef d = CFDataCreate(NULL, (const UInt8 *)&st, sizeof(st));
    if (d) {
        IOSurfaceSetValue(t->_surface, kVgStamp, d);
        CFRelease(d);
    }
    return st.frame;   // the write-back's generation, which the reader finds in the stamp
}

// The reader's check, after its lock: what it reads against the stamp. Counted, and the first mismatches logged.
static _Atomic uint64_t gSumSame, gSumDiffer, gSumSeedMoved, gSumNoStamp;
static void vg_streamsum_check(IOSurfaceRef s, int64_t target, uint64_t waited) {
    if (!vg_streamsum_on()) {
        return;
    }
    vg_stream_stamp st;
    CFTypeRef v = IOSurfaceCopyValue(s, kVgStamp);
    BOOL have = v && CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength(v) == sizeof(st);
    if (have) {
        memcpy(&st, CFDataGetBytePtr(v), sizeof(st));
    }
    if (v) {
        CFRelease(v);
    }
    if (!have) {
        atomic_fetch_add(&gSumNoStamp, 1);
        return;
    }
    uint64_t band[kVgBands];
    vg_stream_sums(IOSurfaceGetBaseAddress(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), IOSurfaceGetBytesPerRow(s),
                   band);
    uint32_t differ = 0;
    for (int b = 0; b < kVgBands; b++) {
        differ |= (band[b] != st.band[b]) << b;
    }
    const uint32_t seed = IOSurfaceGetSeed(s);
    if (seed != st.seed) {
        atomic_fetch_add(&gSumSeedMoved, 1);
    }
    uint64_t n = differ ? atomic_fetch_add(&gSumDiffer, 1) + 1 : 0;
    if (!differ) {
        atomic_fetch_add(&gSumSame, 1);
    }
    if (differ && (n <= 20 || n % 200 == 0)) {
        vglog("streamsum: surface %u read differs from write-back %u (bands 0x%04x), seed %u stamped %u, pending %lld, "
              "waited %.2f ms; %llu same, %llu differ, %llu seed moved, %llu unstamped", IOSurfaceGetID(s), st.frame,
              differ, seed, st.seed, (long long)target, waited / 1e6, (unsigned long long)atomic_load(&gSumSame),
              (unsigned long long)n, (unsigned long long)atomic_load(&gSumSeedMoved),
              (unsigned long long)atomic_load(&gSumNoStamp));
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
        static int names = -1;   // the flag file locknames: which surfaces this reader locks, each once
        if (names < 0) {
            names = vg_debug_flag("locknames");
        }
        if (names && CFGetTypeID(name) == CFStringGetTypeID()) {
            vglog("lockwait: locks surface %u '%s' %zux%zu", sid, [(__bridge NSString *)name UTF8String],
                  IOSurfaceGetWidth(s), IOSurfaceGetHeight(s));
        }
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
        vglog("lockwait: surface %u is a display stream%s", sid, gMeasureOnly ? " (timing only)" : " (tagged)");
    }
    return stream;
}

static kern_return_t vg_surface_lock_hook(IOSurfaceRef s, IOSurfaceLockOptions options, uint32_t *seed) {
    if (!s) {
        return (kern_return_t)0xe00002c2;   // kIOReturnBadArgument, as the stub answers
    }
    if (!(options & kIOSurfaceLockAvoidSync) && vg_is_stream_surface(s)) {
        static _Atomic uint32_t optionsSeen;   // which lock options this reader uses (each set once)
        if (!(atomic_fetch_or(&optionsSeen, 1u << (options & 7)) & (1u << (options & 7)))) {
            vglog("lockwait: this reader locks display-stream surfaces with options 0x%x", (unsigned)options);
        }
        int64_t target = gMeasureOnly ? 0 : vg_pending_generation(s);
        uint64_t t0 = target > 0 ? vg_now() : 0;
        kern_return_t error = target < 0 ? kIOReturnNotReady : KERN_SUCCESS;
        if (target > 0) {
            const uint64_t deadline = t0 + 100000000ull;
            for (;;) {
                // Take the wake sequence before checking metadata so a write in between either changes the
                // predicate or makes the compare-and-wait return immediately.
                uint32_t expected = atomic_load_explicit(&gWakeSequence, memory_order_acquire);
                int64_t pending = vg_pending_generation(s);
                if (pending != target) {
                    error = pending == -target ? kIOReturnNotReady : KERN_SUCCESS;
                    break;
                }
                uint64_t now = vg_now();
                if (now >= deadline) {
                    error = kIOReturnTimeout;
                    break;
                }
                if (os_sync_wait_on_address_with_timeout(&gWakeSequence, expected, sizeof(expected),
                        OS_SYNC_WAIT_ON_ADDRESS_NONE, OS_CLOCK_MACH_ABSOLUTE_TIME, deadline - now) < 0 &&
                    errno != EINTR && errno != ETIMEDOUT) {
                    error = kIOReturnTimeout;
                    break;
                }
            }
        }
        uint64_t now = vg_now();
        vg_lockwait_stat(now, t0 ? now - t0 : 0);
        if (t0) {
            uint64_t total = atomic_fetch_add(&gWaitNs, now - t0) + now - t0;
            if (error == kIOReturnTimeout) {
                atomic_fetch_add(&gTimeouts, 1);
            }
            uint64_t n = atomic_fetch_add(&gWaits, 1) + 1;
            if (n == 1 || n % 1000 == 0) {
                vglog("lockwait: %llu waits for a pending write, %.2f ms each on average, %llu timed out",
                      (unsigned long long)n, total / 1e6 / n, (unsigned long long)atomic_load(&gTimeouts));
            }
        }
        if (error != KERN_SUCCESS) {
            return error;
        }
        void *client = *(void **)((char *)s + *gClientOffset);
        kern_return_t r = gInner(client, options, seed);
        if (r == KERN_SUCCESS) {
            vg_streamsum_check(s, target, t0 ? now - t0 : 0);
        }
        return r;
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
    if (access("/Library/GPUBundles/VirtioGPUMetal-nolockwait", F_OK) == 0) {
        return NO;
    }
    NSString *s = [NSString stringWithContentsOfFile:@"/Library/GPUBundles/VirtioGPUMetal-lockwait"
                                            encoding:NSUTF8StringEncoding error:NULL];
    if (!s) {
        return !strcmp(getprogname(), "ScreensharingAgent");   // the default reader
    }
    NSArray *names = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        componentsSeparatedByString:@"\n"];
    return [names containsObject:@(getprogname())];
}

static uint32_t vg_lockwait_subscribe(int *token) {
    return notify_register_dispatch(kVgWriteBackNotification, token,
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(int _) {
            atomic_fetch_add_explicit(&gWakeSequence, 1, memory_order_release);
            os_sync_wake_by_address_all(&gWakeSequence, sizeof(uint32_t), OS_SYNC_WAKE_BY_ADDRESS_NONE);
        });
}

__attribute__((constructor)) static void vg_lockwait_init(void) {
    @autoreleasepool {
        if (!vg_lockwait_wanted()) {
            return;
        }
        gMeasureOnly = vg_debug_flag("lockwaitmeasure");
        int token = -1;
        if (!gMeasureOnly && vg_lockwait_subscribe(&token) != NOTIFY_STATUS_OK) {
            vglog("lockwait: could not subscribe to write-back notifications");
            return;
        }
        if (!vg_lockwait_install()) {
            if (token >= 0) {
                notify_cancel(token);
            }
            return;
        }
        vglog(gMeasureOnly ? "lockwait: this process's display-stream locks are timed, with no reader wait"
                           : "lockwait: this process's IOSurfaceLock waits for pending display-stream writes");
    }
}
