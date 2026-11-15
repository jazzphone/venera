// VirtioGPUFramebuffer - stage 2c: the screen.
//
// Matches the virtio-gpu PCI function in the IOFramebuffer category at probe score 30000, above
// IONDRVFramebuffer's 20000 for "display" devices, so macOS has exactly one framebuffer: ours.
// It finds the VirtioGPU core attached to the same PCI device, gives WindowServer a block of
// contiguous RAM as VRAM (aperture), shows it through a virtio-gpu 2D scanout resource, and pushes
// the whole frame to the host 30 times a second (WindowServer doesn't say what changed).
// Software cursor for now: WindowServer draws it into the frame.

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOLib.h>
#include <IOKit/graphics/IOFramebuffer.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <kern/thread_call.h>
#include <pexpert/pexpert.h>

#include "VirtioGPU.hpp"

namespace {

struct Mode {
    uint32_t width;
    uint32_t height;
};

// Mode IDs are index + 1. The host's preferred size is added if it isn't here.
const Mode kBaseModes[] = {{1024, 768}, {1280, 800}, {1440, 900}, {1680, 1050}, {1920, 1080}};
constexpr unsigned kMaxModes = 8;
constexpr uint32_t kMaxWidth = 1920;
constexpr uint32_t kMaxHeight = 1200;
constexpr uint32_t kFlushIntervalMs = 33;

const char kPixelFormats[] = IO32BitDirectPixels "\0";

} // namespace

class VirtioGPUFramebuffer : public IOFramebuffer {
    OSDeclareDefaultStructors(VirtioGPUFramebuffer)

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;

    IOReturn enableController() override;
    bool isConsoleDevice() override { return false; }
    IODeviceMemory *getApertureRange(IOPixelAperture aperture) override;
    IODeviceMemory *getVRAMRange() override;
    const char *getPixelFormats() override { return kPixelFormats; }
    IOItemCount getDisplayModeCount() override { return modeCount_; }
    IOReturn getDisplayModes(IODisplayModeID *allDisplayModes) override;
    IOReturn getInformationForDisplayMode(IODisplayModeID mode, IODisplayModeInformation *info) override;
    UInt64 getPixelFormatsForDisplayMode(IODisplayModeID, IOIndex) override { return 0; }
    IOReturn getPixelInformation(IODisplayModeID mode, IOIndex depth, IOPixelAperture aperture,
                                 IOPixelInformation *info) override;
    IOReturn getCurrentDisplayMode(IODisplayModeID *mode, IOIndex *depth) override;
    IOReturn setDisplayMode(IODisplayModeID mode, IOIndex depth) override;
    IOReturn getStartupDisplayMode(IODisplayModeID *mode, IOIndex *depth) override;
    IOReturn getTimingInfoForDisplayMode(IODisplayModeID mode, IOTimingInformation *info) override;
    IOItemCount getConnectionCount() override { return 1; }
    IOReturn getAttribute(IOSelect attribute, uintptr_t *value) override;
    IOReturn getAttributeForConnection(IOIndex index, IOSelect attribute, uintptr_t *value) override;
    IOReturn setAttributeForConnection(IOIndex index, IOSelect attribute, uintptr_t value) override;
    bool hasDDCConnect(IOIndex index) override;
    IOReturn getDDCBlock(IOIndex index, UInt32 blockNumber, IOSelect blockType, IOOptionBits options,
                         UInt8 *data, IOByteCount *length) override;

private:
    const Mode *modeFor(IODisplayModeID id) const {
        return (id >= 1 && (unsigned)id <= modeCount_) ? &modes_[id - 1] : nullptr;
    }
    bool applyMode(IODisplayModeID id);
    void log(const char *fmt, ...) __attribute__((format(printf, 2, 3)));
    static void flushThunk(thread_call_param_t self, thread_call_param_t);
    void flushTick();

    VirtioGPU *core_ = nullptr;
    IOBufferMemoryDescriptor *vram_ = nullptr;
    uint64_t vramPhys_ = 0;
    uint32_t vramBytes_ = 0;
    Mode modes_[kMaxModes] = {};
    unsigned modeCount_ = 0;
    IODisplayModeID preferredMode_ = 0;
    IODisplayModeID currentMode_ = 0;
    thread_call_t flushCall_ = nullptr;
    volatile bool flushing_ = false;
    uint32_t ticks_ = 0;
};

