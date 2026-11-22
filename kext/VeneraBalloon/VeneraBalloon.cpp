// VeneraBalloon: a statistics-only driver for QEMU's virtio-balloon device (virtio 1.2 section 5.5), in place of
// Apple's AppleVirtIOBalloon, so Proxmox shows a macOS VM's real memory use.
//
// Why: Proxmox shows a VM's memory as the guest's total less its free memory only when the VM's balloon device
// reports statistics; otherwise it shows the QEMU process's memory, which macOS fills with caches: ~100% all the time.
// Apple's driver negotiates the statistics queue but sends no figures (Proxmox gets only a zero swap-in count).
//
// What it does: negotiates VIRTIO_BALLOON_F_STATS_VQ and nothing else, never inflates (the host's target is read and
// shown, not acted on; Venera's VM script sets the balloon's minimum to the VM's memory, so Proxmox never asks), and
// answers the statistics queue (section 5.5.6.3) with the figures venera-agent hands it through the user client
// (VeneraBalloonAPI.h). The figures come from user space because the kernel's page counts aren't KPI:
// host_statistics64 there, the same counts Activity Monitor and vm_stat read. Figures older than kStaleMs (no agent)
// go out as the total alone, and Proxmox falls back to its own figure rather than show a stale one.
//
// The statistics protocol: the driver gives the device one buffer of {u16 tag, u64 value} pairs; QEMU reads it at
// once and keeps the buffer, then hands it back at each polling interval (Proxmox sets 2 s) for fresh figures. This
// driver polls its queues once a second on a timer (and when the agent's figures arrive) rather than take
// interrupts: the avail ring asks the device for none, so nothing is raised on a line nobody services.
//
// Matched ahead of Apple's virtio transport (which takes every virtio PCI device), so it loads through OpenCore, as
// VeneraConsole.kext does.
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <kern/clock.h>
#include <libkern/OSAtomic.h>
#include <stdarg.h>

#include "../VirtioGPU/VirtioPCI.hpp"
#include "VeneraBalloonAPI.h"

// IOLog from an OpenCore-injected kext reaches only the verbose boot screen on Tahoe: lines also go into a copy in the
// service's "VeneraBalloonLog" property (ioreg -rc VeneraBalloon -l). As in VeneraConsole, the live array is never
// itself a registry property.
static OSArray *gLog;
static IOLock *gLogLock;

void probeLog(const char *fmt, ...) {
    char line[200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    IOLog("VeneraBalloon: %s\n", line);
    if (gLog && gLogLock) {
        if (OSString *s = OSString::withCString(line)) {
            IOLockLock(gLogLock);
            if (gLog->getCount() >= 100) {
                gLog->removeObject(0);
            }
            gLog->setObject(s);
            IOLockUnlock(gLogLock);
            s->release();
        }
    }
}
#define LOG(fmt, ...) probeLog(fmt, ##__VA_ARGS__)

namespace {

enum : uint32_t {
    kFeatureStatsVQ = 1,   // VIRTIO_BALLOON_F_STATS_VQ
};

// struct virtio_balloon_stat
struct __attribute__((packed)) Stat {
    uint16_t tag;
    uint64_t val;
};
enum : uint16_t {
    kTagSwapIn = 0,
    kTagSwapOut = 1,
    kTagMajFlt = 2,
    kTagMinFlt = 3,
    kTagMemFree = 4,
    kTagMemTot = 5,
    kTagAvail = 6,
    kTagCaches = 7,
};

constexpr uint16_t kNoVector = 0xffff;
constexpr uint32_t kTickMs = 1000;
constexpr uint64_t kStaleMs = 30000;   // the agent sends every 2 s; past this its figures aren't macOS's any more

inline uint64_t nowMs() {
    uint64_t t, ns;
    clock_get_uptime(&t);
    absolutetime_to_nanoseconds(t, &ns);
    return ns / 1000000;
}

} // namespace

class VeneraBalloon : public IOService {
    OSDeclareDefaultStructors(VeneraBalloon);

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    // for the user client
    void setStats(const uint64_t *v, unsigned n);
    void state(uint64_t out[4]);

private:
    bool findRegions(virtio::Region regions[9], uint32_t *notifyMultiplier);
    bool bringUp();
    void tick(IOTimerEventSource *);
    void service();   // with the lock held: the stats buffer back from the device, refilled and handed over
    void publish();

    IOPCIDevice *pci_ = nullptr;
    virtio::Transport transport_;
    IOWorkLoop *workLoop_ = nullptr;
    IOTimerEventSource *timer_ = nullptr;
    IOLock *lock_ = nullptr;
    bool up_ = false;
    uint64_t features_ = 0;
    virtio::Virtqueue *inflate_ = nullptr, *deflate_ = nullptr, *stats_ = nullptr;
    IOBufferMemoryDescriptor *buf_ = nullptr;
    uint64_t bufPhys_ = 0;
    Stat *bufVa_ = nullptr;
    bool outstanding_ = false;   // the device holds the stats buffer
    uint64_t v_[kVBStatCount] = {};
    uint64_t statsAt_ = 0;       // nowMs() of the agent's last figures, 0 for none yet
    uint64_t taken_ = 0;         // buffers handed to the device
    uint32_t target_ = 0;        // the device's num_pages, as last seen
    bool stale_ = true;
};

OSDefineMetaClassAndStructors(VeneraBalloon, IOService);

static void logInit() {
    if (!gLogLock) {
        gLogLock = IOLockAlloc();
        gLog = OSArray::withCapacity(32);
    }
}

IOService *VeneraBalloon::probe(IOService *provider, SInt32 *score) {
    logInit();
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci || pci->configRead16(kIOPCIConfigVendorID) != 0x1af4) {
        return nullptr;
    }
    uint16_t dev = pci->configRead16(kIOPCIConfigDeviceID);
    if (dev != 0x1002 && dev != 0x1045) {
        return nullptr;
    }
    LOG("probe %s: 1af4:%04x", provider->getName(), dev);
    // Apple's virtio transport takes every virtio device and wins a plain IOProbeScore (its own probe raises it)
    if (score) *score = 1000000;
    return IOService::probe(provider, score);
}

