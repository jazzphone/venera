// VirtioGPU - the virtio core (stage 2c).
//
// Claims the virtio-gpu PCI function (1af4:1050) in the default match category, so Apple's
// generic AppleVirtIOPCITransport (probe score 10000) doesn't. Brings the device up (reset,
// features, control + cursor virtqueues on MSI-X vector 0, DRIVER_OK), reads the display info and
// EDID, and serves VirtioGPUFramebuffer: scanout resources backed by its VRAM, transfer + flush.
//
// Command memory is shared: every request is built in commandBytes_ while holding scanoutLock_
// (or during start, before the framebuffer exists), and command() serializes the queue work.
//
// Everything worth seeing goes into the "ProbeLog" registry property (tools/deploy.sh logs).
// Boot with -vgpuoff to keep both drivers from matching.

#include "VirtioGPU.hpp"

#include <IOKit/IOLib.h>
#include <IOKit/IODeviceTreeSupport.h>
#include <libkern/c++/OSArray.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSString.h>
#include <pexpert/pexpert.h>

#include "../VirtioGPUAPI.h"
#include "../VirtioGPUUserAPI.h"
#include "VirtioGPUUserClient.hpp"
#include "VirtioGPUProtocol.h"

// IOLog from an OpenCore-injected kext doesn't reach dmesg or the unified log on Tahoe, so every
// line also goes into the "ProbeLog" registry property.
static OSArray *gProbeLog;
static IOLock *gProbeLogLock;

void probeLog(const char *fmt, ...) {
    char line[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    IOLog("VirtioGPU: %s\n", line);
    if (gProbeLog && gProbeLogLock) {
        if (OSString *s = OSString::withCString(line)) {
            IOLockLock(gProbeLogLock);
            if (gProbeLog->getCount() < 400) {
                gProbeLog->setObject(s);
            }
            IOLockUnlock(gProbeLogLock);
            s->release();
        }
    }
}

#define LOG(fmt, ...) probeLog(fmt, ##__VA_ARGS__)

namespace {

enum : uint8_t {
    kCapCommon = 1,
    kCapNotify = 2,
};

const char *respName(uint32_t type) {
    switch (type) {
    case vgpu::kRespOkNoData: return "OK_NODATA";
    case vgpu::kRespOkDisplayInfo: return "OK_DISPLAY_INFO";
    case vgpu::kRespOkEDID: return "OK_EDID";
    case vgpu::kRespOkCapsetInfo: return "OK_CAPSET_INFO";
    case vgpu::kRespOkCapset: return "OK_CAPSET";
    case vgpu::kRespErrInvalidContextID: return "ERR_INVALID_CONTEXT_ID";
    case vgpu::kRespErrUnspec: return "ERR_UNSPEC";
    case vgpu::kRespErrOutOfMemory: return "ERR_OUT_OF_MEMORY";
    case vgpu::kRespErrInvalidScanoutID: return "ERR_INVALID_SCANOUT_ID";
    case vgpu::kRespErrInvalidResourceID: return "ERR_INVALID_RESOURCE_ID";
    case vgpu::kRespErrInvalidParameter: return "ERR_INVALID_PARAMETER";
    case 0: return "TIMEOUT";
    default: return "?";
    }
}

const char *capsetName(uint32_t id) {
    switch (id) {
    case vgpu::kCapsetVirgl: return "virgl";
    case vgpu::kCapsetVirgl2: return "virgl2";
    case vgpu::kCapsetGfxstreamVulkan: return "gfxstream-vulkan";
    case vgpu::kCapsetVenus: return "venus";
    case vgpu::kCapsetCrossDomain: return "cross-domain";
    case vgpu::kCapsetDRM: return "drm";
    default: return "?";
    }
}

constexpr uint16_t kQueueControl = 0;
constexpr uint16_t kQueueCursor = 1;
constexpr uint16_t kMaxQueueSize = 128;
constexpr uint16_t kNoVector = 0xffff;
// Command memory: the request (up to kRequestMax, room for ~1,790 backing entries) then the reply.
constexpr uint32_t kCommandBytes = 32 * 1024;
constexpr uint32_t kReplyOffset = 28 * 1024;
constexpr uint32_t kRequestMax = kReplyOffset;

uint64_t nowNs() {
    uint64_t t = 0, ns = 0;
    clock_get_uptime(&t);
    absolutetime_to_nanoseconds(t, &ns);
    return ns;
}

// macOS Recovery and the installer: an installed macOS's Recovery boots from a RAM-disk image (the booter leaves
// /chosen's boot-ramdmg-extents), the installer's own Recovery (macOS Base System) through bootbase.efi (/chosen's
// booter-name; a normal boot's is boot.efi). There the rest of Venera (the framebuffer and the accelerator, in the
// Auxiliary KC) never comes: with the device taken, and IONDRVFramebuffer kept off it, WindowServer had nothing to
// draw on and Recovery showed no picture. Both personalities leave the device to IONDRVFramebuffer and the firmware's
// framebuffer there; -vgpurecovery takes it anyway. Only reads: a probe must not change the registry.
bool recoveryBoot() {
    char arg[8];
    if (PE_parse_boot_argn("-vgpurecovery", arg, sizeof(arg))) {
        return false;
    }
    IORegistryEntry *chosen = IORegistryEntry::fromPath("/chosen", gIODTPlane);
    if (!chosen) {
        return false;
    }
    bool recovery = chosen->getProperty("boot-ramdmg-extents") != nullptr;
    if (OSData *booter = OSDynamicCast(OSData, chosen->getProperty("booter-name"))) {
        static const char kBase[] = "bootbase.efi";
        recovery = recovery || (booter->getLength() >= sizeof(kBase) - 1 &&
                                memcmp(booter->getBytesNoCopy(), kBase, sizeof(kBase) - 1) == 0);
    }
    chosen->release();
    return recovery;
}

} // namespace

OSDefineMetaClassAndStructors(VirtioGPU, IOService)

IOService *VirtioGPU::probe(IOService *provider, SInt32 *score) {
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci) {
        return nullptr;
    }
    char arg[8];
    if (PE_parse_boot_argn("-vgpuoff", arg, sizeof(arg))) {
        return nullptr;
    }
    if (recoveryBoot()) {
        IOLog("VirtioGPU: a Recovery or installer boot: leaving the display to the firmware\n");
        return nullptr;
    }
    if (pci->configRead16(kIOPCIConfigVendorID) != 0x1af4 ||
        pci->configRead16(kIOPCIConfigDeviceID) != 0x1050) {
        return nullptr;
    }
    return IOService::probe(provider, score);
}

bool VirtioGPU::start(IOService *provider) {
    if (!IOService::start(provider)) {
        return false;
    }
    pci_ = OSDynamicCast(IOPCIDevice, provider);
    if (!pci_) {
        return false;
    }
    if (!gProbeLogLock) {
        gProbeLogLock = IOLockAlloc();
        gProbeLog = OSArray::withCapacity(128);
    }
    commandLock_ = IOLockAlloc();
    scanoutLock_ = IOLockAlloc();
    twinLock_ = IOLockAlloc();
    cursorLock_ = IOLockAlloc();
    LOG("core start: stage 2c (MSI-X, scanout API for the framebuffer)");
    pci_->setMemoryEnable(true);
    pci_->setBusMasterEnable(true);
    logHeader();

    bool ok = setupInterrupt() && bringUp();
    if (ok) {
        getDisplayInfo();
        if (features_ & (1ULL << vgpu::kFeatureEDID)) {
            getEDID(0);
        }
        getCapsets();
        if (venusCapset_) {
            venusProbe();
        }
        LOG("core ready: %ux%u preferred, interrupts %u", width_, height_, interrupts_);
        VirtioGPUDisplay *nub = OSTypeAlloc(VirtioGPUDisplay);
        if (nub && nub->init() && nub->attach(this)) {
            nub->registerService(); // VirtioGPUFramebuffer.kext matches on this
            display_ = nub;
            LOG("published %s nub", kVGPUDisplayClass);
        } else {
            OSSafeReleaseNULL(nub);
            LOG("could not publish the display nub");
        }
    } else {
        LOG("bring-up failed; resetting the device");
        tearDown();
    }
    publishLog();
    registerService(); // VirtioGPUFramebuffer waits for this
    return true;       // stay attached either way, so the log stays readable
}

