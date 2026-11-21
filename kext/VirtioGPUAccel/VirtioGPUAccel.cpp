// VirtioGPUAccel: the accelerator (stage 4.0), the Metal arm (4a) and the display (5a).
//
// An IOGraphicsAccelerator2 (Apple's IOAcceleratorFamily2) on the virtio-gpu PCI device, in the IOAccelerator match
// category beside the core (default category) and the framebuffer slot (IOFramebuffer category). It answers the
// family's 17 pure virtuals with stubs and does nothing with the GPU. The question it answers: does the family start
// in this guest, and does our subclass attach and register?
//
// UNARMED at boot: no MetalPluginName, so no process (WindowServer included) can load a Metal driver for it until a
// root tool arms it at run time (setProperties below, `acceltest arm`).
// Gates: boot-arg vgpuaccel=1 to start at all (absent = the kext loads, the family loads as its dependency, start
// refuses), -vgpuaccoff to refuse even the probe.
//
// Class layouts come from nullmoth/nvidia-macos-driver's reconstructed headers (vendor/nullmoth, PolyForm NC); macOS 26
// made some inherited methods unlinkable, and vg_tahoe_fwd.h forwards those slots through Apple's exported vtables.
// The overrides below mirror the set NV's classes override, which is what that forwarding list was generated for.
//
// Stage 5a (vgpuaccel=3 and 4): the display. The accelerator watches for VirtioGPUFramebuffer, registers it with its
// display machine (found_framebuffer, which makes the family call newDisplayPipe), delivers a mode change, publishes
// IOAccelDisplayPipeCapabilities, creates the AppleGraphicsDeviceControl on the PCI device (VGDeviceControl.cpp) and,
// at 4, publishes MetalPluginName with VirtioGPUWindowServer = true, the plugin's sign that WindowServer may have the
// device. A boot hold (adjustBusy) keeps the registry busy until then, capped at 20 s. VGDisplayPipe::performTransaction
// copies each composited IOSurface into the framebuffer's scanout RAM (option A of notes/STAGE4-5.md). The Venus user
// client is also served from here (type kVGUCAccelType, attached under IOAccelVirtioCarrier services), because
// WindowServer's sandbox allows the accelerator's user clients and not the core's.
// Guard: a third WindowServer process that opens the Venus client since the last arm (the first two died) withdraws
// the display; so does a third that opens the display pipe, for a WindowServer that dies before it gets to Metal (a
// missing or broken Metal bundle: CoreDisplay asserts while it creates the display, round 12): VirtioGPUWindowServer turns false and the pipe capabilities go (the AGDC can't be terminated and needn't
// be). MetalPluginName stays, so the plugin loads into the next WindowServer, turns CoreDisplay's IOPresentment switch
// off there and refuses it the device: it composites in software (5c). A root process re-arms with {"VirtioGPUArmWindowServer": true} (acceltest wsarm) or withdraws with
// {"VirtioGPUWithdraw": true} (acceltest withdraw), without a reboot.
//
// IOLog doesn't reach the log on Tahoe: lines go to the core's ProbeLog (kVGPULog) and to "VirtioGPUAccelLog" on the
// PCI device (kept even when start fails and this object is gone).
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IORangeAllocator.h>
#include <libkern/c++/OSSymbol.h>
#include <pexpert/pexpert.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/graphics/IOFramebuffer.h>
#include <sys/proc.h>
#include <stdarg.h>
#include "IOAccelerator.h"
#include "IOGraphicsAccelerator2.h"
#include "IOAccelEventMachineFast2.h"
#include "IOAccelLegacyDisplayMachine.h"
#include "IOAccelTask.h"
#include "IOAccelMemoryMap.h"
#include "IOAccelResource2.h"
#include "IOAccelSysMemory.h"
#include "IOAccelVidMemory.h"
#include "IOAccelLegacySurface.h"
#include "IOAccelLegacyDisplayPipe.h"
#include "IOAccelGLContext2.h"
#include "IOAccel2DContext2.h"
#include "IOAccelCLContext2.h"
#include "IOAccelVideoContext2.h"
#include "vg_tahoe_fwd.h"
#include "nv_iop_pixel.h"
#include "nvres_fields.h"
#include "../VirtioGPUAPI.h"
#include "../VirtioGPUUserAPI.h"
#include "accel_shared.h"

extern "C" kern_return_t _start(kmod_info_t *ki, void *d);
extern "C" kern_return_t _stop(kmod_info_t *ki, void *d);
extern "C" kern_return_t _start(kmod_info_t *, void *) { return KERN_SUCCESS; }
extern "C" kern_return_t _stop(kmod_info_t *, void *) { return KERN_SUCCESS; }

// ---- log ---------------------------------------------------------------------------------------------------------

static IOService *gLogPci = nullptr;   // the PCI device: where VirtioGPUAccelLog lives and where we look for the core
static OSArray *gLogLines = nullptr;
static IOLock *gLogLock = nullptr;

#define vlog vgaccel_log
void vgaccel_log(const char *fmt, ...) {
    char line[200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    char prefixed[210];
    snprintf(prefixed, sizeof(prefixed), "accel: %s", line);
    IOLog("VirtioGPU %s\n", prefixed);
    if (!gLogPci) {
        return;
    }
    if (!gLogLock) {
        gLogLock = IOLockAlloc();
    }
    if (gLogLock) {
        IOLockLock(gLogLock);
    }
    if (!gLogLines) {
        gLogLines = OSArray::withCapacity(32);
    }
    if (gLogLines) {
        if (gLogLines->getCount() >= 200) {
            gLogLines->removeObject(0);   // keep the newest 200 (the first 200 used to be all there was)
        }
        if (OSString *s = OSString::withCString(line)) {
            gLogLines->setObject(s);
            s->release();
        }
        if (OSArray *copy = OSArray::withArray(gLogLines)) {
            gLogPci->setProperty("VirtioGPUAccelLog", copy);
            copy->release();
        }
    }
    // The core (class VirtioGPU, a client of the same PCI device) keeps the ProbeLog that tools/deploy.sh logs reads.
    IOService *core = nullptr;
    if (OSIterator *it = gLogPci->getClientIterator()) {
        while (OSObject *o = it->getNextObject()) {
            if (o->metaCast("VirtioGPU")) {
                core = (IOService *)o;
                core->retain();
                break;
            }
        }
        it->release();
    }
    if (gLogLock) {
        IOLockUnlock(gLogLock);
    }
    if (core) {
        if (const OSSymbol *sym = OSSymbol::withCString(kVGPULog)) {
            core->callPlatformFunction(sym, false, prefixed, (void *)1, nullptr, nullptr);
            sym->release();
        }
        core->release();
    }
}

// Logs the first few calls of a stub, then stays quiet.
#define STUB_LOG(name)                                                                                             \
    do {                                                                                                           \
        static int seen_ = 0;                                                                                      \
        if (seen_ < 3) {                                                                                           \
            seen_++;                                                                                               \
            vlog("%s", name);                                                                                      \
        }                                                                                                          \
    } while (0)

class VirtioGPUAccel;
static VirtioGPUAccel *gAccel = nullptr;
static void enableFrom(const char *why);

// ---- the family's helper objects, all stubs ------------------------------------------------------------------------

class VGEventMachine : public IOAccelEventMachineFast2 {
    OSDeclareDefaultStructors(VGEventMachine)
    NM_TAHOE_FWD(VGEventMachine)
public:
    void writeStamp(int s, vendevtCommandRec *r, unsigned int v) APPLE_KEXT_OVERRIDE;
    void prepareBarrier(vendevtBarrierRec *) APPLE_KEXT_OVERRIDE { STUB_LOG("EM prepareBarrier"); }
    void completeBarrier(vendevtBarrierRec *) APPLE_KEXT_OVERRIDE { STUB_LOG("EM completeBarrier"); }
    void writeBarrierElement(vendevtBarrierRec *, int, unsigned int) APPLE_KEXT_OVERRIDE { STUB_LOG("EM writeBarrierElement"); }
    bool checkGPUProgress() APPLE_KEXT_OVERRIDE { return true; }
    bool checkChannelProgress(int) APPLE_KEXT_OVERRIDE { return true; }
    void *eventTimeout(int) APPLE_KEXT_OVERRIDE { STUB_LOG("EM eventTimeout"); return nullptr; }
};
OSDefineMetaClassAndStructors(VGEventMachine, IOAccelEventMachineFast2)

class VGDisplayMachine : public IOAccelLegacyDisplayMachine {
    OSDeclareDefaultStructors(VGDisplayMachine)
    NM_TAHOE_FWD(VGDisplayMachine)
public:
    bool displayModeWillChange() APPLE_KEXT_OVERRIDE { vlog("DM displayModeWillChange"); return true; }
    bool displayModeDidChange() APPLE_KEXT_OVERRIDE {
        vlog("DM displayModeDidChange");
        enableFrom("displayModeDidChange");
        return true;
    }
};
OSDefineMetaClassAndStructors(VGDisplayMachine, IOAccelLegacyDisplayMachine)

// GPU virtual addresses mean nothing to Venus; a bump allocator hands out distinct, aligned, never-reused ranges.
static volatile UInt64 gNextVa = 1ULL << 40;

class VGTask : public IOAccelTask {
    OSDeclareDefaultStructors(VGTask)
    NM_TAHOE_FWD(VGTask)
public:
    unsigned long long allocate(const IOAccelMemoryMap *map) APPLE_KEXT_OVERRIDE {
        unsigned long long len = map ? ((IOAccelMemoryMap *)map)->getLength() : 0;
        len = (len + 0xffffULL) & ~0xffffULL;
        if (!len) {
            len = 0x10000;
        }
        unsigned long long va = (unsigned long long)OSAddAtomic64((SInt64)len, (volatile SInt64 *)&gNextVa);
        STUB_LOG("Task allocate");
        return va;
    }
    void deallocate(const IOAccelMemoryMap *, unsigned long long) APPLE_KEXT_OVERRIDE {}
};
OSDefineMetaClassAndStructors(VGTask, IOAccelTask)

class VGMemoryMap : public IOAccelMemoryMap {
    OSDeclareDefaultStructors(VGMemoryMap)
    NM_TAHOE_FWD(VGMemoryMap)
public:
    bool init(IOGraphicsAccelerator2 *a, IOAccelTask *t, IOAccelMemory *m, unsigned int o) APPLE_KEXT_OVERRIDE {
        return IOAccelMemoryMap::init(a, t, m, o);
    }
    void free() APPLE_KEXT_OVERRIDE { IOAccelMemoryMap::free(); }
    bool commitIntoGPUPageTable() APPLE_KEXT_OVERRIDE { STUB_LOG("MM commit"); return true; }
    void releaseFromGPUPageTable() APPLE_KEXT_OVERRIDE {}
    bool updateGPUPageTable() APPLE_KEXT_OVERRIDE { return true; }
};
OSDefineMetaClassAndStructors(VGMemoryMap, IOAccelMemoryMap)

class VGResource : public IOAccelResource2 {
    OSDeclareDefaultStructors(VGResource)
    NM_TAHOE_FWD(VGResource)
public:
    void rebuildPagingBuffer() APPLE_KEXT_OVERRIDE {}
    // The resource's geometry as NV answers it (nvres_fields.h): an IOSurface's video memory is sized by
    // calculateIOSurfaceDeviceCacheVRAMBytes, so answering 0 made every displayable surface's video memory 0 bytes
    // and its prepare() fail (5b).
    uint64_t getLevelOffset(unsigned char face, unsigned char level, int *pitch) APPLE_KEXT_OVERRIDE {
        const unsigned char *r = (const unsigned char *)this;
        if (pitch) {
            unsigned base = r[kNvResBaseLevel];
            *pitch = (int)(nvResPitch(r) >> (level >= base ? (unsigned)(level - base) : 0u));
        }
        return (uint64_t)face * nvResFaceSize(r);
    }
    uint64_t getBackingLevelOffset(unsigned char face, unsigned char level, int *pitch) APPLE_KEXT_OVERRIDE {
        const unsigned char *r = (const unsigned char *)this;
        if (pitch) {
            unsigned base = r[kNvResBaseLevel];
            *pitch = (int)(nvResBackingPitch(r) >> (level >= base ? (unsigned)(level - base) : 0u));
        }
        return (uint64_t)face * nvResFaceSize(r);
    }
    uint64_t calculateIOSurfaceDeviceCacheVRAMBytes(unsigned long long *bytes, unsigned long long *count) APPLE_KEXT_OVERRIDE {
        const uint64_t size = nvResFaceSize((const unsigned char *)this);
        if (bytes) {
            *bytes = size;
        }
        if (count) {
            *count = 1;
        }
        return size;
    }
    bool addToAperture() APPLE_KEXT_OVERRIDE { return false; }
    void removeFromAperture() APPLE_KEXT_OVERRIDE {}
    void *getApertureMemoryDescriptor(unsigned long long *len) APPLE_KEXT_OVERRIDE {
        if (len) {
            *len = 0;
        }
        return nullptr;
    }
    void free() APPLE_KEXT_OVERRIDE { IOAccelResource2::free(); }
};
OSDefineMetaClassAndStructors(VGResource, IOAccelResource2)

class VGSysMemory : public IOAccelSysMemory {
    OSDeclareDefaultStructors(VGSysMemory)
    NM_TAHOE_FWD(VGSysMemory)
};
OSDefineMetaClassAndStructors(VGSysMemory, IOAccelSysMemory)

// "VRAM" in guest RAM (5b). The family puts displayable surfaces (CoreDisplay's display surfaces, the planes of display
// pipe transactions) in video memory, and IOAccelResource2::prepare() fails with kIOReturnNoResources for a
// transaction whose planes have none, so every transaction failed while this refused. Each allocation is physically
// contiguous kernel memory: the family's own getPhysicalSegment reads one base at +0xc8 (Tahoe 25G342) for the length
// at +0x40. Nothing reads it on the GPU side; frames still reach the screen by performTransaction's copies from the
// IOSurfaces. -vgpunovidmem refuses again (the stage 5a behavior).
// A display surface at 2560x1600 asks for 16 MB, at 4K 33 MB, and contiguous blocks that big are rare once macOS has
// run a while (Retina modes came up black: every transaction's prepare failed). Since nothing reads this memory, one
// spare block, taken when the accelerator starts (the RAM is still in one piece then) and as big as the largest mode,
// stands in for every allocation that can't get its own (0.7.0).
static IOBufferMemoryDescriptor *gSpareVidMem;
static constexpr uint64_t kSpareVidMemBytes = 3840ULL * 2400 * 4;
class VGVidMemory : public IOAccelVidMemory {
    OSDeclareDefaultStructors(VGVidMemory)
    NM_TAHOE_FWD(VGVidMemory)
    IOBufferMemoryDescriptor *buf_ = nullptr;
    static constexpr unsigned kPhysOff = 0xc8, kLengthOff = 0x40;
public:
    bool allocPhysical() APPLE_KEXT_OVERRIDE {
        static uint32_t logged = 0;
        bool refuse = false;
        PE_parse_boot_argn("-vgpunovidmem", &refuse, sizeof(refuse));
        const uint64_t want = *(const volatile uint64_t *)((const uint8_t *)this + kLengthOff);
        if (refuse || buf_ || !want) {
            if (logged++ < 8) {
                vgaccel_log("VidMemory allocPhysical(%llu bytes) -> false (%s)", (unsigned long long)want,
                            refuse ? "-vgpunovidmem" : buf_ ? "already backed" : "no length");
            }
            return false;
        }
        buf_ = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, round_page(want), 0xFFFFFFFFFFFFF000ULL);
        if (!buf_ && gSpareVidMem && want <= gSpareVidMem->getLength()) {
            static uint32_t spared = 0;
            buf_ = gSpareVidMem;
            buf_->retain();
            if (spared++ < 4) {
                vgaccel_log("VidMemory allocPhysical(%llu bytes): no contiguous RAM, the spare block stands in",
                            (unsigned long long)want);
            }
        } else if (!buf_) {
            vgaccel_log("VidMemory allocPhysical(%llu bytes) -> false (no contiguous RAM)", (unsigned long long)want);
            return false;
        } else {
            bzero(buf_->getBytesNoCopy(), buf_->getLength());
        }
        *(volatile uint64_t *)((uint8_t *)this + kPhysOff) = buf_->getPhysicalAddress();
        if (logged++ < 8) {
            vgaccel_log("VidMemory allocPhysical(%llu bytes) -> phys 0x%llx", (unsigned long long)want,
                        (unsigned long long)buf_->getPhysicalAddress());
        }
        return true;
    }
    void deallocPhysical() APPLE_KEXT_OVERRIDE {
        *(volatile uint64_t *)((uint8_t *)this + kPhysOff) = 0;
        OSSafeReleaseNULL(buf_);
    }
    void free() APPLE_KEXT_OVERRIDE {
        deallocPhysical();
        IOAccelVidMemory::free();
    }
    uint64_t getPhysicalSegment(unsigned long long offset, unsigned long long *len) APPLE_KEXT_OVERRIDE {
        const uint64_t total = buf_ ? buf_->getLength() : 0;
        if (!buf_ || offset >= total) {
            if (len) {
                *len = 0;
            }
            return 0;
        }
        if (len) {
            *len = total - offset;
        }
        return buf_->getPhysicalAddress() + offset;
    }
};
OSDefineMetaClassAndStructors(VGVidMemory, IOAccelVidMemory)

