// VeneraVideo: hardware video decoding for macOS on Venera, through Apple's own paravirtualized VideoToolbox.
//
// Intel macOS ships every part of VideoToolbox's paravirtualized video (the guest decoder, the protocol, the
// support framework that talks to a driver) except the driver: AppleVideoToolboxParavirtualization.kext has an
// Info.plist and no code. This kext is that driver, under Apple's class names, so the support framework finds it:
//
//   AppleVideoToolboxParavirtualizationDriver   on QEMU's ivshmem-doorbell device (1af4:1110): BAR0 registers
//                                               (Doorbell, IVPosition), BAR2 the memory shared with the host's
//                                               venera-videod (hostvideo/src/vv_shm.h: two rings, frame slots),
//                                               MSI-X vector 0 when the host has put records in its ring.
//   AppleVideoToolboxParavirtualizationUserClient   one per process (VideoToolboxParavirtualizationSupport.framework),
//                                               methods as that framework calls them:
//      0  scalar  in: the send buffer size wanted   out: its capacity, its address, the message queue's address
//      1  struct  in: a 16-byte UUID (a guest object of this process; host messages for it come here)
//      2  struct  in: a UUID going away
//      3  scalar  in: a message's length (in the send buffer), up to five IOSurface IDs   out: 0
//      4  scalar  the process has drained its queue (if anything came meanwhile, it is told again)
//      and the queue's notification port (IOConnectSetNotificationPort type 0).
//
// The process is told of every message, not only of the first into an empty queue as IODataQueue does: its reader
// drains once per notification, so a message that lands while it drains would wait for the reply clerk's 1 s
// timeout -- and after a burst (the host back from a restart) every reply did, a frame a second from then on.
//
// Messages go to the host as they are, with the IOSurfaces they name described (and kept: an output buffer comes
// back in a "fill" order -- copy frame slot N into surface S -- before the message that hands it to VideoToolbox).
//
// It loads from OpenCore (the boot kernel collection), not the Auxiliary KC: AppleVirtIO's PCI transport matches every
// device of the virtio vendor (1af4), ivshmem's too, and hangs on it -- a driver loaded later never gets the device.
// At boot, this one's probe score wins.
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IODataQueue.h>
#include <IOKit/IODataQueueShared.h>
#include <IOKit/IOFilterInterruptEventSource.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <libkern/OSAtomic.h>

#include "../../hostvideo/src/vv_shm.h"

// IOSurface's kernel interface (com.apple.iokit.IOSurface exports these): declarations only.
class IOSurface : public OSObject {
public:
    IOMemoryDescriptor *getMemoryDescriptor() const;
    unsigned int getPlaneCount() const;
    unsigned long long getPlaneOffset(unsigned int) const;
    unsigned long long getPlaneBytesPerRow(unsigned int) const;
    unsigned long long getPlaneWidth(unsigned int) const;
    unsigned long long getPlaneHeight(unsigned int) const;
    unsigned long long getWidth() const;
    unsigned long long getHeight() const;
    unsigned int getPixelFormat() const;
    unsigned int getSurfaceID() const;
    unsigned long long getAllocSize() const;
    IOReturn lockSurface(unsigned int options, unsigned int *seed);
    IOReturn unlockSurface(unsigned int options, unsigned int *seed);
};
class IOSurfaceRoot : public IOService {
public:
    IOSurface *lookupSurface(unsigned int id, task *t);   // retained, or NULL
};

#define LOG(fmt, ...) IOLog("VeneraVideo: " fmt "\n", ##__VA_ARGS__)
static constexpr UInt32 kTypeWaitsProperly = 0x76776678;   // 'vwfx' (VGMTLVTFix.m)

class AppleVideoToolboxParavirtualizationUserClient;

class AppleVideoToolboxParavirtualizationDriver : public IOService {
    OSDeclareDefaultStructors(AppleVideoToolboxParavirtualizationDriver)

public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    // for the user clients
    IOReturn sendMessage(AppleVideoToolboxParavirtualizationUserClient *c, const uint8_t *msg, uint32_t len,
                         const uint32_t *surfaceIDs, unsigned n, task_t task, bool waitsProperly);
    // Processes whose VideoToolbox waits for an answer properly (Venera's Metal driver corrected its reply wait,
    // VGMTLVTFix.m, and holds a marker client of type kTypeWaitsProperly open): their synchronous decodes aren't held
    // and are marked for the host.
    void markTask(task_t t, bool on);
    bool waitsProperly(task_t t);
    void uuidGone(const uint8_t *uuid);
    void addClient(AppleVideoToolboxParavirtualizationUserClient *c);
    void removeClient(AppleVideoToolboxParavirtualizationUserClient *c);

private:
    struct Surface {
        uint32_t id;
        IOSurface *surface;
        IOMemoryMap *map;   // the surface's memory in the kernel, made at its first fill
        AppleVideoToolboxParavirtualizationUserClient *owner;
        uint64_t used;
    };
    static constexpr unsigned kMaxSurfaces = 96, kMaxClients = 64;

    bool interruptFilter(IOFilterInterruptEventSource *);
    void interruptOccurred(IOInterruptEventSource *, int);
    void timerFired(IOTimerEventSource *);
    void drain();
    void fill(const vv_rec *r, bool pull);
    int putG2H(uint16_t kind, const uint32_t *args, const void *a, uint32_t na, const void *b, uint32_t nb);
    void doorbell();
    Surface *keepSurface(uint32_t id, task_t task, AppleVideoToolboxParavirtualizationUserClient *owner);
    void dropSurface(Surface *s);