void VirtioGPU::stop(IOService *provider) {
    if (display_) {
        display_->terminate();
        display_->release();
        display_ = nullptr;
    }
    disableScanout();
    tearDown();
    if (interrupt_) {
        interrupt_->disable();
        if (workLoop_) {
            workLoop_->removeEventSource(interrupt_);
        }
        interrupt_->release();
        interrupt_ = nullptr;
    }
    if (workLoop_) {
        workLoop_->release();
        workLoop_ = nullptr;
    }
    if (edid_) {
        edid_->release();
        edid_ = nullptr;
    }
    IOService::stop(provider);
}

void VirtioGPU::addLog(const char *line) { probeLog("%s", line); }

void VirtioGPU::publishLog() {
    if (!gProbeLog) {
        return;
    }
    IOLockLock(gProbeLogLock);
    OSArray *copy = OSArray::withArray(gProbeLog);
    IOLockUnlock(gProbeLogLock);
    if (copy) {
        setProperty("ProbeLog", copy);
        copy->release();
    }
    if (OSDictionary *stats = OSDictionary::withCapacity(4)) {
        const struct { const char *key; uint32_t value; } items[] = {
            {"Interrupts", interrupts_},
            {"CommandsByInterrupt", commandsByInterrupt_},
            {"CommandsByPolling", commandsByPolling_},
            {"Flushes", flushes_},
            {"CursorDropped", cursorDropped_},
        };
        for (const auto &item : items) {
            if (OSNumber *n = OSNumber::withNumber(item.value, 32)) {
                stats->setObject(item.key, n);
                n->release();
            }
        }
        setProperty("Stats", stats);
        stats->release();
    }
}

void VirtioGPU::logHeader() {
    LOG("pci %04x:%04x sub %04x:%04x rev %02x cmd %04x",
        pci_->configRead16(kIOPCIConfigVendorID), pci_->configRead16(kIOPCIConfigDeviceID),
        pci_->configRead16(kIOPCIConfigSubSystemVendorID),
        pci_->configRead16(kIOPCIConfigSubSystemID), pci_->configRead8(kIOPCIConfigRevisionID),
        pci_->configRead16(kIOPCIConfigCommand));
}

bool VirtioGPU::findRegions(virtio::Region regions[9], uint32_t *notifyMultiplier) {
    if (!(pci_->configRead16(kIOPCIConfigStatus) & 0x10)) {
        LOG("no capability list");
        return false;
    }
    uint8_t ptr = pci_->configRead8(kIOPCIConfigCapabilitiesPtr) & 0xfc;
    for (int guard = 0; ptr && guard < 48; guard++) {
        uint8_t id = pci_->configRead8(ptr);
        uint8_t next = pci_->configRead8(ptr + 1) & 0xfc;
        if (id == 0x09) {
            uint8_t type = pci_->configRead8(ptr + 3);
            if (type == kCapNotify) {
                *notifyMultiplier = pci_->configRead32(ptr + 16);
            }
            if (type == 8 && pci_->configRead8(ptr + 2) >= 24) { // VIRTIO_PCI_CAP_SHARED_MEMORY_CFG
                uint8_t bar = pci_->configRead8(ptr + 4);
                hostmemID_ = pci_->configRead8(ptr + 5);
                hostmemBar_ = bar;
                hostmemOffset_ = ((uint64_t)pci_->configRead32(ptr + 16) << 32) | pci_->configRead32(ptr + 8);
                hostmemLength_ = ((uint64_t)pci_->configRead32(ptr + 20) << 32) | pci_->configRead32(ptr + 12);
                LOG("shared memory id %u: BAR%u offset 0x%llx length 0x%llx (%llu MB)", hostmemID_, bar,
                    (unsigned long long)hostmemOffset_, (unsigned long long)hostmemLength_,
                    (unsigned long long)(hostmemLength_ >> 20));
            }
            if (type < 9 && !regions[type].present) {
                regions[type].present = true;
                regions[type].bar = pci_->configRead8(ptr + 4);
                regions[type].offset = pci_->configRead32(ptr + 8);
                regions[type].length = pci_->configRead32(ptr + 12);
            }
        }
        ptr = next;
    }
    return regions[kCapCommon].present;
}

bool VirtioGPU::setupInterrupt() {
    int index = -1;
    for (int i = 0; i < 8; i++) {
        int type = 0;
        if (pci_->getInterruptType(i, &type) != kIOReturnSuccess) {
            break;
        }
        if ((type & kIOInterruptTypePCIMessaged) && index < 0) {
            index = i;
        }
    }
    msix_ = index >= 0;
    if (index < 0) {
        index = 0; // INTx
    }
    workLoop_ = IOWorkLoop::workLoop();
    if (!workLoop_) {
        return false;
    }
    interrupt_ = IOFilterInterruptEventSource::filterInterruptEventSource(
        this, OSMemberFunctionCast(IOInterruptEventAction, this, &VirtioGPU::interruptOccurred),
        OSMemberFunctionCast(IOFilterInterruptAction, this, &VirtioGPU::filter), pci_, index);
    if (!interrupt_ || workLoop_->addEventSource(interrupt_) != kIOReturnSuccess) {
        LOG("could not register interrupt index %d", index);
        return false;
    }
    interrupt_->enable();
    LOG("interrupt index %d (%s)", index, msix_ ? "MSI-X" : "INTx");
    return true;
}

bool VirtioGPU::filter(IOFilterInterruptEventSource *) {
    if (!msix_ && !(transport_.readISR() & 1)) {
        return false; // shared INTx line, not ours
    }
    OSIncrementAtomic(reinterpret_cast<volatile SInt32 *>(&interrupts_));
    return true;
}

void VirtioGPU::interruptOccurred(IOInterruptEventSource *, int) {
    IOLockLock(commandLock_);
    drainControl();
    IOLockWakeup(commandLock_, &wakeEvent_, false);
    IOLockUnlock(commandLock_);
}

