// VirtioGPUFramebuffer - stage 2c: the screen. A kext of its own in the Auxiliary kernel
// collection, because IOFramebuffer lives in IOGraphicsFamily (System KC), which OpenCore can't
// link injected kexts against.
//
// Matches the VirtioGPUDisplay nub that VirtioGPU.kext (the core, injected by OpenCore) publishes,
// and talks to the core only through callPlatformFunction (../VirtioGPUAPI.h). Gives WindowServer
// a block of contiguous RAM as VRAM (aperture), shows it through a virtio-gpu 2D scanout resource,
// and pushes the whole frame to the host 30 times a second (WindowServer doesn't say what
// changed). Hardware cursor: 64x64 ARGB images converted by convertCursorImage, shown and moved on
// the device's cursor queue, so pointer motion doesn't depend on the frame flush. The core's
// VirtioGPUFramebufferSlot keeps IONDRVFramebuffer off the PCI device, so this is the only
// framebuffer.

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOLib.h>
#include <IOKit/graphics/IOFramebuffer.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOWorkLoop.h>

#include "../VirtioGPUAPI.h"

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
    IOReturn setCursorImage(void *cursorImage) override;
    IOReturn setCursorState(SInt32 x, SInt32 y, bool visible) override;
    IOReturn getDDCBlock(IOIndex index, UInt32 blockNumber, IOSelect blockType, IOOptionBits options,
                         UInt8 *data, IOByteCount *length) override;

private:
    const Mode *modeFor(IODisplayModeID id) const {
        return (id >= 1 && (unsigned)id <= modeCount_) ? &modes_[id - 1] : nullptr;
    }
    bool applyMode(IODisplayModeID id);
    void log(const char *fmt, ...) __attribute__((format(printf, 2, 3)));
    IOReturn call(const char *function, void *p1 = nullptr, void *p2 = nullptr, void *p3 = nullptr,
                  void *p4 = nullptr);
    bool setScanout(uint32_t w, uint32_t h, uint32_t stride) {
        return call(kVGPUSetScanout, vram_, (void *)(uintptr_t)w, (void *)(uintptr_t)h,
                    (void *)(uintptr_t)stride) == kIOReturnSuccess;
    }
    void publish() { call(kVGPULog, nullptr, (void *)1); }
    void flushTick(IOTimerEventSource *timer);

    IOService *nub_ = nullptr;
    OSData *edid_ = nullptr;
    IOBufferMemoryDescriptor *vram_ = nullptr;
    uint64_t vramPhys_ = 0;
    uint32_t vramBytes_ = 0;
    Mode modes_[kMaxModes] = {};
    unsigned modeCount_ = 0;
    IODisplayModeID preferredMode_ = 0;
    IODisplayModeID currentMode_ = 0;
    // Own work loop: a flush waits ~4 ms on the host, which shouldn't hold IOFramebuffer's.
    IOWorkLoop *flushLoop_ = nullptr;
    IOTimerEventSource *flushTimer_ = nullptr;
    volatile bool flushing_ = false;
    uint32_t cursorPixels_[kVGPUCursorSize * kVGPUCursorSize] = {};
    uint32_t cursorHotX_ = 0, cursorHotY_ = 0;
    bool cursorReady_ = false;
    uint32_t cursorImages_ = 0, cursorMoves_ = 0;
    uint32_t ticks_ = 0;
};

OSDefineMetaClassAndStructors(VirtioGPUFramebuffer, IOFramebuffer)

void VirtioGPUFramebuffer::log(const char *fmt, ...) {
    char line[200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    char prefixed[210];
    snprintf(prefixed, sizeof(prefixed), "fb: %s", line);
    IOLog("VirtioGPU %s\n", prefixed);
    call(kVGPULog, prefixed);
}

IOReturn VirtioGPUFramebuffer::call(const char *function, void *p1, void *p2, void *p3, void *p4) {
    if (!nub_) {
        return kIOReturnNotReady;
    }
    const OSSymbol *sym = OSSymbol::withCString(function);
    if (!sym) {
        return kIOReturnNoMemory;
    }
    IOReturn r = nub_->callPlatformFunction(sym, false, p1, p2, p3, p4);
    sym->release();
    return r;
}

IOService *VirtioGPUFramebuffer::probe(IOService *provider, SInt32 *score) {
    // -vgpuoff is handled by the core: without it there's no VirtioGPUDisplay nub to match.
    return IOFramebuffer::probe(provider, score);
}

bool VirtioGPUFramebuffer::start(IOService *provider) {
    nub_ = provider; // VirtioGPUDisplay, published by the core once the device is up
    uint32_t pw = 0, ph = 0;
    if (call(kVGPUPreferredSize, &pw, &ph) != kIOReturnSuccess) {
        IOLog("VirtioGPU fb: the core didn't answer; not starting\n");
        nub_ = nullptr;
        return false;
    }
    if (call(kVGPUCopyEDID, &edid_) != kIOReturnSuccess) {
        edid_ = nullptr;
    }
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
        OSSafeReleaseNULL(edid_);
        nub_ = nullptr;
        return false;
    }
    bzero(vram_->getBytesNoCopy(), vramBytes_);
    vramPhys_ = vram_->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);
    log("start: %u modes, preferred %u (%ux%u), VRAM %u bytes at 0x%llx", modeCount_, preferredMode_,
        modes_[preferredMode_ - 1].width, modes_[preferredMode_ - 1].height, vramBytes_,
        (unsigned long long)vramPhys_);

    flushLoop_ = IOWorkLoop::workLoop();
    flushTimer_ = IOTimerEventSource::timerEventSource(
        this, OSMemberFunctionCast(IOTimerEventSource::Action, this, &VirtioGPUFramebuffer::flushTick));
    if (!flushLoop_ || !flushTimer_ || flushLoop_->addEventSource(flushTimer_) != kIOReturnSuccess) {
        log("flush timer setup failed");
        return false;
    }
    if (!IOFramebuffer::start(provider)) {
        log("IOFramebuffer::start failed");
        return false;
    }
    publish();
    return true;
}

