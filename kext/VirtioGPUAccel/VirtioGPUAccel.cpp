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
// the display: MetalPluginName, VirtioGPUWindowServer and the pipe capabilities go (the AGDC can't be terminated and
// needn't be), so the next WindowServer finds no display pipe and composites in software (a pipe without a Metal device is an abort loop, "Failed to create
// MetalDevice"). A root process re-arms with {"VirtioGPUArmWindowServer": true} (acceltest wsarm) or withdraws with
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
    uint64_t getLevelOffset(unsigned char, unsigned char, int *pitch) APPLE_KEXT_OVERRIDE {
        if (pitch) {
            *pitch = 0;
        }
        return 0;
    }
    uint64_t getBackingLevelOffset(unsigned char, unsigned char, int *pitch) APPLE_KEXT_OVERRIDE {
        if (pitch) {
            *pitch = 0;
        }
        return 0;
    }
    uint64_t calculateIOSurfaceDeviceCacheVRAMBytes(unsigned long long *bytes, unsigned long long *count) APPLE_KEXT_OVERRIDE {
        if (bytes) {
            *bytes = 0;
        }
        if (count) {
            *count = 0;
        }
        return 0;
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

// No VRAM: every allocation is refused, so the family keeps resources in system memory.
class VGVidMemory : public IOAccelVidMemory {
    OSDeclareDefaultStructors(VGVidMemory)
    NM_TAHOE_FWD(VGVidMemory)
public:
    bool allocPhysical() APPLE_KEXT_OVERRIDE { STUB_LOG("VidMemory allocPhysical -> false (no VRAM)"); return false; }
    void deallocPhysical() APPLE_KEXT_OVERRIDE {}
    void free() APPLE_KEXT_OVERRIDE { IOAccelVidMemory::free(); }
    uint64_t getPhysicalSegment(unsigned long long, unsigned long long *len) APPLE_KEXT_OVERRIDE {
        if (len) {
            *len = 0;
        }
        return 0;
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
static void iopPublishCounts();

class VGDisplayPipe : public IOAccelLegacyDisplayPipe {
    OSDeclareDefaultStructors(VGDisplayPipe)
    NM_TAHOE_FWD(VGDisplayPipe)
public:
    // CPU-only scanout: no framebuffer resource, frames arrive through performTransaction (NV: another GPU's panel).
    IOAccelMemory *initFramebufferResource(unsigned int index, IOAccelResource2 *) APPLE_KEXT_OVERRIDE {
        STUB_LOG("pipe initFramebufferResource -> NULL (frames are copied)");
        return nullptr;
    }
    IOReturn validateTransaction(IOAccelDisplayPipeTransaction2 *) APPLE_KEXT_OVERRIDE {
        return gIop ? kIOReturnSuccess : kIOReturnUnsupported;
    }
    IOReturn performTransaction(IOAccelDisplayPipeTransaction2 *txn) APPLE_KEXT_OVERRIDE;
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
IOReturn VGDisplayPipe::performTransaction(IOAccelDisplayPipeTransaction2 *txn) {
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

static void iopPublishCounts() {
    if (!gAccel) {
        return;
    }
    char line[160];
    snprintf(line, sizeof(line), "calls %lld ok %lld fail %lld empty %lld refused %lld", (long long)gIopCalls,
             (long long)gIopOk, (long long)gIopFail, (long long)gIopEmpty, (long long)gIopRefused);
    gAccel->setProperty("VirtioGPUPipeFrames", line);
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
    setProperty("MetalPluginName", "VirtioGPUMetal");
    setProperty("MetalPluginClassName", "VGMTLDevice");
    setProperty("VirtioGPUWindowServer", kOSBooleanTrue);
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
    removeProperty("MetalPluginName");
    removeProperty("MetalPluginClassName");
    setProperty("VirtioGPUWindowServer", kOSBooleanFalse);
    removeProperty("IOAccelDisplayPipeCapabilities");
    gIop = 0;
    // The AGDC stays: AppleGraphicsDeviceControl refuses terminate (measured: -> 0), and without the capabilities
    // WindowServer finds no display pipe and composites in software anyway (measured 2026-11-15).
    armed_ = 1;
    setProperty("VirtioGPUGuard", why);
    setProperty("VirtioGPUArmState", "withdrawn: no pipe capabilities, no Metal for WindowServer (software compositor)");
    vlog("WITHDRAWN (%s): MetalPluginName and pipe capabilities gone; the next WindowServer composites in software", why);
}

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
