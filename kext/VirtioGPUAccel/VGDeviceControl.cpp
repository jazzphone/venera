// VGDeviceControl: stage 5a, the AppleGraphicsDeviceControl (AGDC) on the virtio-gpu PCI device.
//
// WindowServer's IOPresentment builds a display pipe only for a framebuffer whose PCI device has an AGDC; without one
// CoreDisplay logs "Unable to find display pipe for IOFB service" and WindowServer composites in software. The library
// class (com.apple.AppleGraphicsDeviceControl, System KC) does the talking to AppleGPUWrangler and IOPresentment; a
// subclass only answers device attributes (vendor_doDeviceAttribute). Created by the accelerator once our framebuffer
// is registered with its display machine (VirtioGPUAccel.cpp), attached and started by hand on the PCI device, as
// nvidia-macos-driver's NVRMAGDC does.
//
// Attributes answered (sizes are the exact output sizes asked; anything else is Unsupported and logged):
//   0x1    description, 0x2c: version, name, vendor half-word at +0x24 (IOPresentment's platform check reads it;
//          Reims measured 0x106b passing, NV answers its own 0x10de), device at +0x26, kind 2 at +0x28 (a display GPU).
//   0x3    get (4-byte output): what we make, framebuffers | accelerator (the wrangler goes on only with both);
//          set (4-byte input): the wrangler's InitFlags, recorded.
//   0x980  GPU capabilities, 0xdc: port masks, counts, max framebuffers, the PCI device, framebuffer per
//          IOFBDependentIndex. Read when WindowServer (re)starts; one display pipe per framebuffer listed.
//   0x921  link config, 0xb0 in and out: the current mode's timing (NV's K5 layout).
//   0x711  extended capability, 0x196c in and out: type 0x10 (plane scaler) from the current mode (NV's K5).
//   0x925  connection, 12 bytes: display index + 1 in, connected in the third word (Reims' reading).
// Layouts: NV's nvrm-agdc.cpp / nvrm-agdc-k5.h (PolyForm NC, read, not copied) and Reims' RgfxDeviceControl (read for
// the field meanings). The base class declaration is NV's reconstruction (vendor/nullmoth/agdc).
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/graphics/IOFramebuffer.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <libkern/OSAtomic.h>
#include <pexpert/pexpert.h>
#include "AppleGraphicsDeviceControl_re.h"
#include "accel_shared.h"

namespace {

#pragma pack(push, 1)
struct Description {   // attribute 0x1
    uint32_t version;
    char name[0x20];
    uint16_t vendor;
    uint16_t device;
    uint32_t kind;
};
struct Capability {    // attribute 0x980
    uint64_t portMask[4];
    uint32_t count[4];
    uint32_t maxFramebuffers;
    uint64_t pciDevice;
    uint64_t framebuffer[20];
};
struct Timing {        // inside 0x921
    uint32_t hScaledInset, vScaledInset, scalerFlags, hScaled, vScaled, signalConfig, signalLevels;
    uint64_t pixelClock, minPixelClock, maxPixelClock;
    uint32_t hActive, hBlanking, hSyncOffset, hSyncPulseWidth;
    uint32_t vActive, vBlanking, vSyncOffset, vSyncPulseWidth;
    uint32_t hBorderLeft, hBorderRight, vBorderTop, vBorderBottom;
    uint32_t hSyncConfig, hSyncLevel, vSyncConfig, vSyncLevel;
    uint32_t numLinks, vBlankingExtension;
    uint16_t pixelEncoding, bitsPerColorComponent, colorimetry, dynamicRange;
    uint16_t dscBitsPerPixel, dscSliceHeight, dscSliceWidth, field8a;
    uint8_t tail[8];
};
struct LinkConfig {    // attribute 0x921
    int32_t id;
    int32_t groupID;
    uint64_t flags;
    Timing timing;
    uint32_t port, stream;
    uint32_t state;
};
struct ExtCap {        // attribute 0x711
    uint32_t fbIndex, type, count;
    uint8_t entry[8][0x32c];
};
struct Connection {    // attribute 0x925
    uint32_t display;   // index + 1
    uint32_t unused;
    uint32_t connected;
};
#pragma pack(pop)
static_assert(sizeof(Description) == 0x2c, "attribute 1 is 0x2c bytes");
static_assert(sizeof(Capability) == 0xdc, "attribute 0x980 is 0xdc bytes");
static_assert(sizeof(Timing) == 0x94, "AGDC timing is 0x94 bytes");
static_assert(sizeof(LinkConfig) == 0xb0, "attribute 0x921 is 0xb0 bytes");
static_assert(sizeof(ExtCap) == 0x196c, "attribute 0x711 is 0x196c bytes");
static_assert(sizeof(Connection) == 12, "attribute 0x925 is 12 bytes");

void put32(uint8_t *e, unsigned off, uint32_t v) { memcpy(e + off, &v, 4); }

} // namespace

