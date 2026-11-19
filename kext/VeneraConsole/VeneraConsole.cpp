// VeneraConsole: a driver for QEMU's virtio-serial device (virtio console with multiple ports, virtio 1.2 section
// 5.3), in place of Apple's AppleVirtIOConsole. Proxmox's guest agent port (org.qemu.guest_agent.0) is a port of
// one; SPICE's agent channel (com.redhat.spice.0) a port of another.
//
// Why our own: Apple's driver, written for its Virtualization framework (where the host end of a port never goes
// away), stops sending once the host closes a port while output is queued, and only a close and reopen in the guest
// starts it again; its tty, meanwhile, holds every write and even the close at exit. QEMU itself discards a closed
// port's queued output and completes the buffers, so here the host closing and opening a port is just state: writes
// go on (QEMU drops them while the host is away) and nothing waits for good.
//
// What it offers is a user client (VeneraConsoleAPI.h): list the ports, open one by name, read with a timeout, write
// with a timeout. No tty. The guest agent's port runs the host's commands as root, so only root opens it; the others
// (SPICE's agent channel, for the clipboard) the logged-in user may open too. It is matched ahead of Apple's virtio transport (which takes every virtio
// PCI device), so it loads through OpenCore, as VirtioGPU.kext and VeneraVideo.kext do.
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOFilterInterruptEventSource.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <kern/clock.h>
#include <libkern/OSAtomic.h>
#include <stdarg.h>

#include "../VirtioGPU/VirtioPCI.hpp"
#include "VeneraConsoleAPI.h"

// IOLog from an OpenCore-injected kext reaches only the verbose boot screen on Tahoe: lines also go into a copy in the
// service's "VeneraConsoleLog" property (ioreg -rc VeneraConsole -l), refreshed as ports change. Nothing here touches
// another object's properties while the kernel is matching drivers, and the live array is never itself a registry
// property: either hung the boot (round 18).
static OSArray *gLog;
static IOLock *gLogLock;

