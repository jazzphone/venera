/*
 * User-space interface of VirtioGPU.kext (IOService "VirtioGPU", IOServiceOpen type 0).
 * Plain C: the test tool and Mesa's macOS Venus backend include it.
 *
 * It stands in for the Linux virtgpu DRM ioctls Venus uses:
 *   GETPARAM/GET_CAPS        -> kVGUCGetInfo, kVGUCGetCapset
 *   CONTEXT_INIT             -> kVGUCContextInit (one context per connection)
 *   RESOURCE_CREATE_BLOB     -> kVGUCCreateBlob
 *   MAP + mmap               -> kVGUCMapBlob, then IOConnectMapMemory64(type = resource id)
 *   GEM_CLOSE                -> kVGUCDestroyResource
 *   EXECBUFFER (+fence out)  -> kVGUCSubmit
 *   poll(fence fd)           -> kVGUCWaitFence
 */
#ifndef VIRTIO_GPU_USER_API_H
#define VIRTIO_GPU_USER_API_H

#include <stdint.h>

#define kVGUCServiceClass "VirtioGPU"

/* Stage 5a: the same user client, reached through the accelerator so a sandboxed WindowServer may open it
 * (its sandbox allows the graphics accelerator's user clients, not the core's). IOServiceOpen on class
 * kVGUCAccelClass with type kVGUCAccelType; same selectors. Unsandboxed tools may still open the core. */
#define kVGUCAccelClass "VirtioGPUAccel"
#define kVGUCAccelType 0x56470001u /* 'VG' + 1 */

enum {
    /* struct out: struct vgpu_info */
    kVGUCGetInfo = 0,
    /* scalar in: capset id, version; struct out: capset bytes (up to max size) */
    kVGUCGetCapset = 1,
    /* scalar in: capset id; scalar out: context id */
    kVGUCContextInit = 2,
    /* scalar in: blob_mem, blob_flags, size, blob_id; scalar out: resource id */
    kVGUCCreateBlob = 3,
    /* scalar in: resource id; scalar out: size, map_info (VIRTIO_GPU_MAP_CACHE_*). Then map it with
     * IOConnectMapMemory64(connection, resource id, mach_task_self(), &addr, &size, kIOMapAnywhere). */
    kVGUCMapBlob = 4,
    /* scalar in: resource id (unmaps if mapped; unmap the user mapping first) */
    kVGUCDestroyResource = 5,
    /* scalar in: ring index, want fence (0/1); struct in: command stream; scalar out: fence (0 if none) */
    kVGUCSubmit = 6,
    /* scalar in: ring index, fence, timeout ns (0 = poll); scalar out: 1 signaled, 0 not yet */
    kVGUCWaitFence = 7,
    /* stage 5c, root only: scalar in: blob resource id (0 = the framebuffer again), width, height, stride, offset.
     * Shows that blob on scanout 0 (SET_SCANOUT_BLOB + RESOURCE_FLUSH). */
    kVGUCScanoutBlob = 8,
    /* stage 5c, WindowServer only: scalar in: IOSurface id, blob resource id (0 = forget it), width, height, stride.
     * The blob (one of this process's Venus allocations) holds a copy of that surface's frames: the display pipe
     * scans it out instead of copying the surface through the CPU. Core 0.5.8: a sixth scalar, a second blob, makes
     * two twins, so a frame goes into the one not on screen (kVGUCTwinMark says which). */
    kVGUCSetTwin = 9,
    /* stage 5c, the twin's owner only: scalar in: IOSurface id, frame number, 0 = submitted / 1 = ready (its GPU copy
     * is done). The display pipe flips to a twin only once the frame a transaction asked for is ready, so WindowServer
     * needn't wait for the GPU before presenting. scalar out: shown on a display yet (core 0.5.5); for "submitted",
     * the twin this frame goes into, 0 or 1 (core 0.5.8, with two twins; copy the frame into that one). */
    kVGUCTwinMark = 10,
    /* 5d, core 0.5.6: the caller's image memory behind an IOSurface, for another process's Venus context to import
     * instead of copying the surface through the CPU. scalar in: IOSurface id, blob resource id (0 = forget it),
     * size, VkFormat, width, height, VkImageUsageFlags, VkImageCreateFlags | tiling << 31. The resource must be the
     * caller's own (an exportable allocation). */
    kVGUCShareSurface = 11,
    /* 5d, core 0.5.6: attaches the resource shared for an IOSurface to the caller's context. scalar in: IOSurface id;
     * scalar out: resource id, size, VkFormat, width, height, usage, flags | tiling << 31. The caller's destroy of it
     * only detaches it (the owner's stays). kIOReturnNotFound when nothing is shared for that surface. */
    kVGUCImportSurface = 12,
    kVGUCMethodCount
};

#define VGPU_MAX_CAPSETS 8
#define VGPU_MAX_RINGS 64

struct vgpu_info {
    uint64_t features;      /* negotiated virtio-gpu feature bits */
    uint64_t hostmem_size;  /* host-visible window (0 if none) */
    uint32_t pci_vendor;
    uint32_t pci_device;
    uint32_t num_capsets;
    uint32_t capset_id[VGPU_MAX_CAPSETS];
    uint32_t capset_max_version[VGPU_MAX_CAPSETS];
    uint32_t capset_max_size[VGPU_MAX_CAPSETS];
};

/* virtio-gpu values, for callers that don't have the Linux headers */
#define VGPU_CAPSET_VENUS 4
#define VGPU_BLOB_MEM_GUEST 1
#define VGPU_BLOB_MEM_HOST3D 2
#define VGPU_BLOB_FLAG_MAPPABLE 1
#define VGPU_BLOB_FLAG_SHAREABLE 2
#define VGPU_MAP_CACHE_CACHED 1
#define VGPU_MAP_CACHE_UNCACHED 2
#define VGPU_MAP_CACHE_WC 3

#endif
