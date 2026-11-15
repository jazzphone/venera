// VirtioGPU - stage 1: virtio core.
//
// Claims the virtio-gpu PCI function (1af4:1050) in the default match category, so Apple's
// generic AppleVirtIOPCITransport (probe score 10000) doesn't. Brings the device up (reset,
// features, control + cursor virtqueues, DRIVER_OK), then asks it for the display info and the
// EDID by polling the control queue. Nothing is drawn yet: the firmware's VGA framebuffer
// (IONDRVFramebuffer, its own match category, BAR0) keeps the screen until stage 2 sets a scanout.
//
// Everything worth seeing goes into the "ProbeLog" registry property (tools/deploy.sh logs).
// Boot with -vgpuoff to keep the driver from matching.

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <libkern/c++/OSArray.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSString.h>
#include <pexpert/pexpert.h>

#include "VirtioGPUProtocol.h"
#include "VirtioPCI.hpp"

// IOLog from an OpenCore-injected kext doesn't reach dmesg or the unified log on Tahoe, so every
// line also goes into the "ProbeLog" registry property.
static OSArray *gProbeLog;

void probeLog(const char *fmt, ...) {
    char line[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    IOLog("VirtioGPU: %s\n", line);
    if (gProbeLog) {
        if (OSString *s = OSString::withCString(line)) {
            gProbeLog->setObject(s);
            s->release();
        }
    }
}

#define LOG(fmt, ...) probeLog(fmt, ##__VA_ARGS__)

namespace {

enum : uint8_t {
    kCapCommon = 1,
    kCapNotify = 2,
    kCapISR = 3,
    kCapDevice = 4,
    kCapPCI = 5,
    kCapSharedMem = 8,
};

const char *capName(uint8_t type) {
    switch (type) {
    case kCapCommon: return "common";
    case kCapNotify: return "notify";
    case kCapISR: return "isr";
    case kCapDevice: return "device";
    case kCapPCI: return "pci-cfg";
    case kCapSharedMem: return "shared-mem";
    default: return "?";
    }
}

const struct { uint32_t bit; const char *name; } kFeatures[] = {
    {0, "VIRGL"}, {1, "EDID"}, {2, "RESOURCE_UUID"}, {3, "RESOURCE_BLOB"}, {4, "CONTEXT_INIT"},
    {28, "INDIRECT_DESC"}, {29, "EVENT_IDX"}, {32, "VERSION_1"}, {33, "ACCESS_PLATFORM"},
    {34, "RING_PACKED"}, {35, "IN_ORDER"}, {36, "ORDER_PLATFORM"}, {37, "SR_IOV"},
    {38, "NOTIFICATION_DATA"},
};

const char *respName(uint32_t type) {
    switch (type) {
    case vgpu::kRespOkNoData: return "OK_NODATA";
    case vgpu::kRespOkDisplayInfo: return "OK_DISPLAY_INFO";
    case vgpu::kRespOkEDID: return "OK_EDID";
    case vgpu::kRespErrUnspec: return "ERR_UNSPEC";
    case vgpu::kRespErrOutOfMemory: return "ERR_OUT_OF_MEMORY";
    case vgpu::kRespErrInvalidScanoutID: return "ERR_INVALID_SCANOUT_ID";
    case vgpu::kRespErrInvalidResourceID: return "ERR_INVALID_RESOURCE_ID";
    case vgpu::kRespErrInvalidParameter: return "ERR_INVALID_PARAMETER";
    default: return "?";
    }
}

constexpr uint16_t kQueueControl = 0;
constexpr uint16_t kQueueCursor = 1;
constexpr uint16_t kMaxQueueSize = 64;
constexpr uint32_t kCommandPage = 4096; // request at 0, response at kCommandPage

} // namespace

class VirtioGPU : public IOService {
    OSDeclareDefaultStructors(VirtioGPU)

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;

private:
    void logHeader();
    bool findRegions(virtio::Region regions[9], uint32_t *notifyMultiplier);
    bool bringUp();
    void tearDown();
    // Sends the request at the start of the command page; the reply lands at kCommandPage.
    // Returns the reply's type, or 0 if the device didn't answer in time.
    uint32_t command(uint32_t requestLength, uint32_t replyLength, uint32_t timeoutMs = 2000);
    void getDisplayInfo();
    void getEDID(uint32_t scanout);

    IOPCIDevice *pci_ = nullptr;
    virtio::Transport transport_;
    virtio::Virtqueue *control_ = nullptr;
    virtio::Virtqueue *cursor_ = nullptr;
    IOBufferMemoryDescriptor *commandMemory_ = nullptr;
    uint8_t *commandBytes_ = nullptr;
    uint64_t commandPhys_ = 0;
    uint64_t features_ = 0;
    uint32_t numScanouts_ = 0;
};

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
    gProbeLog = OSArray::withCapacity(64);
    LOG("start: stage 1 (virtio core, polling)");
    pci_->setMemoryEnable(true);
    pci_->setBusMasterEnable(true);
    logHeader();

    bool ok = bringUp();
    if (ok) {
        getDisplayInfo();
        if (features_ & (1ULL << vgpu::kFeatureEDID)) {
            getEDID(0);
        }
        LOG("stage 1 done: device status 0x%02x, screen still on the VGA framebuffer",
            transport_.status());
    } else {
        LOG("bring-up failed; resetting the device");
        tearDown();
    }

    if (gProbeLog) {
        setProperty("ProbeLog", gProbeLog);
        gProbeLog->release();
        gProbeLog = nullptr;
    }
    registerService();
    return true; // stay attached either way, so the log stays readable
}

