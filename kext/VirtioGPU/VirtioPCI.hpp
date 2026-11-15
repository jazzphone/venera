// Modern virtio-pci transport (virtio 1.2 section 4.1) and split virtqueues (section 2.7).
#pragma once

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/pci/IOPCIDevice.h>

void probeLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

namespace virtio {

enum Status : uint8_t {
    kAcknowledge = 1,
    kDriver = 2,
    kDriverOK = 4,
    kFeaturesOK = 8,
    kNeedsReset = 64,
    kFailed = 128,
};

enum Feature : uint32_t {
    kFeatureVersion1 = 32,
};

// One virtio-pci capability region (struct virtio_pci_cap).
struct Region {
    bool present = false;
    uint8_t bar = 0;
    uint32_t offset = 0;
    uint32_t length = 0;
};

// A buffer handed to the device: a guest-physical address range.
struct Segment {
    uint64_t phys;
    uint32_t length;
    bool deviceWrites;
};

class Virtqueue {
public:
    // Allocates and lays out the rings; returns null on failure.
    static Virtqueue *create(uint16_t index, uint16_t size);
    void release();

    uint16_t index() const { return index_; }
    uint16_t size() const { return size_; }
    uint64_t descPhys() const { return phys_; }
    uint64_t availPhys() const { return phys_ + availOffset_; }
    uint64_t usedPhys() const { return phys_ + usedOffset_; }

    // Puts a descriptor chain in the avail ring. Returns the head id, or -1 if the ring is full.
    int submit(const Segment *segments, unsigned count);
    // Takes one completed chain off the used ring, if any. Returns true with its id and length.
    bool takeUsed(uint32_t *id, uint32_t *length);

private:
    struct Desc {
        uint64_t addr;
        uint32_t len;
        uint16_t flags;
        uint16_t next;
    };

    uint16_t index_ = 0;
    uint16_t size_ = 0;
    IOBufferMemoryDescriptor *memory_ = nullptr;
    uint64_t phys_ = 0;
    uint32_t availOffset_ = 0;
    uint32_t usedOffset_ = 0;
    volatile Desc *desc_ = nullptr;
    volatile uint16_t *avail_ = nullptr; // flags, idx, ring[size], used_event
    volatile uint16_t *used_ = nullptr;  // flags, idx, then {u32 id, u32 len}[size]
    uint16_t freeHead_ = 0;
    uint16_t freeCount_ = 0;
    uint16_t lastUsed_ = 0;
};

class Transport {
public:
    // Maps the regions found in the capability list. Touches no device state.
    bool attach(IOPCIDevice *pci, const Region regions[9], uint32_t notifyMultiplier);
    void detach();

    void reset();
    uint8_t status();
    void addStatus(uint8_t bits);
    uint64_t deviceFeatures();
    // Writes the driver features and sets FEATURES_OK; false if the device refuses them.
    bool negotiate(uint64_t wanted, uint64_t *accepted);
    uint16_t numQueues();
    // Sizes, allocates and enables queue `index` (polling: no MSI-X vector).
    Virtqueue *setupQueue(uint16_t index, uint16_t maxSize);
    void notify(Virtqueue *queue);

    volatile uint8_t *deviceConfig() { return device_; }

private:
    volatile uint8_t *common_ = nullptr;
    volatile uint8_t *notify_ = nullptr;
    volatile uint8_t *device_ = nullptr;
    uint32_t notifyMultiplier_ = 0;
    IOMemoryMap *map_ = nullptr;
    uint16_t notifyOffsets_[16] = {};
};

} // namespace virtio