void probeLog(const char *fmt, ...) {
    char line[200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    IOLog("VeneraConsole: %s\n", line);
    if (gLog && gLogLock) {
        if (OSString *s = OSString::withCString(line)) {
            IOLockLock(gLogLock);
            if (gLog->getCount() >= 200) {
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
    kFeatureMultiport = 1,   // VIRTIO_CONSOLE_F_MULTIPORT
};

// struct virtio_console_control
struct Control {
    uint32_t id;
    uint16_t event;
    uint16_t value;
};
enum : uint16_t {
    kDeviceReady = 0,
    kDeviceAdd = 1,
    kDeviceRemove = 2,
    kPortReady = 3,
    kConsolePort = 4,
    kResize = 5,
    kPortOpen = 6,
    kPortName = 7,
};

constexpr uint16_t kNoVector = 0xffff;
constexpr unsigned kCtlRxBufs = 16, kCtlRxSize = 256;   // a PORT_NAME is the header and the name
constexpr unsigned kCtlTxBufs = 16;
constexpr unsigned kRxBufs = 16, kRxSize = 16384;       // 256 KB the host can have in flight to us
constexpr unsigned kTxBufs = 16, kTxSize = 16384;       // and we to it

inline uint32_t rxIndex(uint32_t port) { return port == 0 ? 0 : 2 + 2 * port; }
inline uint32_t txIndex(uint32_t port) { return port == 0 ? 1 : 3 + 2 * port; }

// One physically contiguous block cut into equal buffers.
struct Pool {
    IOBufferMemoryDescriptor *mem = nullptr;
    uint8_t *va = nullptr;
    uint64_t phys = 0;
    bool alloc(uint32_t bytes) {
        mem = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, bytes, 0xFFFFFFFFFFFFF000ULL);
        if (!mem || mem->prepare() != kIOReturnSuccess) {
            OSSafeReleaseNULL(mem);
            return false;
        }
        va = static_cast<uint8_t *>(mem->getBytesNoCopy());
        bzero(va, bytes);
        phys = mem->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);
        return true;
    }
    void free() {
        if (mem) {
            mem->complete();
            mem->release();
            mem = nullptr;
        }
    }
};

} // namespace

class VeneraConsoleUserClient;

class VeneraConsole : public IOService {
    OSDeclareDefaultStructors(VeneraConsole);

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    // for the user client (each takes the lock itself)
    unsigned ports(VCPortInfo *out, unsigned max);
    IOReturn open(const char *name, VeneraConsoleUserClient *who, uint32_t *id);
    void close(uint32_t id, VeneraConsoleUserClient *who);
    IOReturn read(uint32_t id, uint8_t *buf, uint32_t max, uint32_t timeoutMs, uint32_t *got);
    IOReturn write(uint32_t id, const uint8_t *buf, uint32_t len, uint32_t timeoutMs, uint32_t *took);
    bool hostOpen(uint32_t id);
    void counts(uint32_t id, uint64_t *rx, uint64_t *tx);

private:
    struct Port {
        bool added = false, hostOpen = false, guestOpen = false, console = false;
        char name[56] = {};
        virtio::Virtqueue *rxq = nullptr, *txq = nullptr;
        Pool rx, tx;
        uint8_t rxOfDesc[256] = {}, txOfDesc[256] = {};
        // received buffers in arrival order, read from the front; a buffer goes back to the device once read
        uint8_t fifo[kRxBufs] = {};
        uint32_t fifoLen[kRxBufs] = {};
        unsigned fifoHead = 0, fifoCount = 0, readOff = 0;
        bool txBusy[kTxBufs] = {};
        unsigned txFree = 0;
        VeneraConsoleUserClient *owner = nullptr;
        uint64_t rxBytes = 0, txBytes = 0;
    };

    bool findRegions(virtio::Region regions[9], uint32_t *notifyMultiplier);
    bool setupInterrupt();
    bool bringUp();
    bool filter(IOFilterInterruptEventSource *source);
    void interruptOccurred(IOInterruptEventSource *source, int count);
    void serviceQueues();                 // with the lock held
    void handleControl(const Control *c, const uint8_t *extra, uint32_t extraLen);
    void sendControl(uint32_t id, uint16_t event, uint16_t value);   // with the lock held
    void postRx(uint32_t port, unsigned buf);
    bool addPort(uint32_t id);
    void dropRx(Port &p);                 // read-ahead thrown away (a guest close), buffers back to the device
    void publish();

    IOPCIDevice *pci_ = nullptr;
    virtio::Transport transport_;
    IOWorkLoop *workLoop_ = nullptr;
    IOFilterInterruptEventSource *interrupt_ = nullptr;
    bool msix_ = false;
    IOLock *lock_ = nullptr;
    bool up_ = false;
    uint64_t features_ = 0;
    uint32_t maxPorts_ = 0;
    virtio::Virtqueue *ctlRx_ = nullptr, *ctlTx_ = nullptr;
    Pool ctlRxPool_, ctlTxPool_;
    uint8_t ctlRxOfDesc_[256] = {}, ctlTxOfDesc_[256] = {};
    bool ctlTxBusy_[kCtlTxBufs] = {};
    Port ports_[kVCMaxPorts];
    uint32_t wake_ = 0;                   // the event readers and writers sleep on
    volatile UInt32 interrupts_ = 0;
};

OSDefineMetaClassAndStructors(VeneraConsole, IOService);

static void logInit() {
    if (!gLogLock) {
        gLogLock = IOLockAlloc();
        gLog = OSArray::withCapacity(64);
    }
}

IOService *VeneraConsole::probe(IOService *provider, SInt32 *score) {
    logInit();
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci || pci->configRead16(kIOPCIConfigVendorID) != 0x1af4) {
        return nullptr;
    }
    uint16_t dev = pci->configRead16(kIOPCIConfigDeviceID);
    LOG("probe %s: 1af4:%04x, score %d", provider->getName(), dev, score ? (int)*score : -1);
    if (dev != 0x1003 && dev != 0x1043) {
        return nullptr;
    }
    // Apple's virtio transport takes every virtio device and wins a plain IOProbeScore (its own probe raises it), so
    // this one asks for far more.
    if (score) *score = 1000000;
    return IOService::probe(provider, score);
}

bool VeneraConsole::start(IOService *provider) {
    LOG("start: entering");
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
    if (!lock_) {
        return false;
    }
    pci_->setMemoryEnable(true);
    pci_->setBusMasterEnable(true);
    LOG("start: interrupt");
    if (!setupInterrupt() || !bringUp()) {
        LOG("bring-up failed: the device stays unused");
        stop(provider);
        return false;
    }
    up_ = true;
    publish();
    registerService();
    LOG("ready: %u ports at most, MSI-X %d", maxPorts_, msix_);
    return true;
}

