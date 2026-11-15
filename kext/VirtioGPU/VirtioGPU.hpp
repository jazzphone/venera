// VirtioGPU: the virtio core. Owns the device (default match category on 1af4:1050), the queues
// and the command buffer. VirtioGPUFramebuffer (another kext) drives the screen through the
// VirtioGPUDisplay nub and callPlatformFunction (see ../VirtioGPUAPI.h).
#pragma once

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOFilterInterruptEventSource.h>
#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <libkern/c++/OSData.h>

#include "VirtioPCI.hpp"

class VirtioGPUUserClient;
struct vgpu_info;

class VirtioGPU : public IOService {
    OSDeclareDefaultStructors(VirtioGPU)

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;

    // ---- API for VirtioGPUFramebuffer ----
    bool ready() const { return control_ != nullptr; }
    // The host's preferred size for scanout 0 (GET_DISPLAY_INFO), 0 if unknown.
    void preferredSize(uint32_t *width, uint32_t *height) const {
        *width = width_;
        *height = height_;
    }
    // EDID bytes from GET_EDID, or null. Not retained for the caller.
    OSData *edid() const { return edid_; }
    // Shows `memory` (BGRX, `stride` bytes per row) on scanout 0 at width x height: a new 2D
    // resource backed by the first height*stride bytes, replacing the previous one.
    bool setScanout(IOBufferMemoryDescriptor *memory, uint32_t width, uint32_t height,
                    uint32_t stride);
    // Copies a rectangle of the current scanout resource to the host and flushes it.
    bool flush(uint32_t x, uint32_t y, uint32_t width, uint32_t height);
    // Turns the scanout off and drops the resource.
    void disableScanout();
    // Hardware cursor (cursor queue): 64x64 BGRA image + hot spot; position of the hot spot.
    bool setCursor(const uint32_t *pixels, uint32_t hotX, uint32_t hotY);
    void moveCursor(uint32_t x, uint32_t y, bool visible);
    void addLog(const char *line);
    void publishLog();
    // ---- Stage 3: requests for the user client (Venus) ----
    // A control queue request in flight, indexed by its descriptor head.
    struct Request {
        bool inUse;
        volatile bool done;
        bool async;                         // completes on its own: owned buffer released then
        uint32_t usedLength;
        IOBufferMemoryDescriptor *owned;    // request + reply memory, if the request owns it
        VirtioGPUUserClient *fenceOwner;    // retained while in flight
        uint32_t ring;
        uint64_t fence;
    };
    // Sends `request` and waits for the reply (both copied through a private buffer).
    // Returns the reply's type, 0 on timeout.
    uint32_t transact(const void *request, uint32_t requestLength, void *reply, uint32_t replyLength,
                      uint32_t timeoutMs = 2000);
    // SUBMIT_3D of `cs` to (ctx, ring); with fence != 0 the request is fenced and completes when
    // the host signals it (fenceOwner->fenceSignaled is called). Returns false if it couldn't queue.
    bool submit3D(uint32_t ctx, uint32_t ring, uint64_t fence, const void *cs, uint32_t csLength,
                  IOMemoryDescriptor *csDescriptor, VirtioGPUUserClient *fenceOwner);
    // Waits until `done()` is true, the timeout passes, or nothing more can arrive.
    bool waitUntil(bool (*done)(void *), void *context, uint64_t timeoutNs);
    uint32_t allocateResourceID() { return OSIncrementAtomic(reinterpret_cast<volatile SInt32 *>(&nextResource_)); }
    uint32_t allocateContextID() { return OSIncrementAtomic(reinterpret_cast<volatile SInt32 *>(&nextContext_)); }
    bool hostmemAllocate(uint64_t size, uint64_t *offset);
    void hostmemFree(uint64_t offset, uint64_t size);
    IODeviceMemory *hostmem() const { return hostmemMemory_; }
    uint64_t hostmemSize() const { return hostmemLength_; }
    uint64_t features() const { return features_; }
    uint32_t capsetCount() const { return numCapsets_; }
    void fillInfo(struct vgpu_info *info);
    IOReturn newUserClient(task_t owningTask, void *securityID, UInt32 type, IOUserClient **handler) override;

    // Serves the selectors in VirtioGPUAPI.h (the nub forwards its calls here).
    IOReturn callPlatformFunction(const OSSymbol *functionName, bool waitForFunction, void *param1,
                                  void *param2, void *param3, void *param4) override;

private:
    void logHeader();
    bool findRegions(virtio::Region regions[9], uint32_t *notifyMultiplier);
    bool setupInterrupt();
    bool bringUp();
    void tearDown();