    IOPCIDevice *pci_ = nullptr;
    IOMemoryMap *regs_ = nullptr, *mem_ = nullptr;
    volatile uint8_t *shm_ = nullptr;
    vv_ctl *ctl_ = nullptr;
    IOWorkLoop *wl_ = nullptr;
    IOFilterInterruptEventSource *irq_ = nullptr;
    IOTimerEventSource *timer_ = nullptr;
    IOLock *g2hLock_ = nullptr, *lock_ = nullptr;   // the guest-to-host ring; clients and surfaces
    IOSurfaceRoot *root_ = nullptr;
    AppleVideoToolboxParavirtualizationUserClient *clients_[kMaxClients] = {};
    Surface surfaces_[kMaxSurfaces] = {};
    uint64_t useClock_ = 0;
    uint32_t hostGen_ = 0;
    uint64_t stats_[6] = {};   // messages out, messages in, fills, fill failures, dropped (no client), ring full
    task_t properTasks_[kMaxClients] = {};
};

class AppleVideoToolboxParavirtualizationUserClient : public IOUserClient {
    OSDeclareDefaultStructors(AppleVideoToolboxParavirtualizationUserClient)

public:
    bool initWithTask(task_t owningTask, void *securityID, UInt32 type) override;
    bool start(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn clientDied() override;
    void free() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args, IOExternalMethodDispatch *dispatch,
                            OSObject *target, void *reference) override;
    IOReturn registerNotificationPort(mach_port_t port, UInt32 type, io_user_reference_t refCon) override;

    bool owns(const uint8_t *uuid);
    void deliver(const uint8_t *msg, uint32_t len);   // a host message for one of our UUIDs
    task_t task() const { return task_; }

private:
    void closeDown();
    static constexpr unsigned kMaxUUIDs = 64;
    AppleVideoToolboxParavirtualizationDriver *drv_ = nullptr;
    task_t task_ = nullptr;
    IOLock *lock_ = nullptr;
    class VeneraVideoDataQueue *queue_ = nullptr;
    IOMemoryMap *queueMap_ = nullptr;
    IOBufferMemoryDescriptor *send_ = nullptr;
    IOMemoryMap *sendMap_ = nullptr;
    uint8_t uuids_[kMaxUUIDs][16] = {};
    unsigned nuuids_ = 0;
    bool closed_ = false;
    bool marker_ = false;   // a kTypeWaitsProperly client: marks its task, nothing else
    // A request whose answer this process must have in hand before its send returns (see waitsForReply): its number,
    // and 0 waiting, 1 the answer queued, 2 the process has drained its queue since (VideoToolbox has it)
    bool waiting_ = false;
    uint64_t waitReq_ = 0;
    int waitState_ = 0;
    // Host requests that came for this process while it was held, queued after the awaited answer. The process's
    // drain answers a request before it takes the next message, and every send in the process takes one lock
    // (VTParavirtualizationGuestSupportSendRawMessageToHost holds it across method 3): the held thread has it, so the
    // drain would wait for that thread, which waits for the answer behind the request. Messages that need no answer
    // (answers, an encoded frame: venera-videod sends those as plain messages) keep their place, so an encoded frame
    // reaches the app before the answer to the CompleteFrames that waits for it.
    struct Deferred {
        Deferred *next;
        uint32_t len;
        uint8_t msg[];
    };
    Deferred *deferred_ = nullptr, **deferredTail_ = &deferred_;
    void flushDeferred();   // with lock_ held
};

// Intel VideoToolbox's reply wait turns its timeout into nanoseconds in a 32-bit int (cvttsd2si, 26.7.3), so a timeout
// over ~2.1 s overflows to a deadline in the past, and the wait succeeds only if the answer was already delivered. The
// encoder's efrm and ecfr wait 10 s, and so does a synchronous decode's dfrm: without help every such frame fails at
// once (-19092). For those, the send holds the process until the host's answer is in its queue and the process has
// drained it (its drain calls method 4 after handing each message to VideoToolbox), at most 2 s. Apple's own hosts
// never met this: Intel Macs encode on their own hardware.
// held sends: done, ran out with no answer queued, ran out with the answer queued but not drained
static volatile SInt64 gHolds[3], gHoldsBusy[3];   // gHoldsBusy: the same, for holds begun with the queue not empty
static bool waitsForReply(const uint8_t *msg, uint32_t len) {
    if (len < 48) {
        return false;
    }
    uint32_t flags = (uint32_t)msg[12] << 24 | (uint32_t)msg[13] << 16 | (uint32_t)msg[14] << 8 | msg[15];
    if (!(flags & 1)) {
        return false;
    }
    if (!memcmp(msg + 8, "efrm", 4) || !memcmp(msg + 8, "ecfr", 4)) {
        return true;
    }
    if (memcmp(msg + 8, "dfrm", 4)) {
        return false;
    }
    // a frame to decode: held only when decoded synchronously (its dfl lacks EnableAsynchronousDecompression), where
    // VideoToolbox waits for the answer; an asynchronous decode doesn't, and holding it would cost every frame a trip
    static const char key[] = "para,dfl=u32";
    const uint32_t kl = sizeof(key) - 1;
    for (uint32_t i = 48; i + 8 <= len;) {
        uint32_t size = (uint32_t)msg[i] << 24 | (uint32_t)msg[i + 1] << 16 | (uint32_t)msg[i + 2] << 8 | msg[i + 3];
        if (size < 8 || size > len - i) {
            break;
        }
        if (size == 4 + kl + 4 && !memcmp(msg + i + 4, key, kl)) {
            return !(msg[i + 4 + kl + 3] & 1);
        }
        i += size;
    }
    return false;
}
static uint64_t msgReq(const uint8_t *msg) {
    uint64_t r = 0;
    for (int i = 0; i < 8; i++) {
        r = r << 8 | msg[40 + i];
    }
    return r;
}