void VeneraConsole::stop(IOService *provider) {
    if (lock_) {
        IOLockLock(lock_);
        up_ = false;
        IOLockWakeup(lock_, &wake_, false);
        IOLockUnlock(lock_);
    }
    if (interrupt_) {
        interrupt_->disable();
        if (workLoop_) {
            workLoop_->removeEventSource(interrupt_);
        }
        OSSafeReleaseNULL(interrupt_);
    }
    if (transport_.deviceConfig()) {
        transport_.reset();   // the device lets go of every buffer before they're freed
    }
    IOService::stop(provider);
}

void VeneraConsole::free() {
    for (Port &p : ports_) {
        if (p.rxq) p.rxq->release();
        if (p.txq) p.txq->release();
        p.rx.free();
        p.tx.free();
    }
    if (ctlRx_) ctlRx_->release();
    if (ctlTx_) ctlTx_->release();
    ctlRxPool_.free();
    ctlTxPool_.free();
    transport_.detach();
    OSSafeReleaseNULL(workLoop_);
    if (lock_) {
        IOLockFree(lock_);
        lock_ = nullptr;
    }
    IOService::free();
}

bool VeneraConsole::findRegions(virtio::Region regions[9], uint32_t *notifyMultiplier) {
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

bool VeneraConsole::setupInterrupt() {
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
        index = 0;
    }
    workLoop_ = IOWorkLoop::workLoop();
    if (!workLoop_) {
        return false;
    }
    interrupt_ = IOFilterInterruptEventSource::filterInterruptEventSource(
        this, OSMemberFunctionCast(IOInterruptEventAction, this, &VeneraConsole::interruptOccurred),
        OSMemberFunctionCast(IOFilterInterruptAction, this, &VeneraConsole::filter), pci_, index);
    if (!interrupt_ || workLoop_->addEventSource(interrupt_) != kIOReturnSuccess) {
        LOG("could not register interrupt index %d", index);
        return false;
    }
    return true;
}

bool VeneraConsole::filter(IOFilterInterruptEventSource *) {
    if (!msix_ && !(transport_.readISR() & 1)) {
        return false;   // a shared INTx line, not ours
    }
    OSIncrementAtomic(reinterpret_cast<volatile SInt32 *>(&interrupts_));
    return true;
}

void VeneraConsole::interruptOccurred(IOInterruptEventSource *, int) {
    IOLockLock(lock_);
    serviceQueues();
    IOLockWakeup(lock_, &wake_, false);
    IOLockUnlock(lock_);
}