bool VirtioGPU::bringUp() {
    virtio::Region regions[9] = {};
    uint32_t multiplier = 0;
    if (!findRegions(regions, &multiplier) || !transport_.attach(pci_, regions, multiplier)) {
        return false;
    }

    // Section 3.1.1: reset, ACKNOWLEDGE, DRIVER, features, FEATURES_OK, queues, DRIVER_OK.
    transport_.reset();
    transport_.addStatus(virtio::kAcknowledge);
    transport_.addStatus(virtio::kDriver);

    uint64_t offered = transport_.deviceFeatures();
    uint64_t wanted = (1ULL << virtio::kFeatureVersion1) | (1ULL << vgpu::kFeatureEDID) |
                      (1ULL << vgpu::kFeatureVirgl) | (1ULL << vgpu::kFeatureResourceBlob) |
                      (1ULL << vgpu::kFeatureContextInit);
    if (!transport_.negotiate(wanted, &features_) ||
        !(features_ & (1ULL << virtio::kFeatureVersion1))) {
        LOG("feature negotiation failed (0x%llx)", (unsigned long long)features_);
        return false;
    }
    LOG("features offered 0x%llx accepted 0x%llx:%s%s%s%s", (unsigned long long)offered,
        (unsigned long long)features_, (features_ & (1ULL << vgpu::kFeatureVirgl)) ? " VIRGL" : "",
        (features_ & (1ULL << vgpu::kFeatureEDID)) ? " EDID" : "",
        (features_ & (1ULL << vgpu::kFeatureResourceBlob)) ? " RESOURCE_BLOB" : "",
        (features_ & (1ULL << vgpu::kFeatureContextInit)) ? " CONTEXT_INIT" : "");

    volatile vgpu::Config *config = reinterpret_cast<volatile vgpu::Config *>(transport_.deviceConfig());
    numScanouts_ = config->numScanouts;
    numCapsets_ = config->numCapsets;
    LOG("config: scanouts %u capsets %u", numScanouts_, numCapsets_);
    if (hostmemLength_ && hostmemBar_ < 5) {
        // IOPCIFamily lists this 64-bit BAR as an IOSubMemoryDescriptor, which
        // getDeviceMemoryWithRegister doesn't hand back as device memory: read the BAR itself.
        uint8_t reg = kIOPCIConfigBaseAddress0 + hostmemBar_ * 4;
        uint32_t low = pci_->configRead32(reg);
        uint64_t base = low & ~0xfULL;
        if ((low & 0x6) == 0x4) {
            base |= (uint64_t)pci_->configRead32(reg + 4) << 32;
        }
        // No IODeviceMemory for the whole window: macOS won't make a 4 GB one up there.
        // Each mapping gets its own descriptor (clientMemoryForType).
        // IOPCIFamily's own descriptor for the BAR (an IOSubMemoryDescriptor in the device's
        // memory list): mappings are sub-ranges of it.
        for (unsigned i = 0; i < getDeviceMemoryCount() || i < pci_->getDeviceMemoryCount(); i++) {
            IOMemoryDescriptor *md = reinterpret_cast<IOMemoryDescriptor *>(pci_->getDeviceMemoryWithIndex(i));
            if (!md) {
                break;
            }
            uint64_t start = md->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);
            LOG("device memory %u: %s phys 0x%llx length 0x%llx", i, md->getMetaClass()->getClassName(),
                (unsigned long long)start, (unsigned long long)md->getLength());
            if (start == base && md->getLength() >= hostmemOffset_ + hostmemLength_) {
                hostmemDesc_ = md;
                hostmemDesc_->retain();
            }
        }
        if (base && !(low & 1)) {
            hostmemPhys_ = base + hostmemOffset_;
            hostmemLock_ = IOLockAlloc();
            hostmemRanges_ = static_cast<HostmemRange *>(IOMallocZero(kMaxHostmemRanges * sizeof(HostmemRange)));
            LOG("hostmem window at phys 0x%llx, %llu MB, descriptor %s", (unsigned long long)hostmemPhys_,
                (unsigned long long)(hostmemLength_ >> 20), hostmemDesc_ ? "found" : "MISSING");
        } else {
            LOG("hostmem BAR%u not assigned (0x%08x)", hostmemBar_, low);
        }
    }

    uint16_t vector = msix_ ? 0 : kNoVector;
    if (msix_ && !transport_.setConfigVector(0)) {
        LOG("device refused config MSI-X vector");
    }
    control_ = transport_.setupQueue(kQueueControl, kMaxQueueSize, vector);
    cursor_ = transport_.setupQueue(kQueueCursor, kMaxQueueSize, vector);
    if (!control_ || !cursor_) {
        return false;
    }

    commandMemory_ = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, kCommandBytes,
        0xFFFFFFFFFFFFF000ULL);
    if (!commandMemory_ || commandMemory_->prepare() != kIOReturnSuccess) {
        LOG("command buffer allocation failed");
        return false;
    }
    commandBytes_ = static_cast<uint8_t *>(commandMemory_->getBytesNoCopy());
    commandPhys_ = commandMemory_->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);

    transport_.addStatus(virtio::kDriverOK);
    uint8_t status = transport_.status();
    LOG("status after DRIVER_OK 0x%02x", status);
    return (status & virtio::kDriverOK) && !(status & (virtio::kNeedsReset | virtio::kFailed));
}

void VirtioGPU::tearDown() {
    if (transport_.deviceConfig()) {
        transport_.reset(); // the device stops using our rings before we free them
    }
    IOLockLock(commandLock_);
    if (control_) {
        control_->release();
        control_ = nullptr;
    }
    if (cursor_) {
        cursor_->release();
        cursor_ = nullptr;
    }
    if (commandMemory_) {
        commandMemory_->complete();
        commandMemory_->release();
        commandMemory_ = nullptr;
        commandBytes_ = nullptr;
    }
    IOLockUnlock(commandLock_);
    transport_.detach();
}

uint32_t VirtioGPU::command(uint32_t requestLength, uint32_t replyLength, uint32_t timeoutMs) {
    // The shared command memory: callers built the request in commandBytes_ (scanoutLock_ held,
    // or during start).
    if (requestLength > kRequestMax || replyLength > kCommandBytes - kReplyOffset || !commandBytes_) {
        return 0;
    }
    bzero(commandBytes_ + kReplyOffset, replyLength);
    virtio::Segment segments[2] = {
        {commandPhys_, requestLength, false},
        {commandPhys_ + kReplyOffset, replyLength, true},
    };
    IOLockLock(commandLock_);
    uint32_t before = interrupts_;
    int slot = submitRequest(segments, 2, nullptr, false, nullptr, 0, 0);
    if (slot < 0) {
        IOLockUnlock(commandLock_);
        LOG("control queue full");
        return 0;
    }
    uint64_t limit = nowNs() + (uint64_t)timeoutMs * 1000000ULL;
    while (!requests_[slot].done && nowNs() < limit) {
        uint64_t deadline = 0;
        clock_interval_to_deadline(5, kMillisecondScale, &deadline);
        IOLockSleepDeadline(commandLock_, &wakeEvent_, deadline, THREAD_UNINT);
        drainControl(); // polling fallback
    }
    bool done = requests_[slot].done;
    if (done) {
        requests_[slot].inUse = false;
        if (interrupts_ != before) {
            commandsByInterrupt_++;
        } else {
            commandsByPolling_++;
        }
    } // else: left in use, the device may still write the reply; leak the slot rather than race
    IOLockUnlock(commandLock_);
    if (!done) {
        LOG("command timed out after %u ms", timeoutMs);
        return 0;
    }
    return reinterpret_cast<vgpu::CtrlHdr *>(commandBytes_ + kReplyOffset)->type;
}

int VirtioGPU::submitRequest(const virtio::Segment *segments, unsigned count, IOBufferMemoryDescriptor *owned,
                             bool async, VirtioGPUUserClient *fenceOwner, uint32_t ring, uint64_t fence) {
    if (!control_) {
        return -1;
    }
    drainControl(); // free finished slots first
    int head = control_->submit(segments, count);
    if (head < 0 || head >= (int)(sizeof(requests_) / sizeof(requests_[0]))) {
        return -1;
    }
    Request &r = requests_[head];
    r.inUse = true;
    r.done = false;
    r.async = async;
    r.usedLength = 0;
    r.owned = owned;
    r.fenceOwner = fenceOwner;
    r.ring = ring;
    r.fence = fence;
    if (owned) {
        owned->retain();
    }
    if (fenceOwner) {
        fenceOwner->retain();
    }
    if (async) {
        asyncInFlight_++;
    }
    transport_.notify(control_);
    return head;
}

void VirtioGPU::drainControl() {
    if (!control_) {
        return;
    }
    uint32_t id = 0, length = 0;
    bool any = false;
    while (control_->takeUsed(&id, &length)) {
        any = true;
        if (id >= sizeof(requests_) / sizeof(requests_[0])) {
            continue;
        }
        Request &r = requests_[id];
        r.usedLength = length;
        r.done = true;
        if (r.async) {
            if (r.fenceOwner) {
                r.fenceOwner->requestCompleted(r.ring, r.fence);
                r.fenceOwner->release();
                r.fenceOwner = nullptr;
            }
            if (r.owned) {
                r.owned->complete();
                r.owned->release();
                r.owned = nullptr;
            }
            r.inUse = false;
            asyncInFlight_--;
        }
    }
    if (any) {
        IOLockWakeup(commandLock_, &wakeEvent_, false);
    }
}

bool VirtioGPU::waitUntil(bool (*done)(void *), void *context, uint64_t timeoutNs) {
    IOLockLock(commandLock_);
    uint64_t limit = nowNs() + timeoutNs;
    bool result;
    while (!(result = done(context)) && nowNs() < limit) {
        uint64_t deadline = 0;
        clock_interval_to_deadline(5, kMillisecondScale, &deadline);
        IOLockSleepDeadline(commandLock_, &wakeEvent_, deadline, THREAD_UNINT);
        drainControl();
    }
    IOLockUnlock(commandLock_);
    return result;
}

