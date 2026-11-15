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
    void addLog(const char *line);
    void publishLog();
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
    uint32_t nextResource_ = 1;
    uint32_t scanoutWidth_ = 0;
    uint32_t scanoutHeight_ = 0;
    uint32_t scanoutStride_ = 0;
    uint32_t flushes_ = 0;
    IOService *display_ = nullptr; // VirtioGPUDisplay nub
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