OSDefineMetaClassAndStructors(VirtioGPUFramebuffer, IOFramebuffer)

void VirtioGPUFramebuffer::log(const char *fmt, ...) {
    char line[200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    probeLog("fb: %s", line);
}

IOService *VirtioGPUFramebuffer::probe(IOService *provider, SInt32 *score) {
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    char arg[8];
    if (!pci || PE_parse_boot_argn("-vgpuoff", arg, sizeof(arg)) ||
        pci->configRead16(kIOPCIConfigVendorID) != 0x1af4 ||
        pci->configRead16(kIOPCIConfigDeviceID) != 0x1050) {
        return nullptr;
    }
    return IOFramebuffer::probe(provider, score);
}

bool VirtioGPUFramebuffer::start(IOService *provider) {
    // The core matches the same PCI device in the default category; wait for it.
    OSDictionary *match = serviceMatching("VirtioGPU");
    IOService *found = match ? waitForMatchingService(match, 15ULL * 1000 * 1000 * 1000) : nullptr;
    if (match) {
        match->release();
    }
    core_ = OSDynamicCast(VirtioGPU, found);
    if (!core_ || core_->getProvider() != provider || !core_->ready()) {
        probeLog("fb: no ready VirtioGPU core on this device; not starting");
        if (found) {
            found->release();
        }
        core_ = nullptr;
        return false;
    }

    uint32_t pw = 0, ph = 0;
    core_->preferredSize(&pw, &ph);
    for (const Mode &m : kBaseModes) {
        modes_[modeCount_++] = m;
        if (m.width == pw && m.height == ph) {
            preferredMode_ = (IODisplayModeID)modeCount_;
        }
    }
    if (!preferredMode_ && pw && ph && pw <= kMaxWidth && ph <= kMaxHeight) {
        modes_[modeCount_++] = {pw, ph};
        preferredMode_ = (IODisplayModeID)modeCount_;
    }
    if (!preferredMode_) {
        preferredMode_ = 2; // 1280x800
    }

    vramBytes_ = round_page(kMaxWidth * kMaxHeight * 4);
    vram_ = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, vramBytes_, 0xFFFFFFFFFFFFF000ULL);
    if (!vram_ || vram_->prepare() != kIOReturnSuccess) {
        log("VRAM allocation (%u bytes) failed", vramBytes_);
        OSSafeReleaseNULL(vram_);
        core_->release();
        core_ = nullptr;
        return false;
    }
    bzero(vram_->getBytesNoCopy(), vramBytes_);
    vramPhys_ = vram_->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);
    log("start: %u modes, preferred %u (%ux%u), VRAM %u bytes at 0x%llx", modeCount_, preferredMode_,
        modes_[preferredMode_ - 1].width, modes_[preferredMode_ - 1].height, vramBytes_,
        (unsigned long long)vramPhys_);

    flushCall_ = thread_call_allocate(&VirtioGPUFramebuffer::flushThunk, this);
    if (!IOFramebuffer::start(provider)) {
        log("IOFramebuffer::start failed");
        return false;
    }
    core_->publishLog();
    return true;
}

void VirtioGPUFramebuffer::stop(IOService *provider) {
    flushing_ = false;
    if (flushCall_) {
        thread_call_cancel_wait(flushCall_);
        thread_call_free(flushCall_);
        flushCall_ = nullptr;
    }
    if (core_) {
        core_->disableScanout();
        core_->release();
        core_ = nullptr;
    }
    if (vram_) {
        vram_->complete();
        vram_->release();
        vram_ = nullptr;
    }
    IOFramebuffer::stop(provider);
}