uint32_t VirtioGPU::transact(const void *request, uint32_t requestLength, void *reply, uint32_t replyLength,
                             uint32_t timeoutMs) {
    if (!ready() || requestLength == 0 || requestLength > 64 * 1024 || replyLength > 64 * 1024) {
        return 0;
    }
    uint32_t replyOffset = (requestLength + 63) & ~63u;
    IOBufferMemoryDescriptor *buffer = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, replyOffset + replyLength,
        0xFFFFFFFFFFFFF000ULL);
    if (!buffer || buffer->prepare() != kIOReturnSuccess) {
        OSSafeReleaseNULL(buffer);
        return 0;
    }
    uint8_t *bytes = static_cast<uint8_t *>(buffer->getBytesNoCopy());
    memcpy(bytes, request, requestLength);
    bzero(bytes + replyOffset, replyLength);
    uint64_t phys = buffer->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);
    virtio::Segment segments[2] = {{phys, requestLength, false}, {phys + replyOffset, replyLength, true}};

    IOLockLock(commandLock_);
    int slot = submitRequest(segments, 2, nullptr, false, nullptr, 0, 0);
    uint32_t type = 0;
    if (slot >= 0) {
        uint64_t limit = nowNs() + (uint64_t)timeoutMs * 1000000ULL;
        while (!requests_[slot].done && nowNs() < limit) {
            uint64_t deadline = 0;
            clock_interval_to_deadline(5, kMillisecondScale, &deadline);
            IOLockSleepDeadline(commandLock_, &wakeEvent_, deadline, THREAD_UNINT);
            drainControl();
        }
        if (requests_[slot].done) {
            requests_[slot].inUse = false;
            type = reinterpret_cast<vgpu::CtrlHdr *>(bytes + replyOffset)->type;
            if (reply) {
                memcpy(reply, bytes + replyOffset, replyLength);
            }
        }
    }
    IOLockUnlock(commandLock_);
    if (type) {
        buffer->complete();
        buffer->release();
    } else {
        LOG("transact: no reply (slot %d)", slot); // the buffer stays allocated: the device may still write it
    }
    return type;
}

bool VirtioGPU::submit3D(uint32_t ctx, uint32_t ring, uint64_t fence, const void *cs, uint32_t csLength,
                         IOMemoryDescriptor *csDescriptor, VirtioGPUUserClient *fenceOwner) {
    if (!ready()) {
        return false;
    }
    uint32_t header = sizeof(vgpu::CmdSubmit3D);
    uint32_t replyOffset = (header + csLength + 63) & ~63u;
    IOBufferMemoryDescriptor *buffer = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, replyOffset + sizeof(vgpu::CtrlHdr),
        0xFFFFFFFFFFFFF000ULL);
    if (!buffer || buffer->prepare() != kIOReturnSuccess) {
        OSSafeReleaseNULL(buffer);
        return false;
    }
    uint8_t *bytes = static_cast<uint8_t *>(buffer->getBytesNoCopy());
    auto *cmd = reinterpret_cast<vgpu::CmdSubmit3D *>(bytes);
    bzero(cmd, header);
    cmd->hdr.type = vgpu::kCmdSubmit3D;
    cmd->hdr.ctxID = ctx;
    cmd->hdr.ringIdx = (uint8_t)ring;
    if (fence) {
        cmd->hdr.flags = vgpu::kFlagFence | vgpu::kFlagInfoRingIdx;
        cmd->hdr.fenceID = fence;
    }
    cmd->size = csLength;
    if (csLength) {
        if (csDescriptor) {
            csDescriptor->readBytes(0, bytes + header, csLength);
        } else {
            memcpy(bytes + header, cs, csLength);
        }
    }
    uint64_t phys = buffer->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);
    virtio::Segment segments[2] = {{phys, header + csLength, false},
                                   {phys + replyOffset, (uint32_t)sizeof(vgpu::CtrlHdr), true}};
    IOLockLock(commandLock_);
    int slot = submitRequest(segments, 2, buffer, true, fenceOwner, ring, fence);
    IOLockUnlock(commandLock_);
    buffer->release(); // the request holds its own reference until it completes
    return slot >= 0;
}

bool VirtioGPU::hostmemAllocate(uint64_t size, uint64_t *offset) {
    size = (size + PAGE_SIZE - 1) & ~(uint64_t)(PAGE_SIZE - 1);
    if (!hostmemLock_ || !hostmemRanges_ || !size || size > hostmemLength_) {
        return false;
    }
    IOLockLock(hostmemLock_);
    bool ok = false;
    uint64_t candidate = 0;
    unsigned at = 0;
    for (; at <= hostmemRangeCount_; at++) {
        uint64_t limit = at < hostmemRangeCount_ ? hostmemRanges_[at].offset : hostmemLength_;
        if (limit >= candidate && limit - candidate >= size) {
            ok = hostmemRangeCount_ < kMaxHostmemRanges;
            break;
        }
        if (at < hostmemRangeCount_) {
            candidate = hostmemRanges_[at].offset + hostmemRanges_[at].size;
        }
    }
    if (ok) {
        memmove(&hostmemRanges_[at + 1], &hostmemRanges_[at], (hostmemRangeCount_ - at) * sizeof(HostmemRange));
        hostmemRanges_[at] = {candidate, size};
        hostmemRangeCount_++;
        *offset = candidate;
    }
    IOLockUnlock(hostmemLock_);
    return ok;
}

void VirtioGPU::hostmemFree(uint64_t offset, uint64_t size) {
    if (!hostmemLock_ || !hostmemRanges_) {
        return;
    }
    IOLockLock(hostmemLock_);
    for (unsigned i = 0; i < hostmemRangeCount_; i++) {
        if (hostmemRanges_[i].offset == offset) {
            memmove(&hostmemRanges_[i], &hostmemRanges_[i + 1], (hostmemRangeCount_ - i - 1) * sizeof(HostmemRange));
            hostmemRangeCount_--;
            break;
        }
    }
    IOLockUnlock(hostmemLock_);
}

IOReturn VirtioGPU::newUserClient(task_t owningTask, void *securityID, UInt32 type, IOUserClient **handler) {
    if (!ready() || !venusCapset_) {
        return kIOReturnNotReady;
    }
    VirtioGPUUserClient *client = OSTypeAlloc(VirtioGPUUserClient);
    if (!client || !client->initWithTask(owningTask, securityID, type) || !client->attach(this) ||
        !client->start(this)) {
        if (client) {
            client->detach(this);
            client->release();
        }
        return kIOReturnNoMemory;
    }
    *handler = client;
    return kIOReturnSuccess;
}

uint32_t VirtioGPU::simple(uint32_t requestLength) {
    return command(requestLength, sizeof(vgpu::CtrlHdr));
}

void VirtioGPU::getDisplayInfo() {
    auto *req = reinterpret_cast<vgpu::CtrlHdr *>(commandBytes_);
    bzero(req, sizeof(*req));
    req->type = vgpu::kCmdGetDisplayInfo;
    uint32_t type = command(sizeof(*req), sizeof(vgpu::RespDisplayInfo));
    LOG("GET_DISPLAY_INFO -> %s", respName(type));
    if (type != vgpu::kRespOkDisplayInfo) {
        return;
    }
    auto *info = reinterpret_cast<vgpu::RespDisplayInfo *>(commandBytes_ + kReplyOffset);
    width_ = info->pmodes[0].r.width;
    height_ = info->pmodes[0].r.height;
    for (uint32_t i = 0; i < vgpu::kMaxScanouts && i < (numScanouts_ ? numScanouts_ : 1); i++) {
        const auto &m = info->pmodes[i];
        LOG("scanout %u: %ux%u enabled %u", i, m.r.width, m.r.height, m.enabled);
    }
}

void VirtioGPU::getEDID(uint32_t scanout) {
    auto *req = reinterpret_cast<vgpu::CmdGetEDID *>(commandBytes_);
    bzero(req, sizeof(*req));
    req->hdr.type = vgpu::kCmdGetEDID;
    req->scanout = scanout;
    uint32_t type = command(sizeof(*req), sizeof(vgpu::RespEDID));
    LOG("GET_EDID -> %s", respName(type));
    if (type != vgpu::kRespOkEDID) {
        return;
    }
    auto *resp = reinterpret_cast<vgpu::RespEDID *>(commandBytes_ + kReplyOffset);
    uint32_t size = resp->size > sizeof(resp->edid) ? sizeof(resp->edid) : resp->size;
    edid_ = OSData::withBytes(resp->edid, size);
    if (edid_) {
        setProperty("EDID", edid_);
    }
}

