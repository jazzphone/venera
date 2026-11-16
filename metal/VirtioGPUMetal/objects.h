// The plugin's Metal objects that more than one file needs.
#pragma once
#import "vg.h"
#import <IOSurface/IOSurfaceRef.h>

enum {
    kVGMaxBufferSlots = 31,
    kVGMaxTextureSlots = 32,
    kVGMaxSamplerSlots = 16,
    kVGMaxThreadgroupSlots = 32,
    // The translator's descriptor bands (metal2vulkan reflect/mod.rs)
    kVGTextureBase = 32,
    kVGSamplerBase = 160,
    kVGStorageTextureBase = 480,
};

@interface VGMTLBuffer : NSObject <MTLBuffer> {
@public
    vg_buffer _b;
    NSUInteger _length;
    MTLResourceOptions _options;
    id<MTLDevice> _dev;
    // newBufferWithBytesNoCopy: the caller's memory; copied into _b each time the buffer is bound (Venus can't map
    // guest memory under a VkBuffer), so CPU writes made before encoding reach the GPU. GPU writes don't come back.
    void *_host;
    void (^_deallocator)(void *pointer, NSUInteger length);
}
@property(readonly) id<MTLDevice> device;
@property(copy, atomic) NSString *label;
@end
id<MTLBuffer> vg_new_buffer_nocopy(id<MTLDevice> device, void *pointer, NSUInteger length, MTLResourceOptions options,
                                   void (^deallocator)(void *, NSUInteger));

@interface VGMTLTexture : NSObject <MTLTexture> {
@public
    VkImage _image;
    VkDeviceMemory _memory;
    VkImageView _view;
    VkFormat _format;
    VkImageAspectFlags _aspect;
    MTLPixelFormat _pixelFormat;
    MTLTextureType _type;
    NSUInteger _width, _height, _depth, _mips, _layers;
    NSUInteger _samples;   // multisample images (5d); 0 or 1 = one sample
    MTLTextureUsage _usage;
    MTLStorageMode _storage;
    id<MTLDevice> _dev;
    // IOSurface-backed (stage 4d): the image is a private GPU copy; _staging is laid out like the surface's plane.
    IOSurfaceRef _surface;
    NSUInteger _plane, _surfaceBpr;
    uint32_t _syncedSeed;   // the surface seed the image matches (after a pull or our own copy-out)
    BOOL _neverSynced;
    vg_buffer _staging;
    // A texture over a buffer's memory (newTextureWithDescriptor:offset:bytesPerRow: and the tiled/linear SPI): Venus
    // can't alias the two, so the image is refreshed from the buffer each time it is bound or read (5b).
    id _srcBuffer;
    NSUInteger _srcOffset, _srcBpr;
    // A texture view (newTextureViewWithPixelFormat:...): shares _parent's image, has its own VkImageView.
    VGMTLTexture *_parent;
    VkImageUsageFlags _imageUsage;
    // A WindowServer display surface's twin (5c): a host-visible copy of each presented frame, made on the GPU, that the
    // kext shows with SET_SCANOUT_BLOB instead of copying the surface through the CPU.
    vg_buffer _twin;
    uint32_t _twinRes;
    uint32_t _twinGen;   // frames copied into the twin so far (kVGUCTwinMark)
    BOOL _twinRefused;   // the kext said no (not the screen's size): no twin, the CPU write-back stays
    uint32_t _hotWrites;   // display command buffers in a row that wrote it, each within 100 ms of the last (5c round 6)
    uint64_t _hotLast;
}
@property(readonly) id<MTLDevice> device;
@property(copy, atomic) NSString *label;
@end

// The surface's CPU contents -> the image, when the surface changed since the image last matched it (synchronous).
void vg_surface_pull(VGMTLTexture *t);
// Records that `cmd` writes texture `t`: a surface texture is copied back to its IOSurface when `cmd` completes.
void vg_cmd_wrote(id cmd, VGMTLTexture *t);
// Display-surface twins (5c): make and register one for a root surface texture that qualifies (WindowServer, BGRA,
// screen-sized); forget it (the kext first) before the texture goes.
BOOL vg_twin_ensure(VGMTLTexture *t);
BOOL vg_twin_mark(uint32_t surface, uint32_t frame, BOOL ready);   // YES: shown on the display already
int vg_snap_wanted(void);
VGMTLTexture *vg_twinned_shown(void);   // the twinned surface the kext flipped to last
void vg_snap_write(VGMTLTexture *t, int number);
void vg_twin_forget(VGMTLTexture *t);
id<MTLTexture> vg_new_surface_texture(id<MTLDevice> device, MTLTextureDescriptor *d, IOSurfaceRef surface, NSUInteger plane);
id<MTLTexture> vg_texture_view(VGMTLTexture *p, MTLPixelFormat pf, MTLTextureType type, NSRange levels, NSRange slices);
id<MTLTexture> vg_new_buffer_texture(id<MTLBuffer> buffer, MTLTextureDescriptor *d, NSUInteger offset, NSUInteger bpr);

@interface VGMTLSamplerState : NSObject <MTLSamplerState> {
@public
    VkSampler _sampler;
    id<MTLDevice> _dev;
}
@property(readonly) id<MTLDevice> device;
@property(readonly) NSString *label;
@end

@interface VGMTLDepthStencilState : NSObject <MTLDepthStencilState> {
@public
    BOOL _test, _write;
    VkCompareOp _compare;
    id<MTLDevice> _dev;
}
@property(readonly) id<MTLDevice> device;
@property(readonly) NSString *label;
@end

