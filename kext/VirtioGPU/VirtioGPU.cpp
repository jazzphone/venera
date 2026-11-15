// VirtioGPU - stage 2a/2b: interrupts and a 2D scanout test.
//
// Claims the virtio-gpu PCI function (1af4:1050) in the default match category, so Apple's
// generic AppleVirtIOPCITransport (probe score 10000) doesn't. Brings the device up (reset,
// features, control + cursor virtqueues on an MSI-X vector, DRIVER_OK) and reads the display info
// and EDID. 45 s later a thread call runs the 2D test: a 1280x800 resource backed by guest
// memory, color bars, SET_SCANOUT, 10 s of a moving block (transfer + flush, timed), then the
// scanout is disabled and the device reset so the firmware's VGA framebuffer (IONDRVFramebuffer,
// BAR0) shows again.
//
// Everything worth seeing goes into the "ProbeLog" registry property (tools/deploy.sh logs).
// Boot with -vgpuoff to keep the driver from matching.

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOFilterInterruptEventSource.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOWorkLoop.h>
#include <kern/thread_call.h>
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
            gProbeLog->setObject(s);
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
constexpr uint16_t kNoVector = 0xffff;
// Command memory: the request (up to kRequestMax, room for ~1,790 backing entries) then the reply.
constexpr uint32_t kCommandBytes = 32 * 1024;
constexpr uint32_t kReplyOffset = 28 * 1024;
constexpr uint32_t kRequestMax = kReplyOffset;
constexpr uint32_t kTestResource = 1;
constexpr uint32_t kTestDelaySeconds = 45;
constexpr uint32_t kTestSeconds = 10;

uint64_t nowNs() {
    uint64_t t = 0, ns = 0;
    clock_get_uptime(&t);
    absolutetime_to_nanoseconds(t, &ns);
    return ns;
}

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
    bool setupInterrupt();
    bool bringUp();
    void tearDown();
    void publishLog();

    // Sends the request at the start of the command memory; the reply lands at kReplyOffset.
    // Waits for the device's interrupt (or polls every 5 ms). Returns the reply type, 0 on timeout.
    uint32_t command(uint32_t requestLength, uint32_t replyLength, uint32_t timeoutMs = 2000);
    uint32_t simple(uint32_t requestLength) { return command(requestLength, sizeof(vgpu::CtrlHdr)); }
    void getDisplayInfo();
    void getEDID(uint32_t scanout);

    // Stage 2b
    static void testThunk(thread_call_param_t self, thread_call_param_t);
    void scanoutTest();
    bool attachBacking(uint32_t resource, IOBufferMemoryDescriptor *memory, uint32_t bytes);
    bool transferAndFlush(uint32_t resource, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                          uint32_t stride);

    bool filter(IOFilterInterruptEventSource *source);
    void interruptOccurred(IOInterruptEventSource *source, int count);

    IOPCIDevice *pci_ = nullptr;
    virtio::Transport transport_;
    virtio::Virtqueue *control_ = nullptr;
    virtio::Virtqueue *cursor_ = nullptr;
    IOBufferMemoryDescriptor *commandMemory_ = nullptr;
    uint8_t *commandBytes_ = nullptr;
    uint64_t commandPhys_ = 0;
    IOLock *commandLock_ = nullptr;
    IOWorkLoop *workLoop_ = nullptr;
    IOFilterInterruptEventSource *interrupt_ = nullptr;
    bool msix_ = false;
    volatile uint32_t interrupts_ = 0;
    uint32_t wakeups_ = 0;
    char wakeEvent_ = 0; // address the command waiter sleeps on
    uint32_t commandsByInterrupt_ = 0;
    uint32_t commandsByPolling_ = 0;
    thread_call_t testCall_ = nullptr;
    uint64_t features_ = 0;
    uint32_t numScanouts_ = 0;
    uint32_t width_ = 0;
    uint32_t height_ = 0;
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
    gProbeLogLock = IOLockAlloc();
    gProbeLog = OSArray::withCapacity(128);
    commandLock_ = IOLockAlloc();
    LOG("start: stage 2a/2b (MSI-X, 2D scanout test in %u s)", kTestDelaySeconds);
    pci_->setMemoryEnable(true);
    pci_->setBusMasterEnable(true);
    logHeader();

    bool ok = setupInterrupt() && bringUp();
    if (ok) {
        getDisplayInfo();
        if (features_ & (1ULL << vgpu::kFeatureEDID)) {
            getEDID(0);
        }
        LOG("interrupts %u, commands completed by interrupt %u, by polling %u", interrupts_,
            commandsByInterrupt_, commandsByPolling_);
        testCall_ = thread_call_allocate(&VirtioGPU::testThunk, this);
        if (testCall_) {
            uint64_t deadline = 0;
            clock_interval_to_deadline(kTestDelaySeconds, kSecondScale, &deadline);
            thread_call_enter_delayed(testCall_, deadline);
        }
    } else {
        LOG("bring-up failed; resetting the device");
        tearDown();
    }
    publishLog();
    registerService();
    return true; // stay attached either way, so the log stays readable
}