void VirtioGPU::getCapsets() {
    for (uint32_t i = 0; i < numCapsets_ && i < 8; i++) {
        auto *req = reinterpret_cast<vgpu::CmdGetCapsetInfo *>(commandBytes_);
        bzero(req, sizeof(*req));
        req->hdr.type = vgpu::kCmdGetCapsetInfo;
        req->capsetIndex = i;
        if (command(sizeof(*req), sizeof(vgpu::RespCapsetInfo)) != vgpu::kRespOkCapsetInfo) {
            LOG("GET_CAPSET_INFO %u failed", i);
            continue;
        }
        auto *info = reinterpret_cast<vgpu::RespCapsetInfo *>(commandBytes_ + kReplyOffset);
        LOG("capset %u: id %u (%s) max version %u max size %u", i, info->capsetID,
            capsetName(info->capsetID), info->capsetMaxVersion, info->capsetMaxSize);
        capsetID_[i] = info->capsetID;
        capsetMaxVersion_[i] = info->capsetMaxVersion;
        capsetMaxSize_[i] = info->capsetMaxSize;
        if (info->capsetID == vgpu::kCapsetVenus) {
            venusCapset_ = true;
        }
    }
    if (OSNumber *n = OSNumber::withNumber(venusCapset_ ? 1 : 0, 32)) {
        setProperty("Venus", n);
        n->release();
    }
}

// Stage 3: read the Venus capset, then create and destroy a Venus context on the host.
void VirtioGPU::venusProbe() {
    auto *get = reinterpret_cast<vgpu::CmdGetCapset *>(commandBytes_);
    bzero(get, sizeof(*get));
    get->hdr.type = vgpu::kCmdGetCapset;
    get->capsetID = vgpu::kCapsetVenus;
    get->capsetVersion = 0;
    uint32_t type = command(sizeof(*get), sizeof(vgpu::CtrlHdr) + 160);
    LOG("GET_CAPSET venus -> %s", respName(type));
    if (type == vgpu::kRespOkCapset) {
        auto *v = reinterpret_cast<vgpu::CapsetVenus *>(commandBytes_ + kReplyOffset + sizeof(vgpu::CtrlHdr));
        LOG("venus: wire format %u, vk.xml %u.%u.%u, command serialization spec %u, mesa venus protocol "
            "spec %u, blob id 0 %u, wait syncs %u, multiple timelines %u, guest vram %u",
            v->wireFormatVersion, (v->vkXMLVersion >> 22) & 0x7f, (v->vkXMLVersion >> 12) & 0x3ff,
            v->vkXMLVersion & 0xfff, v->vkExtCommandSerializationSpecVersion,
            v->vkMesaVenusProtocolSpecVersion, v->supportsBlobID0, v->allowVkWaitSyncs,
            v->supportsMultipleTimelines, v->useGuestVram);
    }

    constexpr uint32_t kProbeContext = 1;
    auto *create = reinterpret_cast<vgpu::CmdCtxCreate *>(commandBytes_);
    bzero(create, sizeof(*create));
    create->hdr.type = vgpu::kCmdCtxCreate;
    create->hdr.ctxID = kProbeContext;
    create->contextInit = vgpu::kCapsetVenus & vgpu::kContextInitCapsetIDMask;
    strlcpy(create->debugName, "macos-virtio-gpu probe", sizeof(create->debugName));
    create->nlen = (uint32_t)strlen(create->debugName);
    type = simple(sizeof(*create));
    LOG("CTX_CREATE venus ctx %u -> %s", kProbeContext, respName(type));
    if (type != vgpu::kRespOkNoData) {
        return;
    }
    auto *destroy = reinterpret_cast<vgpu::CmdCtxDestroy *>(commandBytes_);
    bzero(destroy, sizeof(*destroy));
    destroy->hdr.type = vgpu::kCmdCtxDestroy;
    destroy->hdr.ctxID = kProbeContext;
    LOG("CTX_DESTROY ctx %u -> %s", kProbeContext, respName(simple(sizeof(*destroy))));
}

bool VirtioGPU::attachBacking(uint32_t resource, IOBufferMemoryDescriptor *memory, uint32_t bytes) {
    auto *req = reinterpret_cast<vgpu::CmdResourceAttachBacking *>(commandBytes_);
    auto *entries = reinterpret_cast<vgpu::MemEntry *>(commandBytes_ + sizeof(*req));
    uint32_t maxEntries = (kRequestMax - sizeof(*req)) / sizeof(vgpu::MemEntry);
    uint32_t n = 0;
    for (uint64_t offset = 0; offset < bytes;) {
        IOByteCount segLength = 0;
        addr64_t phys = memory->getPhysicalSegment(offset, &segLength, kIOMemoryMapperNone);
        if (!phys || !segLength) {
            LOG("backing: no physical segment at %llu", (unsigned long long)offset);
            return false;
        }
        if (segLength > bytes - offset) {
            segLength = bytes - offset;
        }
        if (n > 0 && entries[n - 1].addr + entries[n - 1].length == phys) {
            entries[n - 1].length += (uint32_t)segLength; // merge physically adjacent pieces
        } else if (n == maxEntries) {
            LOG("backing: more than %u segments", maxEntries);
            return false;
        } else {
            entries[n].addr = phys;
            entries[n].length = (uint32_t)segLength;
            entries[n].padding = 0;
            n++;
        }
        offset += segLength;
    }
    bzero(req, sizeof(*req));
    req->hdr.type = vgpu::kCmdResourceAttachBacking;
    req->resourceID = resource;
    req->nrEntries = n;
    uint32_t type = simple(sizeof(*req) + n * sizeof(vgpu::MemEntry));
    LOG("ATTACH_BACKING res %u: %u bytes in %u segments -> %s", resource, bytes, n, respName(type));
    return type == vgpu::kRespOkNoData;
}

void VirtioGPU::dropResource(uint32_t resource) {
    auto *detach = reinterpret_cast<vgpu::CmdResourceDetachBacking *>(commandBytes_);
    bzero(detach, sizeof(*detach));
    detach->hdr.type = vgpu::kCmdResourceDetachBacking;
    detach->resourceID = resource;
    simple(sizeof(*detach));
    auto *unref = reinterpret_cast<vgpu::CmdResourceUnref *>(commandBytes_);
    bzero(unref, sizeof(*unref));
    unref->hdr.type = vgpu::kCmdResourceUnref;
    unref->resourceID = resource;
    simple(sizeof(*unref));
}

bool VirtioGPU::setScanout(IOBufferMemoryDescriptor *memory, uint32_t width, uint32_t height,
                           uint32_t stride) {
    if (!ready() || !memory || !width || !height || stride < width * 4 ||
        (uint64_t)stride * height > memory->getLength()) {
        return false;
    }
    IOLockLock(scanoutLock_);
    uint32_t old = scanoutResource_;
    uint32_t resource = nextResource_++;

    auto *create = reinterpret_cast<vgpu::CmdResourceCreate2D *>(commandBytes_);
    bzero(create, sizeof(*create));
    create->hdr.type = vgpu::kCmdResourceCreate2D;
    create->resourceID = resource;
    create->format = vgpu::kFormatB8G8R8X8;
    create->width = width;
    create->height = height;
    uint32_t type = simple(sizeof(*create));
    bool ok = type == vgpu::kRespOkNoData;
    LOG("RESOURCE_CREATE_2D res %u %ux%u -> %s", resource, width, height, respName(type));
    ok = ok && attachBacking(resource, memory, stride * height);

    if (ok) {
        auto *set = reinterpret_cast<vgpu::CmdSetScanout *>(commandBytes_);
        bzero(set, sizeof(*set));
        set->hdr.type = vgpu::kCmdSetScanout;
        set->r = {0, 0, width, height};
        set->scanoutID = 0;
        set->resourceID = resource;
        type = simple(sizeof(*set));
        LOG("SET_SCANOUT res %u -> %s", resource, respName(type));
        ok = type == vgpu::kRespOkNoData;
    }
    if (ok) {
        scanoutBlob_ = 0;   // a new mode: the framebuffer's own resource is on screen again
        scanoutResource_ = resource;
        scanoutWidth_ = width;
        scanoutHeight_ = height;
        scanoutStride_ = stride;
        if (old) {
            dropResource(old);
        }
    } else {
        dropResource(resource);
    }
    IOLockUnlock(scanoutLock_);
    if (ok) {
        flush(0, 0, width, height);
    }
    return ok;
}

