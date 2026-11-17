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
//      4  scalar  the process has drained its queue
//      and the queue's notification port (IOConnectSetNotificationPort type 0).
//
// Messages go to the host as they are, with the IOSurfaces they name described (and kept: an output buffer comes
// back in a "fill" order -- copy frame slot N into surface S -- before the message that hands it to VideoToolbox).
//
// It loads from OpenCore (the boot kernel collection), not the Auxiliary KC: AppleVirtIO's PCI transport matches every
// device of the virtio vendor (1af4), ivshmem's too, and hangs on it -- a driver loaded later never gets the device.
// At boot, this one's probe score wins.
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IODataQueue.h>
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

class AppleVideoToolboxParavirtualizationUserClient;

class AppleVideoToolboxParavirtualizationDriver : public IOService {
    OSDeclareDefaultStructors(AppleVideoToolboxParavirtualizationDriver)

public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    // for the user clients
    IOReturn sendMessage(AppleVideoToolboxParavirtualizationUserClient *c, const uint8_t *msg, uint32_t len,
                         const uint32_t *surfaceIDs, unsigned n, task_t task);
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
    void fill(const vv_rec *r);
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
    IODataQueue *queue_ = nullptr;
    IOMemoryMap *queueMap_ = nullptr;
    IOBufferMemoryDescriptor *send_ = nullptr;
    IOMemoryMap *sendMap_ = nullptr;
    uint8_t uuids_[kMaxUUIDs][16] = {};
    unsigned nuuids_ = 0;
    bool closed_ = false;
};

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
    uint32_t a[6] = {ctl_->guest_gen, 0, 0, 0, 0, 0};
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
        char s[160];
        snprintf(s, sizeof(s), "out %llu, in %llu, fills %llu (failed %llu), undeliverable %llu, ring full %llu",
                 stats_[0], stats_[1], stats_[2], stats_[3], stats_[4], stats_[5]);
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
                                                                unsigned n, task_t task) {
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
    uint32_t a[6] = {ns, len, 0, 0, 0, 0};
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

// Copy slot r->arg[1] into the IOSurface r->arg[0], then tell the host the slot is free.
void AppleVideoToolboxParavirtualizationDriver::fill(const vv_rec *r) {
    uint32_t id = r->arg[0], slot = r->arg[1], w = r->arg[2], h = r->arg[3], stride = r->arg[4], bps = r->arg[5];
    uint32_t err = 1;
    IOLockLock(lock_);
    Surface *s = nullptr;
    for (unsigned i = 0; i < kMaxSurfaces; i++) {
        if (surfaces_[i].surface && surfaces_[i].id == id) {
            s = &surfaces_[i];
        }
    }
    if (s && slot < VV_NSLOTS && bps >= 1 && bps <= 2 && (uint64_t)stride * h * 3 / 2 <= VV_SLOT_SIZE) {
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
            const uint8_t *src = (const uint8_t *)(shm_ + VV_SLOT_OFF + (uint64_t)slot * VV_SLOT_SIZE);
            unsigned int seed = 0;
            surf->lockSurface(0, &seed);
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
                const uint8_t *from = src + (p ? (uint64_t)stride * h : 0);
                for (uint64_t y = 0; y < rh; y++) {
                    memcpy(base + off + y * bpr, from + y * stride, rowBytes);
                }
            }
            surf->unlockSurface(0, &seed);
            err = ok ? 0 : 2;
        }
        s->used = ++useClock_;
    }
    IOLockUnlock(lock_);
    OSIncrementAtomic64((volatile SInt64 *)&stats_[err ? 3 : 2]);
    uint32_t a[6] = {slot, err, 0, 0, 0, 0};
    IOLockLock(g2hLock_);
    putG2H(VV_G_SLOTDONE, a, nullptr, 0, nullptr, 0);
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
        } else if (rec->kind == VV_H_FILL) {
            fill(rec);
            any = true;
        }
        __atomic_store_n(&r->tail, tail + step, __ATOMIC_RELEASE);
    }
    if (any) {
        doorbell();
    }
}

// ---- the user client -----------------------------------------------------------------------------------------------

bool AppleVideoToolboxParavirtualizationUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type) {
    if (!IOUserClient::initWithTask(owningTask, securityID, type)) {
        return false;
    }
    task_ = owningTask;
    lock_ = IOLockAlloc();
    return lock_ != nullptr;
}

bool AppleVideoToolboxParavirtualizationUserClient::start(IOService *provider) {
    drv_ = OSDynamicCast(AppleVideoToolboxParavirtualizationDriver, provider);
    if (!drv_ || !IOUserClient::start(provider)) {
        return false;
    }
    queue_ = IODataQueue::withCapacity(256 * 1024);
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
    unsigned n = nuuids_;
    uint8_t uu[kMaxUUIDs][16];
    memcpy(uu, uuids_, sizeof(uu));
    nuuids_ = 0;
    IOLockUnlock(lock_);
    if (was || !drv_) {
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

void AppleVideoToolboxParavirtualizationUserClient::deliver(const uint8_t *msg, uint32_t len) {
    IOLockLock(lock_);
    if (queue_ && !closed_ && !queue_->enqueue((void *)msg, len)) {
        IOLog("VeneraVideo: a process's message queue is full; a host message was dropped\n");
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
        IOReturn rc = drv_->sendMessage(this, copy, (uint32_t)len, ids, n, task_);
        IOFreeData(copy, len);
        if (a->scalarOutputCount >= 1) {
            a->scalarOutput[0] = rc == kIOReturnSuccess ? 0 : (uint64_t)(int64_t)-12911;
            a->scalarOutputCount = 1;
        }
        return kIOReturnSuccess;
    }
    case 4:   // the process drained its queue
        return kIOReturnSuccess;
    default:
        return kIOReturnUnsupported;
    }
}
