#include "VirtioPCI.hpp"

#include <IOKit/IOLib.h>

namespace virtio {

namespace {

// struct virtio_pci_common_cfg
enum : uint32_t {
    kDeviceFeatureSelect = 0x00,
    kDeviceFeature = 0x04,
    kDriverFeatureSelect = 0x08,
    kDriverFeature = 0x0c,
    kMsixConfig = 0x10,
    kNumQueues = 0x12,
    kDeviceStatus = 0x14,
    kQueueSelect = 0x16,
    kQueueSize = 0x18,
    kQueueMsixVector = 0x1a,
    kQueueEnable = 0x1c,
    kQueueNotifyOff = 0x1e,
    kQueueDesc = 0x20,
    kQueueDriver = 0x28,
    kQueueDevice = 0x30,
};

constexpr uint16_t kNoVector = 0xffff;
constexpr uint16_t kDescNext = 1;
constexpr uint16_t kDescWrite = 2;
constexpr uint16_t kAvailNoInterrupt = 1;

inline void fence() { __atomic_thread_fence(__ATOMIC_SEQ_CST); }

template <typename T> inline T rd(volatile uint8_t *base, uint32_t off) {
    return *reinterpret_cast<volatile T *>(base + off);
}
template <typename T> inline void wr(volatile uint8_t *base, uint32_t off, T value) {
    *reinterpret_cast<volatile T *>(base + off) = value;
}
inline void wr64(volatile uint8_t *base, uint32_t off, uint64_t value) {
    wr<uint32_t>(base, off, (uint32_t)value);
    wr<uint32_t>(base, off + 4, (uint32_t)(value >> 32));
}

} // namespace

// ---- Virtqueue ----

Virtqueue *Virtqueue::create(uint16_t index, uint16_t size) {
    // Every member starts at zero, so zeroed memory is a valid empty Virtqueue.
    Virtqueue *q = static_cast<Virtqueue *>(IOMallocZero(sizeof(Virtqueue)));
    if (!q) {
        return nullptr;
    }
    q->index_ = index;
    q->size_ = size;
    uint32_t descBytes = 16u * size;
    q->availOffset_ = descBytes;
    uint32_t availBytes = 6u + 2u * size;
    q->usedOffset_ = (descBytes + availBytes + 63u) & ~63u;
    uint32_t total = q->usedOffset_ + 6u + 8u * size;

    // One physically contiguous, page-aligned block (the device takes 64-bit addresses).
    q->memory_ = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, total, 0xFFFFFFFFFFFFF000ULL);
    if (!q->memory_ || q->memory_->prepare() != kIOReturnSuccess) {
        q->release();
        return nullptr;
    }
    bzero(q->memory_->getBytesNoCopy(), total);
    q->phys_ = q->memory_->getPhysicalSegment(0, nullptr, kIOMemoryMapperNone);
    uint8_t *base = static_cast<uint8_t *>(q->memory_->getBytesNoCopy());
    q->desc_ = reinterpret_cast<volatile Desc *>(base);
    q->avail_ = reinterpret_cast<volatile uint16_t *>(base + q->availOffset_);
    q->used_ = reinterpret_cast<volatile uint16_t *>(base + q->usedOffset_);

    for (uint16_t i = 0; i < size; i++) {
        q->desc_[i].next = (uint16_t)(i + 1);
    }
    q->freeHead_ = 0;
    q->freeCount_ = size;
    q->avail_[0] = kAvailNoInterrupt; // we poll for now
    return q;
}

void Virtqueue::release() {
    if (memory_) {
        memory_->complete();
        memory_->release();
        memory_ = nullptr;
    }
    IOFree(this, sizeof(Virtqueue));
}

int Virtqueue::submit(const Segment *segments, unsigned count) {
    if (count == 0 || count > freeCount_) {
        return -1;
    }
    uint16_t head = freeHead_;
    uint16_t id = head;
    for (unsigned i = 0; i < count; i++) {
        volatile Desc &d = desc_[id];
        d.addr = segments[i].phys;
        d.len = segments[i].length;
        uint16_t flags = segments[i].deviceWrites ? kDescWrite : 0;
        if (i + 1 < count) {
            flags |= kDescNext;
        }
        d.flags = flags;
        if (i + 1 < count) {
            id = d.next;
        }
    }
    freeHead_ = desc_[id].next;
    freeCount_ -= count;

    uint16_t availIdx = avail_[1];
    avail_[2 + (availIdx % size_)] = head;
    fence(); // descriptors and ring entry before the index
    avail_[1] = (uint16_t)(availIdx + 1);
    fence();
    return head;
}

void Virtqueue::setInterrupts(bool on) {
    avail_[0] = on ? 0 : kAvailNoInterrupt;
    fence();
}

bool Virtqueue::takeUsed(uint32_t *id, uint32_t *length) {
    fence();
    uint16_t usedIdx = used_[1];
    if (usedIdx == lastUsed_) {
        return false;
    }
    fence();
    volatile uint32_t *ring = reinterpret_cast<volatile uint32_t *>(used_ + 2);
    uint32_t slot = lastUsed_ % size_;
    uint32_t head = ring[slot * 2];
    uint32_t len = ring[slot * 2 + 1];
    lastUsed_++;

    // Return the chain to the free list.
    uint16_t last = (uint16_t)head;
    uint16_t n = 1;
    while (desc_[last].flags & kDescNext) {
        last = desc_[last].next;
        n++;
    }
    desc_[last].next = freeHead_;
    freeHead_ = (uint16_t)head;
    freeCount_ += n;

    *id = head;
    *length = len;
    return true;
}