OSDefineMetaClassAndStructors(AppleVideoToolboxParavirtualizationDriver, IOService)
OSDefineMetaClassAndStructors(AppleVideoToolboxParavirtualizationUserClient, IOUserClient)

// ---- the driver ----------------------------------------------------------------------------------------------------

bool AppleVideoToolboxParavirtualizationDriver::start(IOService *provider) {
    if (!IOService::start(provider)) {
        return false;
    }
    pci_ = OSDynamicCast(IOPCIDevice, provider);
    if (!pci_) {
        return false;
    }
    pci_->retain();
    pci_->setMemoryEnable(true);
    pci_->setBusMasterEnable(true);
    regs_ = pci_->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0);
    IODeviceMemory *bar2 = pci_->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress2);
    if (bar2) {
        mem_ = bar2->map(kIOMapCopybackCache);   // RAM on the host: cached, as any RAM
        if (!mem_) {
            mem_ = bar2->map();
        }
    }
    if (!regs_ || !mem_ || mem_->getLength() < VV_SHM_SIZE) {
        LOG("ivshmem BARs missing or too small (%llu bytes shared)", mem_ ? (unsigned long long)mem_->getLength() : 0ull);
        return false;
    }
    shm_ = reinterpret_cast<volatile uint8_t *>(mem_->getVirtualAddress());
    ctl_ = (vv_ctl *)shm_;
    uint32_t pos = *(volatile uint32_t *)(regs_->getVirtualAddress() + 8);
    LOG("ivshmem: our peer id %u, %llu MB shared, host memory %s (magic 0x%x version %u)", pos,
        (unsigned long long)mem_->getLength() >> 20, ctl_->magic == VV_MAGIC ? "set up" : "NOT set up", ctl_->magic,
        ctl_->version);
    if (ctl_->magic != VV_MAGIC || ctl_->version != VV_VERSION) {
        return false;
    }
    lock_ = IOLockAlloc();
    g2hLock_ = IOLockAlloc();
    wl_ = IOWorkLoop::workLoop();
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
    irq_ = IOFilterInterruptEventSource::filterInterruptEventSource(
        this, OSMemberFunctionCast(IOInterruptEventAction, this, &AppleVideoToolboxParavirtualizationDriver::interruptOccurred),
        OSMemberFunctionCast(IOFilterInterruptAction, this, &AppleVideoToolboxParavirtualizationDriver::interruptFilter), pci_,
        index < 0 ? 0 : index);
    timer_ = IOTimerEventSource::timerEventSource(
        this, OSMemberFunctionCast(IOTimerEventSource::Action, this, &AppleVideoToolboxParavirtualizationDriver::timerFired));
    if (!wl_ || !irq_ || !timer_ || wl_->addEventSource(irq_) != kIOReturnSuccess ||
        wl_->addEventSource(timer_) != kIOReturnSuccess) {
        LOG("work loop setup failed");
        return false;
    }
    irq_->enable();
    hostGen_ = ctl_->host_gen;
    // a fresh start: the guest's side of both rings
    OSIncrementAtomic((volatile SInt32 *)&ctl_->guest_gen);
    __sync_synchronize();
    ctl_->h2g.tail = ctl_->h2g.head;
    ctl_->g2h.head = ctl_->g2h.tail;
    ctl_->guest_features = VV_GF_ENCODE | VV_GF_SPAN;   // here too, for a host that (re)starts after the hello
    uint32_t a[6] = {ctl_->guest_gen, VV_GF_ENCODE | VV_GF_SPAN, 0, 0, 0, 0};
    putG2H(VV_G_HELLO, a, nullptr, 0, nullptr, 0);
    doorbell();
    timer_->setTimeoutMS(100);
    setProperty("IOUserClientClass", "AppleVideoToolboxParavirtualizationUserClient");
    registerService();
    LOG("ready (interrupt index %d%s)", index < 0 ? 0 : index, index < 0 ? ", INTx" : ", MSI-X");
    return true;
}

void AppleVideoToolboxParavirtualizationDriver::stop(IOService *provider) {
    if (timer_) {
        timer_->cancelTimeout();
    }
    if (irq_) {
        irq_->disable();
    }
    IOService::stop(provider);
}

void AppleVideoToolboxParavirtualizationDriver::free() {
    for (unsigned i = 0; i < kMaxSurfaces; i++) {
        dropSurface(&surfaces_[i]);
    }
    if (wl_) {
        if (irq_) {
            wl_->removeEventSource(irq_);
        }
        if (timer_) {
            wl_->removeEventSource(timer_);
        }
    }
    OSSafeReleaseNULL(irq_);
    OSSafeReleaseNULL(timer_);
    OSSafeReleaseNULL(wl_);
    OSSafeReleaseNULL(regs_);
    OSSafeReleaseNULL(mem_);
    OSSafeReleaseNULL(root_);
    OSSafeReleaseNULL(pci_);
    if (lock_) {
        IOLockFree(lock_);
    }
    if (g2hLock_) {
        IOLockFree(g2hLock_);
    }
    IOService::free();
}