class VGSurface : public IOAccelLegacySurface {
    OSDeclareDefaultStructors(VGSurface)
    NM_TAHOE_FWD(VGSurface)
public:
    void setSyncCommand(unsigned int *, unsigned int &, unsigned int &, _AMDSurfaceSwapSyncOptions const &) const APPLE_KEXT_OVERRIDE {
        STUB_LOG("Surface setSyncCommand");
    }
    void _pure335() APPLE_KEXT_OVERRIDE { STUB_LOG("Surface _pure335"); }
    bool copyFromBuffer(int, int, int, int, unsigned int, unsigned int, IOAccelEvent *, IOAccelResource2 *, IOAccelSysMemory *,
                        unsigned int, unsigned long long, unsigned int) APPLE_KEXT_OVERRIDE {
        STUB_LOG("Surface copyFromBuffer");
        return false;
    }
    bool copyToBuffer(int, int, int, int, unsigned int, unsigned int, IOAccelEvent *, IOAccelResource2 *, IOAccelSysMemory *,
                      unsigned int, unsigned long long, unsigned int) APPLE_KEXT_OVERRIDE {
        STUB_LOG("Surface copyToBuffer");
        return false;
    }
    void submitSwapCopy(IOAccelEvent *, IOAccelResource2 *, IOAccelResource2 *) APPLE_KEXT_OVERRIDE { STUB_LOG("Surface submitSwapCopy"); }
    void shapeSurface(unsigned int, unsigned short, unsigned short) APPLE_KEXT_OVERRIDE { STUB_LOG("Surface shapeSurface"); }
    uint32_t getDirtyBufferBitsFromPrivateModeBits(unsigned long long) APPLE_KEXT_OVERRIDE { return 0; }
};
OSDefineMetaClassAndStructors(VGSurface, IOAccelLegacySurface)

// ---- the display pipe (stage 5a) ---------------------------------------------------------------------------------
// The family makes one per framebuffer found_framebuffer registers (newDisplayPipe). WindowServer's IOPresentment hands
// it a transaction per composited frame; ours has no scanout engine, so performTransaction copies the frame's IOSurface
// into the framebuffer's scanout RAM, which the framebuffer flushes to the host (NV's copy path, nvrm-accel.cpp
// performTransaction). Transactions are refused (0xe00002c7, as the base class) until IOAccelDisplayPipeCapabilities
// is published.

// IOSurface's kernel accessors (com.apple.iokit.IOSurface exports them), and the transaction's plane accessors
// (IOAcceleratorFamily2): declarations only, as NV's.
class IOSurface {
public:
    IOMemoryDescriptor *getMemoryDescriptor() const;
    unsigned long long getWidth() const;
    unsigned long long getHeight() const;
    unsigned long long getBytesPerRow() const;
    unsigned int getPixelFormat() const;
    unsigned int getSurfaceID() const;
};
class IOAccelDisplayPipeTransaction2 {
public:
    IOSurface *getPlaneIOSurface(unsigned int, unsigned int) const;
    OSObject *getPlaneResource(unsigned int, unsigned int) const;
};