// ---- Transport ----

bool Transport::attach(IOPCIDevice *pci, const Region regions[9], uint32_t notifyMultiplier) {
    const Region &common = regions[1];
    const Region &notify = regions[2];
    const Region &isr = regions[3];
    const Region &device = regions[4];
    if (!common.present || !notify.present || !device.present) {
        probeLog("transport: missing a region (common %d notify %d device %d)", common.present,
                 notify.present, device.present);
        return false;
    }
    if (common.bar != notify.bar || common.bar != device.bar) {
        probeLog("transport: regions in different BARs, not supported yet");
        return false;
    }
    map_ = pci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0 + common.bar * 4,
                                            kIOMapInhibitCache);
    if (!map_) {
        probeLog("transport: could not map BAR%u", common.bar);
        return false;
    }
    volatile uint8_t *base = reinterpret_cast<volatile uint8_t *>(map_->getVirtualAddress());
    common_ = base + common.offset;
    isr_ = (isr.present && isr.bar == common.bar) ? base + isr.offset : nullptr;
    notify_ = base + notify.offset;
    device_ = base + device.offset;
    notifyMultiplier_ = notifyMultiplier;
    return true;
}

void Transport::detach() {
    if (map_) {
        map_->release();
        map_ = nullptr;
    }
    common_ = isr_ = notify_ = device_ = nullptr;
}

bool Transport::setConfigVector(uint16_t vector) {
    wr<uint16_t>(common_, kMsixConfig, vector);
    return rd<uint16_t>(common_, kMsixConfig) == vector;
}

uint8_t Transport::readISR() { return isr_ ? *isr_ : 0; }

void Transport::reset() {
    wr<uint8_t>(common_, kDeviceStatus, 0);
    for (int i = 0; i < 1000 && rd<uint8_t>(common_, kDeviceStatus) != 0; i++) {
        IODelay(100);
    }
}

uint8_t Transport::status() { return rd<uint8_t>(common_, kDeviceStatus); }

void Transport::addStatus(uint8_t bits) {
    wr<uint8_t>(common_, kDeviceStatus, (uint8_t)(status() | bits));
}

uint64_t Transport::deviceFeatures() {
    uint64_t features = 0;
    for (uint32_t select = 0; select < 2; select++) {
        wr<uint32_t>(common_, kDeviceFeatureSelect, select);
        features |= (uint64_t)rd<uint32_t>(common_, kDeviceFeature) << (32 * select);
    }
    return features;
}

bool Transport::negotiate(uint64_t wanted, uint64_t *accepted) {
    uint64_t features = deviceFeatures() & wanted;
    for (uint32_t select = 0; select < 2; select++) {
        wr<uint32_t>(common_, kDriverFeatureSelect, select);
        wr<uint32_t>(common_, kDriverFeature, (uint32_t)(features >> (32 * select)));
    }
    addStatus(kFeaturesOK);
    *accepted = features;
    return (status() & kFeaturesOK) != 0;
}

uint16_t Transport::numQueues() { return rd<uint16_t>(common_, kNumQueues); }

Virtqueue *Transport::setupQueue(uint16_t index, uint16_t maxSize, uint16_t vector) {
    wr<uint16_t>(common_, kQueueSelect, index);
    uint16_t deviceSize = rd<uint16_t>(common_, kQueueSize);
    if (deviceSize == 0) {
        probeLog("queue %u: not available", index);
        return nullptr;
    }
    uint16_t size = deviceSize < maxSize ? deviceSize : maxSize;
    Virtqueue *q = Virtqueue::create(index, size);
    if (!q) {
        probeLog("queue %u: ring allocation failed", index);
        return nullptr;
    }
    wr<uint16_t>(common_, kQueueSize, size);
    wr<uint16_t>(common_, kQueueMsixVector, vector);
    if (vector != kNoVector && rd<uint16_t>(common_, kQueueMsixVector) != vector) {
        probeLog("queue %u: device refused MSI-X vector %u, polling", index, vector);
        wr<uint16_t>(common_, kQueueMsixVector, kNoVector);
    } else if (vector != kNoVector) {
        q->setInterrupts(true);
    }
    wr64(common_, kQueueDesc, q->descPhys());
    wr64(common_, kQueueDriver, q->availPhys());
    wr64(common_, kQueueDevice, q->usedPhys());
    if (index < 16) {
        notifyOffsets_[index] = rd<uint16_t>(common_, kQueueNotifyOff);
    }
    fence();
    wr<uint16_t>(common_, kQueueEnable, 1);
    probeLog("queue %u: size %u (device max %u) desc 0x%llx notify_off %u", index, size, deviceSize,
             (unsigned long long)q->descPhys(), index < 16 ? notifyOffsets_[index] : 0);
    return q;
}

void Transport::notify(Virtqueue *queue) {
    uint16_t index = queue->index();
    uint32_t off = (index < 16 ? notifyOffsets_[index] : 0) * notifyMultiplier_;
    fence();
    wr<uint16_t>(notify_, off, index);
}

} // namespace virtio