bool AppleVideoToolboxParavirtualizationDriver::interruptFilter(IOFilterInterruptEventSource *) { return true; }
void AppleVideoToolboxParavirtualizationDriver::interruptOccurred(IOInterruptEventSource *, int) { drain(); }
void AppleVideoToolboxParavirtualizationDriver::timerFired(IOTimerEventSource *t) {
    drain();   // in case an interrupt was missed
    if (ctl_->host_gen != hostGen_) {
        LOG("the host restarted (run %u -> %u)", hostGen_, ctl_->host_gen);
        hostGen_ = ctl_->host_gen;
    }
    static unsigned n;
    if (++n % 50 == 0) {   // every 5 s
        char s[300];
        snprintf(s, sizeof(s), "out %llu, in %llu, fills %llu (failed %llu), undeliverable %llu, ring full %llu, holds %lld "
                 "(no answer %lld, not drained %lld); begun busy %lld (%lld, %lld)", stats_[0], stats_[1], stats_[2], stats_[3],
                 stats_[4], stats_[5], gHolds[0], gHolds[1], gHolds[2], gHoldsBusy[0], gHoldsBusy[1], gHoldsBusy[2]);
        setProperty("VeneraVideoStats", s);
    }
    t->setTimeoutMS(100);
}

void AppleVideoToolboxParavirtualizationDriver::doorbell() {
    *(volatile uint32_t *)(regs_->getVirtualAddress() + 12) = (VV_HOST_PEER << 16) | 0;
}

int AppleVideoToolboxParavirtualizationDriver::putG2H(uint16_t kind, const uint32_t *args, const void *a, uint32_t na,
                                                      const void *b, uint32_t nb) {
    vv_ring *r = &ctl_->g2h;
    volatile uint8_t *base = shm_ + VV_G2H_OFF;
    uint32_t len = na + nb, need = VV_ALIGN((uint32_t)sizeof(vv_rec) + len);
    if (need > VV_G2H_SIZE / 2) {
        return -1;
    }
    for (int tries = 0;; tries++) {
        uint32_t head = r->head, tail = __atomic_load_n(&r->tail, __ATOMIC_ACQUIRE);
        uint32_t off = head % VV_G2H_SIZE, toend = VV_G2H_SIZE - off;
        bool wrap = toend < need;
        uint32_t want = wrap ? toend + need : need;
        if (VV_G2H_SIZE - (head - tail) >= want) {
            if (wrap) {
                vv_rec *pad = (vv_rec *)(base + off);
                bzero(pad, sizeof(*pad));
                pad->len = toend - (uint32_t)sizeof(vv_rec);
                pad->kind = VV_PAD;
                head += toend;
                off = 0;
            }
            vv_rec *rec = (vv_rec *)(base + off);
            bzero(rec, sizeof(*rec));
            rec->len = len;
            rec->kind = kind;
            if (args) {
                memcpy(rec->arg, args, sizeof(rec->arg));
            }
            if (na) {
                memcpy((uint8_t *)(rec + 1), a, na);
            }
            if (nb) {
                memcpy((uint8_t *)(rec + 1) + na, b, nb);
            }
            __atomic_store_n(&r->head, head + need, __ATOMIC_RELEASE);
            return 0;
        }
        if (tries == 0) {
            OSIncrementAtomic64((volatile SInt64 *)&stats_[5]);
            doorbell();
        }
        if (tries > 400) {   // ~2 s: the host isn't reading
            return -1;
        }
        IOSleep(5);
    }
}

AppleVideoToolboxParavirtualizationDriver::Surface *
AppleVideoToolboxParavirtualizationDriver::keepSurface(uint32_t id, task_t task, AppleVideoToolboxParavirtualizationUserClient *owner) {
    Surface *slot = nullptr, *oldest = nullptr;
    for (unsigned i = 0; i < kMaxSurfaces; i++) {
        Surface *s = &surfaces_[i];
        if (s->surface && s->id == id) {
            s->used = ++useClock_;
            s->owner = owner;
            return s;
        }
        if (!s->surface && !slot) {
            slot = s;
        }
        if (s->surface && (!oldest || s->used < oldest->used)) {
            oldest = s;
        }
    }
    if (!root_) {   // found at first use: this driver starts at early boot, from OpenCore, before IOSurface
        OSDictionary *m = IOService::serviceMatching("IOSurfaceRoot");
        root_ = OSDynamicCast(IOSurfaceRoot, IOService::waitForMatchingService(m, 5ull * 1000000000ull));
        OSSafeReleaseNULL(m);
        if (!root_) {
            LOG("no IOSurfaceRoot");
            return nullptr;
        }
    }
    IOSurface *surf = root_->lookupSurface(id, task);
    if (!surf) {
        return nullptr;
    }
    if (!slot) {
        dropSurface(oldest);
        slot = oldest;
    }
    slot->id = id;
    slot->surface = surf;
    slot->map = nullptr;
    slot->owner = owner;
    slot->used = ++useClock_;
    return slot;
}