class VGDeviceControl : public AppleGraphicsDeviceControl {
    OSDeclareDefaultStructors(VGDeviceControl)
public:
    IOService *pci_ = nullptr;
    IOFramebuffer *fb_ = nullptr;   // not retained: the accelerator holds it for as long as this object lives
    uint32_t initFlags_ = 0;
    SInt32 calls_ = 0;
    using AppleGraphicsDeviceControl::vendor_doDeviceAttribute;
    IOReturn vendor_doDeviceAttribute(unsigned int cmd, unsigned long *in, unsigned long inSize, unsigned long *out,
                                      unsigned long *outSize, IOExternalMethodArguments *args) APPLE_KEXT_OVERRIDE;
private:
    IOReturn answer(unsigned cmd, const void *in, unsigned long inSize, void *out, unsigned long outSize);
    bool currentTiming(IOTimingInformation *t);
};
OSDefineMetaClassAndStructors(VGDeviceControl, AppleGraphicsDeviceControl)

bool VGDeviceControl::currentTiming(IOTimingInformation *t) {
    IODisplayModeID mode = 0;
    IOIndex depth = 0;
    bzero(t, sizeof(*t));
    return fb_ && fb_->getCurrentDisplayMode(&mode, &depth) == kIOReturnSuccess &&
           fb_->getTimingInfoForDisplayMode(mode, t) == kIOReturnSuccess && t->detailedInfo.v2.horizontalActive &&
           t->detailedInfo.v2.verticalActive;
}

IOReturn VGDeviceControl::vendor_doDeviceAttribute(unsigned int cmd, unsigned long *in, unsigned long inSize,
                                                   unsigned long *out, unsigned long *outSize,
                                                   IOExternalMethodArguments *) {
    unsigned long cap = (out && outSize) ? *outSize : 0;
    IOReturn r = answer(cmd, in, in ? inSize : 0, cap ? out : nullptr, cap);
    if (OSIncrementAtomic(&calls_) < 120) {
        uint32_t w[2] = {};
        if (in && inSize >= sizeof(w)) {
            memcpy(w, in, sizeof(w));
        }
        vgaccel_log("agdc: attribute 0x%x in %lu [0x%x 0x%x] out %lu -> 0x%x", cmd, in ? inSize : 0, w[0], w[1], cap, r);
    }
    return r;
}