void VirtioGPUFramebuffer::stop(IOService *provider) {
    flushing_ = false;
    if (flushTimer_) {
        flushTimer_->cancelTimeout();
        if (flushLoop_) {
            flushLoop_->removeEventSource(flushTimer_);
        }
        OSSafeReleaseNULL(flushTimer_);
    }
    OSSafeReleaseNULL(flushLoop_);
    if (nub_) {
        call(kVGPUDisableScanout);
        nub_ = nullptr;
    }
    OSSafeReleaseNULL(edid_);
    if (vram_) {
        vram_->complete();
        vram_->release();
        vram_ = nullptr;
    }
    IOFramebuffer::stop(provider);
}

bool VirtioGPUFramebuffer::applyMode(IODisplayModeID id) {
    const Mode *m = modeFor(id);
    if (!m || !nub_) {
        return false;
    }
    bool ok = setScanout(m->width, m->height, m->width * 4);
    log("mode %d %ux%u -> %s", id, m->width, m->height, ok ? "on screen" : "FAILED");
    if (ok) {
        currentMode_ = id;
        if (!flushing_ && flushTimer_) {
            flushing_ = true;
            flushTimer_->setTimeoutMS(kFlushIntervalMs);
        }
    }
    publish();
    return ok;
}

void VirtioGPUFramebuffer::flushTick(IOTimerEventSource *) {
    if (!flushing_) {
        return;
    }
    if (const Mode *m = modeFor(currentMode_)) {
        call(kVGPUFlush, nullptr, nullptr, (void *)(uintptr_t)m->width, (void *)(uintptr_t)m->height);
    }
    if (++ticks_ % 300 == 0) { // every ~10 s
        publish();
    }
    flushTimer_->setTimeoutMS(kFlushIntervalMs);
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
            *value = 1; // cursor queue
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
        return edid_ ? kIOReturnSuccess : kIOReturnUnsupported;
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
    return index == 0 && edid_ && edid_->getLength() >= 128;
}

IOReturn VirtioGPUFramebuffer::getDDCBlock(IOIndex index, UInt32 blockNumber, IOSelect blockType,
                                           IOOptionBits, UInt8 *data, IOByteCount *length) {
    OSData *edid = edid_;
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

// ---- Hardware cursor ----

IOReturn VirtioGPUFramebuffer::setCursorImage(void *cursorImage) {
    IOHardwareCursorDescriptor desc;
    bzero(&desc, sizeof(desc));
    desc.majorVersion = kHardwareCursorDescriptorMajorVersion;
    desc.height = kVGPUCursorSize;
    desc.width = kVGPUCursorSize;
    desc.bitDepth = 32; // ARGB, which is B8G8R8A8 in memory
    IOHardwareCursorInfo info;
    bzero(&info, sizeof(info));
    info.majorVersion = kHardwareCursorInfoMajorVersion;
    bzero(cursorPixels_, sizeof(cursorPixels_));
    info.hardwareCursorData = reinterpret_cast<UInt8 *>(cursorPixels_);
    if (!convertCursorImage(cursorImage, &desc, &info)) {
        return kIOReturnUnsupported;
    }
    // convertCursorImage packs rows at the cursor's own width; the device wants a 64-pixel stride.
    uint32_t w = info.cursorWidth, h = info.cursorHeight;
    if (w && w < kVGPUCursorSize) {
        for (int y = (int)h - 1; y >= 0; y--) {
            memmove(&cursorPixels_[y * kVGPUCursorSize], &cursorPixels_[y * w], w * 4);
            bzero(&cursorPixels_[y * kVGPUCursorSize + w], (kVGPUCursorSize - w) * 4);
        }
    }
    cursorHotX_ = info.cursorHotSpotX;
    cursorHotY_ = info.cursorHotSpotY;
    cursorReady_ = call(kVGPUSetCursor, cursorPixels_, (void *)(uintptr_t)cursorHotX_,
                        (void *)(uintptr_t)cursorHotY_) == kIOReturnSuccess;
    if (cursorImages_++ < 3) {
        log("cursor image %ux%u hot %u,%u -> %s", w, h, cursorHotX_, cursorHotY_,
            cursorReady_ ? "on the cursor queue" : "FAILED");
    }
    return cursorReady_ ? kIOReturnSuccess : kIOReturnError;
}

IOReturn VirtioGPUFramebuffer::setCursorState(SInt32 x, SInt32 y, bool visible) {
    if (!cursorReady_) {
        return kIOReturnNotReady;
    }
    // IOFramebuffer gives the image's top-left corner; virtio-gpu positions the hot spot.
    SInt32 hx = x + (SInt32)cursorHotX_, hy = y + (SInt32)cursorHotY_;
    call(kVGPUMoveCursor, (void *)(uintptr_t)(hx < 0 ? 0 : hx), (void *)(uintptr_t)(hy < 0 ? 0 : hy),
         visible ? (void *)1 : nullptr);
    if (cursorMoves_++ == 0) {
        log("first cursor move to %d,%d visible %d", (int)hx, (int)hy, visible);
    }
    return kIOReturnSuccess;
}
