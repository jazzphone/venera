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
#include <libkern/c++/OSArray.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSString.h>
#include <pexpert/pexpert.h>

#include "../VirtioGPUAPI.h"
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
constexpr uint16_t kMaxQueueSize = 64;
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
    IOLockWakeup(commandLock_, &wakeEvent_, false);
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
    if (requestLength > kRequestMax || replyLength > kCommandBytes - kReplyOffset) {
        return 0;
    }
    IOLockLock(commandLock_);
    if (!control_) {
        IOLockUnlock(commandLock_);
        return 0;
    }
    bzero(commandBytes_ + kReplyOffset, replyLength);
    virtio::Segment segments[2] = {
        {commandPhys_, requestLength, false},
        {commandPhys_ + kReplyOffset, replyLength, true},
    };
    if (control_->submit(segments, 2) < 0) {
        IOLockUnlock(commandLock_);
        LOG("control queue full");
        return 0;
    }
    uint32_t before = interrupts_;
    transport_.notify(control_);

    uint64_t limit = nowNs() + (uint64_t)timeoutMs * 1000000ULL;
    uint32_t id = 0, length = 0;
    bool done = false;
    while (!(done = control_->takeUsed(&id, &length)) && nowNs() < limit) {
        uint64_t deadline = 0;
        clock_interval_to_deadline(5, kMillisecondScale, &deadline);
        IOLockSleepDeadline(commandLock_, &wakeEvent_, deadline, THREAD_UNINT);
    }
    uint32_t type = done ? reinterpret_cast<vgpu::CtrlHdr *>(commandBytes_ + kReplyOffset)->type : 0;
    if (done) {
        if (interrupts_ != before) {
            commandsByInterrupt_++;
        } else {
            commandsByPolling_++;
        }
    }
    IOLockUnlock(commandLock_);
    if (!done) {
        LOG("command timed out after %u ms", timeoutMs);
    }
    return type;
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

bool VirtioGPU::flush(uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
    IOLockLock(scanoutLock_);
    uint32_t resource = scanoutResource_;
    if (!resource || x >= scanoutWidth_ || y >= scanoutHeight_) {
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
    if (name->isEqualTo(kVGPUDisableScanout)) {
        disableScanout();
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
    if (!pci || PE_parse_boot_argn("-vgpuoff", arg, sizeof(arg)) ||
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