IOReturn VGDeviceControl::answer(unsigned cmd, const void *in, unsigned long inSize, void *out, unsigned long outSize) {
    switch (cmd) {
    case 0x1: {
        if (!out || outSize != sizeof(Description)) {
            return kIOReturnBadArgument;
        }
        Description d = {};
        uint32_t vendor = 0x106b, version = 0x30000;
        PE_parse_boot_argn("vgpuagdcvendor", &vendor, sizeof(vendor));
        PE_parse_boot_argn("vgpuagdcversion", &version, sizeof(version));
        d.version = version;
        strlcpy(d.name, "VirtioGPU", sizeof(d.name));
        d.vendor = (uint16_t)vendor;
        d.device = 0x1050;
        d.kind = 2;
        memcpy(out, &d, sizeof(d));
        return kIOReturnSuccess;
    }
    case 0x3:
        if (out && outSize == sizeof(uint32_t)) {
            uint32_t mask = 0x3;   // framebuffers | accelerator
            memcpy(out, &mask, sizeof(mask));
            return kIOReturnSuccess;
        }
        if (in && inSize == sizeof(uint32_t)) {
            memcpy(&initFlags_, in, sizeof(initFlags_));
            setProperty("VirtioGPUInitFlags", initFlags_, 32);
            return kIOReturnSuccess;
        }
        return kIOReturnBadArgument;
    case 0x980: {
        if (!out || outSize != sizeof(Capability)) {
            return kIOReturnBadArgument;
        }
        Capability c = {};
        c.portMask[0] = 1ULL << 1;   // one port, display 0 (bit 1 + i); NV leaves the next three words 0
        c.count[0] = c.count[1] = c.count[2] = c.count[3] = 1;
        c.maxFramebuffers = 1;
        c.pciDevice = (uint64_t)(uintptr_t)pci_;
        c.framebuffer[0] = (uint64_t)(uintptr_t)fb_;
        memcpy(out, &c, sizeof(c));
        return kIOReturnSuccess;
    }
    case 0x921: {
        if (!out || outSize != sizeof(LinkConfig) || !in || inSize != sizeof(LinkConfig)) {
            return kIOReturnBadArgument;
        }
        LinkConfig l;
        memcpy(&l, in, sizeof(l));
        if (l.id != 0) {
            return kIOReturnBadArgument;
        }
        IOTimingInformation t;
        if (!currentTiming(&t)) {
            return kIOReturnNotFound;
        }
        const auto &d = t.detailedInfo.v2;
        bzero(&l, sizeof(l));
        l.id = 0;
        l.groupID = -1;
        l.flags = 0x8 | 0x1 | 0x2;
        l.timing.pixelClock = l.timing.minPixelClock = l.timing.maxPixelClock = d.pixelClock;
        l.timing.hActive = d.horizontalActive;
        l.timing.hBlanking = d.horizontalBlanking;
        l.timing.hSyncOffset = d.horizontalSyncOffset;
        l.timing.hSyncPulseWidth = d.horizontalSyncPulseWidth;
        l.timing.vActive = d.verticalActive;
        l.timing.vBlanking = d.verticalBlanking;
        l.timing.vSyncOffset = d.verticalSyncOffset;
        l.timing.vSyncPulseWidth = d.verticalSyncPulseWidth;
        l.timing.numLinks = 1;
        l.timing.pixelEncoding = 1;
        l.timing.bitsPerColorComponent = 2;
        l.timing.colorimetry = 1;
        l.timing.dynamicRange = 1;
        l.port = 1;
        l.stream = 0;
        l.state = 1;
        memcpy(out, &l, sizeof(l));
        return kIOReturnSuccess;
    }
    case 0x711: {
        if (!out || outSize != sizeof(ExtCap) || !in || inSize != sizeof(ExtCap)) {
            return kIOReturnBadArgument;
        }
        uint32_t head[2];
        memcpy(head, in, sizeof(head));
        if (head[1] != 0x10) {
            return kIOReturnUnsupported;   // only the plane scaler, as NV
        }
        if (head[0] != 0) {
            return kIOReturnBadArgument;
        }
        IOTimingInformation t;
        if (!currentTiming(&t)) {
            return kIOReturnNotFound;
        }
        uint32_t w = t.detailedInfo.v2.horizontalActive, h = t.detailedInfo.v2.verticalActive;
        auto *c = static_cast<ExtCap *>(out);
        if (out != in) {
            memmove(out, in, sizeof(ExtCap));
        }
        uint32_t idx = c->fbIndex, type = c->type;
        bzero(c, sizeof(*c));
        c->fbIndex = idx;
        c->type = type;
        c->count = 1;
        uint8_t *e = c->entry[0];
        put32(e, 0x000, 0x80004);
        put32(e, 0x01c, 1);
        put32(e, 0x024, h);
        put32(e, 0x028, w);
        put32(e, 0x02c, h);
        put32(e, 0x030, w);
        put32(e, 0x034, 0x70007);
        put32(e, 0x1a4, 1);
        put32(e, 0x1ac, h);
        put32(e, 0x1b0, w);
        put32(e, 0x1b4, h);
        put32(e, 0x1b8, w);
        put32(e, 0x1bc, 0x70007);
        return kIOReturnSuccess;
    }
    case 0x925: {
        if (!in || inSize != sizeof(Connection)) {
            return kIOReturnBadArgument;
        }
        Connection q;
        memcpy(&q, in, sizeof(q));
        if (q.display != 1) {
            return kIOReturnError;
        }
        if (out && outSize >= sizeof(Connection)) {
            q.connected = fb_ ? 1 : 0;
            memcpy(out, &q, sizeof(q));
        }
        return kIOReturnSuccess;
    }
    default:
        return kIOReturnUnsupported;
    }
}

// Called by the accelerator from its arm work loop. Returns the started object (retained) or null.
IOService *vgaccel_agdc_create(IOService *pci, IOService *fb) {
    VGDeviceControl *d = OSTypeAlloc(VGDeviceControl);
    if (!d || !d->init()) {
        vgaccel_log("agdc: alloc/init failed");
        OSSafeReleaseNULL(d);
        return nullptr;
    }
    d->pci_ = pci;
    d->fb_ = OSDynamicCast(IOFramebuffer, fb);
    if (!d->attach(pci)) {
        vgaccel_log("agdc: attach to the PCI device failed");
        d->release();
        return nullptr;
    }
    if (!d->start(pci)) {
        vgaccel_log("agdc: AppleGraphicsDeviceControl::start failed (%d vendor calls so far)", (int)d->calls_);
        d->detach(pci);
        d->release();
        return nullptr;
    }
    vgaccel_log("agdc: up on the PCI device (%d vendor calls during start)", (int)d->calls_);
    return d;
}