// What one set-0 (or set-1) binding of a translated module is.
typedef struct {
    uint32_t binding;
    VkDescriptorType type;
} vg_binding;
int vg_spirv_bindings(NSData *spv, uint32_t set, vg_binding *out, int max, NSString **error);
NSData *vg_spirv_retarget_set(NSData *spv, uint32_t newSet);
BOOL vg_spirv_has_push_constants(NSData *spv);   // DescriptorSet 0 -> newSet (NV's fragment move)

@interface VGMTLCommandBuffer : NSObject <MTLCommandBuffer> {
@public
    VkCommandBuffer _cb;
    VkCommandBuffer _pendingCb;   // deferred work submitted just ahead of _cb (5c), freed at completion
    NSMutableData *_pendingOwned;
    int _timePair;   // GPU timestamps (5c), -1 when off
    BOOL _present;          // committed by commitAndWaitUntilSubmitted (Core Animation's display frames)
    BOOL _allTwinned;       // every IOSurface it wrote got a twin copy: waiting for the GPU is enough
    dispatch_semaphore_t _gpuDone;   // signaled once the fence is (before the CPU write-backs)
    dispatch_group_t _fenced;        // left once the fence is (vg_present_throttle waits on it)
    BOOL _fencedEntered;
    NSMutableData *_twinFrames;      // (surface id, frame) pairs to mark ready once the GPU is done (5c round 3)
    VGMTLTexture *_snapTex;          // a display snapshot asked for (vg_snap_wanted), written once the GPU is done
    int _snapNumber;
    VkDescriptorPool _pools[64];
    void *_setMemo;   // recent descriptor sets by binding contents (5c round 4), see vg_write_set
    unsigned _setMemoNext;
    int _npools;
    uint32_t _setsInPool;
    NSMutableArray *_keep;   // resources referenced until completion
    NSMutableArray *_handlers;
    NSMutableArray *_scheduledHandlers;   // run once the command buffer is submitted
    dispatch_group_t _done;
    vg_buffer _arena[64];   // setBytes data
    int _narena;
    VkDeviceSize _arenaUsed;
    MTLCommandBufferStatus _status;
    NSError *_error;
    uint64_t _submitted, _completed;
    NSMutableSet *_surfacesWritten;   // VGMTLTexture with an IOSurface, copied out at completion
    NSMutableArray *_drawables;       // presented after the copy-out
    NSMutableArray *_signals;         // [event, value]: signaled at completion, after the write-back (5d)
    NSMutableArray *_waits;           // [event, value]: shared events waited for at commit (5d)
}
@property(readonly) id<MTLDevice> device;
@property(readonly) id<MTLCommandQueue> commandQueue;
@property(copy, atomic) NSString *label;
- (BOOL)begin;
- (void)fail:(NSString *)why;
- (void)barrier;
- (VkDescriptorSet)allocSet:(VkDescriptorSetLayout)dsl;
- (BOOL)upload:(const void *)bytes length:(NSUInteger)len buffer:(VkBuffer *)buf offset:(VkDeviceSize *)off;
@end

@interface VGEncoder : NSObject {
@public
    VGMTLCommandBuffer *_owner;
}
@property(readonly) id<MTLDevice> device;
@property(copy, atomic) NSString *label;
- (instancetype)initWithCommandBuffer:(VGMTLCommandBuffer *)cmd;
@end

// What a stage has bound: Metal's argument tables.
typedef struct {
    VkBuffer buf[kVGMaxBufferSlots];
    VkDeviceSize off[kVGMaxBufferSlots];
    __unsafe_unretained VGMTLTexture *tex[kVGMaxTextureSlots];
    __unsafe_unretained VGMTLSamplerState *smp[kVGMaxSamplerSlots];
} vg_stage_bindings;

// Allocates a set from `dsl` and writes every binding of `bindings` from the stage's tables (buffer n at binding n,
// texture n at 32+n / 480+n, sampler n at 160+n). Fails the command buffer, naming the slot, when one is empty.
VkDescriptorSet vg_write_set(VGMTLCommandBuffer *cmd, VkDescriptorSetLayout dsl, const vg_binding *bindings, int n,
                             const vg_stage_bindings *t, NSString *who);

VkBuffer vg_vkbuffer(id<MTLBuffer> b);
id<MTLTexture> vg_new_texture(id<MTLDevice> device, MTLTextureDescriptor *d);
NSUInteger vg_bytes_per_pixel(MTLPixelFormat f);   // 0 for a format we don't have
// Purgeable state, kept per object (VGMTLProtection.m): returns the previous state and keeps the new one unless it is
// KeepCurrent. Nothing is ever purged, so Empty never comes back (5b: Core Animation tracks its surfaces by it).
MTLPurgeableState vg_purgeable(id resource, MTLPurgeableState state);
// VGMTLHeap.m
id<MTLHeap> vg_new_heap(id<MTLDevice> device, MTLHeapDescriptor *d);
MTLSizeAndAlign vg_heap_texture_size(MTLTextureDescriptor *d);
MTLSizeAndAlign vg_heap_buffer_size(NSUInteger length);
// What a resource made by a heap answers (associated objects; nil / 0 / NO for the device's own resources).
id<MTLHeap> vg_heap_of(id resource);
NSUInteger vg_heap_offset_of(id resource);
BOOL vg_heap_aliasable(id resource);
void vg_heap_make_aliasable(id resource);
id<MTLSamplerState> vg_new_sampler(id<MTLDevice> device, MTLSamplerDescriptor *d);
id<MTLDepthStencilState> vg_new_depth_stencil(id<MTLDevice> device, MTLDepthStencilDescriptor *d);
id<MTLRenderPipelineState> vg_new_render_pipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor *d, NSError **error);
VkFormat vg_vk_format(MTLPixelFormat f);
// Runs `record` in a one-time command buffer and waits for it (texture uploads, readbacks, layout setup).
BOOL vg_one_shot(void (^record)(VkCommandBuffer cb));