bool VirtioGPUFramebuffer::applyMode(IODisplayModeID id) {
    const Mode *m = modeFor(id);
    if (!m || !core_) {
        return false;
    }
    bool ok = core_->setScanout(vram_, m->width, m->height, m->width * 4);
    log("mode %d %ux%u -> %s", id, m->width, m->height, ok ? "on screen" : "FAILED");
    if (ok) {
        currentMode_ = id;
        if (!flushing_ && flushCall_) {
            flushing_ = true;
            uint64_t deadline = 0;
            clock_interval_to_deadline(kFlushIntervalMs, kMillisecondScale, &deadline);
            thread_call_enter_delayed(flushCall_, deadline);
        }
    }
    core_->publishLog();
    return ok;
}

void VirtioGPUFramebuffer::flushThunk(thread_call_param_t self, thread_call_param_t) {
    static_cast<VirtioGPUFramebuffer *>(self)->flushTick();
}

void VirtioGPUFramebuffer::flushTick() {
    if (!flushing_) {
        return;
    }
    if (const Mode *m = modeFor(currentMode_)) {
        core_->flush(0, 0, m->width, m->height);
    }
    if (++ticks_ % 300 == 0) { // every ~10 s
        core_->publishLog();
    }
    uint64_t deadline = 0;
    clock_interval_to_deadline(kFlushIntervalMs, kMillisecondScale, &deadline);
    thread_call_enter_delayed(flushCall_, deadline);
}

IOReturn VirtioGPUFramebuffer::enableController() {
    log("enableController");
    return applyMode(currentMode_ ? currentMode_ : preferredMode_) ? kIOReturnSuccess : kIOReturnError;
}

IODeviceMemory *VirtioGPUFramebuffer::getApertureRange(IOPixelAperture aperture) {
    const Mode *m = modeFor(currentMode_ ? currentMode_ : preferredMode_);
    if (aperture != kIOFBSystemAperture || !m) {
        return nullptr;
    }
    return IODeviceMemory::withRange(vramPhys_, round_page(m->width * 4 * m->height));
}

IODeviceMemory *VirtioGPUFramebuffer::getVRAMRange() {
    return IODeviceMemory::withRange(vramPhys_, vramBytes_);
}

IOReturn VirtioGPUFramebuffer::getDisplayModes(IODisplayModeID *allDisplayModes) {
    for (unsigned i = 0; i < modeCount_; i++) {
        allDisplayModes[i] = (IODisplayModeID)(i + 1);
    }
    return kIOReturnSuccess;
}

IOReturn VirtioGPUFramebuffer::getInformationForDisplayMode(IODisplayModeID id,
                                                            IODisplayModeInformation *info) {
    const Mode *m = modeFor(id);
    if (!m || !info) {
        return kIOReturnBadArgument;
    }
    bzero(info, sizeof(*info));
    info->nominalWidth = m->width;
    info->nominalHeight = m->height;
    info->refreshRate = 60 << 16;
    info->maxDepthIndex = 0;
    info->flags = kDisplayModeValidFlag | kDisplayModeSafeFlag;
    if (id == preferredMode_) {
        info->flags |= kDisplayModeDefaultFlag;
    }
    return kIOReturnSuccess;
}

IOReturn VirtioGPUFramebuffer::getPixelInformation(IODisplayModeID id, IOIndex depth,
                                                   IOPixelAperture aperture, IOPixelInformation *info) {
    const Mode *m = modeFor(id);
    if (!m || depth != 0 || aperture != kIOFBSystemAperture || !info) {
        return kIOReturnBadArgument;
    }
    bzero(info, sizeof(*info));
    info->bytesPerRow = m->width * 4;
    info->bitsPerPixel = 32;
    info->pixelType = kIORGBDirectPixels;
    info->componentCount = 3;
    info->bitsPerComponent = 8;
    info->componentMasks[0] = 0x00ff0000;
    info->componentMasks[1] = 0x0000ff00;
    info->componentMasks[2] = 0x000000ff;
    strlcpy(info->pixelFormat, IO32BitDirectPixels, sizeof(info->pixelFormat));
    info->activeWidth = m->width;
    info->activeHeight = m->height;
    return kIOReturnSuccess;
}

IOReturn VirtioGPUFramebuffer::getCurrentDisplayMode(IODisplayModeID *mode, IOIndex *depth) {
    if (mode) {
        *mode = currentMode_ ? currentMode_ : preferredMode_;
    }
    if (depth) {
        *depth = 0;
    }
    return kIOReturnSuccess;
}