bool VeneraConsole::bringUp() {
    virtio::Region regions[9] = {};
    uint32_t multiplier = 0;
    if (!findRegions(regions, &multiplier) || !transport_.attach(pci_, regions, multiplier)) {
        LOG("no virtio-pci regions (common %d notify %d device %d)", regions[1].present, regions[2].present, regions[4].present);
        return false;
    }
    // Section 3.1.1: reset, ACKNOWLEDGE, DRIVER, features, FEATURES_OK, the queues, DRIVER_OK.
    transport_.reset();
    transport_.addStatus(virtio::kAcknowledge);
    transport_.addStatus(virtio::kDriver);
    uint64_t wanted = (1ULL << virtio::kFeatureVersion1) | (1ULL << kFeatureMultiport);
    if (!transport_.negotiate(wanted, &features_) || !(features_ & (1ULL << virtio::kFeatureVersion1)) ||
        !(features_ & (1ULL << kFeatureMultiport))) {
        LOG("features: 0x%llx offered, 0x%llx taken (need VERSION_1 and MULTIPORT)",
            (unsigned long long)transport_.deviceFeatures(), (unsigned long long)features_);
        transport_.addStatus(virtio::kFailed);
        return false;
    }
    volatile uint8_t *cfg = transport_.deviceConfig();
    uint32_t max = *reinterpret_cast<volatile uint32_t *>(cfg + 4);   // max_nr_ports
    uint16_t nq = transport_.numQueues();
    maxPorts_ = max < kVCMaxPorts ? max : kVCMaxPorts;
    LOG("features 0x%llx, max_nr_ports %u, %u queues", (unsigned long long)features_, max, nq);
    if (nq < 4) {
        LOG("only %u queues: no control queues", nq);
        transport_.addStatus(virtio::kFailed);
        return false;
    }
    uint16_t vector = msix_ ? 0 : kNoVector;
    transport_.setConfigVector(kNoVector);
    ctlRx_ = transport_.setupQueue(2, 64, vector);
    ctlTx_ = transport_.setupQueue(3, 64, vector);
    if (!ctlRx_ || !ctlTx_ || !ctlRxPool_.alloc(kCtlRxBufs * kCtlRxSize) || !ctlTxPool_.alloc(kCtlTxBufs * sizeof(Control))) {
        LOG("control queues: rx %p tx %p", ctlRx_, ctlTx_);
        transport_.addStatus(virtio::kFailed);
        return false;
    }
    ctlRx_->setInterrupts(true);
    ctlTx_->setInterrupts(true);
    for (uint32_t p = 0; p < maxPorts_; p++) {   // every port's queues now: queues are set up before DRIVER_OK
        if (txIndex(p) >= nq) {
            maxPorts_ = p;
            break;
        }
        ports_[p].rxq = transport_.setupQueue((uint16_t)rxIndex(p), 64, vector);
        ports_[p].txq = transport_.setupQueue((uint16_t)txIndex(p), 64, vector);
        if (!ports_[p].rxq || !ports_[p].txq) {
            LOG("port %u's queues %u/%u failed", p, rxIndex(p), txIndex(p));
            transport_.addStatus(virtio::kFailed);
            return false;
        }
        ports_[p].rxq->setInterrupts(true);
        ports_[p].txq->setInterrupts(true);
    }
    for (unsigned i = 0; i < kCtlRxBufs; i++) {
        virtio::Segment s = {ctlRxPool_.phys + i * kCtlRxSize, kCtlRxSize, true};
        int id = ctlRx_->submit(&s, 1);
        if (id >= 0) {
            ctlRxOfDesc_[id] = (uint8_t)i;
        }
    }
    LOG("queues set up, DRIVER_OK");
    transport_.addStatus(virtio::kDriverOK);
    interrupt_->enable();
    transport_.notify(ctlRx_);
    IOLockLock(lock_);
    sendControl(0, kDeviceReady, 1);   // the device answers with a DEVICE_ADD for each port
    IOLockUnlock(lock_);
    return true;
}

void VeneraConsole::sendControl(uint32_t id, uint16_t event, uint16_t value) {
    uint32_t used, len;
    while (ctlTx_->takeUsed(&used, &len)) {
        ctlTxBusy_[ctlTxOfDesc_[used]] = false;
    }
    for (unsigned i = 0; i < kCtlTxBufs; i++) {
        if (ctlTxBusy_[i]) {
            continue;
        }
        Control *c = reinterpret_cast<Control *>(ctlTxPool_.va + i * sizeof(Control));
        c->id = id;
        c->event = event;
        c->value = value;
        virtio::Segment s = {ctlTxPool_.phys + i * sizeof(Control), sizeof(Control), false};
        int d = ctlTx_->submit(&s, 1);
        if (d < 0) {
            break;
        }
        ctlTxOfDesc_[d] = (uint8_t)i;
        ctlTxBusy_[i] = true;
        transport_.notify(ctlTx_);
        return;
    }
    LOG("control queue full: event %u for port %u lost", event, id);
}

void VeneraConsole::postRx(uint32_t port, unsigned buf) {
    Port &p = ports_[port];
    virtio::Segment s = {p.rx.phys + buf * kRxSize, kRxSize, true};
    int d = p.rxq->submit(&s, 1);
    if (d >= 0) {
        p.rxOfDesc[d] = (uint8_t)buf;
    }
}

bool VeneraConsole::addPort(uint32_t id) {
    Port &p = ports_[id];
    if (p.added) {
        return true;
    }
    // allocated on the work loop, not in the filter; kept for the device's lifetime once made
    if (!p.rx.mem && !p.rx.alloc(kRxBufs * kRxSize)) {
        return false;
    }
    if (!p.tx.mem && !p.tx.alloc(kTxBufs * kTxSize)) {
        return false;
    }
    p.fifoHead = p.fifoCount = p.readOff = 0;
    for (unsigned i = 0; i < kTxBufs; i++) p.txBusy[i] = false;
    p.txFree = kTxBufs;
    for (unsigned i = 0; i < kRxBufs; i++) {
        postRx(id, i);
    }
    transport_.notify(p.rxq);
    p.added = true;
    sendControl(id, kPortReady, 1);
    return true;
}