bool VirtioGPU::setScanoutBlob(uint32_t resource, uint32_t width, uint32_t height, uint32_t stride, uint32_t offset) {
    if (!ready() || !scanoutLock_) {
        return false;
    }
    IOLockLock(scanoutLock_);
    bool ok;
    if (!resource) {   // back to the framebuffer's 2D resource
        if (!scanoutBlob_) {
            IOLockUnlock(scanoutLock_);
            return true;
        }
        auto *set = reinterpret_cast<vgpu::CmdSetScanout *>(commandBytes_);
        bzero(set, sizeof(*set));
        set->hdr.type = vgpu::kCmdSetScanout;
        set->r = {0, 0, scanoutWidth_, scanoutHeight_};
        set->scanoutID = 0;
        set->resourceID = scanoutResource_;
        uint32_t type = simple(sizeof(*set));
        ok = type == vgpu::kRespOkNoData;
        LOG("SET_SCANOUT back to res %u (from blob %u) -> %s", scanoutResource_, scanoutBlob_, respName(type));
        scanoutBlob_ = 0;
        IOLockUnlock(scanoutLock_);
        if (ok) {
            flush(0, 0, scanoutWidth_, scanoutHeight_);
        }
        return ok;
    }
    if (!width || !height || stride < width * 4) {
        IOLockUnlock(scanoutLock_);
        return false;
    }
    if (resource != scanoutBlob_) {
        auto *set = reinterpret_cast<vgpu::CmdSetScanoutBlob *>(commandBytes_);
        bzero(set, sizeof(*set));
        set->hdr.type = vgpu::kCmdSetScanoutBlob;
        set->r = {0, 0, width, height};
        set->scanoutID = 0;
        set->resourceID = resource;
        set->width = width;
        set->height = height;
        set->format = vgpu::kFormatB8G8R8X8;
        set->strides[0] = stride;
        set->offsets[0] = offset;
        uint32_t type = simple(sizeof(*set));
        ok = type == vgpu::kRespOkNoData;
        if (blobFlips_ < 8 || !ok) {
            LOG("SET_SCANOUT_BLOB res %u %ux%u stride %u offset %u -> %s", resource, width, height, stride, offset,
                respName(type));
        }
        if (!ok) {
            IOLockUnlock(scanoutLock_);
            return false;
        }
        scanoutBlob_ = resource;
    }
    auto *f = reinterpret_cast<vgpu::CmdResourceFlush *>(commandBytes_);
    bzero(f, sizeof(*f));
    f->hdr.type = vgpu::kCmdResourceFlush;
    f->r = {0, 0, width, height};
    f->resourceID = resource;
    ok = simple(sizeof(*f)) == vgpu::kRespOkNoData;
    blobFlips_++;
    IOLockUnlock(scanoutLock_);
    return ok;
}

void VirtioGPU::addClient(VirtioGPUUserClient *c) {
    if (!twinLock_) {
        return;
    }
    IOLockLock(twinLock_);
    for (unsigned i = 0; i < kMaxClients; i++) {
        if (!clients_[i]) {
            clients_[i] = c;
            break;
        }
    }
    IOLockUnlock(twinLock_);
}

void VirtioGPU::removeClient(VirtioGPUUserClient *c) {
    if (!twinLock_) {
        return;
    }
    IOLockLock(twinLock_);
    for (unsigned i = 0; i < kMaxClients; i++) {
        if (clients_[i] == c) {
            clients_[i] = nullptr;
        }
    }
    IOLockUnlock(twinLock_);
}

IOReturn VirtioGPU::setTwin(task_t task, uint32_t surface, uint32_t resource, uint32_t width, uint32_t height,
                            uint32_t stride, uint32_t resource2) {
    if (!twinLock_ || !surface) {
        return kIOReturnBadArgument;
    }
    IOLockLock(twinLock_);
    if (resource) {
        bool owned = false, owned2 = !resource2;
        for (unsigned i = 0; i < kMaxClients; i++) {
            owned = owned || (clients_[i] && clients_[i]->owns(task, resource));
            owned2 = owned2 || (clients_[i] && clients_[i]->owns(task, resource2));
        }
        owned = owned && owned2 && resource2 != resource;
        // Only the screen's own size (5c round 3): a window snapshot (the Dock's minimize preview) written in a
        // display frame qualified too, lost its CPU write-back to the twin, and the Dock read blank memory.
        bool screenSized = width == scanoutWidth_ && height == scanoutHeight_;
        if (!owned || !width || !height || stride < width * 4 || !screenSized) {
            IOLockUnlock(twinLock_);
            LOG("twin for surface 0x%x (%ux%u): resource %u refused (%s)", surface, width, height, resource,
                !owned ? "not the caller's" : !screenSized ? "not the screen's size" : "size");
            return kIOReturnNotPermitted;
        }
    }
    unsigned slot = kMaxTwins, free = kMaxTwins;
    for (unsigned i = 0; i < kMaxTwins; i++) {
        if (twins_[i].surface == surface) {
            slot = i;
        } else if (!twins_[i].surface && free == kMaxTwins) {
            free = i;
        }
    }
    uint32_t old = slot < kMaxTwins ? twins_[slot].resource : 0, old2 = slot < kMaxTwins ? twins_[slot].resource2 : 0;
    if (!resource) {
        if (slot < kMaxTwins) {
            twins_[slot] = {};
        }
    } else {
        if (slot == kMaxTwins) {
            slot = free;
        }
        if (slot == kMaxTwins) {
            IOLockUnlock(twinLock_);
            return kIOReturnNoSpace;
        }
        twins_[slot] = {surface, resource, width, height, stride, 0, 0, task, false, resource2, 0};
    }
    IOLockUnlock(twinLock_);
    uint32_t on = scanoutBlob_;
    bool oldGone = on == old && old != resource && old != resource2;
    bool old2Gone = on == old2 && old2 != resource && old2 != resource2;
    if (on && (oldGone || old2Gone)) {
        setScanoutBlob(0, 0, 0, 0, 0);   // what was on screen is going away
    }
    return kIOReturnSuccess;
}

// shown: whether a display transaction has asked for this surface yet (5c round 6). Only those surfaces may skip
// their CPU write-back: Core Animation also renders screen-sized surfaces it reads on the CPU (a screenshot) in the
// same display command buffers, and those came out blank.
// Frames submitted into a twin, and of those, into the twin on screen at the time (round 17): the flip loop runs behind
// WindowServer, which can come back around to the surface still shown; a viewer reading it then could get a torn
// frame. VirtioGPUTwinRewrites, every 64 frames.
static volatile SInt64 gTwinMarks = 0, gTwinRewritesShown = 0;
IOReturn VirtioGPU::markTwin(task_t task, uint32_t surface, uint32_t frame, bool ready, bool *shown, uint32_t *use) {
    *shown = false;
    if (!twinLock_ || !surface) {
        return kIOReturnBadArgument;
    }
    IOReturn r = kIOReturnNotFound;
    IOLockLock(twinLock_);
    for (unsigned i = 0; i < kMaxTwins; i++) {
        if (twins_[i].surface == surface) {
            if (twins_[i].task != task) {
                r = kIOReturnNotPermitted;
            } else {
                Twin &t = twins_[i];
                if (!ready && t.resource2) {   // a new frame: into the twin not on screen, the other one than last time
                    uint32_t other = t.cur ^ 1u, on = scanoutBlob_;
                    t.cur = (other ? t.resource2 : t.resource) != on ? other : t.cur;
                }
                if (use) {
                    *use = t.cur;
                }
                (ready ? t.ready : t.submitted) = frame;
                *shown = t.shown;
                r = kIOReturnSuccess;
                if (!ready) {   // a new frame into this twin
                    OSIncrementAtomic64(&gTwinMarks);
                    if (t.res() && t.res() == scanoutBlob_) {
                        OSIncrementAtomic64(&gTwinRewritesShown);
                    }
                    if ((gTwinMarks & 63) == 0) {
                        char line[96];
                        snprintf(line, sizeof(line), "%lld frames, %lld into the twin on screen", (long long)gTwinMarks,
                                 (long long)gTwinRewritesShown);
                        setProperty("VirtioGPUTwinRewrites", line);
                    }
                }
            }
            break;
        }
    }
    IOLockUnlock(twinLock_);
    return r;
}