void VirtioGPU::stop(IOService *provider) {
    if (testCall_) {
        thread_call_cancel_wait(testCall_);
        thread_call_free(testCall_);
        testCall_ = nullptr;
    }
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
    IOService::stop(provider);
}

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
        OSNumber *a = OSNumber::withNumber(interrupts_, 32);
        OSNumber *b = OSNumber::withNumber(commandsByInterrupt_, 32);
        OSNumber *c = OSNumber::withNumber(commandsByPolling_, 32);
        stats->setObject("Interrupts", a);
        stats->setObject("CommandsByInterrupt", b);
        stats->setObject("CommandsByPolling", c);
        a->release();
        b->release();
        c->release();
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
            }
        } else if (id == 0x11) {
            uint16_t ctrl = pci_->configRead16(ptr + 2);
            LOG("msi-x: %u vectors, enabled %u", (ctrl & 0x7ff) + 1, (ctrl >> 15) & 1);
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
        LOG("interrupt index %d type 0x%x", i, type);
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
    LOG("using interrupt index %d (%s)", index, msix_ ? "message signaled" : "INTx");
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
    wakeups_++;
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

    uint64_t wanted = (1ULL << virtio::kFeatureVersion1) | (1ULL << vgpu::kFeatureEDID);
    if (!transport_.negotiate(wanted, &features_) ||
        !(features_ & (1ULL << virtio::kFeatureVersion1))) {
        LOG("feature negotiation failed (0x%llx)", (unsigned long long)features_);
        return false;
    }
    LOG("features accepted 0x%llx", (unsigned long long)features_);

    volatile vgpu::Config *config = reinterpret_cast<volatile vgpu::Config *>(transport_.deviceConfig());
    numScanouts_ = config->numScanouts;

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
    transport_.detach();
}