void VeneraConsole::dropRx(Port &p) {
    uint32_t id = (uint32_t)(&p - ports_);
    while (p.fifoCount) {
        postRx(id, p.fifo[p.fifoHead]);
        p.fifoHead = (p.fifoHead + 1) % kRxBufs;
        p.fifoCount--;
    }
    p.readOff = 0;
    if (p.rxq) {
        transport_.notify(p.rxq);
    }
}

void VeneraConsole::handleControl(const Control *c, const uint8_t *extra, uint32_t extraLen) {
    uint32_t id = c->id;
    if (c->event != kDeviceReady && id >= maxPorts_) {
        if (c->event == kDeviceAdd) {
            sendControl(id, kPortReady, 0);   // a port past the ones we set queues up for: refused
            LOG("port %u: past the %u this driver takes", id, maxPorts_);
        }
        return;
    }
    Port &p = ports_[id];
    switch (c->event) {
    case kDeviceAdd:
        if (!addPort(id)) {
            sendControl(id, kPortReady, 0);
            LOG("port %u: out of memory", id);
        }
        break;
    case kDeviceRemove:
        p.added = false;
        p.hostOpen = false;
        LOG("port %u (%s) removed", id, p.name);
        break;
    case kConsolePort:
        p.console = true;
        break;
    case kPortName: {
        uint32_t n = extraLen < sizeof(p.name) - 1 ? extraLen : (uint32_t)sizeof(p.name) - 1;
        memcpy(p.name, extra, n);
        p.name[n] = 0;
        for (uint32_t i = 0; i < n; i++) {
            if (!p.name[i]) break;
            if (p.name[i] < 0x20 || p.name[i] > 0x7e) p.name[i] = '?';
        }
        LOG("port %u is %s", id, p.name);
        break;
    }
    case kPortOpen:
        p.hostOpen = c->value != 0;
        break;
    default:
        break;
    }
    publish();
}

void VeneraConsole::serviceQueues() {
    uint32_t d, len;
    if (ctlRx_) {
        bool any = false;
        while (ctlRx_->takeUsed(&d, &len)) {
            unsigned buf = ctlRxOfDesc_[d];
            const uint8_t *b = ctlRxPool_.va + buf * kCtlRxSize;
            if (len >= sizeof(Control) && len <= kCtlRxSize) {
                handleControl(reinterpret_cast<const Control *>(b), b + sizeof(Control), len - (uint32_t)sizeof(Control));
            }
            virtio::Segment s = {ctlRxPool_.phys + buf * kCtlRxSize, kCtlRxSize, true};
            int nd = ctlRx_->submit(&s, 1);
            if (nd >= 0) {
                ctlRxOfDesc_[nd] = (uint8_t)buf;
            }
            any = true;
        }
        if (any) {
            transport_.notify(ctlRx_);
        }
    }
    for (uint32_t i = 0; i < maxPorts_; i++) {
        Port &p = ports_[i];
        if (!p.rxq) continue;
        while (p.rxq->takeUsed(&d, &len)) {
            unsigned buf = p.rxOfDesc[d];
            if (!p.guestOpen || len == 0) {   // nobody has the port open: nothing to keep
                postRx(i, buf);
                transport_.notify(p.rxq);
                continue;
            }
            unsigned slot = (p.fifoHead + p.fifoCount) % kRxBufs;
            p.fifo[slot] = (uint8_t)buf;
            p.fifoLen[slot] = len > kRxSize ? kRxSize : len;
            p.fifoCount++;
            p.rxBytes += len;
        }
        while (p.txq->takeUsed(&d, &len)) {
            unsigned buf = p.txOfDesc[d];
            if (buf < kTxBufs && p.txBusy[buf]) {
                p.txBusy[buf] = false;
                p.txFree++;
            }
        }
    }
}

void VeneraConsole::publish() {
    OSArray *a = OSArray::withCapacity(kVCMaxPorts);
    if (!a) return;
    for (uint32_t i = 0; i < maxPorts_; i++) {
        Port &p = ports_[i];
        if (!p.added) continue;
        char line[120];
        snprintf(line, sizeof(line), "%u %s host %s guest %s", i, p.name[0] ? p.name : "(unnamed)",
                 p.hostOpen ? "open" : "closed", p.guestOpen ? "open" : "closed");
        if (OSString *s = OSString::withCString(line)) {
            a->setObject(s);
            s->release();
        }
    }
    setProperty("VeneraConsolePorts", a);
    a->release();
    if (gLog && gLogLock) {
        IOLockLock(gLogLock);
        OSArray *copy = OSArray::withArray(gLog);
        IOLockUnlock(gLogLock);
        if (copy) {
            setProperty("VeneraConsoleLog", copy);
            copy->release();
        }
    }
}