bool VeneraBalloon::start(IOService *provider) {
    if (!IOService::start(provider)) {
        return false;
    }
    pci_ = OSDynamicCast(IOPCIDevice, provider);
    if (!pci_) {
        return false;
    }
    logInit();
    LOG("start on %s", provider->getName());
    lock_ = IOLockAlloc();
    workLoop_ = IOWorkLoop::workLoop();
    if (!lock_ || !workLoop_) {
        return false;
    }
    pci_->setMemoryEnable(true);
    pci_->setBusMasterEnable(true);
    if (!bringUp()) {
        LOG("bring-up failed: the device stays unused");
        stop(provider);
        return false;
    }
    timer_ = IOTimerEventSource::timerEventSource(
        this, OSMemberFunctionCast(IOTimerEventSource::Action, this, &VeneraBalloon::tick));
    if (!timer_ || workLoop_->addEventSource(timer_) != kIOReturnSuccess) {
        LOG("no timer");
        stop(provider);
        return false;
    }
    up_ = true;
    timer_->setTimeoutMS(kTickMs);
    publish();
    registerService();
    LOG("ready: statistics only, never inflates");
    return true;
}

void VeneraBalloon::stop(IOService *provider) {
    if (lock_) {
        IOLockLock(lock_);
        up_ = false;
        IOLockUnlock(lock_);
    }
    if (timer_) {
        timer_->cancelTimeout();
        if (workLoop_) {
            workLoop_->removeEventSource(timer_);
        }
        OSSafeReleaseNULL(timer_);
    }
    if (transport_.deviceConfig()) {
        transport_.reset();   // the device lets go of the buffer before it's freed
    }
    IOService::stop(provider);
}

void VeneraBalloon::free() {
    if (inflate_) inflate_->release();
    if (deflate_) deflate_->release();
    if (stats_) stats_->release();
    if (buf_) {
        buf_->complete();
        buf_->release();
        buf_ = nullptr;
    }
    transport_.detach();
    OSSafeReleaseNULL(workLoop_);
    if (lock_) {
        IOLockFree(lock_);
        lock_ = nullptr;
    }
    IOService::free();
}