IOReturn VirtioGPU::setShare(task_t task, uint32_t surface, uint32_t resource, uint64_t size, const uint32_t params[5]) {
    if (!twinLock_ || !surface) {
        return kIOReturnBadArgument;
    }
    IOLockLock(twinLock_);
    if (!shares_) {
        shares_ = static_cast<Share *>(IOMallocZero(kMaxShares * sizeof(Share)));
        if (!shares_) {
            IOLockUnlock(twinLock_);
            return kIOReturnNoMemory;
        }
    }
    if (resource) {
        bool owned = false;
        for (unsigned i = 0; i < kMaxClients && !owned; i++) {
            owned = clients_[i] && clients_[i]->owns(task, resource);
        }
        if (!owned || !size) {
            IOLockUnlock(twinLock_);
            return kIOReturnNotPermitted;
        }
    }
    unsigned slot = kMaxShares, free = kMaxShares;
    for (unsigned i = 0; i < kMaxShares; i++) {
        if (shares_[i].surface == surface) {
            slot = i;
        } else if (!shares_[i].surface && free == kMaxShares) {
            free = i;
        }
    }
    IOReturn r = kIOReturnSuccess;
    if (!resource) {
        if (slot < kMaxShares && shares_[slot].task == task) {
            shares_[slot] = {};
        }
    } else {
        if (slot == kMaxShares) {
            slot = free;
        }
        if (slot == kMaxShares) {
            r = kIOReturnNoSpace;
        } else {
            shares_[slot] = {surface, resource, size, {params[0], params[1], params[2], params[3], params[4]}, task};
        }
    }
    IOLockUnlock(twinLock_);
    return r;
}

bool VirtioGPU::shareFor(uint32_t surface, Share *out) {
    if (!twinLock_ || !surface) {
        return false;
    }
    bool found = false;
    IOLockLock(twinLock_);
    for (unsigned i = 0; shares_ && i < kMaxShares && !found; i++) {
        if (shares_[i].surface == surface) {
            *out = shares_[i];
            found = true;
        }
    }
    IOLockUnlock(twinLock_);
    return found;
}

void VirtioGPU::forgetResource(uint32_t resource) {
    if (!twinLock_ || !resource) {
        return;
    }
    IOLockLock(twinLock_);
    for (unsigned i = 0; i < kMaxTwins; i++) {
        if (twins_[i].resource == resource || (twins_[i].resource2 && twins_[i].resource2 == resource)) {
            twins_[i] = {};
        }
    }
    for (unsigned i = 0; shares_ && i < kMaxShares; i++) {
        if (shares_[i].resource == resource) {
            shares_[i] = {};
        }
    }
    IOLockUnlock(twinLock_);
    if (scanoutBlob_ == resource) {
        setScanoutBlob(0, 0, 0, 0, 0);
    }
}

bool VirtioGPU::twinFor(uint32_t surface, Twin *out) {
    if (!twinLock_ || !surface) {
        return false;
    }
    bool found = false;
    IOLockLock(twinLock_);
    for (unsigned i = 0; i < kMaxTwins && !found; i++) {
        if (twins_[i].surface == surface) {
            twins_[i].shown = true;   // only the accelerator's display path asks (transactions, the flip loop)
            *out = twins_[i];
            found = true;
        }
    }
    IOLockUnlock(twinLock_);
    return found;
}

bool VirtioGPU::flush(uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
    IOLockLock(scanoutLock_);
    uint32_t resource = scanoutResource_;
    if (!resource || scanoutBlob_ || x >= scanoutWidth_ || y >= scanoutHeight_) {
        IOLockUnlock(scanoutLock_);
        return false;
    }
    if (x + width > scanoutWidth_) {
        width = scanoutWidth_ - x;
    }
    if (y + height > scanoutHeight_) {
        height = scanoutHeight_ - y;
    }
    auto *t = reinterpret_cast<vgpu::CmdTransferToHost2D *>(commandBytes_);
    bzero(t, sizeof(*t));
    t->hdr.type = vgpu::kCmdTransferToHost2D;
    t->r = {x, y, width, height};
    t->offset = (uint64_t)y * scanoutStride_ + (uint64_t)x * 4;
    t->resourceID = resource;
    bool ok = simple(sizeof(*t)) == vgpu::kRespOkNoData;
    if (ok) {
        auto *f = reinterpret_cast<vgpu::CmdResourceFlush *>(commandBytes_);
        bzero(f, sizeof(*f));
        f->hdr.type = vgpu::kCmdResourceFlush;
        f->r = {x, y, width, height};
        f->resourceID = resource;
        ok = simple(sizeof(*f)) == vgpu::kRespOkNoData;
    }
    if (ok) {
        flushes_++;
    }
    IOLockUnlock(scanoutLock_);
    return ok;
}

void VirtioGPU::disableScanout() {
    if (!ready() || !scanoutLock_) {
        return;
    }
    IOLockLock(scanoutLock_);
    if (scanoutResource_) {
        auto *off = reinterpret_cast<vgpu::CmdSetScanout *>(commandBytes_);
        bzero(off, sizeof(*off));
        off->hdr.type = vgpu::kCmdSetScanout;
        simple(sizeof(*off));
        dropResource(scanoutResource_);
        scanoutResource_ = 0;
    }
    IOLockUnlock(scanoutLock_);
}

IOReturn VirtioGPU::callPlatformFunction(const OSSymbol *name, bool wait, void *p1, void *p2, void *p3,
                                         void *p4) {
    if (!name) {
        return kIOReturnBadArgument;
    }
    if (name->isEqualTo(kVGPUPreferredSize)) {
        if (!p1 || !p2) {
            return kIOReturnBadArgument;
        }
        preferredSize(static_cast<uint32_t *>(p1), static_cast<uint32_t *>(p2));
        return kIOReturnSuccess;
    }
    if (name->isEqualTo(kVGPUCopyEDID)) {
        if (!p1) {
            return kIOReturnBadArgument;
        }
        if (!edid_) {
            return kIOReturnNotFound;
        }
        edid_->retain();
        *static_cast<OSData **>(p1) = edid_;
        return kIOReturnSuccess;
    }
    if (name->isEqualTo(kVGPUSetScanout)) {
        auto *memory = OSDynamicCast(IOBufferMemoryDescriptor, static_cast<OSObject *>(p1));
        return setScanout(memory, (uint32_t)(uintptr_t)p2, (uint32_t)(uintptr_t)p3, (uint32_t)(uintptr_t)p4)
                   ? kIOReturnSuccess
                   : kIOReturnError;
    }
    if (name->isEqualTo(kVGPUFlush)) {
        return flush((uint32_t)(uintptr_t)p1, (uint32_t)(uintptr_t)p2, (uint32_t)(uintptr_t)p3,
                     (uint32_t)(uintptr_t)p4)
                   ? kIOReturnSuccess
                   : kIOReturnError;
    }
    if (name->isEqualTo(kVGPUSetCursor)) {
        return setCursor(static_cast<const uint32_t *>(p1), (uint32_t)(uintptr_t)p2, (uint32_t)(uintptr_t)p3)
                   ? kIOReturnSuccess
                   : kIOReturnError;
    }
    if (name->isEqualTo(kVGPUMoveCursor)) {
        moveCursor((uint32_t)(uintptr_t)p1, (uint32_t)(uintptr_t)p2, p3 != nullptr);
        return kIOReturnSuccess;
    }
    if (name->isEqualTo(kVGPUDisableScanout)) {
        disableScanout();
        return kIOReturnSuccess;
    }
    if (name->isEqualTo(kVGPUTwinFor)) {
        Twin t;
        if (!p2 || !twinFor((uint32_t)(uintptr_t)p1, &t)) {
            return kIOReturnNotFound;
        }
        uint32_t *out = static_cast<uint32_t *>(p2);
        out[0] = t.res(), out[1] = t.width, out[2] = t.height, out[3] = t.stride;
        out[4] = t.submitted, out[5] = t.ready;
        return kIOReturnSuccess;
    }
    if (name->isEqualTo(kVGPUScanoutBlob)) {
        return setScanoutBlob((uint32_t)(uintptr_t)p1, (uint32_t)(uintptr_t)p2, (uint32_t)(uintptr_t)p3,
                              (uint32_t)(uintptr_t)p4, 0)
                   ? kIOReturnSuccess
                   : kIOReturnError;
    }
    if (name->isEqualTo(kVGPUNewClient)) {
        // Stage 5a: a Venus client for the accelerator to attach under itself (kVGUCAccelType).
        auto **out = static_cast<IOUserClient **>(p2);
        if (!out) {
            return kIOReturnBadArgument;
        }
        *out = nullptr;
        if (!ready() || !venusCapset_) {
            return kIOReturnNotReady;
        }
        VirtioGPUUserClient *client = OSTypeAlloc(VirtioGPUUserClient);
        if (!client || !client->initWithTask(static_cast<task_t>(p1), p3, 0)) {
            OSSafeReleaseNULL(client);
            return kIOReturnNoMemory;
        }
        client->setCore(this);
        *out = client;
        return kIOReturnSuccess;
    }
    if (name->isEqualTo(kVGPULog)) {
        if (p1) {
            probeLog("%s", static_cast<const char *>(p1));
        }
        if (p2) {
            publishLog();
        }
        return kIOReturnSuccess;
    }
    return IOService::callPlatformFunction(name, wait, p1, p2, p3, p4);
}