// ---- for the user client ------------------------------------------------------------------------------------------

unsigned VeneraConsole::ports(VCPortInfo *out, unsigned max) {
    unsigned n = 0;
    IOLockLock(lock_);
    for (uint32_t i = 0; i < maxPorts_ && n < max; i++) {
        Port &p = ports_[i];
        if (!p.added) continue;
        out[n].id = i;
        out[n].flags = (p.hostOpen ? kVCPortHostOpen : 0) | (p.guestOpen ? kVCPortGuestOpen : 0) |
                       (p.console ? kVCPortConsole : 0);
        strlcpy(out[n].name, p.name, sizeof(out[n].name));
        n++;
    }
    IOLockUnlock(lock_);
    return n;
}

IOReturn VeneraConsole::open(const char *name, VeneraConsoleUserClient *who, uint32_t *id) {
    IOReturn rc = kIOReturnNotFound;
    IOLockLock(lock_);
    for (uint32_t i = 0; i < maxPorts_; i++) {
        Port &p = ports_[i];
        if (!p.added || strncmp(p.name, name, sizeof(p.name)) != 0) continue;
        if (p.owner) {
            rc = kIOReturnExclusiveAccess;
            break;
        }
        p.owner = who;
        p.guestOpen = true;
        dropRx(p);
        sendControl(i, kPortOpen, 1);
        *id = i;
        rc = kIOReturnSuccess;
        LOG("port %u (%s) opened", i, p.name);
        publish();
        break;
    }
    IOLockUnlock(lock_);
    return rc;
}

void VeneraConsole::close(uint32_t id, VeneraConsoleUserClient *who) {
    IOLockLock(lock_);
    if (id < maxPorts_ && ports_[id].owner == who) {
        Port &p = ports_[id];
        p.owner = nullptr;
        p.guestOpen = false;
        dropRx(p);
        if (up_) {
            sendControl(id, kPortOpen, 0);
        }
        LOG("port %u (%s) closed", id, p.name);
        publish();
        IOLockWakeup(lock_, &wake_, false);
    }
    IOLockUnlock(lock_);
}

IOReturn VeneraConsole::read(uint32_t id, uint8_t *buf, uint32_t max, uint32_t timeoutMs, uint32_t *got) {
    *got = 0;
    if (id >= maxPorts_) return kIOReturnBadArgument;
    uint64_t deadline;
    clock_interval_to_deadline(timeoutMs, kMillisecondScale, &deadline);
    IOLockLock(lock_);
    Port &p = ports_[id];
    for (;;) {
        if (!up_ || !p.added || !p.guestOpen) {
            IOLockUnlock(lock_);
            return kIOReturnNotOpen;
        }
        serviceQueues();   // what came in since the last interrupt
        if (p.fifoCount) break;
        if (timeoutMs == 0 || IOLockSleepDeadline(lock_, &wake_, deadline, THREAD_ABORTSAFE) != THREAD_AWAKENED) {
            if (!p.fifoCount) {
                IOLockUnlock(lock_);
                return kIOReturnSuccess;   // nothing yet
            }
            break;
        }
    }
    bool reposted = false;
    while (p.fifoCount && *got < max) {
        unsigned slot = p.fifoHead, b = p.fifo[slot];
        uint32_t left = p.fifoLen[slot] - p.readOff;
        uint32_t n = left < max - *got ? left : max - *got;
        memcpy(buf + *got, p.rx.va + b * kRxSize + p.readOff, n);
        *got += n;
        p.readOff += n;
        if (p.readOff >= p.fifoLen[slot]) {
            p.readOff = 0;
            p.fifoHead = (p.fifoHead + 1) % kRxBufs;
            p.fifoCount--;
            postRx(id, b);
            reposted = true;
        }
    }
    if (reposted) {
        transport_.notify(p.rxq);
    }
    IOLockUnlock(lock_);
    return kIOReturnSuccess;
}