void VirtioGPU::stop(IOService *provider) {
    tearDown();
    IOService::stop(provider);
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
            uint8_t bar = pci_->configRead8(ptr + 4);
            uint32_t offset = pci_->configRead32(ptr + 8);
            uint32_t length = pci_->configRead32(ptr + 12);
            if (type == kCapNotify) {
                *notifyMultiplier = pci_->configRead32(ptr + 16);
            }
            if (type < 9 && !regions[type].present) {
                regions[type].present = true;
                regions[type].bar = bar;
                regions[type].offset = offset;
                regions[type].length = length;
                LOG("cap %-6s bar %u off 0x%x len 0x%x", capName(type), bar, offset, length);
            }
        }
        ptr = next;
    }
    return regions[kCapCommon].present;
}

bool VirtioGPU::bringUp() {
    virtio::Region regions[9] = {};
    uint32_t multiplier = 0;
    if (!findRegions(regions, &multiplier) || !transport_.attach(pci_, regions, multiplier)) {
        return false;
    }

    // Section 3.1.1: reset, ACKNOWLEDGE, DRIVER, features, FEATURES_OK, queues, DRIVER_OK.
    LOG("status before reset 0x%02x", transport_.status());
    transport_.reset();
    transport_.addStatus(virtio::kAcknowledge);
    transport_.addStatus(virtio::kDriver);

    uint64_t offered = transport_.deviceFeatures();
    uint64_t wanted = (1ULL << virtio::kFeatureVersion1) | (1ULL << vgpu::kFeatureEDID);
    if (!transport_.negotiate(wanted, &features_)) {
        LOG("device refused features 0x%llx", (unsigned long long)features_);
        return false;
    }
    if (!(features_ & (1ULL << virtio::kFeatureVersion1))) {
        LOG("no VERSION_1: legacy device, not supported");
        return false;
    }
    LOG("features offered 0x%llx accepted 0x%llx", (unsigned long long)offered,
        (unsigned long long)features_);
    for (const auto &f : kFeatures) {
        if (features_ & (1ULL << f.bit)) {
            LOG("  using %s", f.name);
        }
    }

    volatile vgpu::Config *config = reinterpret_cast<volatile vgpu::Config *>(transport_.deviceConfig());
    numScanouts_ = config->numScanouts;
    LOG("config: scanouts %u capsets %u events %u", numScanouts_, config->numCapsets,
        config->eventsRead);

    if (transport_.numQueues() < 2) {
        LOG("device has %u queues, need 2", transport_.numQueues());
        return false;
    }
    control_ = transport_.setupQueue(kQueueControl, kMaxQueueSize);
    cursor_ = transport_.setupQueue(kQueueCursor, kMaxQueueSize);
    if (!control_ || !cursor_) {
        return false;
    }

    commandMemory_ = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, 2 * kCommandPage,
        0xFFFFFFFFFFFFF000ULL);
    if (!commandMemory_ || commandMemory_->prepare() != kIOReturnSuccess) {
        LOG("command buffer allocation failed");
        return false;
    }
    commandBytes_ = static_cast<uint8_t *>(commandMemory_->getBytesNoCopy());
    commandPhys_ = commandMemory_->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);

    transport_.addStatus(virtio::kDriverOK);
    uint8_t status = transport_.status();
    LOG("status after DRIVER_OK 0x%02x%s", status,
        (status & virtio::kNeedsReset) ? " (NEEDS_RESET)" : "");
    return (status & virtio::kDriverOK) && !(status & (virtio::kNeedsReset | virtio::kFailed));
}

void VirtioGPU::tearDown() {
    if (transport_.deviceConfig()) {
        transport_.reset(); // the device stops using our rings before we free them
    }
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
    }
    transport_.detach();
}