void AppleVideoToolboxParavirtualizationDriver::dropSurface(Surface *s) {
    if (!s || !s->surface) {
        return;
    }
    OSSafeReleaseNULL(s->map);
    s->surface->release();
    s->surface = nullptr;
    s->owner = nullptr;
    s->id = 0;
}

IOReturn AppleVideoToolboxParavirtualizationDriver::sendMessage(AppleVideoToolboxParavirtualizationUserClient *c,
                                                                const uint8_t *msg, uint32_t len, const uint32_t *ids,
                                                                unsigned n, task_t task, bool waitsProperly) {
    vv_surf desc[5];
    unsigned ns = 0;
    IOLockLock(lock_);
    for (unsigned i = 0; i < n && i < 5; i++) {
        if (!ids[i]) {
            continue;
        }
        Surface *s = keepSurface(ids[i], task, c);
        if (!s) {
            LOG("surface %u: not found for this process", ids[i]);
            continue;
        }
        vv_surf *d = &desc[ns++];
        bzero(d, sizeof(*d));
        d->id = ids[i];
        d->format = s->surface->getPixelFormat();
        d->width = (uint32_t)s->surface->getWidth();
        d->height = (uint32_t)s->surface->getHeight();
        d->planes = s->surface->getPlaneCount();
        for (unsigned p = 0; p < 2 && p < d->planes; p++) {
            d->plane_bpr[p] = (uint32_t)s->surface->getPlaneBytesPerRow(p);
        }
    }
    IOLockUnlock(lock_);
    uint32_t a[6] = {ns, len, waitsProperly ? VV_MSG_WAITS_PROPERLY : 0u, 0, 0, 0};
    IOLockLock(g2hLock_);
    int rc = putG2H(VV_G_MSG, a, desc, ns * (uint32_t)sizeof(vv_surf), msg, len);
    IOLockUnlock(g2hLock_);
    if (rc) {
        return kIOReturnNoSpace;
    }
    OSIncrementAtomic64((volatile SInt64 *)&stats_[0]);
    doorbell();
    return kIOReturnSuccess;
}

void AppleVideoToolboxParavirtualizationDriver::markTask(task_t t, bool on) {
    IOLockLock(lock_);
    for (unsigned i = 0; i < kMaxClients; i++) {
        if (on ? !properTasks_[i] : properTasks_[i] == t) {
            properTasks_[i] = on ? t : nullptr;
            break;
        }
    }
    IOLockUnlock(lock_);
}

bool AppleVideoToolboxParavirtualizationDriver::waitsProperly(task_t t) {
    IOLockLock(lock_);
    bool yes = false;
    for (unsigned i = 0; i < kMaxClients && !yes; i++) {
        yes = properTasks_[i] == t;
    }
    IOLockUnlock(lock_);
    return yes;
}

void AppleVideoToolboxParavirtualizationDriver::uuidGone(const uint8_t *uuid) {
    IOLockLock(g2hLock_);
    putG2H(VV_G_UUIDGONE, nullptr, uuid, 16, nullptr, 0);
    IOLockUnlock(g2hLock_);
    doorbell();
}

void AppleVideoToolboxParavirtualizationDriver::addClient(AppleVideoToolboxParavirtualizationUserClient *c) {
    IOLockLock(lock_);
    for (unsigned i = 0; i < kMaxClients; i++) {
        if (!clients_[i]) {
            clients_[i] = c;
            break;
        }
    }
    IOLockUnlock(lock_);
}

void AppleVideoToolboxParavirtualizationDriver::removeClient(AppleVideoToolboxParavirtualizationUserClient *c) {
    IOLockLock(lock_);
    for (unsigned i = 0; i < kMaxClients; i++) {
        if (clients_[i] == c) {
            clients_[i] = nullptr;
        }
    }
    for (unsigned i = 0; i < kMaxSurfaces; i++) {
        if (surfaces_[i].surface && surfaces_[i].owner == c) {
            dropSurface(&surfaces_[i]);
        }
    }
    IOLockUnlock(lock_);
}