// ---- VirtioGPUDisplay: the nub the framebuffer kext matches ----

OSDefineMetaClassAndStructors(VirtioGPUDisplay, IOService)

IOReturn VirtioGPUDisplay::callPlatformFunction(const OSSymbol *name, bool wait, void *p1, void *p2,
                                                void *p3, void *p4) {
    if (VirtioGPU *core = OSDynamicCast(VirtioGPU, getProvider())) {
        return core->callPlatformFunction(name, wait, p1, p2, p3, p4);
    }
    return IOService::callPlatformFunction(name, wait, p1, p2, p3, p4);
}

// ---- VirtioGPUFramebufferSlot: keeps IONDRVFramebuffer off the device ----

OSDefineMetaClassAndStructors(VirtioGPUFramebufferSlot, IOService)

IOService *VirtioGPUFramebufferSlot::probe(IOService *provider, SInt32 *score) {
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    char arg[8];
    if (!pci || PE_parse_boot_argn("-vgpuoff", arg, sizeof(arg)) || recoveryBoot() ||
        pci->configRead16(kIOPCIConfigVendorID) != 0x1af4 ||
        pci->configRead16(kIOPCIConfigDeviceID) != 0x1050) {
        return nullptr;
    }
    return IOService::probe(provider, score);
}

bool VirtioGPUFramebufferSlot::start(IOService *provider) {
    if (!IOService::start(provider)) {
        return false;
    }
    probeLog("framebuffer slot held on the PCI device (IONDRVFramebuffer stays off)");
    return true;
}

// ---- Hardware cursor ----

bool VirtioGPU::cursorCommand(uint32_t type, uint32_t resource) {
    // Cursor queue entries are fire-and-forget: reclaim what the device finished, then submit.
    IOLockLock(cursorLock_);
    if (!cursor_ || !cursorCmds_) {
        IOLockUnlock(cursorLock_);
        return false;
    }
    uint32_t id = 0, length = 0;
    while (cursor_->takeUsed(&id, &length)) {
        cursorInFlight_--;
    }
    if (cursorInFlight_ >= cursor_->size()) {
        cursorDropped_++;
        IOLockUnlock(cursorLock_);
        return false;
    }
    uint32_t slot = cursorSlot_++ % cursor_->size();
    auto *cmd = reinterpret_cast<vgpu::CmdUpdateCursor *>(
        static_cast<uint8_t *>(cursorCmds_->getBytesNoCopy()) + slot * 64);
    bzero(cmd, sizeof(*cmd));
    cmd->hdr.type = type;
    cmd->pos.scanoutID = 0;
    cmd->pos.x = cursorX_;
    cmd->pos.y = cursorY_;
    cmd->resourceID = resource;
    cmd->hotX = cursorHotX_;
    cmd->hotY = cursorHotY_;
    uint64_t phys = cursorCmds_->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone) + slot * 64;
    virtio::Segment segment = {phys, (uint32_t)sizeof(*cmd), false};
    bool ok = cursor_->submit(&segment, 1) >= 0;
    if (ok) {
        cursorInFlight_++;
        transport_.notify(cursor_);
    } else {
        cursorDropped_++;
    }
    IOLockUnlock(cursorLock_);
    return ok;
}

bool VirtioGPU::setCursor(const uint32_t *pixels, uint32_t hotX, uint32_t hotY) {
    if (!ready() || !pixels) {
        return false;
    }
    constexpr uint32_t kSize = kVGPUCursorSize, kBytes = kSize * kSize * 4;
    IOLockLock(scanoutLock_); // the control queue work uses the shared command memory
    if (!cursorResource_) {
        cursorImage_ = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, kBytes, 0xFFFFFFFFFFFFF000ULL);
        cursorCmds_ = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, 64 * 64, 0xFFFFFFFFFFFFF000ULL);
        if (!cursorImage_ || !cursorCmds_ || cursorImage_->prepare() != kIOReturnSuccess ||
            cursorCmds_->prepare() != kIOReturnSuccess) {
            OSSafeReleaseNULL(cursorImage_);
            OSSafeReleaseNULL(cursorCmds_);
            IOLockUnlock(scanoutLock_);
            LOG("cursor: allocation failed");
            return false;
        }
        uint32_t resource = nextResource_++;
        auto *create = reinterpret_cast<vgpu::CmdResourceCreate2D *>(commandBytes_);
        bzero(create, sizeof(*create));
        create->hdr.type = vgpu::kCmdResourceCreate2D;
        create->resourceID = resource;
        create->format = vgpu::kFormatB8G8R8A8;
        create->width = kSize;
        create->height = kSize;
        uint32_t type = simple(sizeof(*create));
        bool ok = type == vgpu::kRespOkNoData && attachBacking(resource, cursorImage_, kBytes);
        LOG("cursor: resource %u 64x64 -> %s", resource, ok ? "ready" : respName(type));
        if (!ok) {
            IOLockUnlock(scanoutLock_);
            return false;
        }
        cursorResource_ = resource;
    }
    memcpy(cursorImage_->getBytesNoCopy(), pixels, kBytes);
    auto *t = reinterpret_cast<vgpu::CmdTransferToHost2D *>(commandBytes_);
    bzero(t, sizeof(*t));
    t->hdr.type = vgpu::kCmdTransferToHost2D;
    t->r = {0, 0, kSize, kSize};
    t->resourceID = cursorResource_;
    bool ok = simple(sizeof(*t)) == vgpu::kRespOkNoData;
    IOLockUnlock(scanoutLock_);
    if (!ok) {
        return false;
    }
    cursorHotX_ = hotX;
    cursorHotY_ = hotY;
    return cursorVisible_ ? cursorCommand(vgpu::kCmdUpdateCursor, cursorResource_) : true;
}

void VirtioGPU::moveCursor(uint32_t x, uint32_t y, bool visible) {
    cursorX_ = x;
    cursorY_ = y;
    if (visible != cursorVisible_) {
        cursorVisible_ = visible;
        cursorCommand(vgpu::kCmdUpdateCursor, visible ? cursorResource_ : 0); // 0 hides it
    } else if (visible) {
        cursorCommand(vgpu::kCmdMoveCursor, cursorResource_);
    }
}

void VirtioGPU::fillInfo(struct vgpu_info *info) {
    bzero(info, sizeof(*info));
    info->features = features_;
    info->hostmem_size = hostmemPhys_ ? hostmemLength_ : 0;
    info->pci_vendor = pci_->configRead16(kIOPCIConfigVendorID);
    info->pci_device = pci_->configRead16(kIOPCIConfigDeviceID);
    info->num_capsets = numCapsets_ < VGPU_MAX_CAPSETS ? numCapsets_ : VGPU_MAX_CAPSETS;
    for (uint32_t i = 0; i < info->num_capsets; i++) {
        info->capset_id[i] = capsetID_[i];
        info->capset_max_version[i] = capsetMaxVersion_[i];
        info->capset_max_size[i] = capsetMaxSize_[i];
    }
}
