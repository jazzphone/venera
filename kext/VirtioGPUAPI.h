// The interface between VirtioGPU.kext (core, Boot kernel collection via OpenCore) and
// VirtioGPUFramebuffer.kext (IOFramebuffer, Auxiliary kernel collection). The kexts don't link
// against each other: the framebuffer calls the core through IOService::callPlatformFunction on
// its provider, the VirtioGPUDisplay nub, which forwards to the core.
//
// Each function name is a callPlatformFunction selector; params are the four void * arguments.
#pragma once

// param1: uint32_t *width, param2: uint32_t *height (host's preferred size for scanout 0)
#define kVGPUPreferredSize "vgpu.preferredSize"
// param1: OSData **edid (retained; release it), kIOReturnNotFound if the host gave none
#define kVGPUCopyEDID "vgpu.copyEDID"
// param1: IOBufferMemoryDescriptor *memory, param2..4: width, height, stride (uintptr_t)
#define kVGPUSetScanout "vgpu.setScanout"
// param1..4: x, y, width, height (uintptr_t)
#define kVGPUFlush "vgpu.flush"
// no params: scanout off, resource dropped
#define kVGPUDisableScanout "vgpu.disableScanout"
// param1: const uint32_t *pixels (64x64 B8G8R8A8, row stride 256 bytes), param2/3: hot spot x/y
#define kVGPUSetCursor "vgpu.setCursor"
// param1/2: x, y of the hot spot (uintptr_t), param3: non-null = visible
#define kVGPUMoveCursor "vgpu.moveCursor"
#define kVGPUCursorSize 64
// param1: const char *line for the core's ProbeLog; param2: non-null to publish the log now
#define kVGPULog "vgpu.log"

#define kVGPUDisplayClass "VirtioGPUDisplay"

// ---- stage 5a: VirtioGPUAccel (Auxiliary KC) <-> VirtioGPUFramebuffer and the core ----
// Asked of the framebuffer itself (callPlatformFunction on the VirtioGPUFramebuffer service).
// param1: VGPUScanoutInfo * (filled): the RAM the host scans out, as the accelerator's display pipe copies into it
#define kVGPUFBScanoutInfo "vgpu.fb.scanoutInfo"
// no params: a display-pipe frame was written into the scanout RAM; flush it to the host now
#define kVGPUFBPresent "vgpu.fb.present"
struct VGPUScanoutInfo {
    void *kva;          // kernel address of the scanout's first pixel (X8R8G8B8, little endian = BGRX bytes)
    unsigned pitch;     // bytes per row
    unsigned width;
    unsigned height;
    unsigned long long bytes;   // mapped length from kva
};
// Asked of the core (VirtioGPU, the PCI device's client): a Venus user client not yet attached to anything.
// param1: task_t owner, param2: IOUserClient ** (retained; the caller attaches and starts it under its own service)
#define kVGPUNewClient "vgpu.newClient"

// Stage 5c, accelerator -> core: the blob twin of an IOSurface (p1 = surface id as uintptr_t, p2 = uint32_t[4]
// {resource, width, height, stride} out; kIOReturnNotFound when it has none).
#define kVGPUTwinFor "vgpu.twinFor"
// Stage 5c: show a blob on scanout 0 (p1 resource, p2 width, p3 height, p4 stride), or the framebuffer again (p1 0).
#define kVGPUScanoutBlob "vgpu.scanoutBlob"