// Copy slot r->arg[1] into the IOSurface r->arg[0], then tell the host the slot is free. A frame bigger than a slot
// runs on into the next ones (VV_GF_SPAN), up to the last.
// A fill order (slot -> IOSurface: a decoded frame) or a pull order (IOSurface -> slot: a frame to encode).
void AppleVideoToolboxParavirtualizationDriver::fill(const vv_rec *r, bool pull) {
    uint32_t id = r->arg[0], slot = r->arg[1], w = r->arg[2], h = r->arg[3], stride = r->arg[4], bps = r->arg[5];
    uint32_t err = 1;
    IOLockLock(lock_);
    Surface *s = nullptr;
    for (unsigned i = 0; i < kMaxSurfaces; i++) {
        if (surfaces_[i].surface && surfaces_[i].id == id) {
            s = &surfaces_[i];
        }
    }
    if (s && slot < VV_NSLOTS && bps >= 1 && bps <= 2 &&
        (uint64_t)stride * h * 3 / 2 <= (uint64_t)(VV_NSLOTS - slot) * VV_SLOT_SIZE) {
        IOSurface *surf = s->surface;
        if (!s->map) {
            IOMemoryDescriptor *md = surf->getMemoryDescriptor();
            if (md) {
                s->map = md->createMappingInTask(kernel_task, 0, kIOMapAnywhere);
            }
        }
        if (s->map && surf->getPlaneCount() >= 2) {
            uint8_t *base = (uint8_t *)s->map->getVirtualAddress();
            uint64_t size = s->map->getLength();
            uint8_t *slotp = (uint8_t *)(shm_ + VV_SLOT_OFF + (uint64_t)slot * VV_SLOT_SIZE);
            unsigned int seed = 0;
            surf->lockSurface(pull ? 1 : 0, &seed);   // 1: read-only
            bool ok = true;
            for (unsigned p = 0; p < 2 && ok; p++) {
                uint64_t off = surf->getPlaneOffset(p), bpr = surf->getPlaneBytesPerRow(p);
                uint64_t rows = surf->getPlaneHeight(p), rh = p ? h / 2 : h;
                uint64_t rowBytes = (uint64_t)w * bps;
                if (rows < rh) {
                    rh = rows;
                }
                if (rowBytes > bpr) {
                    rowBytes = bpr;
                }
                if (off + bpr * (rh ? rh - 1 : 0) + rowBytes > size) {
                    ok = false;
                    break;
                }
                uint8_t *packed = slotp + (p ? (uint64_t)stride * h : 0);
                for (uint64_t y = 0; y < rh; y++) {
                    if (pull) {
                        memcpy(packed + y * stride, base + off + y * bpr, rowBytes);
                    } else {
                        memcpy(base + off + y * bpr, packed + y * stride, rowBytes);
                    }
                }
            }
            surf->unlockSurface(pull ? 1 : 0, &seed);
            err = ok ? 0 : 2;
        }
        s->used = ++useClock_;
    }
    IOLockUnlock(lock_);
    OSIncrementAtomic64((volatile SInt64 *)&stats_[err ? 3 : 2]);
    uint32_t a[6] = {slot, err, id, 0, 0, 0};
    IOLockLock(g2hLock_);
    putG2H(pull ? VV_G_PULLDONE : VV_G_SLOTDONE, a, nullptr, 0, nullptr, 0);
    IOLockUnlock(g2hLock_);
}

// Everything the host has put in its ring (on the work loop).
void AppleVideoToolboxParavirtualizationDriver::drain() {
    vv_ring *r = &ctl_->h2g;
    volatile uint8_t *base = shm_ + VV_H2G_OFF;
    bool any = false;
    for (;;) {
        uint32_t tail = r->tail, head = __atomic_load_n(&r->head, __ATOMIC_ACQUIRE);
        if (tail == head) {
            break;
        }
        const vv_rec *rec = (const vv_rec *)(base + tail % VV_H2G_SIZE);
        if (rec->len > VV_H2G_SIZE) {
            LOG("host ring corrupt; dropping it");
            __atomic_store_n(&r->tail, head, __ATOMIC_RELEASE);
            break;
        }
        uint32_t step = VV_ALIGN((uint32_t)sizeof(vv_rec) + rec->len);
        if (rec->kind == VV_H_MSG && rec->len >= 48) {
            const uint8_t *msg = (const uint8_t *)(rec + 1);
            AppleVideoToolboxParavirtualizationUserClient *to = nullptr;
            IOLockLock(lock_);
            for (unsigned i = 0; i < kMaxClients && !to; i++) {
                if (clients_[i] && clients_[i]->owns(msg + 16)) {
                    to = clients_[i];
                    to->retain();
                }
            }
            IOLockUnlock(lock_);
            if (to) {
                to->deliver(msg, rec->len);
                to->release();
                OSIncrementAtomic64((volatile SInt64 *)&stats_[1]);
            } else {
                OSIncrementAtomic64((volatile SInt64 *)&stats_[4]);
            }
        } else if (rec->kind == VV_H_FILL || rec->kind == VV_H_PULL) {
            fill(rec, rec->kind == VV_H_PULL);
            any = true;
        }
        __atomic_store_n(&r->tail, tail + step, __ATOMIC_RELEASE);
    }
    if (any) {
        doorbell();
    }
}

// ---- the user client -----------------------------------------------------------------------------------------------

// IODataQueue with its notification and emptiness reachable.
class VeneraVideoDataQueue : public IODataQueue {
    OSDeclareDefaultStructors(VeneraVideoDataQueue)
public:
    static VeneraVideoDataQueue *make(UInt32 size) {
        VeneraVideoDataQueue *q = OSTypeAlloc(VeneraVideoDataQueue);
        if (q && !q->initWithCapacity(size)) {
            q->release();
            q = nullptr;
        }
        return q;
    }
    void notify() { sendDataAvailableNotification(); }
    bool holdsData() const {
        return dataQueue && __atomic_load_n(&dataQueue->head, __ATOMIC_ACQUIRE) != __atomic_load_n(&dataQueue->tail, __ATOMIC_ACQUIRE);
    }
};
OSDefineMetaClassAndStructors(VeneraVideoDataQueue, IODataQueue)

bool AppleVideoToolboxParavirtualizationUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type) {
    if (!IOUserClient::initWithTask(owningTask, securityID, type)) {
        return false;
    }
    task_ = owningTask;
    marker_ = type == kTypeWaitsProperly;
    lock_ = IOLockAlloc();
    return lock_ != nullptr;
}