IOReturn VeneraConsole::write(uint32_t id, const uint8_t *buf, uint32_t len, uint32_t timeoutMs, uint32_t *took) {
    *took = 0;
    if (id >= maxPorts_) return kIOReturnBadArgument;
    uint64_t deadline;
    clock_interval_to_deadline(timeoutMs, kMillisecondScale, &deadline);
    IOLockLock(lock_);
    Port &p = ports_[id];
    while (*took < len) {
        if (!up_ || !p.added || !p.guestOpen) {
            IOLockUnlock(lock_);
            return *took ? kIOReturnSuccess : kIOReturnNotOpen;
        }
        serviceQueues();
        if (!p.txFree) {   // all in flight: QEMU completes them as the host reads, or drops them if it hung up
            if (IOLockSleepDeadline(lock_, &wake_, deadline, THREAD_ABORTSAFE) != THREAD_AWAKENED) {
                serviceQueues();
                if (!p.txFree) break;
            }
            continue;
        }
        unsigned b = 0;
        while (b < kTxBufs && p.txBusy[b]) b++;
        uint32_t n = len - *took < kTxSize ? len - *took : kTxSize;
        memcpy(p.tx.va + b * kTxSize, buf + *took, n);
        virtio::Segment s = {p.tx.phys + b * kTxSize, n, false};
        int d = p.txq->submit(&s, 1);
        if (d < 0) break;
        p.txOfDesc[d] = (uint8_t)b;
        p.txBusy[b] = true;
        p.txFree--;
        p.txBytes += n;
        *took += n;
        transport_.notify(p.txq);
    }
    IOLockUnlock(lock_);
    return kIOReturnSuccess;
}

bool VeneraConsole::hostOpen(uint32_t id) {
    IOLockLock(lock_);
    bool o = id < maxPorts_ && ports_[id].hostOpen;
    IOLockUnlock(lock_);
    return o;
}

void VeneraConsole::counts(uint32_t id, uint64_t *rx, uint64_t *tx) {
    IOLockLock(lock_);
    *rx = id < maxPorts_ ? ports_[id].rxBytes : 0;
    *tx = id < maxPorts_ ? ports_[id].txBytes : 0;
    IOLockUnlock(lock_);
}

// ---- the user client ----------------------------------------------------------------------------------------------

class VeneraConsoleUserClient : public IOUserClient {
    OSDeclareDefaultStructors(VeneraConsoleUserClient);

public:
    bool initWithTask(task_t owningTask, void *securityID, UInt32 type) override;
    bool start(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn clientDied() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args, IOExternalMethodDispatch *dispatch,
                            OSObject *target, void *reference) override;

private:
    void closeDown();
    VeneraConsole *drv_ = nullptr;
    int32_t port_ = -1;
    bool admin_ = false;
    volatile SInt32 closed_ = 0;
};

OSDefineMetaClassAndStructors(VeneraConsoleUserClient, IOUserClient);

bool VeneraConsoleUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type) {
    if (!IOUserClient::initWithTask(owningTask, securityID, type)) {
        return false;
    }
    admin_ = clientHasPrivilege(owningTask, kIOClientPrivilegeAdministrator) == kIOReturnSuccess;
    // anyone else: only the user logged in at the console (and only ports other than the agent's, at open)
    return admin_ || clientHasPrivilege(owningTask, kIOClientPrivilegeLocalUser) == kIOReturnSuccess;
}

bool VeneraConsoleUserClient::start(IOService *provider) {
    drv_ = OSDynamicCast(VeneraConsole, provider);
    return drv_ && IOUserClient::start(provider);
}

void VeneraConsoleUserClient::closeDown() {
    if (!OSCompareAndSwap(0, 1, &closed_)) return;
    if (drv_ && port_ >= 0) {
        drv_->close((uint32_t)port_, this);
    }
    port_ = -1;
}

IOReturn VeneraConsoleUserClient::clientClose() {
    closeDown();
    terminate();
    return kIOReturnSuccess;
}

IOReturn VeneraConsoleUserClient::clientDied() {
    closeDown();
    return IOUserClient::clientDied();
}