    // Sends the request at the start of the command memory; the reply lands at kReplyOffset.
    // Waits for the device's interrupt (or polls every 5 ms). Returns the reply type, 0 on timeout.
    uint32_t command(uint32_t requestLength, uint32_t replyLength, uint32_t timeoutMs = 2000);
    uint32_t simple(uint32_t requestLength);
    void getDisplayInfo();
    void getEDID(uint32_t scanout);
    void getCapsets();
    void venusProbe();
    int submitRequest(const virtio::Segment *segments, unsigned count, IOBufferMemoryDescriptor *owned,
                      bool async, VirtioGPUUserClient *fenceOwner, uint32_t ring, uint64_t fence);
    void drainControl(); // commandLock_ held
    bool cursorCommand(uint32_t type, uint32_t resource);
    bool attachBacking(uint32_t resource, IOBufferMemoryDescriptor *memory, uint32_t bytes);
    void dropResource(uint32_t resource);

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
    IOLock *scanoutLock_ = nullptr;
    IOWorkLoop *workLoop_ = nullptr;
    IOFilterInterruptEventSource *interrupt_ = nullptr;
    bool msix_ = false;
    volatile uint32_t interrupts_ = 0;
    char wakeEvent_ = 0; // address the command waiter sleeps on
    uint32_t commandsByInterrupt_ = 0;
    uint32_t commandsByPolling_ = 0;
    uint64_t features_ = 0;
    uint32_t numScanouts_ = 0;
    uint32_t width_ = 0;
    uint32_t height_ = 0;
    OSData *edid_ = nullptr;
    uint32_t scanoutResource_ = 0;
    volatile uint32_t nextResource_ = 1;
    uint32_t scanoutWidth_ = 0;
    uint32_t scanoutHeight_ = 0;
    uint32_t scanoutStride_ = 0;
    uint32_t flushes_ = 0;
    IOService *display_ = nullptr; // VirtioGPUDisplay nub
    // Stage 3: host-visible memory window (VIRTIO_PCI_CAP_SHARED_MEMORY_CFG) and capsets
    uint32_t numCapsets_ = 0;
    bool venusCapset_ = false;
    uint32_t capsetID_[8] = {};
    uint32_t capsetMaxVersion_[8] = {};
    uint32_t capsetMaxSize_[8] = {};
    uint8_t hostmemID_ = 0;
    uint8_t hostmemBar_ = 0;
    uint64_t hostmemOffset_ = 0;
    uint64_t hostmemLength_ = 0;
    IODeviceMemory *hostmemMemory_ = nullptr;
    struct HostmemRange {
        uint64_t offset;
        uint64_t size;
    };
    static constexpr unsigned kMaxHostmemRanges = 2048;
    HostmemRange *hostmemRanges_ = nullptr; // sorted by offset
    unsigned hostmemRangeCount_ = 0;
    IOLock *hostmemLock_ = nullptr;
    Request requests_[256] = {};
    volatile uint32_t nextContext_ = 1;
    uint32_t asyncInFlight_ = 0;
    // Hardware cursor
    IOLock *cursorLock_ = nullptr;
    IOBufferMemoryDescriptor *cursorImage_ = nullptr;  // 64x64x4 backing of the cursor resource
    IOBufferMemoryDescriptor *cursorCmds_ = nullptr;   // one 64-byte slot per cursor queue entry
    uint32_t cursorResource_ = 0;
    uint32_t cursorHotX_ = 0, cursorHotY_ = 0, cursorX_ = 0, cursorY_ = 0;
    bool cursorVisible_ = false;
    uint32_t cursorSlot_ = 0;
    uint32_t cursorInFlight_ = 0;
    uint32_t cursorDropped_ = 0;
};

// The nub VirtioGPUFramebuffer.kext matches on. Forwards callPlatformFunction to the core.
class VirtioGPUDisplay : public IOService {
    OSDeclareDefaultStructors(VirtioGPUDisplay)

public:
    IOReturn callPlatformFunction(const OSSymbol *functionName, bool waitForFunction, void *param1,
                                  void *param2, void *param3, void *param4) override;
};

// Holds the IOFramebuffer match category on the PCI device (score 30000 > IONDRVFramebuffer's
// 20000), so the firmware framebuffer driver from the System kernel collection never takes the
// screen. Does nothing else.
class VirtioGPUFramebufferSlot : public IOService {
    OSDeclareDefaultStructors(VirtioGPUFramebufferSlot)

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
};