bool VeneraBalloon::findRegions(virtio::Region regions[9], uint32_t *notifyMultiplier) {
    if (!(pci_->configRead16(kIOPCIConfigStatus) & 0x10)) {
        LOG("no capability list (a legacy-only device?)");
        return false;
    }
    uint8_t ptr = pci_->configRead8(kIOPCIConfigCapabilitiesPtr) & 0xfc;
    for (int guard = 0; ptr && guard < 48; guard++) {
        uint8_t id = pci_->configRead8(ptr);
        uint8_t next = pci_->configRead8(ptr + 1) & 0xfc;
        if (id == 0x09) {
            uint8_t type = pci_->configRead8(ptr + 3);
            if (type == 2) {
                *notifyMultiplier = pci_->configRead32(ptr + 16);
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
    return regions[1].present;
}

bool VeneraBalloon::bringUp() {
    virtio::Region regions[9] = {};
    uint32_t multiplier = 0;
    if (!findRegions(regions, &multiplier) || !transport_.attach(pci_, regions, multiplier)) {
        LOG("no virtio-pci regions (common %d notify %d device %d)", regions[1].present, regions[2].present,
            regions[4].present);
        return false;
    }
    // Section 3.1.1: reset, ACKNOWLEDGE, DRIVER, features, FEATURES_OK, the queues, DRIVER_OK.
    transport_.reset();
    transport_.addStatus(virtio::kAcknowledge);
    transport_.addStatus(virtio::kDriver);
    uint64_t offered = transport_.deviceFeatures();
    uint64_t wanted = (1ULL << virtio::kFeatureVersion1) | (1ULL << kFeatureStatsVQ);
    if (!transport_.negotiate(wanted, &features_) || features_ != wanted) {
        LOG("features: 0x%llx offered, 0x%llx taken (need VERSION_1 and STATS_VQ)", (unsigned long long)offered,
            (unsigned long long)features_);
        transport_.addStatus(virtio::kFailed);
        return false;
    }
    uint16_t nq = transport_.numQueues();
    LOG("features 0x%llx offered, 0x%llx taken, %u queues", (unsigned long long)offered,
        (unsigned long long)features_, nq);
    transport_.setConfigVector(kNoVector);
    // inflateq and deflateq exist whether used or not; statsq is the third with STATS_VQ (section 5.5.2)
    inflate_ = transport_.setupQueue(0, 8, kNoVector);
    deflate_ = transport_.setupQueue(1, 8, kNoVector);
    stats_ = transport_.setupQueue(2, 8, kNoVector);
    buf_ = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous,
                                                            PAGE_SIZE, 0xFFFFFFFFFFFFF000ULL);
    if (!inflate_ || !deflate_ || !stats_ || !buf_ || buf_->prepare() != kIOReturnSuccess) {
        LOG("queues: inflate %p deflate %p stats %p, buffer %p", inflate_, deflate_, stats_, buf_);
        OSSafeReleaseNULL(buf_);
        transport_.addStatus(virtio::kFailed);
        return false;
    }
    bufVa_ = static_cast<Stat *>(buf_->getBytesNoCopy());
    bzero(bufVa_, PAGE_SIZE);
    bufPhys_ = buf_->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);
    transport_.addStatus(virtio::kDriverOK);
    LOG("queues set up, DRIVER_OK: waiting for venera-agent's figures");
    return true;
}

void VeneraBalloon::service() {
    if (!up_) return;
    uint32_t id, len;
    while (stats_->takeUsed(&id, &len)) {
        outstanding_ = false;   // the device wants fresh figures
    }
    // inflate and deflate get no buffers from this driver: nothing comes back on them
    target_ = *reinterpret_cast<volatile uint32_t *>(transport_.deviceConfig());   // num_pages
    if (outstanding_ || !statsAt_) {
        return;   // the device has the buffer, or nothing to tell it yet
    }
    stale_ = nowMs() - statsAt_ > kStaleMs;
    unsigned n = 0;
    bufVa_[n++] = {kTagMemTot, v_[kVBTotal]};
    if (!stale_) {
        bufVa_[n++] = {kTagMemFree, v_[kVBFree]};
        bufVa_[n++] = {kTagAvail, v_[kVBAvail]};
        bufVa_[n++] = {kTagCaches, v_[kVBCaches]};
        bufVa_[n++] = {kTagSwapIn, v_[kVBSwapIn]};
        bufVa_[n++] = {kTagSwapOut, v_[kVBSwapOut]};
        bufVa_[n++] = {kTagMajFlt, v_[kVBMajorFaults]};
        bufVa_[n++] = {kTagMinFlt, v_[kVBMinorFaults]};
    }
    virtio::Segment s = {bufPhys_, (uint32_t)(n * sizeof(Stat)), false};
    if (stats_->submit(&s, 1) < 0) {
        return;
    }
    outstanding_ = true;
    taken_++;
    transport_.notify(stats_);
}

void VeneraBalloon::tick(IOTimerEventSource *) {
    IOLockLock(lock_);
    bool wasStale = stale_;
    uint64_t taken = taken_;
    service();
    bool changed = taken != taken_ && (taken_ < 4 || wasStale != stale_ || taken_ % 30 == 0);
    if (wasStale != stale_ && statsAt_) {
        LOG(stale_ ? "venera-agent's figures are over %llu s old: the total only" : "fresh figures again (%llu s)",
            (unsigned long long)(kStaleMs / 1000));
    }
    bool up = up_;
    IOLockUnlock(lock_);
    if (changed) {
        publish();
    }
    if (up) {
        timer_->setTimeoutMS(kTickMs);
    }
}

void VeneraBalloon::setStats(const uint64_t *v, unsigned n) {
    IOLockLock(lock_);
    for (unsigned i = 0; i < kVBStatCount; i++) {
        v_[i] = i < n ? v[i] : 0;
    }
    bool first = !statsAt_;
    statsAt_ = nowMs();
    service();
    IOLockUnlock(lock_);
    if (first) {
        LOG("first figures: total %llu MB, free %llu MB", (unsigned long long)(v_[kVBTotal] >> 20),
            (unsigned long long)(v_[kVBFree] >> 20));
        publish();
    }
}

void VeneraBalloon::state(uint64_t out[4]) {
    IOLockLock(lock_);
    out[0] = taken_;
    out[1] = statsAt_ ? nowMs() - statsAt_ : ~0ULL;
    out[2] = target_;
    out[3] = kStaleMs;
    IOLockUnlock(lock_);
}

void VeneraBalloon::publish() {
    char line[160];
    IOLockLock(lock_);
    snprintf(line, sizeof(line), "%llu sent; total %llu MB, free %llu MB, cached %llu MB%s; host target %u pages",
             (unsigned long long)taken_, (unsigned long long)(v_[kVBTotal] >> 20),
             (unsigned long long)(v_[kVBFree] >> 20), (unsigned long long)(v_[kVBCaches] >> 20),
             !statsAt_ ? " (no figures yet)" : stale_ ? " (stale: the total only)" : "", target_);
    IOLockUnlock(lock_);
    if (OSString *s = OSString::withCString(line)) {
        setProperty("VeneraBalloonState", s);
        s->release();
    }
    if (gLog && gLogLock) {
        IOLockLock(gLogLock);
        OSArray *copy = OSArray::withArray(gLog);
        IOLockUnlock(gLogLock);
        if (copy) {
            setProperty("VeneraBalloonLog", copy);
            copy->release();
        }
    }
}

// ---- the user client ----------------------------------------------------------------------------------------------

class VeneraBalloonUserClient : public IOUserClient {
    OSDeclareDefaultStructors(VeneraBalloonUserClient);

public:
    bool initWithTask(task_t owningTask, void *securityID, UInt32 type) override;
    bool start(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args, IOExternalMethodDispatch *dispatch,
                            OSObject *target, void *reference) override;

private:
    VeneraBalloon *drv_ = nullptr;
};

OSDefineMetaClassAndStructors(VeneraBalloonUserClient, IOUserClient);

bool VeneraBalloonUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type) {
    // only root: the figures become what the host is told about the VM
    return IOUserClient::initWithTask(owningTask, securityID, type) &&
           clientHasPrivilege(owningTask, kIOClientPrivilegeAdministrator) == kIOReturnSuccess;
}

bool VeneraBalloonUserClient::start(IOService *provider) {
    drv_ = OSDynamicCast(VeneraBalloon, provider);
    return drv_ && IOUserClient::start(provider);
}

IOReturn VeneraBalloonUserClient::clientClose() {
    terminate();
    return kIOReturnSuccess;
}

IOReturn VeneraBalloonUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *a,
                                                 IOExternalMethodDispatch *, OSObject *, void *) {
    switch (selector) {
    case kVBMethodSetStats:
        if (a->scalarInputCount < 2) return kIOReturnBadArgument;   // at least the total and the free figure
        drv_->setStats(a->scalarInput, a->scalarInputCount);
        return kIOReturnSuccess;
    case kVBMethodState: {
        if (a->scalarOutputCount < 4) return kIOReturnBadArgument;
        uint64_t s[4];
        drv_->state(s);
        for (int i = 0; i < 4; i++) a->scalarOutput[i] = s[i];
        a->scalarOutputCount = 4;
        return kIOReturnSuccess;
    }
    default:
        return kIOReturnUnsupported;
    }
}