IOReturn VirtioGPUFramebuffer::setDisplayMode(IODisplayModeID mode, IOIndex depth) {
    if (!modeFor(mode) || depth != 0) {
        return kIOReturnBadArgument;
    }
    return applyMode(mode) ? kIOReturnSuccess : kIOReturnError;
}

IOReturn VirtioGPUFramebuffer::getStartupDisplayMode(IODisplayModeID *mode, IOIndex *depth) {
    if (mode) {
        *mode = preferredMode_;
    }
    if (depth) {
        *depth = 0;
    }
    return kIOReturnSuccess;
}

IOReturn VirtioGPUFramebuffer::getTimingInfoForDisplayMode(IODisplayModeID id, IOTimingInformation *info) {
    const Mode *m = modeFor(id);
    if (!m || !info) {
        return kIOReturnBadArgument;
    }
    bzero(info, sizeof(*info));
    info->appleTimingID = kIOTimingIDApple_FixedRateLCD;
    info->flags = kIODetailedTimingValid;
    auto &d = info->detailedInfo.v2;
    d.horizontalActive = m->width;
    d.horizontalBlanking = 160;
    d.horizontalSyncOffset = 48;
    d.horizontalSyncPulseWidth = 32;
    d.verticalActive = m->height;
    d.verticalBlanking = 30;
    d.verticalSyncOffset = 3;
    d.verticalSyncPulseWidth = 6;
    d.pixelClock = (uint64_t)(m->width + 160) * (m->height + 30) * 60;
    d.minPixelClock = d.pixelClock;
    d.maxPixelClock = d.pixelClock;
    return kIOReturnSuccess;
}

IOReturn VirtioGPUFramebuffer::getAttribute(IOSelect attribute, uintptr_t *value) {
    if (attribute == kIOHardwareCursorAttribute) {
        if (value) {
            *value = 0; // software cursor for now
        }
        return kIOReturnSuccess;
    }
    return IOFramebuffer::getAttribute(attribute, value);
}

IOReturn VirtioGPUFramebuffer::getAttributeForConnection(IOIndex index, IOSelect attribute,
                                                         uintptr_t *value) {
    switch (attribute) {
    case kConnectionEnable:
    case kConnectionCheckEnable:
        if (value) {
            *value = 1;
        }
        return kIOReturnSuccess;
    case kConnectionFlags:
        if (value) {
            *value = 0;
        }
        return kIOReturnSuccess;
    case kConnectionSupportsHLDDCSense:
        return (core_ && core_->edid()) ? kIOReturnSuccess : kIOReturnUnsupported;
    case kConnectionDisplayParameterCount:
        if (value) {
            *value = 0;
        }
        return kIOReturnSuccess;
    default:
        return IOFramebuffer::getAttributeForConnection(index, attribute, value);
    }
}

IOReturn VirtioGPUFramebuffer::setAttributeForConnection(IOIndex index, IOSelect attribute, uintptr_t value) {
    switch (attribute) {
    case kConnectionEnable:
    case kConnectionCheckEnable:
        return kIOReturnSuccess;
    default:
        return IOFramebuffer::setAttributeForConnection(index, attribute, value);
    }
}

bool VirtioGPUFramebuffer::hasDDCConnect(IOIndex index) {
    return index == 0 && core_ && core_->edid() && core_->edid()->getLength() >= 128;
}

IOReturn VirtioGPUFramebuffer::getDDCBlock(IOIndex index, UInt32 blockNumber, IOSelect blockType,
                                           IOOptionBits, UInt8 *data, IOByteCount *length) {
    OSData *edid = core_ ? core_->edid() : nullptr;
    if (index != 0 || blockType != kIODDCBlockTypeEDID || !edid || !data || !length || blockNumber < 1) {
        return kIOReturnBadArgument;
    }
    uint32_t offset = (blockNumber - 1) * 128;
    if (offset + 128 > edid->getLength() || *length < 128) {
        return kIOReturnBadArgument;
    }
    memcpy(data, static_cast<const uint8_t *>(edid->getBytesNoCopy()) + offset, 128);
    *length = 128;
    return kIOReturnSuccess;
}