bool AppleVideoToolboxParavirtualizationUserClient::start(IOService *provider) {
    drv_ = OSDynamicCast(AppleVideoToolboxParavirtualizationDriver, provider);
    if (!drv_ || !IOUserClient::start(provider)) {
        return false;
    }
    if (marker_) {
        drv_->markTask(task_, true);
        return true;
    }
    queue_ = VeneraVideoDataQueue::make(256 * 1024);
    if (!queue_) {
        return false;
    }
    drv_->addClient(this);
    return true;
}

void AppleVideoToolboxParavirtualizationUserClient::closeDown() {
    IOLockLock(lock_);
    bool was = closed_;
    closed_ = true;
    IOLockWakeup(lock_, &waitState_, false);   // a held sender goes
    unsigned n = nuuids_;
    uint8_t uu[kMaxUUIDs][16];
    memcpy(uu, uuids_, sizeof(uu));
    nuuids_ = 0;
    IOLockUnlock(lock_);
    if (was || !drv_) {
        return;
    }
    if (marker_) {
        drv_->markTask(task_, false);
        return;
    }
    drv_->removeClient(this);
    for (unsigned i = 0; i < n; i++) {
        drv_->uuidGone(uu[i]);
    }
}

IOReturn AppleVideoToolboxParavirtualizationUserClient::clientClose() {
    closeDown();
    terminate();
    return kIOReturnSuccess;
}
IOReturn AppleVideoToolboxParavirtualizationUserClient::clientDied() {
    closeDown();
    return IOUserClient::clientDied();
}

void AppleVideoToolboxParavirtualizationUserClient::free() {
    closed_ = true;
    flushDeferred();   // closed: frees them
    OSSafeReleaseNULL(queueMap_);
    OSSafeReleaseNULL(queue_);
    OSSafeReleaseNULL(sendMap_);
    OSSafeReleaseNULL(send_);
    if (lock_) {
        IOLockFree(lock_);
    }
    IOUserClient::free();
}

bool AppleVideoToolboxParavirtualizationUserClient::owns(const uint8_t *uuid) {
    IOLockLock(lock_);
    bool yes = false;
    for (unsigned i = 0; i < nuuids_ && !yes; i++) {
        yes = !memcmp(uuids_[i], uuid, 16);
    }
    IOLockUnlock(lock_);
    return yes;
}

void AppleVideoToolboxParavirtualizationUserClient::flushDeferred() {
    bool any = deferred_ != nullptr;
    while (deferred_) {
        Deferred *d = deferred_;
        deferred_ = d->next;
        if (queue_ && !closed_ && !queue_->enqueue(d->msg, d->len)) {
            IOLog("VeneraVideo: a process's message queue is full; a host message was dropped\n");
        }
        IOFreeData(d, sizeof(Deferred) + d->len);
    }
    deferredTail_ = &deferred_;
    if (any && queue_ && !closed_) {
        queue_->notify();
    }
}

void AppleVideoToolboxParavirtualizationUserClient::deliver(const uint8_t *msg, uint32_t len) {
    IOLockLock(lock_);
    if (queue_ && !closed_) {
        bool awaited = waiting_ && waitState_ == 0 && len >= 48 && (msg[15] & 4) && msgReq(msg) == waitReq_;
        if (waiting_ && !awaited && len >= 48 && (msg[15] & 2)) {   // after the awaited answer (Deferred says why)
            Deferred *d = (Deferred *)IOMallocData(sizeof(Deferred) + len);
            if (d) {
                d->next = nullptr;
                d->len = len;
                memcpy(d->msg, msg, len);
                *deferredTail_ = d;
                deferredTail_ = &d->next;
                IOLockUnlock(lock_);
                return;
            }
        }
        if (!queue_->enqueue((void *)msg, len)) {
            IOLog("VeneraVideo: a process's message queue is full; a host message was dropped\n");
        } else if (awaited) {
            waitState_ = 1;
        }
        queue_->notify();   // every time (the header says why)
    }
    IOLockUnlock(lock_);
}

IOReturn AppleVideoToolboxParavirtualizationUserClient::registerNotificationPort(mach_port_t port, UInt32 type,
                                                                                  io_user_reference_t refCon) {
    if (!queue_) {
        return kIOReturnNotReady;
    }
    queue_->setNotificationPort(port);
    return kIOReturnSuccess;
}