static volatile SInt32 gIop = 0;   // 1 once the capabilities are published
static SInt64 gIopOk = 0, gIopFail = 0, gIopEmpty = 0, gIopRefused = 0;
static unsigned gIopLogs = 0;
#define IOPLOG(fmt, ...)                                                                                           \
    do {                                                                                                           \
        if (gIopLogs < 40) {                                                                                       \
            gIopLogs++;                                                                                            \
            vlog("iop: " fmt, ##__VA_ARGS__);                                                                      \
        }                                                                                                          \
    } while (0)
#define IOPFAIL(rc, fmt, ...)                                                                                      \
    do {                                                                                                           \
        OSAddAtomic64(1, &gIopFail);                                                                               \
        IOPLOG(fmt, ##__VA_ARGS__);                                                                                \
        return (rc);                                                                                               \
    } while (0)
static unsigned gPipeLogs = 0;
#define PIPELOG(fmt, ...)                                                                                          \
    do {                                                                                                           \
        if (gPipeLogs < 60) {                                                                                      \
            gPipeLogs++;                                                                                           \
            vlog(fmt, ##__VA_ARGS__);                                                                              \
        }                                                                                                          \
    } while (0)
static IOService *displayFramebuffer();
static const OSSymbol *gSymScanoutInfo, *gSymPresent, *gSymNewClient;   // made in start()
static const OSSymbol *gSymTwinFor, *gSymScanoutBlob;                   // 5c, made in start()
static IOService *coreService();                                         // the core (VirtioGPU), for blob scanouts
static SInt64 gIopBlob = 0;                                              // frames shown from a twin (5c)
static volatile bool gBlobShown = false;                                 // a twin is on scanout 0
// Blob flips run on a work loop of their own (5c): QEMU answers SET_SCANOUT_BLOB / RESOURCE_FLUSH only after it has
// drawn the frame and read it back for VNC (~9 ms with egl-headless), which must not stall WindowServer's present.
// The newest *ready* frame wins (5c round 6): with frames asked for faster than the GPU finishes them, waiting for the
// newest one starved the screen (each became ready only after a newer one had replaced it: flips 25-200 ms apart while
// WindowServer made a frame every ~16 ms). Core Animation rotates 3-4 surfaces, so a twin isn't rewritten before its flip.
static IOWorkLoop *gPresentLoop;
static IOTimerEventSource *gPresentTimer;
static IOLock *gPresentLock;
struct PendingFlip {
    uint32_t twin[6];   // resource, width, height, stride, the frame wanted, surface
    uint64_t sinceAbs;  // when it was asked for (a frame never marked ready flips anyway after 100 ms)
};
static const int kPendingMax = 8;
static PendingFlip gPending[kPendingMax];   // oldest first
static int gPendingCount = 0;
static SInt64 gFlipNs = 0, gFlipMaxNs = 0, gFlips = 0, gFlipsSkipped = 0, gFlipsUnready = 0;
// Wait this many ms after a flip (0 = no limit). For display-rate pacing, the scanout call and the wait share one
// refresh interval. A slower explicit throttle keeps its full wait. Override with vgpuflipms or `acceltest flipms N`.
static volatile uint32_t gFlipMinMs = 12;
static constexpr uint64_t kFlipFrameNs = 1000000000ULL / kVGPUDisplayRefreshHz;
static uint64_t gLastFlipAbs = 0, gLastFlipDurationNs = 0;

// Pacing (5c round 3): how evenly frames come from WindowServer and go to the screen. Gaps between marks in ms,
// counted in bins (gaps over 200 ms are idle time, not counted); flip durations likewise. VirtioGPUPacing;
// {"VirtioGPUPaceReset": true} (root, `acceltest pacereset`) starts over.
struct Pace {
    uint64_t last;
    uint32_t bins[10];
    uint64_t sumUs, n;   // gaps under the idle edge: their mean (5c round 6)
};
enum { kEdges = 9 };
// ms; the last bin (over the last edge) is idle for gaps and not shown; for durations it is "more". Finer around a
// 60 Hz frame (16.7 ms) since round 6.
static const uint32_t kGapEdges[kEdges] = {12, 15, 18, 21, 25, 34, 50, 100, 200};
static const uint32_t kDurEdges[kEdges] = {1, 2, 3, 4, 6, 8, 12, 16, 32};
static Pace gPaceTxn, gPaceFlip, gFlipDur;
static void paceBin(Pace *p, uint64_t ns, const uint32_t *edges) {
    uint32_t ms = (uint32_t)(ns / 1000000ULL), b = 0;
    while (b < kEdges && ms >= edges[b]) {
        b++;
    }
    p->bins[b]++;
    if (b < kEdges) {
        p->sumUs += ns / 1000;
        p->n++;
    }
}
static void paceMark(Pace *p, uint64_t abs) {
    if (p->last) {
        uint64_t ns = 0;
        absolutetime_to_nanoseconds(abs - p->last, &ns);
        paceBin(p, ns, kGapEdges);
    }
    p->last = abs;
}
static int paceLine(char *out, size_t n, const char *name, const Pace *p, const uint32_t *edges, bool lastBin) {
    int k = snprintf(out, n, "%s:", name);
    for (int b = 0; b < (lastBin ? kEdges + 1 : kEdges) && k < (int)n; b++) {
        if (b < kEdges) {
            k += snprintf(out + k, n - k, " <%u:%u", edges[b], p->bins[b]);
        } else {
            k += snprintf(out + k, n - k, " more:%u", p->bins[b]);
        }
    }
    if (p->n && k < (int)n) {
        k += snprintf(out + k, n - k, " mean %llu.%llu", p->sumUs / p->n / 1000, p->sumUs / p->n % 1000 / 100);
    }
    return k;
}

static void publishShown(uint32_t surface);
static void presentTick(OSObject *, IOTimerEventSource *) {
    for (;;) {
        uint64_t waitNs = (uint64_t)gFlipMinMs * 1000000ULL;
        const uint64_t budget = gLastFlipDurationNs < kFlipFrameNs ? kFlipFrameNs - gLastFlipDurationNs : 0;
        if (waitNs <= kFlipFrameNs && budget < waitNs) {
            waitNs = budget;
        }
        if (waitNs && gLastFlipAbs) {
            uint64_t since = 0;
            absolutetime_to_nanoseconds(mach_absolute_time() - gLastFlipAbs, &since);
            if (since < waitNs) {   // too soon: come back, showing the newest frame then
                gPresentTimer->setTimeoutUS((uint32_t)((waitNs - since) / 1000) + 1);
                return;
            }
        }
        PendingFlip q[kPendingMax];
        IOLockLock(gPresentLock);
        int n = gPendingCount;
        memcpy(q, gPending, sizeof(PendingFlip) * (size_t)n);
        IOLockUnlock(gPresentLock);
        if (!n) {
            return;
        }
        IOService *core = coreService();
        // A frame must be in its twin (its GPU copy done) before it is shown: the newest one the plugin has marked
        // ready goes, older ones are dropped. None ready: look again every ms; after 100 ms the newest goes anyway.
        // Not a twin a newer frame of its surface is being copied into right now (two twins a surface, core 0.5.8:
        // the surface's latest frame went into the same twin and isn't ready): that would show it half copied.
        int pick = -1;
        for (int i = n - 1; i >= 0 && pick < 0; i--) {
            uint32_t now[6] = {};
            if (!core || !q[i].twin[4] ||
                core->callPlatformFunction(gSymTwinFor, false, (void *)(uintptr_t)q[i].twin[5], now, nullptr,
                                           nullptr) != kIOReturnSuccess) {
                pick = i;
            } else if ((int32_t)(now[5] - q[i].twin[4]) >= 0 &&
                       !(now[0] == q[i].twin[0] && now[4] != q[i].twin[4] && (int32_t)(now[5] - now[4]) < 0)) {
                pick = i;
            }
        }
        if (pick < 0) {
            uint64_t waited = 0;
            absolutetime_to_nanoseconds(mach_absolute_time() - q[0].sinceAbs, &waited);
            if (waited < 100000000ULL) {
                gPresentTimer->setTimeoutUS(1000);
                return;
            }
            gFlipsUnready++;
            pick = n - 1;
        }
        uint32_t t[6];
        memcpy(t, q[pick].twin, sizeof(t));
        IOLockLock(gPresentLock);
        // taken, with everything older (requests that came meanwhile stay; the queue only grows at its end, and only
        // scanoutFramebufferAgain empties it)
        int drop = 0;
        while (drop < gPendingCount && !(gPending[drop].twin[0] == t[0] && gPending[drop].twin[4] == t[4] &&
                                         gPending[drop].sinceAbs == q[pick].sinceAbs)) {
            drop++;
        }
        if (drop < gPendingCount) {
            gFlipsSkipped += drop;
            drop++;
            memmove(gPending, gPending + drop, sizeof(PendingFlip) * (size_t)(gPendingCount - drop));
            gPendingCount -= drop;
        }
        IOLockUnlock(gPresentLock);
        const uint64_t flipStart = mach_absolute_time();
        if (core) {
            core->callPlatformFunction(gSymScanoutBlob, false, (void *)(uintptr_t)t[0], (void *)(uintptr_t)t[1],
                                       (void *)(uintptr_t)t[2], (void *)(uintptr_t)t[3]);
        }
        gLastFlipAbs = mach_absolute_time();
        publishShown(t[5]);   // what the screen shows now (the plugin's display snapshots read it)
        uint64_t ns = 0;
        absolutetime_to_nanoseconds(gLastFlipAbs - flipStart, &ns);
        gLastFlipDurationNs = ns;
        paceMark(&gPaceFlip, gLastFlipAbs);
        paceBin(&gFlipDur, ns, kDurEdges);
        gFlipNs += (SInt64)ns;
        gFlips++;
        if ((SInt64)ns > gFlipMaxNs) {
            gFlipMaxNs = (SInt64)ns;
        }
    }
}

// Queues a flip (performTransaction); false when there is no present loop (then the caller flips itself).
static bool queueFlip(const uint32_t twin[6], uint32_t surface) {
    if (!gPresentTimer || !gPresentLock) {
        return false;
    }
    IOLockLock(gPresentLock);
    if (gPendingCount == kPendingMax) {   // full: the oldest goes unshown
        gFlipsSkipped++;
        memmove(gPending, gPending + 1, sizeof(PendingFlip) * (kPendingMax - 1));
        gPendingCount--;
    }
    PendingFlip *p = &gPending[gPendingCount++];
    memcpy(p->twin, twin, 4 * sizeof(uint32_t));
    p->twin[4] = twin[4];   // the frame last submitted into this twin: the one this transaction shows
    p->twin[5] = surface;
    p->sinceAbs = mach_absolute_time();
    IOLockUnlock(gPresentLock);
    gPresentTimer->setTimeoutUS(1);
    return true;
}

// Back to the framebuffer's own resource (the CPU path, a withdraw).
static void scanoutFramebufferAgain() {
    if (gPresentLock) {   // a queued flip must not land after this
        IOLockLock(gPresentLock);
        gPendingCount = 0;
        IOLockUnlock(gPresentLock);
    }
    if (gBlobShown || gPresentTimer) {   // with flips on their own loop, one may have just landed: ask the core
        if (IOService *core = coreService()) {
            core->callPlatformFunction(gSymScanoutBlob, false, nullptr, nullptr, nullptr, nullptr);
        }
        gBlobShown = false;
    }
}
static void iopPublishCounts();

class VGDisplayPipe : public IOAccelLegacyDisplayPipe {
    OSDeclareDefaultStructors(VGDisplayPipe)
    NM_TAHOE_FWD(VGDisplayPipe)
public:
    // The framebuffer resource: the family's IOAccelDisplayPipe::init_framebuffer_resource asks for it when the
    // framebuffer's mode is set, and only a pipe that got one is active (+0x298), which transaction_end requires
    // (kIOReturnNotReady otherwise: CoreDisplay's "Fallback GPU Display Pipe transaction submission failed", 5b). The
    // base class asks the display machine, whose base answers NULL; GPU drivers return their scanout memory. Ours is
    // the framebuffer's VRAM as system memory (IOAccelSysMemory::withMemoryDescriptor, the family's own); frames still
    // arrive by performTransaction's copies.
    IOAccelMemory *initFramebufferResource(unsigned int index, IOAccelResource2 *res) APPLE_KEXT_OVERRIDE;
    IOReturn validateTransaction(IOAccelDisplayPipeTransaction2 *) APPLE_KEXT_OVERRIDE {
        return gIop ? kIOReturnSuccess : kIOReturnUnsupported;
    }
    IOReturn performTransaction(IOAccelDisplayPipeTransaction2 *txn) APPLE_KEXT_OVERRIDE;
    IOReturn performTransactionTimed(IOAccelDisplayPipeTransaction2 *txn);
    bool isTransactionComplete(IOAccelDisplayPipeTransaction2 *) APPLE_KEXT_OVERRIDE { return true; }   // copied synchronously
    // 5b probes: which of the family's pipe entry points WindowServer drives (first calls logged, then the base class).
    void gates(const char *why) {
        vlog("pipe %s: active(+0x298) %u wsaaDefer(+0x282) %u", why, *(const volatile uint8_t *)((const uint8_t *)this + 0x298),
             *(const volatile uint8_t *)((const uint8_t *)this + 0x282));
    }
    OSObject *newDisplayPipeTransaction() APPLE_KEXT_OVERRIDE {
        OSObject *t = IOAccelLegacyDisplayPipe::newDisplayPipeTransaction();
        PIPELOG("pipe newDisplayPipeTransaction -> %p", t);
        return t;
    }
    void submitTransaction(IOAccelDisplayPipeTransaction2 *t) APPLE_KEXT_OVERRIDE {
        PIPELOG("pipe submitTransaction %p", t);
        IOAccelLegacyDisplayPipe::submitTransaction(t);
    }
    void beginTransaction(IOAccelEvent *e) APPLE_KEXT_OVERRIDE {
        PIPELOG("pipe beginTransaction");
        IOAccelLegacyDisplayPipe::beginTransaction(e);
    }
    void enableVBLInterrupt() APPLE_KEXT_OVERRIDE {
        PIPELOG("pipe enableVBLInterrupt");
        IOAccelLegacyDisplayPipe::enableVBLInterrupt();
    }
    void disableVBLInterrupt() APPLE_KEXT_OVERRIDE {
        PIPELOG("pipe disableVBLInterrupt");
        IOAccelLegacyDisplayPipe::disableVBLInterrupt();
    }
    void enableTransactionInterrupt() APPLE_KEXT_OVERRIDE {
        PIPELOG("pipe enableTransactionInterrupt");
        IOAccelLegacyDisplayPipe::enableTransactionInterrupt();
    }
    void displayModeDidChange() APPLE_KEXT_OVERRIDE {
        IOAccelLegacyDisplayPipe::displayModeDidChange();
        gates("after displayModeDidChange");
    }
    void framebuffer_did_power_on() APPLE_KEXT_OVERRIDE {
        PIPELOG("pipe framebuffer_did_power_on");
        IOAccelLegacyDisplayPipe::framebuffer_did_power_on();
    }
    void wsaaEnterDefer(int a) APPLE_KEXT_OVERRIDE {
        PIPELOG("pipe wsaaEnterDefer(%d)", a);
        IOAccelLegacyDisplayPipe::wsaaEnterDefer(a);
    }
    void wsaaDidExitDefer(int a) APPLE_KEXT_OVERRIDE {
        PIPELOG("pipe wsaaDidExitDefer(%d)", a);
        IOAccelLegacyDisplayPipe::wsaaDidExitDefer(a);
    }
    void free() APPLE_KEXT_OVERRIDE {
        dropSources();
        IOAccelLegacyDisplayPipe::free();
    }

private:
    enum { kSrcSlots = 4 };
    struct Src {
        unsigned id;
        IOMemoryDescriptor *md;
        IOMemoryMap *map;
    } src_[kSrcSlots] = {};
    unsigned srcNext_ = 0;
    const void *mapSurface(unsigned id, IOMemoryDescriptor *md, unsigned long long need);
    void dropSources() {
        for (unsigned i = 0; i < kSrcSlots; i++) {
            if (src_[i].map) {
                src_[i].map->release();
            }
            if (src_[i].md) {
                src_[i].md->complete();
                src_[i].md->release();
            }
            src_[i] = {};
        }
    }
};
OSDefineMetaClassAndStructors(VGDisplayPipe, IOAccelLegacyDisplayPipe)

// Keeps the last few source surfaces mapped (WindowServer cycles through ~3 per display).
const void *VGDisplayPipe::mapSurface(unsigned id, IOMemoryDescriptor *md, unsigned long long need) {
    for (unsigned i = 0; i < kSrcSlots; i++) {
        if (src_[i].md == md && src_[i].id == id && src_[i].map) {
            return src_[i].map->getLength() >= need ? (const void *)src_[i].map->getVirtualAddress() : nullptr;
        }
    }
    if (md->getLength() < need) {
        return nullptr;
    }
    Src *e = &src_[srcNext_++ % kSrcSlots];
    if (e->map) {
        e->map->release();
    }
    if (e->md) {
        e->md->complete();
        e->md->release();
    }
    *e = {};
    if (md->prepare() != kIOReturnSuccess) {
        return nullptr;
    }
    IOMemoryMap *m = md->map(kIOMapReadOnly);
    if (!m) {
        md->complete();
        return nullptr;
    }
    md->retain();
    e->md = md;
    e->map = m;
    e->id = id;
    IOPLOG("mapped source surface 0x%x (%llu bytes)", id, (unsigned long long)m->getLength());
    return (const void *)m->getVirtualAddress();
}

static SInt64 gIopCalls = 0;
// 5c timing: how long each transaction's copy takes, and how often transactions come (VirtioGPUPipeTiming).
static SInt64 gIopNs = 0, gIopMaxNs = 0, gIopFirstAbs = 0, gIopLastAbs = 0;

IOReturn VGDisplayPipe::performTransaction(IOAccelDisplayPipeTransaction2 *txn) {
    uint64_t t0 = mach_absolute_time();
    IOReturn r = performTransactionTimed(txn);
    uint64_t t1 = mach_absolute_time(), ns = 0;
    absolutetime_to_nanoseconds(t1 - t0, &ns);
    OSAddAtomic64((SInt64)ns, &gIopNs);
    if ((SInt64)ns > gIopMaxNs) {
        gIopMaxNs = (SInt64)ns;
    }
    if (!gIopFirstAbs) {
        gIopFirstAbs = (SInt64)t0;
    }
    gIopLastAbs = (SInt64)t1;
    return r;
}

IOReturn VGDisplayPipe::performTransactionTimed(IOAccelDisplayPipeTransaction2 *txn) {
    if (OSAddAtomic64(1, &gIopCalls) % 60 == 0) {
        iopPublishCounts();
    }
    if (!gIop) {
        OSAddAtomic64(1, &gIopRefused);
        return (IOReturn)0xe00002c7;
    }
    if (!txn) {
        IOPFAIL(kIOReturnBadArgument, "performTransaction(NULL)");
    }
    IOService *fb = *(IOService *const volatile *)((const uint8_t *)this + 0x98);
    if (!fb || fb != displayFramebuffer()) {
        IOPFAIL(kIOReturnNotAttached, "pipe %p drives %p, not our framebuffer %p", this, fb, displayFramebuffer());
    }
    IOSurface *s = txn->getPlaneIOSurface(0, 0);
    if (!s) {
        OSObject *ro = txn->getPlaneResource(0, 0);
        if (OSAddAtomic64(1, &gIopEmpty) < 3) {
            IOPLOG("transaction without a plane-0 IOSurface (resource %s)", ro ? ro->getMetaClass()->getClassName() : "none");
        }
        return kIOReturnSuccess;
    }
    const unsigned fmt = s->getPixelFormat();
    if (fmt != NV_IOP_FMT_BGRA && fmt != NV_IOP_FMT_L10R && fmt != NV_IOP_FMT_RGHA) {
        IOPFAIL(kIOReturnUnsupported, "surface 0x%x format '%c%c%c%c' (0x%08x) is not BGRA, l10r or RGhA", s->getSurfaceID(),
                (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, fmt);
    }
    const unsigned long long W = s->getWidth(), H = s->getHeight(), P = s->getBytesPerRow();
    const unsigned long long bpp = NV_IOP_BYTES_PER_PIXEL(fmt);
    if (!W || !H || W > 16384 || H > 16384 || P < bpp * W || (P & 3)) {
        IOPFAIL(kIOReturnBadArgument, "surface 0x%x geometry %llux%llu pitch %llu", s->getSurfaceID(), W, H, P);
    }
    // Stage 5c: a frame the Metal plugin also copied (on the GPU) into a blob of the same size: show that blob
    // (SET_SCANOUT_BLOB). No CPU copy, and QEMU takes the frame straight from the host GPU's memory. -vgpunoblob off.
    static int noBlob = -1;
    if (noBlob < 0) {
        bool off = false;
        PE_parse_boot_argn("-vgpunoblob", &off, sizeof(off));
        noBlob = off;
    }
    if (!noBlob && fmt == NV_IOP_FMT_BGRA) {
        uint32_t twin[6] = {};
        IOService *core = coreService();
        VGPUScanoutInfo qi = {};
        if (core && core->callPlatformFunction(gSymTwinFor, false, (void *)(uintptr_t)s->getSurfaceID(), twin, nullptr,
                                               nullptr) == kIOReturnSuccess &&
            twin[1] == W && twin[2] == H &&
            fb->callPlatformFunction(gSymScanoutInfo, false, &qi, nullptr, nullptr, nullptr) == kIOReturnSuccess &&
            qi.width == W && qi.height == H) {
            paceMark(&gPaceTxn, mach_absolute_time());
            IOReturn br = queueFlip(twin, s->getSurfaceID()) ? kIOReturnSuccess
                                          : core->callPlatformFunction(gSymScanoutBlob, false, (void *)(uintptr_t)twin[0],
                                                                       (void *)(uintptr_t)twin[1],
                                                                       (void *)(uintptr_t)twin[2],
                                                                       (void *)(uintptr_t)twin[3]);
            if (br == kIOReturnSuccess) {
                gBlobShown = true;
                SInt64 n = OSAddAtomic64(1, &gIopBlob);
                OSAddAtomic64(1, &gIopOk);
                if (n < 3 || n % 600 == 0) {
                    IOPLOG("frame from twin #%lld: surface 0x%x -> blob %u (%ux%u stride %u)", (long long)n + 1,
                           s->getSurfaceID(), twin[0], twin[1], twin[2], twin[3]);
                }
                return kIOReturnSuccess;
            }
            IOPLOG("blob scanout of %u refused (0x%x): copying instead", twin[0], br);
        }
    }
    scanoutFramebufferAgain();
    IOMemoryDescriptor *md = s->getMemoryDescriptor();
    if (!md) {
        IOPFAIL(kIOReturnNoMemory, "surface 0x%x has no memory descriptor", s->getSurfaceID());
    }
    const volatile unsigned *src = (const volatile unsigned *)mapSurface(s->getSurfaceID(), md, H * P);
    if (!src) {
        IOPFAIL(kIOReturnVMError, "surface 0x%x would not prepare/map %llu bytes", s->getSurfaceID(), H * P);
    }
    VGPUScanoutInfo q = {};
    IOReturn r = fb->callPlatformFunction(gSymScanoutInfo, false, &q, nullptr, nullptr, nullptr);
    if (r != kIOReturnSuccess || !q.kva || q.pitch < 4 || !q.height) {
        IOPFAIL(kIOReturnNotReady, "framebuffer would not describe its scanout (0x%x)", r);
    }
    // The copy covers what both have; NV refuses a size mismatch, we log it once and copy the overlap.
    unsigned w = (unsigned)(W < q.width ? W : q.width), h = (unsigned)(H < q.height ? H : q.height);
    if ((W != q.width || H != q.height)) {
        IOPLOG("surface %llux%llu is not the scanout's %ux%u: copying %ux%u", W, H, q.width, q.height, w, h);
    }
    if ((unsigned long long)(h - 1) * q.pitch + 4ULL * w > q.bytes) {
        IOPFAIL(kIOReturnOverrun, "scanout %u rows of pitch %u exceed its %llu bytes", h, q.pitch, q.bytes);
    }
    const unsigned spr = (unsigned)(P / 4), dpr = q.pitch / 4;
    volatile unsigned *d = (volatile unsigned *)q.kva;
    for (unsigned y = 0; y < h; y++) {
        nv_iop_convert_row(d + (unsigned long)y * dpr, src + (unsigned long)y * spr, w, fmt, 0);
    }
    fb->callPlatformFunction(gSymPresent, false, nullptr, nullptr, nullptr, nullptr);
    SInt64 n = OSAddAtomic64(1, &gIopOk);
    if (n < 3 || n % 300 == 0) {
        IOPLOG("frame #%lld: %ux%u '%c%c%c%c' surface 0x%x -> scanout", (long long)n + 1, w, h, (char)(fmt >> 24),
               (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, s->getSurfaceID());
    }
    if (n % 60 == 0) {
        iopPublishCounts();
    }
    return kIOReturnSuccess;
}

class VGGLContext : public IOAccelGLContext2 {
    OSDeclareDefaultStructors(VGGLContext)
    NM_TAHOE_FWD(VGGLContext)
public:
    void _pure362() APPLE_KEXT_OVERRIDE { STUB_LOG("GLContext _pure362"); }
    void _pure363() APPLE_KEXT_OVERRIDE { STUB_LOG("GLContext _pure363"); }
    void _pure364() APPLE_KEXT_OVERRIDE { STUB_LOG("GLContext _pure364"); }
    void _pure367() APPLE_KEXT_OVERRIDE { STUB_LOG("GLContext _pure367"); }
};
OSDefineMetaClassAndStructors(VGGLContext, IOAccelGLContext2)

class VG2DContext : public IOAccel2DContext2 {
    OSDeclareDefaultStructors(VG2DContext)
    NM_TAHOE_FWD(VG2DContext)
public:
    void _pure362() APPLE_KEXT_OVERRIDE { STUB_LOG("2DContext _pure362"); }
    void _pure363() APPLE_KEXT_OVERRIDE { STUB_LOG("2DContext _pure363"); }
};
OSDefineMetaClassAndStructors(VG2DContext, IOAccel2DContext2)

class VGCLContext : public IOAccelCLContext2 {
    OSDeclareDefaultStructors(VGCLContext)
    NM_TAHOE_FWD(VGCLContext)
};
OSDefineMetaClassAndStructors(VGCLContext, IOAccelCLContext2)

class VGVideoContext : public IOAccelVideoContext2 {
    OSDeclareDefaultStructors(VGVideoContext)
    NM_TAHOE_FWD(VGVideoContext)
};
OSDefineMetaClassAndStructors(VGVideoContext, IOAccelVideoContext2)

// Parents for the Venus user clients served through the accelerator: IOService::attach sleeps once a service has
// ~1019 children (NV), and the name keeps the sandbox's IOAccel prefix rules happy whichever entry they look at.
#define VG_CARRIERS 8
class IOAccelVirtioCarrier : public IOService {
    OSDeclareDefaultStructors(IOAccelVirtioCarrier)
};
OSDefineMetaClassAndStructors(IOAccelVirtioCarrier, IOService)

// ---- the accelerator ---------------------------------------------------------------------------------------------

class VirtioGPUAccel : public IOGraphicsAccelerator2 {
    OSDeclareDefaultStructors(VirtioGPUAccel)
    NM_TAHOE_FWD(VirtioGPUAccel)

public:
    IOBufferMemoryDescriptor *stamps_ = nullptr;
    IORangeAllocator *ranges_[32] = {};
    unsigned enables_ = 0;
    // stage 5a
    uint32_t gate_ = 0;                       // the vgpuaccel boot-arg
    IOPCIDevice *pci_ = nullptr;
    VGDisplayMachine *dm_ = nullptr;          // the family keeps it; not retained here (NV does the same)
    IOService *volatile fb_ = nullptr;        // VirtioGPUFramebuffer, retained
    IONotifier *fbNote_ = nullptr;
    IOWorkLoop *armLoop_ = nullptr;           // our own: found_framebuffer must not run on the family's or IOKit's
    IOTimerEventSource *armTimer_ = nullptr;
    IOTimerEventSource *holdTimer_ = nullptr;
    volatile SInt32 hold_ = 0;                // 1 while the boot hold (adjustBusy(1)) is on
    volatile SInt32 armed_ = 0;               // 1 registered + pipe; 2 + AGDC + capabilities; 3 + MetalPluginName
    IOService *agdc_ = nullptr;
    IOService *carriers_[VG_CARRIERS] = {};
    unsigned carrierNext_ = 0;
    int wsPids_[4] = {};                      // WindowServer pids that opened the Venus client since the last arm
    unsigned wsCount_ = 0;
    int pipePids_[4] = {};                    // WindowServer pids that opened the display pipe since the last arm
    unsigned pipeCount_ = 0;
    volatile SInt32 request_ = 0;
    bool noLegacy_ = true;                    // armed: refuse WindowServer legacy IOAccelSurfaces (type 0); 5b probe             // for armTick after the first arm: 1 withdraw, 2 arm for WindowServer

    IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;
    bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    void free() APPLE_KEXT_OVERRIDE;
    IOReturn setProperties(OSObject *properties) APPLE_KEXT_OVERRIDE;
    IOReturn newUserClient(task_t owningTask, void *securityID, UInt32 type, IOUserClient **handler) APPLE_KEXT_OVERRIDE;
    OSObject *newDisplayPipe() APPLE_KEXT_OVERRIDE {
        VGDisplayPipe *p = OSTypeAlloc(VGDisplayPipe);
        vlog("newDisplayPipe -> %p", p);
        return p;
    }
    static bool fbPublished(void *target, void *ref, IOService *service, IONotifier *note);
    void armTick(IOTimerEventSource *);
    void holdTick(IOTimerEventSource *);
    void releaseHold(const char *why);
    bool registerFramebuffer();
    void nameOnFramebuffer(bool on);
    IOService *findCore();
    void withdrawForWindowServer(const char *why);
    void armForWindowServer(const char *why);
    void request(SInt32 what) {
        request_ = what;
        if (armTimer_) {
            armTimer_->setTimeoutMS(1);
        }
    }

    uint64_t getStampMemory(unsigned int *count) APPLE_KEXT_OVERRIDE {
        if (!stamps_) {
            stamps_ = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous,
                                                                 16384, 4096);
            if (stamps_) {
                stamps_->prepare();
                bzero(stamps_->getBytesNoCopy(), 16384);
            }
        }
        if (count) {
            *count = stamps_ ? 4096 : 0;
        }
        vlog("getStampMemory -> %p (4096 stamps)", stamps_);
        return (uint64_t)stamps_;
    }
    void writeStamp(int index, unsigned int value) {
        if (stamps_ && index >= 0 && index < 4096) {
            ((volatile unsigned int *)stamps_->getBytesNoCopy())[index] = value;
        }
    }
    OSObject *newEventMachine() APPLE_KEXT_OVERRIDE { vlog("newEventMachine"); return OSTypeAlloc(VGEventMachine); }
    OSObject *newGPUTask(const char *who) {
        for (unsigned i = 0; i < 32; i++) {
            if (!ranges_[i]) {
                ranges_[i] = IORangeAllocator::withRange(1ULL << 40, 4096);
                if (ranges_[i]) {
                    ranges_[i]->allocateRange(0, 0x100000);
                }
            }
        }
        VGTask *t = OSTypeAlloc(VGTask);
        bool ok = t && t->init(this, 1, ranges_);
        vlog("%s -> init %d", who, ok);
        if (t && !ok) {
            t->release();
            t = nullptr;
        }
        return t;
    }
    OSObject *createUserGPUTask() APPLE_KEXT_OVERRIDE { return newGPUTask("createUserGPUTask"); }
    OSObject *createKernelGPUTask() APPLE_KEXT_OVERRIDE { return newGPUTask("createKernelGPUTask"); }
    void populateAccelConfig(IOAccelConfig *c) APPLE_KEXT_OVERRIDE;
    bool configureDevice(IOPCIDevice *pci) APPLE_KEXT_OVERRIDE {
        vlog("configureDevice %04x:%04x (the core owns the device; nothing to do)", pci ? pci->configRead16(0) : 0,
             pci ? pci->configRead16(2) : 0);
        return true;
    }
    void teardownDevice(IOPCIDevice *) APPLE_KEXT_OVERRIDE { vlog("teardownDevice"); }
    OSObject *newDisplayMachine() APPLE_KEXT_OVERRIDE {
        dm_ = OSTypeAlloc(VGDisplayMachine);
        vlog("newDisplayMachine -> %p", dm_);
        return dm_;
    }
    OSObject *newGLContext() APPLE_KEXT_OVERRIDE { STUB_LOG("newGLContext"); return OSTypeAlloc(VGGLContext); }
    OSObject *newCLContext() APPLE_KEXT_OVERRIDE { STUB_LOG("newCLContext"); return OSTypeAlloc(VGCLContext); }
    OSObject *newSurface() APPLE_KEXT_OVERRIDE { STUB_LOG("newSurface"); return OSTypeAlloc(VGSurface); }
    OSObject *new2DContext() APPLE_KEXT_OVERRIDE { STUB_LOG("new2DContext"); return OSTypeAlloc(VG2DContext); }
    OSObject *newVideoContext() APPLE_KEXT_OVERRIDE { STUB_LOG("newVideoContext"); return OSTypeAlloc(VGVideoContext); }
    OSObject *newSysMemory() APPLE_KEXT_OVERRIDE { STUB_LOG("newSysMemory"); return OSTypeAlloc(VGSysMemory); }
    OSObject *newVidMemory() APPLE_KEXT_OVERRIDE { STUB_LOG("newVidMemory"); return OSTypeAlloc(VGVidMemory); }
    OSObject *newResource() APPLE_KEXT_OVERRIDE { STUB_LOG("newResource"); return OSTypeAlloc(VGResource); }
    OSObject *newMemoryMap() APPLE_KEXT_OVERRIDE { STUB_LOG("newMemoryMap"); return OSTypeAlloc(VGMemoryMap); }

    // The family's enable gate: IOAccelSharedUserClient2::new_resource sleeps in acceleratorWaitEnabled() until bit 0x2
    // of the flags dword at ivar +0xc78 is set, and only enableAccelerator() sets it (NV, re/IOGraphicsAccelerator2.h).
    uint32_t enableFlags() const { return *(const volatile uint32_t *)((const uint8_t *)this + 0xc78); }
    void enableNow(const char *why) {
        uint32_t before = enableFlags();
        enableAccelerator();
        enables_++;
        vlog("enableAccelerator() from %s (#%u): flags +0xc78 0x%x -> 0x%x (bit 0x2 %s)", why, enables_, before,
             enableFlags(), (enableFlags() & 2) ? "set: allocations won't wait" : "CLEAR");
        setProperty("VirtioGPUAccelEnabledFrom", why);
    }
};
OSDefineMetaClassAndStructors(VirtioGPUAccel, IOGraphicsAccelerator2)

NM_TAHOE_FWD_DEFS

void VGEventMachine::writeStamp(int s, vendevtCommandRec *, unsigned int v) {
    if (gAccel) {
        gAccel->writeStamp(s, v);
    }
}

static void enableFrom(const char *why) {
    if (gAccel) {
        gAccel->enableNow(why);
    }
}

static IOService *displayFramebuffer() {
    return gAccel ? gAccel->fb_ : nullptr;
}

static void publishShown(uint32_t surface) {
    static uint32_t shown;
    if (gAccel && surface && shown != surface) {
        shown = surface;
        gAccel->setProperty("VirtioGPUShownSurface", surface, 32);
    }
}

static IOService *coreService() {
    static IOService *core;
    if (!core && gAccel) {
        core = gAccel->findCore();   // the core outlives us (it is our provider's other client)
    }
    return core;
}

static void iopPublishCounts() {
    if (!gAccel) {
        return;
    }
    char line[160];
    snprintf(line, sizeof(line), "calls %lld ok %lld (from a twin %lld) fail %lld empty %lld refused %lld",
             (long long)gIopCalls, (long long)gIopOk, (long long)gIopBlob, (long long)gIopFail, (long long)gIopEmpty,
             (long long)gIopRefused);
    gAccel->setProperty("VirtioGPUPipeFrames", line);
    uint64_t span = 0;
    absolutetime_to_nanoseconds((uint64_t)(gIopLastAbs - gIopFirstAbs), &span);
    snprintf(line, sizeof(line), "copy avg %lld us max %lld us; %lld frames in %lld ms (%lld.%lld fps)",
             gIopCalls ? (long long)(gIopNs / gIopCalls / 1000) : 0LL, (long long)(gIopMaxNs / 1000), (long long)gIopCalls,
             (long long)(span / 1000000), span ? (long long)(gIopCalls * 1000000000LL / (SInt64)span) : 0LL,
             span ? (long long)((gIopCalls * 10000000000LL / (SInt64)span) % 10) : 0LL);
    gAccel->setProperty("VirtioGPUPipeTiming", line);
    snprintf(line, sizeof(line), "%lld flips, avg %lld us, max %lld us; %lld frames replaced before their flip, %lld "
             "flipped unready",
             (long long)gFlips, gFlips ? (long long)(gFlipNs / gFlips / 1000) : 0LL, (long long)(gFlipMaxNs / 1000),
             (long long)gFlipsSkipped, (long long)gFlipsUnready);
    gAccel->setProperty("VirtioGPUBlobFlips", line);
    char pace[600];
    int k = paceLine(pace, sizeof(pace), "frame gaps ms", &gPaceTxn, kGapEdges, false);
    k += snprintf(pace + k, sizeof(pace) - k, " | ");
    k += paceLine(pace + k, sizeof(pace) - k, "flip gaps", &gPaceFlip, kGapEdges, false);
    k += snprintf(pace + k, sizeof(pace) - k, " | ");
    paceLine(pace + k, sizeof(pace) - k, "flip took", &gFlipDur, kDurEdges, true);
    gAccel->setProperty("VirtioGPUPacing", pace);
}

void VirtioGPUAccel::populateAccelConfig(IOAccelConfig *c) {
    uint8_t *p = reinterpret_cast<uint8_t *>(c);
    if (!p) {
        vlog("populateAccelConfig(NULL)");
        return;
    }
    if (((uintptr_t)p & 0xFFF) + 0x70 > 0x1000) {
        vlog("populateAccelConfig: 0x70 bytes would cross a page; not touching it");
        return;
    }
    vlog("populateAccelConfig: family pre-filled %016llx %016llx %016llx %016llx", *(const uint64_t *)(p + 0),
         *(const uint64_t *)(p + 8), *(const uint64_t *)(p + 0x28), *(const uint64_t *)(p + 0x30));
    // NV's values (nvrm-accel.cpp populateAccelConfig): AccelCaps 15, flags, 16384^2 textures, one framebuffer.
    *(uint64_t *)(p + 0x00) = (uint64_t)(uintptr_t) "VirtioGPUAccelerator";
    *(uint32_t *)(p + 0x08) = 0x30844300u;
    *(uint32_t *)(p + 0x0c) = 15u;
    *(uint32_t *)(p + 0x18) = 8u;
    *(uint32_t *)(p + 0x30) = 0x40004000u;
    *(uint32_t *)(p + 0x34) = 0x00008000u;
    *(uint32_t *)(p + 0x38) = 0x00008000u;
    *(uint8_t *)(p + 0x44) = 0;
    *(uint8_t *)(p + 0x46) = 1;
    *(uint8_t *)(p + 0x47) = 1;
    *(uint64_t *)(p + 0x48) = 0x0000001F0000000FULL;
    *(uint64_t *)(p + 0x50) = 0x7FFFFFFF0000001FULL;
    *(uint64_t *)(p + 0x58) = 0x0000000C00000000ULL;
    *(uint32_t *)(p + 0x64) = 0x4Bu;
    *(uint32_t *)(p + 0x28) = 1;
    vlog("populateAccelConfig: filled (AccelCaps 15, max framebuffers 1)");
}

IOService *VirtioGPUAccel::probe(IOService *provider, SInt32 *score) {
    gLogPci = provider;
    int off = 0;
    if (PE_parse_boot_argn("-vgpuaccoff", &off, sizeof(off))) {
        vlog("probe: -vgpuaccoff, not claiming");
        return nullptr;
    }
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci || pci->configRead16(0) != 0x1af4 || pci->configRead16(2) != 0x1050) {
        vlog("probe: not the virtio-gpu device");
        return nullptr;
    }
    vlog("probe: virtio-gpu %04x:%04x, score %d", pci->configRead16(0), pci->configRead16(2), score ? (int)*score : 0);
    return IOGraphicsAccelerator2::probe(provider, score);
}

bool VirtioGPUAccel::start(IOService *provider) {
    gLogPci = provider;
    uint32_t gate = 0;
    if (!PE_parse_boot_argn("vgpuaccel", &gate, sizeof(gate)) || !gate) {
        vlog("start: boot-arg vgpuaccel absent, not starting (the family is loaded; nothing else happens)");
        return false;
    }
    gAccel = this;
    if (!gSpareVidMem) {
        gSpareVidMem = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, round_page(kSpareVidMemBytes), 0xFFFFFFFFFFFFF000ULL);
        vlog("start: spare video memory block (%llu bytes) %s", (unsigned long long)kSpareVidMemBytes,
             gSpareVidMem ? "taken" : "NOT available (Retina modes may come up black)");
    }
    vlog("start: vgpuaccel=%u, calling IOGraphicsAccelerator2::start", gate);
    bool ok = IOGraphicsAccelerator2::start(provider);
    vlog("IOGraphicsAccelerator2::start -> %d", ok);
    if (!ok) {
        gAccel = nullptr;
        return false;
    }
    gate_ = gate;
    if (int legacy = 0; PE_parse_boot_argn("-vgpulegacy", &legacy, sizeof(legacy))) {
        noLegacy_ = false;   // armed WindowServer may open legacy IOAccelSurfaces (as before 5b)
    }
    gSymScanoutInfo = OSSymbol::withCStringNoCopy(kVGPUFBScanoutInfo);
    gSymPresent = OSSymbol::withCStringNoCopy(kVGPUFBPresent);
    gSymTwinFor = OSSymbol::withCStringNoCopy(kVGPUTwinFor);
    gSymScanoutBlob = OSSymbol::withCStringNoCopy(kVGPUScanoutBlob);
    gSymNewClient = OSSymbol::withCStringNoCopy(kVGPUNewClient);
    pci_ = OSDynamicCast(IOPCIDevice, provider);
    setProperty("IOAccelRevision", 2ULL, 32);
    setProperty("IOVARendererID", 0x01020000ULL, 32);
    setProperty("VirtioGPUAccelUnarmed", kOSBooleanTrue);   // no MetalPluginName until armed
    for (unsigned i = 0; i < VG_CARRIERS; i++) {
        IOAccelVirtioCarrier *c = OSTypeAlloc(IOAccelVirtioCarrier);
        if (!c || !c->init() || !c->attach(this)) {
            OSSafeReleaseNULL(c);
            break;
        }
        if (!c->start(this)) {
            c->detach(this);
            c->release();
            break;
        }
        carriers_[i] = c;
    }
    if (uint32_t ms = 0; PE_parse_boot_argn("vgpuflipms", &ms, sizeof(ms))) {
        gFlipMinMs = ms;
    }
    if (gate >= 3 && !gPresentLoop) {
        gPresentLock = IOLockAlloc();
        gPresentLoop = IOWorkLoop::workLoop();
        gPresentTimer = IOTimerEventSource::timerEventSource(this, presentTick);
        if (!gPresentLock || !gPresentLoop || !gPresentTimer ||
            gPresentLoop->addEventSource(gPresentTimer) != kIOReturnSuccess) {
            vlog("start: present work loop setup failed: blob flips run inline");
            OSSafeReleaseNULL(gPresentTimer);
        }
    }
    if (gate >= 3) {
        // The display (5a): hold the registry busy (WindowServer waits for quiet) until the arm finishes or 20 s pass.
        armLoop_ = IOWorkLoop::workLoop();
        armTimer_ = IOTimerEventSource::timerEventSource(
            this, OSMemberFunctionCast(IOTimerEventSource::Action, this, &VirtioGPUAccel::armTick));
        holdTimer_ = IOTimerEventSource::timerEventSource(
            this, OSMemberFunctionCast(IOTimerEventSource::Action, this, &VirtioGPUAccel::holdTick));
        if (!armLoop_ || !armTimer_ || !holdTimer_ || armLoop_->addEventSource(armTimer_) != kIOReturnSuccess ||
            armLoop_->addEventSource(holdTimer_) != kIOReturnSuccess) {
            vlog("start: arm work loop setup FAILED: the display stays unarmed (software compositor)");
            gate_ = 2;
        } else if (int nohold = 0; !PE_parse_boot_argn("-vgpunohold", &nohold, sizeof(nohold))) {
            hold_ = 1;
            adjustBusy(1);
            holdTimer_->setTimeoutMS(20000);
            setProperty("VirtioGPUBootHold", "holding");
            vlog("boot hold ON (adjustBusy +1, released when armed or after 20 s)");
        }
    }
    if (gate_ >= 3) {
        // The index the framebuffer names this accelerator by (IOAccelIndex); IOPresentment reads it on the
        // accelerator, before it is registered, to match the display to this GPU (Reims' finding).
        setProperty("IOAccelIndex", 0ULL, 32);
    }
    if (gate_ >= 2) {
        registerService();
        vlog("registerService() (vgpuaccel=%u)", gate_);
    } else {
        vlog("not registered (vgpuaccel=1); vgpuaccel=2 registers");
    }
    enableNow("start");
    if (gate_ >= 3) {
        if (OSDictionary *m = serviceMatching("VirtioGPUFramebuffer")) {
            fbNote_ = addMatchingNotification(gIOFirstPublishNotification, m, &VirtioGPUAccel::fbPublished, this, nullptr, 0);
            m->release();
        }
        vlog("display arm (vgpuaccel=%u): watching for VirtioGPUFramebuffer -> %p", gate_, fbNote_);
        if (!fbNote_) {
            releaseHold("no framebuffer notifier");
        }
    }
    return true;
}

bool VirtioGPUAccel::fbPublished(void *target, void *, IOService *service, IONotifier *) {
    VirtioGPUAccel *me = (VirtioGPUAccel *)target;
    if (!me || !service) {
        return true;
    }
    service->retain();
    if (!OSCompareAndSwapPtr(nullptr, service, (void *volatile *)&me->fb_)) {
        service->release();
        vlog("a second VirtioGPUFramebuffer published: ignored (one display)");
        return true;
    }
    OSNumber *idx = OSDynamicCast(OSNumber, service->getProperty("IOFBDependentIndex"));
    vlog("VirtioGPUFramebuffer published (IOFBDependentIndex %d): arming from the arm work loop", idx ? (int)idx->unsigned32BitValue() : -1);
    // Not here: found_framebuffer from inside a matching notification is NV's documented don't.
    me->armTimer_->setTimeoutMS(50);
    return true;
}

void VirtioGPUAccel::holdTick(IOTimerEventSource *) {
    if (hold_) {
        vlog("boot hold: 20 s passed, armed level %d: releasing", (int)armed_);
        releaseHold("cap (20 s)");
    }
}

void VirtioGPUAccel::releaseHold(const char *why) {
    if (OSCompareAndSwap(1, 0, &hold_)) {
        adjustBusy(-1);
        setProperty("VirtioGPUBootHold", why);
        vlog("boot hold released (%s)", why);
    }
}

// found_framebuffer: the family adds a framebuffer to the display machine and makes its display pipe (newDisplayPipe).
// The machine's pipe count is at +0x108 and its pipes at +0x88 (NV, macOS 26.7.1); a pipe's framebuffer is at +0x98.
// The framebuffer names its accelerator (5b): IOAccelTypes = this accelerator's service-plane path, IOAccelIndex = 0.
// CoreDisplay pairs a display with a GPU through them (CDDisplay::compositor() is the Metal compositor only for a
// display with an accelerator; without them it was CompositorSW beside a Metal device, and Core Animation aborted on
// a surface of the other context). Only while WindowServer may have the device: a framebuffer naming a registered
// accelerator with no Metal device aborts WindowServer (Reims measured it).
void VirtioGPUAccel::nameOnFramebuffer(bool on) {
    IOService *fb = fb_;
    if (!fb) {
        return;
    }
    if (!on) {
        fb->removeProperty("IOAccelTypes");
        fb->removeProperty("IOAccelIndex");
        vlog("framebuffer no longer names the accelerator");
        return;
    }
    char path[512];
    int len = sizeof(path);
    if (getPath(path, &len, gIOServicePlane)) {
        fb->setProperty("IOAccelTypes", path);
        fb->setProperty("IOAccelIndex", 0ULL, 32);
        vlog("framebuffer names the accelerator: IOAccelTypes %s, IOAccelIndex 0", path);
    } else {
        vlog("framebuffer naming: no service-plane path for the accelerator");
    }
}

bool VirtioGPUAccel::registerFramebuffer() {
    IOService *fb = fb_;
    if (!dm_ || !fb) {
        vlog("register: no display machine (%p) or framebuffer (%p)", dm_, fb);
        return false;
    }
    uint8_t *dm = (uint8_t *)dm_;
    uint32_t before = *(volatile uint32_t *)(dm + 0x108);
    if (before > 8) {
        vlog("register: implausible pipe count %u at dm+0x108: layout differs, not touching it", before);
        return false;
    }
    for (uint32_t i = 0; i < before; i++) {
        uint8_t *p = *(uint8_t *volatile *)(dm + 0x88 + 8 * i);
        if (p && *(IOService *volatile *)(p + 0x98) == fb) {
            vlog("register: the family already has our framebuffer (pipe %u = %p)", i, p);
            return true;
        }
    }
    vlog("register: found_framebuffer(%p), pipes before %u", fb, before);
    dm_->found_framebuffer((IOFramebuffer *)fb);
    uint32_t after = *(volatile uint32_t *)(dm + 0x108);
    if (after != before + 1) {
        vlog("register: pipe count %u -> %u: the family did not add it", before, after);
        return false;
    }
    uint8_t *pipe = *(uint8_t *volatile *)(dm + 0x88 + 8 * before);
    if (!pipe) {
        *(volatile uint32_t *)(dm + 0x108) = before;   // NV: the family stores a NULL pipe unchecked; never broadcast to it
        vlog("register: the family stored a NULL pipe; count put back to %u", before);
        return false;
    }
    IOService *pfb = *(IOService *volatile *)(pipe + 0x98);
    vlog("register: pipe %u = %p (%s), drives %p%s", before, pipe, ((OSObject *)pipe)->getMetaClass()->getClassName(), pfb,
         pfb == fb ? " = ours" : " -- NOT ours");
    return pfb == fb;
}

// The arm (5a), NV's order (NVRM.cpp auto-go): framebuffer registered + mode change, then AGDC, then the pipe
// capabilities, then (level 4) the plugin name, then the hold goes.
void VirtioGPUAccel::armTick(IOTimerEventSource *) {
    if (armed_) {
        SInt32 r = request_;
        request_ = 0;
        if (r == 1) {
            withdrawForWindowServer(getProperty("VirtioGPUGuardWhy") ? "the guard" : "a root request");
        } else if (r == 2) {
            armForWindowServer("a root request");
        }
        return;
    }
    if (gate_ >= 4) {
        nameOnFramebuffer(true);   // before found_framebuffer, as a framebuffer that names its GPU at its start
    }
    if (!registerFramebuffer()) {
        setProperty("VirtioGPUArmState", "framebuffer NOT registered: software compositor");
        releaseHold("framebuffer not registered");
        return;
    }
    armed_ = 1;
    uint8_t *dm = (uint8_t *)dm_;
    vlog("arm: display_mode_will_change/did_change (pipes %u)", *(volatile uint32_t *)(dm + 0x108));
    dm_->display_mode_will_change(0);
    dm_->display_mode_did_change(0);
    vlog("arm: flags +0xc78 = 0x%x", enableFlags());
    int off = 0;
    if (!PE_parse_boot_argn("-vgpunoagdc", &off, sizeof(off))) {
        agdc_ = vgaccel_agdc_create(pci_, fb_);
    } else {
        vlog("arm: -vgpunoagdc: no AGDC");
    }
    if (OSDictionary *caps = OSDictionary::withCapacity(2)) {
        caps->setObject("DisplayPipeSupported", kOSBooleanTrue);
        caps->setObject("TransactionsSupported", kOSBooleanTrue);
        setProperty("IOAccelDisplayPipeCapabilities", caps);
        caps->release();
        gIop = 1;
    }
    armed_ = 2;
    vlog("arm: IOAccelDisplayPipeCapabilities published, transactions open (AGDC %s)", agdc_ ? "up" : "NOT up");
    if (gate_ >= 4) {
        armForWindowServer("vgpuaccel=4");
    } else {
        setProperty("VirtioGPUArmState", "display only (no MetalPluginName)");
    }
    releaseHold("armed");
}

void VirtioGPUAccel::armForWindowServer(const char *why) {
    nameOnFramebuffer(true);
    if (!agdc_) {
        agdc_ = vgaccel_agdc_create(pci_, fb_);
    }
    if (OSDictionary *caps = OSDictionary::withCapacity(2)) {
        caps->setObject("DisplayPipeSupported", kOSBooleanTrue);
        caps->setObject("TransactionsSupported", kOSBooleanTrue);
        setProperty("IOAccelDisplayPipeCapabilities", caps);
        caps->release();
    }
    gIop = 1;
    wsCount_ = 0;
    pipeCount_ = 0;
    setProperty("MetalPluginName", "VirtioGPUMetal");
    setProperty("MetalPluginClassName", "VGMTLDevice");
    setProperty("VirtioGPUWindowServer", kOSBooleanTrue);
    // OpenGL over Metal (5d; boot-arg vgpugl=0 turns it off): new OpenGL processes get Apple's AppleMetalOpenGLRenderer,
    // which runs on this accelerator's Metal device, instead of the software renderer (GLRendererFloat). After
    // nullmoth's nvrm-accel.
    if (int gl = 1; !PE_parse_boot_argn("vgpugl", &gl, sizeof(gl)) || gl) {
        setProperty("IOGLBundleName", "AppleMetalOpenGLRenderer");
        vlog("arm: IOGLBundleName AppleMetalOpenGLRenderer (vgpugl)");
    }
    removeProperty("VirtioGPUAccelUnarmed");
    removeProperty("VirtioGPUGuard");
    removeProperty("VirtioGPUGuardWhy");
    armed_ = 3;
    setProperty("VirtioGPUArmState", "display + Metal for WindowServer");
    vlog("arm: MetalPluginName published, WindowServer allowed (%s; AGDC %s)", why, agdc_ ? "up" : "NOT up");
}

IOService *VirtioGPUAccel::findCore() {
    IOService *core = nullptr;
    if (OSIterator *it = pci_ ? pci_->getClientIterator() : nullptr) {
        while (OSObject *o = it->getNextObject()) {
            if (o->metaCast("VirtioGPU")) {
                core = (IOService *)o;
                break;
            }
        }
        it->release();
    }
    return core;
}

// From the arm work loop only (it terminates the AGDC synchronously).
void VirtioGPUAccel::withdrawForWindowServer(const char *why) {
    // MetalPluginName stays (5c): at vgpuaccel=4 the framebuffer's class name sends every WindowServer down the
    // IOPresentment path, and only our plugin, loaded into WindowServer, can turn that off again (vg_coredisplay_off);
    // VirtioGPUWindowServer = false makes it refuse WindowServer the device.
    setProperty("VirtioGPUWindowServer", kOSBooleanFalse);
    removeProperty("IOAccelDisplayPipeCapabilities");
    nameOnFramebuffer(false);
    gIop = 0;
    scanoutFramebufferAgain();
    // The AGDC stays: AppleGraphicsDeviceControl refuses terminate (measured: -> 0), and without the capabilities
    // WindowServer finds no display pipe and composites in software anyway (measured 2026-11-15).
    armed_ = 1;
    setProperty("VirtioGPUGuard", why);
    setProperty("VirtioGPUArmState", "withdrawn: no pipe capabilities, no Metal for WindowServer (software compositor)");
    vlog("WITHDRAWN (%s): pipe capabilities gone, WindowServer refused; the next WindowServer composites in software", why);
}

// ---- 5b probe: the display pipe's user client (IOAccelDisplayPipeUserClient2, the family's) ----------------------
// CoreDisplay logs "Fallback GPU Display Pipe transaction submission failed" while no transaction reaches the pipe's
// submitTransaction: the call fails in the family's user client first. Its externalMethod is wrapped (a copy of its
// vtable with that one slot replaced) to log each selector's first calls, its arguments and every failure.
namespace {
using ExtFn = IOReturn (*)(IOUserClient *, uint32_t, IOExternalMethodArguments *, IOExternalMethodDispatch *, OSObject *,
                           void *);
ExtFn gPipeUCExt = nullptr;
unsigned gPipeUCSlot = 0;
uint32_t gPipeUCCalls[64];
uint32_t gPipeUCFails = 0;
constexpr unsigned kVtableCopySlots = 600;

IOReturn vg_pipeuc_ext(IOUserClient *self, uint32_t sel, IOExternalMethodArguments *a, IOExternalMethodDispatch *d,
                       OSObject *t, void *ref) {
    IOReturn r = gPipeUCExt(self, sel, a, d, t, ref);
    uint32_t n = sel < 64 ? __atomic_add_fetch(&gPipeUCCalls[sel], 1, __ATOMIC_RELAXED) : 0;
    bool fail = r != kIOReturnSuccess && __atomic_add_fetch(&gPipeUCFails, 1, __ATOMIC_RELAXED) <= 40;
    if (n <= 2 || fail) {
        vgaccel_log("pipeuc sel %u #%u -> 0x%x (in %u scalars [0x%llx 0x%llx 0x%llx] %u bytes, out %u scalars %u bytes)", sel,
                    n, r, a ? a->scalarInputCount : 0, a && a->scalarInputCount > 0 ? a->scalarInput[0] : 0,
                    a && a->scalarInputCount > 1 ? a->scalarInput[1] : 0, a && a->scalarInputCount > 2 ? a->scalarInput[2] : 0,
                    a ? a->structureInputSize : 0, a ? a->scalarOutputCount : 0, a ? a->structureOutputSize : 0);
    }
    return r;
}

void vg_pipeuc_wrap(IOUserClient *uc) {
    auto mfp = static_cast<IOReturn (IOUserClient::*)(uint32_t, IOExternalMethodArguments *, IOExternalMethodDispatch *,
                                                      OSObject *, void *)>(&IOUserClient::externalMethod);
    uintptr_t raw[2];
    memcpy(raw, &mfp, sizeof(raw));
    if (!(raw[0] & 1)) {
        vgaccel_log("pipeuc: externalMethod isn't virtual by its member pointer (0x%lx): no probe", (unsigned long)raw[0]);
        return;
    }
    unsigned slot = (unsigned)((raw[0] - 1) / sizeof(void *));
    void **vptr = *(void ***)uc;
    if (gPipeUCExt && (ExtFn)vptr[slot] == vg_pipeuc_ext) {
        return;
    }
    void **copy = (void **)IOMalloc((kVtableCopySlots + 2) * sizeof(void *));   // never freed: objects keep using it
    if (!copy || slot >= kVtableCopySlots) {
        return;
    }
    memcpy(copy, vptr - 2, (kVtableCopySlots + 2) * sizeof(void *));
    if (!gPipeUCExt) {
        gPipeUCExt = (ExtFn)vptr[slot];
        gPipeUCSlot = slot;
    }
    copy[2 + slot] = (void *)vg_pipeuc_ext;
    *(void ***)uc = copy + 2;
    vgaccel_log("pipeuc: %s's externalMethod (slot %u) wrapped", uc->getMetaClass()->getClassName(), slot);
}
} // namespace

IOReturn VirtioGPUAccel::newUserClient(task_t owningTask, void *securityID, UInt32 type, IOUserClient **handler) {
    char who[32] = "?";
    proc_selfname(who, sizeof(who));
    if (type == 0 && armed_ == 3 && noLegacy_ && !strcmp(who, "WindowServer")) {
        static int logged = 0;
        if (logged++ < 3) {
            vlog("WindowServer asks for a legacy IOAccelSurface (type 0): refused while armed (VirtioGPULegacySurfaces)");
        }
        return kIOReturnUnsupported;
    }
    if (type != kVGUCAccelType) {
        IOReturn r = IOGraphicsAccelerator2::newUserClient(owningTask, securityID, type, handler);
        static int logged = 0;
        if (logged < 30 && !strcmp(who, "WindowServer")) {
            logged++;
            vlog("WindowServer opened family user client type %u -> 0x%x %s", (unsigned)type, r,
                 (r == kIOReturnSuccess && handler && *handler) ? (*handler)->getMetaClass()->getClassName() : "");
        }
        bool noProbe = false;
        PE_parse_boot_argn("-vgpunopipeprobe", &noProbe, sizeof(noProbe));
        if (type == 4 && r == kIOReturnSuccess && handler && *handler && !strcmp(who, "WindowServer") && !noProbe) {
            vg_pipeuc_wrap(*handler);
        }
        if (type == 4 && r == kIOReturnSuccess && !strcmp(who, "WindowServer")) {
            int pid = proc_selfpid();
            bool seen = false;
            for (unsigned i = 0; i < pipeCount_ && i < 4; i++) {
                seen |= pipePids_[i] == pid;
            }
            if (!seen) {
                if (pipeCount_ < 4) {
                    pipePids_[pipeCount_] = pid;
                }
                pipeCount_++;
                vlog("WindowServer pid %d opens the display pipe (#%u since the arm)", pid, pipeCount_);
                if (pipeCount_ >= 3 && armed_ == 3) {
                    setProperty("VirtioGPUGuardWhy", "a third WindowServer on the display pipe since the arm");
                    vlog("GUARD: a third WindowServer on the display pipe since the arm: withdrawing");
                    request(1);
                }
            }
        }
        return r;
    }
    if (!strcmp(who, "WindowServer")) {
        int pid = proc_selfpid();
        bool seen = false;
        for (unsigned i = 0; i < wsCount_ && i < 4; i++) {
            seen |= wsPids_[i] == pid;
        }
        if (!seen) {
            if (wsCount_ < 4) {
                wsPids_[wsCount_] = pid;
            }
            wsCount_++;
            vlog("WindowServer pid %d opens the Venus client (WindowServer #%u this boot)", pid, wsCount_);
            if (dm_ && *(volatile uint32_t *)((uint8_t *)dm_ + 0x108) >= 1) {
                if (VGDisplayPipe *p = OSDynamicCast(VGDisplayPipe, *(OSObject *volatile *)((uint8_t *)dm_ + 0x88))) {
                    p->gates("as WindowServer opens Venus");
                }
            }
            if (wsCount_ >= 3 && armed_ == 3) {
                setProperty("VirtioGPUGuardWhy", "a third WindowServer since the arm");
                vlog("GUARD: a third WindowServer since the arm: withdrawing");
                request(1);
            }
        }
    }
    IOService *core = findCore();
    if (!core) {
        vlog("Venus client for %s: no core service", who);
        return kIOReturnNotAttached;
    }
    IOUserClient *uc = nullptr;
    IOReturn r = core->callPlatformFunction(gSymNewClient, false, (void *)owningTask, &uc, securityID, nullptr);
    if (r != kIOReturnSuccess || !uc) {
        vlog("Venus client for %s: the core refused (0x%x)", who, r);
        return r ? r : kIOReturnNoResources;
    }
    IOService *carrier = nullptr;
    for (unsigned i = 0; i < VG_CARRIERS && !carrier; i++) {
        carrier = carriers_[(carrierNext_ + i) % VG_CARRIERS];
    }
    carrierNext_++;
    if (!carrier || !uc->attach(carrier)) {
        vlog("Venus client for %s: no carrier to attach to", who);
        uc->release();
        return kIOReturnNoResources;
    }
    if (!uc->start(carrier)) {
        vlog("Venus client for %s: start failed", who);
        uc->detach(carrier);
        uc->release();
        return kIOReturnInternalError;
    }
    static int logged = 0;
    if (logged++ < 20) {
        vlog("Venus client for %s (pid %d) through the accelerator", who, proc_selfpid());
    }
    *handler = uc;
    return kIOReturnSuccess;
}

void VirtioGPUAccel::stop(IOService *provider) {
    gIop = 0;
    if (fbNote_) {
        fbNote_->remove();
        fbNote_ = nullptr;
    }
    if (armTimer_) {
        armTimer_->cancelTimeout();
    }
    if (holdTimer_) {
        holdTimer_->cancelTimeout();
    }
    releaseHold("stop");
    IOGraphicsAccelerator2::stop(provider);
}

// The late arm (stage 4a). A root process sets, through IORegistryEntrySetCFProperties on this service:
//   {"VirtioGPUArm": {"MetalPluginName": "...", "MetalPluginClassName": "..."}}  publish the Metal plugin
//   {"VirtioGPUDisarm": true}                                                     withdraw it
// Only processes that ask Metal for devices afterwards load the plugin (WindowServer is already running and never
// sees it). Nothing persists: every boot starts unarmed. Anything else goes to the family's own setProperties.
IOReturn VirtioGPUAccel::setProperties(OSObject *properties) {
    OSDictionary *dict = OSDynamicCast(OSDictionary, properties);
    if (dict && (dict->getObject("VirtioGPUPaceReset") || dict->getObject("VirtioGPUPacePublish"))) {
        if (IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess) {
            return kIOReturnNotPrivileged;
        }
        if (dict->getObject("VirtioGPUPaceReset")) {
            bzero(&gPaceTxn, sizeof(gPaceTxn));
            bzero(&gPaceFlip, sizeof(gPaceFlip));
            bzero(&gFlipDur, sizeof(gFlipDur));
            gFlipsSkipped = gFlipsUnready = 0;   // per measurement too (5c round 6)
        }
        iopPublishCounts();   // the property shows this at once (it is otherwise renewed every 60 frames)
        return kIOReturnSuccess;
    }
    if (dict && dict->getObject("VirtioGPUFlipMs")) {
        if (IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess) {
            return kIOReturnNotPrivileged;
        }
        if (OSNumber *n = OSDynamicCast(OSNumber, dict->getObject("VirtioGPUFlipMs"))) {
            gFlipMinMs = n->unsigned32BitValue();
            setProperty("VirtioGPUFlipMs", gFlipMinMs, 32);
            vlog("blob flips: at least %u ms apart", gFlipMinMs);
            return kIOReturnSuccess;
        }
        return kIOReturnBadArgument;
    }
    if (dict && (dict->getObject("VirtioGPUArm") || dict->getObject("VirtioGPUDisarm") || dict->getObject("VirtioGPULegacySurfaces") ||
                 dict->getObject("VirtioGPUArmWindowServer") || dict->getObject("VirtioGPUWithdraw"))) {
        if (IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess) {
            vlog("arm: refused, the caller isn't root");
            return kIOReturnNotPrivileged;
        }
        if (OSBoolean *b = OSDynamicCast(OSBoolean, dict->getObject("VirtioGPULegacySurfaces"))) {
            noLegacy_ = !b->getValue();
            setProperty("VirtioGPULegacySurfaces", b);
            vlog("legacy IOAccelSurfaces for an armed WindowServer: %s", noLegacy_ ? "refused" : "allowed");
            return kIOReturnSuccess;
        }
        if (dict->getObject("VirtioGPUArmWindowServer") || dict->getObject("VirtioGPUWithdraw")) {
            if (armed_ < 1 || !armTimer_) {
                vlog("display request refused: the display isn't registered (vgpuaccel=3 or 4 needed)");
                return kIOReturnNotReady;
            }
            removeProperty("VirtioGPUGuardWhy");
            request(dict->getObject("VirtioGPUWithdraw") ? 1 : 2);
            return kIOReturnSuccess;
        }
        if (dict->getObject("VirtioGPUDisarm")) {
            removeProperty("MetalPluginName");
            removeProperty("MetalPluginClassName");
            setProperty("VirtioGPUWindowServer", kOSBooleanFalse);
            setProperty("VirtioGPUAccelUnarmed", kOSBooleanTrue);
            vlog("disarmed: MetalPluginName withdrawn");
            return kIOReturnSuccess;
        }
        OSDictionary *arm = OSDynamicCast(OSDictionary, dict->getObject("VirtioGPUArm"));
        OSString *name = arm ? OSDynamicCast(OSString, arm->getObject("MetalPluginName")) : nullptr;
        OSString *cls = arm ? OSDynamicCast(OSString, arm->getObject("MetalPluginClassName")) : nullptr;
        if (!name || !cls || !name->getLength() || !cls->getLength()) {
            vlog("arm: needs MetalPluginName and MetalPluginClassName strings");
            return kIOReturnBadArgument;
        }
        setProperty("MetalPluginName", name);
        setProperty("MetalPluginClassName", cls);
        removeProperty("VirtioGPUAccelUnarmed");
        vlog("armed: MetalPluginName %s, MetalPluginClassName %s", name->getCStringNoCopy(), cls->getCStringNoCopy());
        return kIOReturnSuccess;
    }
    return IOGraphicsAccelerator2::setProperties(properties);
}

void VirtioGPUAccel::free() {
    if (gAccel == this) {
        gAccel = nullptr;
    }
    if (armLoop_) {
        if (armTimer_) {
            armLoop_->removeEventSource(armTimer_);
        }
        if (holdTimer_) {
            armLoop_->removeEventSource(holdTimer_);
        }
    }
    OSSafeReleaseNULL(armTimer_);
    OSSafeReleaseNULL(holdTimer_);
    OSSafeReleaseNULL(armLoop_);
    OSSafeReleaseNULL(agdc_);
    if (fb_) {
        fb_->release();
        fb_ = nullptr;
    }
    for (unsigned i = 0; i < VG_CARRIERS; i++) {
        OSSafeReleaseNULL(carriers_[i]);
    }
    if (stamps_) {
        stamps_->complete();
        stamps_->release();
        stamps_ = nullptr;
    }
    for (unsigned i = 0; i < 32; i++) {
        if (ranges_[i]) {
            ranges_[i]->release();
            ranges_[i] = nullptr;
        }
    }
    IOGraphicsAccelerator2::free();
}

extern IOAccelSysMemory *vg_sysmem_with_descriptor(IOGraphicsAccelerator2 *, IOAccelResource2 *, IOMemoryDescriptor *) __asm(
    "__ZN16IOAccelSysMemory20withMemoryDescriptorEP22IOGraphicsAccelerator2P16IOAccelResource2P18IOMemoryDescriptor");

// After VirtioGPUAccel's definition: gAccel converts to IOGraphicsAccelerator2 here.
IOAccelMemory *VGDisplayPipe::initFramebufferResource(unsigned int index, IOAccelResource2 *res) {
    IOFramebuffer *fb = OSDynamicCast(IOFramebuffer, displayFramebuffer());
    bool noResource = false;
    PE_parse_boot_argn("-vgpunofbresource", &noResource, sizeof(noResource));
    if (!gIop || !gAccel || !fb || noResource) {
        vlog("pipe initFramebufferResource(%u) -> NULL (%s)", index,
             noResource ? "-vgpunofbresource" : !gIop ? "not armed" : "no accelerator or framebuffer");
        return nullptr;
    }
    IODeviceMemory *vram = fb->getVRAMRange();
    IOAccelSysMemory *m = vram ? vg_sysmem_with_descriptor(gAccel, res, vram) : nullptr;
    vlog("pipe initFramebufferResource(%u) -> %p (the framebuffer's VRAM, %llu bytes)", index, m,
         vram ? (unsigned long long)vram->getLength() : 0ULL);
    OSSafeReleaseNULL(vram);   // the memory retains it
    gates("after initFramebufferResource");
    return m;
}