uint32_t VirtioGPU::command(uint32_t requestLength, uint32_t replyLength, uint32_t timeoutMs) {
    bzero(commandBytes_ + kCommandPage, replyLength);
    virtio::Segment segments[2] = {
        {commandPhys_, requestLength, false},
        {commandPhys_ + kCommandPage, replyLength, true},
    };
    int head = control_->submit(segments, 2);
    if (head < 0) {
        LOG("control queue full");
        return 0;
    }
    transport_.notify(control_);

    uint32_t id = 0, length = 0;
    uint64_t start = 0, now = 0;
    clock_get_uptime(&start);
    uint64_t limitNs = (uint64_t)timeoutMs * 1000000ULL;
    for (;;) {
        if (control_->takeUsed(&id, &length)) {
            break;
        }
        clock_get_uptime(&now);
        uint64_t elapsedNs = 0;
        absolutetime_to_nanoseconds(now - start, &elapsedNs);
        if (elapsedNs > limitNs) {
            LOG("command timed out after %u ms", timeoutMs);
            return 0;
        }
        IODelay(20);
    }
    clock_get_uptime(&now);
    uint64_t tookNs = 0;
    absolutetime_to_nanoseconds(now - start, &tookNs);
    auto *reply = reinterpret_cast<vgpu::CtrlHdr *>(commandBytes_ + kCommandPage);
    LOG("reply %s (0x%x) for chain %u, %u bytes, %llu us", respName(reply->type), reply->type,
        id, length, (unsigned long long)(tookNs / 1000));
    return reply->type;
}

void VirtioGPU::getDisplayInfo() {
    auto *req = reinterpret_cast<vgpu::CtrlHdr *>(commandBytes_);
    bzero(req, sizeof(*req));
    req->type = vgpu::kCmdGetDisplayInfo;
    LOG("-> GET_DISPLAY_INFO");
    if (command(sizeof(*req), sizeof(vgpu::RespDisplayInfo)) != vgpu::kRespOkDisplayInfo) {
        return;
    }
    auto *info = reinterpret_cast<vgpu::RespDisplayInfo *>(commandBytes_ + kCommandPage);
    OSArray *modes = OSArray::withCapacity(4);
    for (uint32_t i = 0; i < vgpu::kMaxScanouts && i < (numScanouts_ ? numScanouts_ : 1); i++) {
        const auto &m = info->pmodes[i];
        LOG("scanout %u: %ux%u at %u,%u enabled %u flags 0x%x", i, m.r.width, m.r.height, m.r.x,
            m.r.y, m.enabled, m.flags);
        if (OSDictionary *d = OSDictionary::withCapacity(4)) {
            OSNumber *w = OSNumber::withNumber(m.r.width, 32);
            OSNumber *h = OSNumber::withNumber(m.r.height, 32);
            OSNumber *e = OSNumber::withNumber(m.enabled, 32);
            d->setObject("Width", w);
            d->setObject("Height", h);
            d->setObject("Enabled", e);
            w->release();
            h->release();
            e->release();
            if (modes) {
                modes->setObject(d);
            }
            d->release();
        }
    }
    if (modes) {
        setProperty("DisplayModes", modes);
        modes->release();
    }
}

void VirtioGPU::getEDID(uint32_t scanout) {
    auto *req = reinterpret_cast<vgpu::CmdGetEDID *>(commandBytes_);
    bzero(req, sizeof(*req));
    req->hdr.type = vgpu::kCmdGetEDID;
    req->scanout = scanout;
    LOG("-> GET_EDID scanout %u", scanout);
    if (command(sizeof(*req), sizeof(vgpu::RespEDID)) != vgpu::kRespOkEDID) {
        return;
    }
    auto *resp = reinterpret_cast<vgpu::RespEDID *>(commandBytes_ + kCommandPage);
    uint32_t size = resp->size > sizeof(resp->edid) ? sizeof(resp->edid) : resp->size;
    const uint8_t *e = resp->edid;
    static const uint8_t kHeader[8] = {0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00};
    if (size < 128 || memcmp(e, kHeader, 8) != 0) {
        LOG("EDID: %u bytes, no valid header", size);
        return;
    }
    char vendor[4] = {(char)('@' + ((e[8] >> 2) & 0x1f)),
                      (char)('@' + (((e[8] & 3) << 3) | (e[9] >> 5))), (char)('@' + (e[9] & 0x1f)),
                      0};
    const uint8_t *dtd = e + 54; // first detailed timing = preferred mode
    uint32_t clockKHz = (uint32_t)(dtd[0] | (dtd[1] << 8)) * 10;
    uint32_t hActive = dtd[2] | ((dtd[4] & 0xf0) << 4);
    uint32_t vActive = dtd[5] | ((dtd[7] & 0xf0) << 4);
    char name[14] = "";
    for (int d = 0; d < 4; d++) {
        const uint8_t *desc = e + 54 + d * 18;
        if (desc[0] == 0 && desc[1] == 0 && desc[3] == 0xfc) {
            int n = 0;
            for (; n < 13 && desc[5 + n] != 0x0a; n++) {
                name[n] = (char)desc[5 + n];
            }
            name[n] = 0;
        }
    }
    LOG("EDID: %u bytes, vendor %s product 0x%04x, preferred %ux%u at %u kHz, name \"%s\"", size,
        vendor, e[10] | (e[11] << 8), hActive, vActive, clockKHz, name);
    if (OSData *data = OSData::withBytes(e, size)) {
        setProperty("EDID", data);
        data->release();
    }
}