IOReturn VeneraConsoleUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *a,
                                                 IOExternalMethodDispatch *, OSObject *, void *) {
    constexpr uint32_t kMaxIO = 1u << 20;
    if (closed_) return kIOReturnNotOpen;
    switch (selector) {
    case kVCMethodPorts: {
        VCPortInfo info[kVCMaxPorts] = {};
        unsigned n = drv_->ports(info, kVCMaxPorts);
        uint32_t bytes = n * (uint32_t)sizeof(VCPortInfo);
        if (a->structureOutputDescriptor) return kIOReturnBadArgument;
        if (a->structureOutputSize < bytes) bytes = a->structureOutputSize / sizeof(VCPortInfo) * sizeof(VCPortInfo);
        memcpy(a->structureOutput, info, bytes);
        a->structureOutputSize = bytes;
        return kIOReturnSuccess;
    }
    case kVCMethodOpen: {
        if (port_ >= 0 || !a->structureInput || a->structureInputSize == 0 || a->structureInputSize > 56 ||
            a->scalarOutputCount < 1) {
            return kIOReturnBadArgument;
        }
        char name[57] = {};
        memcpy(name, a->structureInput, a->structureInputSize);
        if (!admin_ && !strncmp(name, "org.qemu.guest_agent", 20)) {
            return kIOReturnNotPrivileged;   // the host's agent port runs commands as root: only root may hold it
        }
        uint32_t id = 0;
        IOReturn rc = drv_->open(name, this, &id);
        if (rc == kIOReturnSuccess) {
            port_ = (int32_t)id;
            a->scalarOutput[0] = id;
        }
        return rc;
    }
    case kVCMethodRead: {
        if (port_ < 0 || a->scalarInputCount < 1 || a->scalarOutputCount < 1) return kIOReturnBadArgument;
        uint32_t cap = a->structureOutputDescriptor ? (uint32_t)a->structureOutputDescriptor->getLength()
                                                    : a->structureOutputSize;
        if (cap > kMaxIO) cap = kMaxIO;
        if (cap == 0) return kIOReturnBadArgument;
        uint32_t timeout = (uint32_t)(a->scalarInput[0] > 60000 ? 60000 : a->scalarInput[0]);
        uint8_t *tmp = a->structureOutputDescriptor ? static_cast<uint8_t *>(IOMalloc(cap))
                                                    : static_cast<uint8_t *>(a->structureOutput);
        if (!tmp) return kIOReturnNoMemory;
        uint32_t got = 0;
        IOReturn rc = drv_->read((uint32_t)port_, tmp, cap, timeout, &got);
        if (a->structureOutputDescriptor) {
            if (rc == kIOReturnSuccess && got) {
                IOMemoryDescriptor *md = a->structureOutputDescriptor;
                if (md->prepare() == kIOReturnSuccess) {
                    md->writeBytes(0, tmp, got);
                    md->complete();
                } else {
                    rc = kIOReturnVMError;
                }
            }
            IOFree(tmp, cap);
            a->structureOutputDescriptorSize = got;
        } else {
            a->structureOutputSize = got;
        }
        a->scalarOutput[0] = got;
        return rc;
    }
    case kVCMethodWrite: {
        if (port_ < 0 || a->scalarInputCount < 1 || a->scalarOutputCount < 1) return kIOReturnBadArgument;
        uint32_t timeout = (uint32_t)(a->scalarInput[0] > 60000 ? 60000 : a->scalarInput[0]);
        const uint8_t *src = static_cast<const uint8_t *>(a->structureInput);
        uint32_t len = a->structureInputSize;
        uint8_t *tmp = nullptr;
        if (a->structureInputDescriptor) {
            IOMemoryDescriptor *md = a->structureInputDescriptor;
            len = (uint32_t)(md->getLength() > kMaxIO ? kMaxIO : md->getLength());
            tmp = static_cast<uint8_t *>(IOMalloc(len));
            if (!tmp) return kIOReturnNoMemory;
            if (md->prepare() != kIOReturnSuccess) {
                IOFree(tmp, len);
                return kIOReturnVMError;
            }
            md->readBytes(0, tmp, len);
            md->complete();
            src = tmp;
        }
        uint32_t took = 0;
        IOReturn rc = len ? drv_->write((uint32_t)port_, src, len, timeout, &took) : kIOReturnSuccess;
        if (tmp) IOFree(tmp, len);
        a->scalarOutput[0] = took;
        return rc;
    }
    case kVCMethodState: {
        if (port_ < 0 || a->scalarOutputCount < 3) return kIOReturnBadArgument;
        uint64_t rx, tx;
        drv_->counts((uint32_t)port_, &rx, &tx);
        a->scalarOutput[0] = drv_->hostOpen((uint32_t)port_);
        a->scalarOutput[1] = rx;
        a->scalarOutput[2] = tx;
        return kIOReturnSuccess;
    }
    default:
        return kIOReturnUnsupported;
    }
}