uint32_t VirtioGPU::command(uint32_t requestLength, uint32_t replyLength, uint32_t timeoutMs) {
    if (!control_ || requestLength > kRequestMax || replyLength > kCommandBytes - kReplyOffset) {
        return 0;
    }
    IOLockLock(commandLock_);
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

void VirtioGPU::getDisplayInfo() {
    auto *req = reinterpret_cast<vgpu::CtrlHdr *>(commandBytes_);
    bzero(req, sizeof(*req));
    req->type = vgpu::kCmdGetDisplayInfo;
    uint64_t t0 = nowNs();
    uint32_t type = command(sizeof(*req), sizeof(vgpu::RespDisplayInfo));
    LOG("GET_DISPLAY_INFO -> %s in %llu us", respName(type), (unsigned long long)((nowNs() - t0) / 1000));
    if (type != vgpu::kRespOkDisplayInfo) {
        return;
    }
    auto *info = reinterpret_cast<vgpu::RespDisplayInfo *>(commandBytes_ + kReplyOffset);
    width_ = info->pmodes[0].r.width;
    height_ = info->pmodes[0].r.height;
    OSArray *modes = OSArray::withCapacity(4);
    for (uint32_t i = 0; i < vgpu::kMaxScanouts && i < (numScanouts_ ? numScanouts_ : 1); i++) {
        const auto &m = info->pmodes[i];
        LOG("scanout %u: %ux%u at %u,%u enabled %u", i, m.r.width, m.r.height, m.r.x, m.r.y,
            m.enabled);
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
    uint32_t type = command(sizeof(*req), sizeof(vgpu::RespEDID));
    LOG("GET_EDID -> %s", respName(type));
    if (type != vgpu::kRespOkEDID) {
        return;
    }
    auto *resp = reinterpret_cast<vgpu::RespEDID *>(commandBytes_ + kReplyOffset);
    uint32_t size = resp->size > sizeof(resp->edid) ? sizeof(resp->edid) : resp->size;
    if (OSData *data = OSData::withBytes(resp->edid, size)) {
        setProperty("EDID", data);
        data->release();
    }
}

// ---- Stage 2b: scanout test ----

void VirtioGPU::testThunk(thread_call_param_t self, thread_call_param_t) {
    static_cast<VirtioGPU *>(self)->scanoutTest();
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
        } else {
            if (n == maxEntries) {
                LOG("backing: more than %u segments", maxEntries);
                return false;
            }
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
    LOG("ATTACH_BACKING %u bytes in %u segments -> %s", bytes, n, respName(type));
    return type == vgpu::kRespOkNoData;
}

bool VirtioGPU::transferAndFlush(uint32_t resource, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                                 uint32_t stride) {
    auto *t = reinterpret_cast<vgpu::CmdTransferToHost2D *>(commandBytes_);
    bzero(t, sizeof(*t));
    t->hdr.type = vgpu::kCmdTransferToHost2D;
    t->r = {x, y, w, h};
    t->offset = (uint64_t)y * stride + (uint64_t)x * 4;
    t->resourceID = resource;
    if (simple(sizeof(*t)) != vgpu::kRespOkNoData) {
        return false;
    }
    auto *f = reinterpret_cast<vgpu::CmdResourceFlush *>(commandBytes_);
    bzero(f, sizeof(*f));
    f->hdr.type = vgpu::kCmdResourceFlush;
    f->r = {x, y, w, h};
    f->resourceID = resource;
    return simple(sizeof(*f)) == vgpu::kRespOkNoData;
}

void VirtioGPU::scanoutTest() {
    if (!control_ || !width_ || !height_) {
        LOG("scanout test: device not ready");
        publishLog();
        return;
    }
    const uint32_t w = width_, h = height_, stride = w * 4, bytes = stride * h;
    LOG("scanout test: %ux%u, %u bytes", w, h, bytes);

    IOBufferMemoryDescriptor *fb = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, bytes, 0xFFFFFFFFFFFFF000ULL);
    bool contiguous = fb != nullptr;
    if (!fb) {
        fb = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task, kIODirectionInOut, bytes, PAGE_SIZE);
    }
    if (!fb || fb->prepare() != kIOReturnSuccess) {
        LOG("scanout test: framebuffer allocation failed");
        if (fb) {
            fb->release();
        }
        publishLog();
        return;
    }
    LOG("framebuffer: %s", contiguous ? "physically contiguous" : "scattered pages");
    uint32_t *px = static_cast<uint32_t *>(fb->getBytesNoCopy());

    // Eight color bars, BGRX in memory.
    static const uint32_t kBars[8] = {0x00ffffff, 0x0000ffff, 0x00ffff00, 0x0000ff00,
                                      0x00ff00ff, 0x000000ff, 0x00ff0000, 0x00202020};
    auto paintBars = [&](uint32_t x0, uint32_t y0, uint32_t bw, uint32_t bh) {
        for (uint32_t y = y0; y < y0 + bh && y < h; y++) {
            for (uint32_t x = x0; x < x0 + bw && x < w; x++) {
                px[y * w + x] = kBars[(x * 8) / w];
            }
        }
    };
    paintBars(0, 0, w, h);

    auto *create = reinterpret_cast<vgpu::CmdResourceCreate2D *>(commandBytes_);
    bzero(create, sizeof(*create));
    create->hdr.type = vgpu::kCmdResourceCreate2D;
    create->resourceID = kTestResource;
    create->format = vgpu::kFormatB8G8R8X8;
    create->width = w;
    create->height = h;
    uint32_t type = simple(sizeof(*create));
    LOG("RESOURCE_CREATE_2D -> %s", respName(type));
    bool ok = type == vgpu::kRespOkNoData && attachBacking(kTestResource, fb, bytes);

    if (ok) {
        auto *set = reinterpret_cast<vgpu::CmdSetScanout *>(commandBytes_);
        bzero(set, sizeof(*set));
        set->hdr.type = vgpu::kCmdSetScanout;
        set->r = {0, 0, w, h};
        set->scanoutID = 0;
        set->resourceID = kTestResource;
        type = simple(sizeof(*set));
        LOG("SET_SCANOUT -> %s", respName(type));
        ok = type == vgpu::kRespOkNoData;
    }

    if (ok) {
        uint64_t t0 = nowNs();
        ok = transferAndFlush(kTestResource, 0, 0, w, h, stride);
        LOG("full-frame transfer + flush: %s in %llu us", ok ? "ok" : "FAILED",
            (unsigned long long)((nowNs() - t0) / 1000));
    }

    if (ok) {
        // A 160x160 block moving across the bars for kTestSeconds, damage-only updates.
        const uint32_t box = 160;
        uint32_t frames = 0, x = 0, y = (h - box) / 2;
        uint64_t worstNs = 0, totalNs = 0;
        uint64_t end = nowNs() + (uint64_t)kTestSeconds * 1000000000ULL;
        while (nowNs() < end && ok) {
            uint32_t oldX = x;
            x = (x + 12) % (w - box);
            paintBars(oldX, y, box, box);
            for (uint32_t yy = y; yy < y + box; yy++) {
                for (uint32_t xx = x; xx < x + box; xx++) {
                    px[yy * w + xx] = ((xx / 20 + yy / 20) & 1) ? 0x00ffffff : 0x00000000;
                }
            }
            uint32_t ux = oldX < x ? oldX : x;
            uint32_t uw = (oldX < x ? x - oldX : oldX - x) + box;
            if (ux + uw > w) {
                ux = 0;
                uw = w; // wrapped around: send the whole row band
            }
            uint64_t t0 = nowNs();
            ok = transferAndFlush(kTestResource, ux, y, uw, box, stride);
            uint64_t took = nowNs() - t0;
            totalNs += took;
            worstNs = took > worstNs ? took : worstNs;
            frames++;
            IOSleep(16);
        }
        LOG("animation: %u frames in %u s, update avg %llu us worst %llu us%s", frames, kTestSeconds,
            (unsigned long long)(frames ? totalNs / frames / 1000 : 0),
            (unsigned long long)(worstNs / 1000), ok ? "" : " (an update FAILED)");
    }

    // Give the screen back: no scanout, drop the resource, reset (VGA mode returns).
    auto *off = reinterpret_cast<vgpu::CmdSetScanout *>(commandBytes_);
    bzero(off, sizeof(*off));
    off->hdr.type = vgpu::kCmdSetScanout;
    off->resourceID = 0;
    LOG("SET_SCANOUT off -> %s", respName(simple(sizeof(*off))));
    auto *detach = reinterpret_cast<vgpu::CmdResourceDetachBacking *>(commandBytes_);
    bzero(detach, sizeof(*detach));
    detach->hdr.type = vgpu::kCmdResourceDetachBacking;
    detach->resourceID = kTestResource;
    LOG("DETACH_BACKING -> %s", respName(simple(sizeof(*detach))));
    auto *unref = reinterpret_cast<vgpu::CmdResourceUnref *>(commandBytes_);
    bzero(unref, sizeof(*unref));
    unref->hdr.type = vgpu::kCmdResourceUnref;
    unref->resourceID = kTestResource;
    LOG("RESOURCE_UNREF -> %s", respName(simple(sizeof(*unref))));
    LOG("interrupts %u (%u wakeups), commands by interrupt %u, by polling %u", interrupts_, wakeups_,
        commandsByInterrupt_, commandsByPolling_);
    tearDown();
    LOG("device reset: the VGA framebuffer should be back on screen");
    fb->complete();
    fb->release();
    publishLog();
}