IOReturn AppleVideoToolboxParavirtualizationUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *a,
                                                                        IOExternalMethodDispatch *, OSObject *, void *) {
    if (marker_) {
        return kIOReturnUnsupported;
    }
    switch (selector) {
    case 0: {   // the send buffer (at least the size asked for) and the message queue, mapped into the process
        if (a->scalarInputCount < 1 || a->scalarOutputCount < 3) {
            return kIOReturnBadArgument;
        }
        uint64_t want = a->scalarInput[0];
        if (want > 64ull << 20) {
            return kIOReturnNoMemory;
        }
        IOLockLock(lock_);
        IOReturn rc = kIOReturnSuccess;
        if (!send_ || send_->getLength() < want) {
            OSSafeReleaseNULL(sendMap_);
            OSSafeReleaseNULL(send_);
            uint64_t size = (want + 0xFFFF) & ~0xFFFFull;
            send_ = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task, kIODirectionInOut | kIOMemoryKernelUserShared,
                                                                size, page_size);
            sendMap_ = send_ ? send_->createMappingInTask(task_, 0, kIOMapAnywhere) : nullptr;
            if (!sendMap_) {
                rc = kIOReturnNoMemory;
            }
        }
        if (rc == kIOReturnSuccess && !queueMap_) {
            IOMemoryDescriptor *qd = queue_->getMemoryDescriptor();
            queueMap_ = qd ? qd->createMappingInTask(task_, 0, kIOMapAnywhere) : nullptr;
            OSSafeReleaseNULL(qd);
            if (!queueMap_) {
                rc = kIOReturnNoMemory;
            }
        }
        if (rc == kIOReturnSuccess) {
            a->scalarOutput[0] = send_->getLength();
            a->scalarOutput[1] = sendMap_->getAddress();
            a->scalarOutput[2] = queueMap_->getAddress();
            a->scalarOutputCount = 3;
        }
        IOLockUnlock(lock_);
        return rc;
    }
    case 1:
    case 2: {   // a guest UUID of this process, coming or going
        if (a->structureInputSize != 16 || !a->structureInput) {
            return kIOReturnBadArgument;
        }
        const uint8_t *u = (const uint8_t *)a->structureInput;
        IOLockLock(lock_);
        unsigned at = nuuids_;
        for (unsigned i = 0; i < nuuids_; i++) {
            if (!memcmp(uuids_[i], u, 16)) {
                at = i;
            }
        }
        IOReturn rc = kIOReturnSuccess;
        if (selector == 1 && at == nuuids_) {
            if (nuuids_ < kMaxUUIDs) {
                memcpy(uuids_[nuuids_++], u, 16);
            } else {
                rc = kIOReturnNoResources;
            }
        } else if (selector == 2 && at < nuuids_) {
            memcpy(uuids_[at], uuids_[--nuuids_], 16);
        }
        IOLockUnlock(lock_);
        if (selector == 2) {
            drv_->uuidGone(u);
        }
        return rc;
    }
    case 3: {   // send: the message in the send buffer, and the IOSurfaces it names
        if (a->scalarInputCount < 1) {
            return kIOReturnBadArgument;
        }
        uint64_t len = a->scalarInput[0];
        uint32_t ids[5] = {};
        unsigned n = 0;
        for (unsigned i = 1; i < a->scalarInputCount && n < 5; i++) {
            ids[n++] = (uint32_t)a->scalarInput[i];
        }
        IOLockLock(lock_);
        if (!send_ || len < 48 || len > send_->getLength()) {
            IOLockUnlock(lock_);
            return kIOReturnBadArgument;
        }
        // copied out of the shared buffer first: the process may write its next message meanwhile
        uint8_t *copy = (uint8_t *)IOMallocData(len);
        if (copy) {
            memcpy(copy, send_->getBytesNoCopy(), len);
        }
        IOLockUnlock(lock_);
        if (!copy) {
            return kIOReturnNoMemory;
        }
        // A synchronous decode from a process whose VideoToolbox waits properly isn't held: the hold keeps VideoToolbox's
        // queue from answering the frame, which then comes after the call (VGMTLVTFix.m); venera-videod answers it as
        // Apple's host does instead. The encoder's waits keep their hold.
        bool proper = drv_->waitsProperly(task_) && !memcmp(copy + 8, "dfrm", 4);
        bool hold = !proper && waitsForReply(copy, (uint32_t)len), busy = false;
        if (hold) {
            IOLockLock(lock_);
            waiting_ = true, waitReq_ = msgReq(copy), waitState_ = 0;
            busy = queue_ && queue_->holdsData();
            IOLockUnlock(lock_);
        }
        IOReturn rc = drv_->sendMessage(this, copy, (uint32_t)len, ids, n, task_, proper);
        IOFreeData(copy, len);
        if (hold) {   // until the answer is in VideoToolbox's hands (waitsForReply says why), 2 s at most
            uint64_t deadline;
            clock_interval_to_deadline(2000, kMillisecondScale, &deadline);
            IOLockLock(lock_);
            while (rc == kIOReturnSuccess && waitState_ < 2 && !closed_) {
                if (IOLockSleepDeadline(lock_, &waitState_, *(AbsoluteTime *)&deadline, THREAD_UNINT) == THREAD_TIMED_OUT) {
                    break;
                }
            }
            OSIncrementAtomic64(&(busy ? gHoldsBusy : gHolds)[waitState_ >= 2 ? 0 : waitState_ == 0 ? 1 : 2]);
            waiting_ = false;
            flushDeferred();
            IOLockUnlock(lock_);
        }
        if (a->scalarOutputCount >= 1) {
            a->scalarOutput[0] = rc == kIOReturnSuccess ? 0 : (uint64_t)(int64_t)-12911;
            a->scalarOutputCount = 1;
        }
        return kIOReturnSuccess;
    }
    case 4:   // the process drained its queue: anything that came meanwhile, it is told of again
        IOLockLock(lock_);
        // the awaited answer went to VideoToolbox, its sender may go on: only when the queue is empty, since a drain
        // that found it empty just before the answer came calls this too, with the answer still in the queue
        if (waiting_ && waitState_ == 1 && queue_ && !queue_->holdsData()) {
            waitState_ = 2;
            IOLockWakeup(lock_, &waitState_, false);
        }
        if (queue_ && !closed_ && queue_->holdsData()) {
            queue_->notify();
        }
        IOLockUnlock(lock_);
        return kIOReturnSuccess;
    default:
        return kIOReturnUnsupported;
    }
}
