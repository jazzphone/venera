// VirtioGPUAccel: stage 4.0, the accelerator spike.
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
#include "../VirtioGPUAPI.h"

extern "C" kern_return_t _start(kmod_info_t *ki, void *d);
extern "C" kern_return_t _stop(kmod_info_t *ki, void *d);
extern "C" kern_return_t _start(kmod_info_t *, void *) { return KERN_SUCCESS; }
extern "C" kern_return_t _stop(kmod_info_t *, void *) { return KERN_SUCCESS; }

// ---- log ---------------------------------------------------------------------------------------------------------

static IOService *gLogPci = nullptr;   // the PCI device: where VirtioGPUAccelLog lives and where we look for the core
static OSArray *gLogLines = nullptr;
static IOLock *gLogLock = nullptr;

static void vlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void vlog(const char *fmt, ...) {
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
    if (gLogLines && gLogLines->getCount() < 200) {
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

// Not handed out yet (newDisplayPipe keeps the family's default): defined so the forwarding list and a later stage have it.
class VGDisplayPipe : public IOAccelLegacyDisplayPipe {
    OSDeclareDefaultStructors(VGDisplayPipe)
    NM_TAHOE_FWD(VGDisplayPipe)
public:
    IOAccelMemory *initFramebufferResource(unsigned int, IOAccelResource2 *) APPLE_KEXT_OVERRIDE { return nullptr; }
    IOReturn validateTransaction(IOAccelDisplayPipeTransaction2 *) APPLE_KEXT_OVERRIDE { return kIOReturnUnsupported; }
    IOReturn performTransaction(IOAccelDisplayPipeTransaction2 *) APPLE_KEXT_OVERRIDE { return kIOReturnUnsupported; }
    bool isTransactionComplete(IOAccelDisplayPipeTransaction2 *) APPLE_KEXT_OVERRIDE { return true; }
    void free() APPLE_KEXT_OVERRIDE { IOAccelLegacyDisplayPipe::free(); }
};
OSDefineMetaClassAndStructors(VGDisplayPipe, IOAccelLegacyDisplayPipe)

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

// ---- the accelerator ---------------------------------------------------------------------------------------------

class VirtioGPUAccel : public IOGraphicsAccelerator2 {
    OSDeclareDefaultStructors(VirtioGPUAccel)
    NM_TAHOE_FWD(VirtioGPUAccel)

public:
    IOBufferMemoryDescriptor *stamps_ = nullptr;
    IORangeAllocator *ranges_[32] = {};
    unsigned enables_ = 0;

    IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;
    bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void free() APPLE_KEXT_OVERRIDE;
    IOReturn setProperties(OSObject *properties) APPLE_KEXT_OVERRIDE;

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
    OSObject *newDisplayMachine() APPLE_KEXT_OVERRIDE { vlog("newDisplayMachine"); return OSTypeAlloc(VGDisplayMachine); }
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
    setProperty("IOAccelRevision", 2ULL, 32);
    setProperty("IOVARendererID", 0x01020000ULL, 32);
    setProperty("VirtioGPUAccelUnarmed", kOSBooleanTrue);   // no MetalPluginName until a later stage arms it
    if (gate >= 2) {
        registerService();
        vlog("registerService() (vgpuaccel=%u)", gate);
    } else {
        vlog("not registered (vgpuaccel=1); vgpuaccel=2 registers");
    }
    enableNow("start");
    return true;
}

// The late arm (stage 4a). A root process sets, through IORegistryEntrySetCFProperties on this service:
//   {"VirtioGPUArm": {"MetalPluginName": "...", "MetalPluginClassName": "..."}}  publish the Metal plugin
//   {"VirtioGPUDisarm": true}                                                     withdraw it
// Only processes that ask Metal for devices afterwards load the plugin (WindowServer is already running and never
// sees it). Nothing persists: every boot starts unarmed. Anything else goes to the family's own setProperties.
IOReturn VirtioGPUAccel::setProperties(OSObject *properties) {
    OSDictionary *dict = OSDynamicCast(OSDictionary, properties);
    if (dict && (dict->getObject("VirtioGPUArm") || dict->getObject("VirtioGPUDisarm"))) {
        if (IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess) {
            vlog("arm: refused, the caller isn't root");
            return kIOReturnNotPrivileged;
        }
        if (dict->getObject("VirtioGPUDisarm")) {
            removeProperty("MetalPluginName");
            removeProperty("MetalPluginClassName");
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
