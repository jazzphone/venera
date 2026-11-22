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
    VkImageView _attView;   // depth and stencil together, for a depth-stencil attachment (5d); else null
    VkFormat _format;
    VkImageAspectFlags _aspect;
    MTLPixelFormat _pixelFormat;
    MTLTextureType _type;
    NSUInteger _width, _height, _depth, _mips, _layers;
    NSUInteger _samples;   // multisample images (5d); 0 or 1 = one sample
    MTLTextureSwizzleChannels _swz;   // the descriptor's (or view's) channel swizzle (5d); all zero = identity
    MTLTextureUsage _usage;
    MTLStorageMode _storage;
    id<MTLDevice> _dev;
    // IOSurface-backed (stage 4d): the image is a private GPU copy; _staging is laid out like the surface's plane.
    IOSurfaceRef _surface;
    NSUInteger _plane, _surfaceBpr;
    uint32_t _syncedSeed;   // the surface seed the image matches (after a pull or our own copy-out)
    BOOL _neverSynced;
    vg_buffer _staging;
    // The other images of the same surface plane in this process (a regrouping into other texels, another size): a
    // VGSurfaceGroup, and the group's write generation this image holds (round 23). A sibling behind the newest GPU
    // write is copied from it on the GPU before it is used (vg_surface_pull), not from the surface's CPU copy.
    id _group;
    uint64_t _gpuGen;
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
    // Its second twin (round 17, core 0.5.8): each frame goes into the one the kext says isn't on screen (_twinUse), so
    // nothing is copied into what a viewer may be reading. Empty with an older core.
    vg_buffer _twin2;
    uint32_t _twinUse;
    uint32_t _twinGen;   // frames copied into the twin so far (kVGUCTwinMark)
    BOOL _twinRefused;   // the kext said no (not the screen's size): no twin, the CPU write-back stays
    uint32_t _hotWrites;   // display command buffers in a row that wrote it, each within 100 ms of the last (5c round 6)
    uint64_t _hotLast;
    int8_t _scanout;   // CoreDisplay made it to scan out (IsDisplayable): 1, else 0; -1 not looked at yet
    // Shared with another process (5d, core 0.5.6): the image's memory is one blob resource both processes' contexts
    // have, registered with the kext by its creator and imported by the other. Each process's write-back tags the
    // surface (vg_surface_tag) so the other skips the pull of a frame its image already holds.
    uint32_t _shareRes;
    BOOL _shareImported;
    uint32_t _shareParams[5];   // the creator's: VkFormat, width, height, usage, flags | tiling << 31
    uint64_t _shareSize;
    BOOL _shareable;   // exportable, offered to other processes at its first GPU write-back (vg_surface_wrote_back)
    // A display stream's surface whose reader waits for pending writes (VGMTLLockWait.m, round 23): 1 tagged, 0 not
    // yet (looked up again every 30th write).
    BOOL _readerWaits;
    BOOL _described;   // synclog has said what this surface is
    int8_t _gpuOnly;   // SkyLight's Selective Sharing surface: 1, not: -1, not looked at yet: 0
    int8_t _neverShown;   // named as a surface the display never scans out (no twin): 1, not: -1, not looked at yet: 0
    uint32_t _neverShownEpoch;   // the twindrop list it was looked up against (VGMTLTexture.m)
    uint32_t _readerChecks;
}
@property(readonly) id<MTLDevice> device;
@property(copy, atomic) NSString *label;
@end
// Surface sharing (5d, VGMTLTexture.m): a write-back's new seed, tagged for the other process; a shared root's end.
void vg_surface_wrote_back(VGMTLTexture *t, uint32_t seed);
void vg_texture_share_dealloc(VGMTLTexture *t);

// The surface's CPU contents -> the image, when the surface changed since the image last matched it (synchronous);
// then, when another image of the same surface plane holds a newer GPU write, a GPU copy from it (deferred work).
void vg_surface_pull(VGMTLTexture *t);
// A submitted command buffer wrote root t on the GPU: its image is now the surface's newest (round 23).
void vg_surface_gpu_wrote(VGMTLTexture *t);
// t's write-back made the surface's seed `seed` from `before`, nobody else having written: its siblings that matched
// `before` match `seed` too, since they get t's pixels on the GPU (call with gVgSurfaceSync held).
void vg_surface_siblings_synced(VGMTLTexture *t, uint32_t before, uint32_t seed);
// A reader that waits for pending writes has tagged t's surface (VGMTLLockWait.m); mark or clear "write pending".
BOOL vg_lockwait_begin(VGMTLTexture *t);
void vg_lockwait_end(VGMTLTexture *t, BOOL written);
// Records that `cmd` writes texture `t`: a surface texture is copied back to its IOSurface when `cmd` completes.
void vg_cmd_wrote(id cmd, VGMTLTexture *t);
void vg_cmd_wrote_rect(id cmd, VGMTLTexture *t, int32_t x0, int32_t y0, int32_t x1, int32_t y1);
// Display-surface twins (5c): make and register one for a root surface texture that qualifies (WindowServer, BGRA,
// screen-sized); forget it (the kext first) before the texture goes.
BOOL vg_twin_ensure(VGMTLTexture *t);
uint32_t vg_streamsum_stamp(VGMTLTexture *t, uint32_t seed);   // the generation, 0 when off
// YES: shown on the display already. use (a submitted frame): which twin to copy it into, 0 or 1.
BOOL vg_twin_mark(uint32_t surface, uint32_t frame, BOOL ready, uint32_t *use);
int vg_snap_wanted(void);
VGMTLTexture *vg_twinned_shown(void);   // the twinned surface the kext flipped to last
void vg_snap_write(VGMTLTexture *t, int number);
void vg_twin_forget(VGMTLTexture *t);
id<MTLTexture> vg_new_surface_texture(id<MTLDevice> device, MTLTextureDescriptor *d, IOSurfaceRef surface, NSUInteger plane);
id<MTLTexture> vg_texture_view(VGMTLTexture *p, MTLPixelFormat pf, MTLTextureType type, NSRange levels, NSRange slices);
// the same with a channel swizzle (5d)
id<MTLTexture> vg_texture_view_swz(VGMTLTexture *p, MTLPixelFormat pf, MTLTextureType type, NSRange levels, NSRange slices,
                                   MTLTextureSwizzleChannels swz);
id<MTLTexture> vg_new_buffer_texture(id<MTLBuffer> buffer, MTLTextureDescriptor *d, NSUInteger offset, NSUInteger bpr);
VGMTLTexture *vg_new_zero_color_texture(id<MTLDevice> device, MTLTextureDescriptor *descriptor);

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
    BOOL _stencil;                     // 5d: a stencil descriptor on either face
    VkStencilOpState _sfront, _sback;  // ops, compare, masks (the reference is the encoder's)
    id<MTLDevice> _dev;
}
@property(readonly) id<MTLDevice> device;
@property(readonly) NSString *label;
@end

// What one set-0 (or set-1) binding of a translated module is.
typedef struct {
    uint32_t binding;
    VkDescriptorType type;
    VkSampler fixed;   // a constexpr sampler of the shader's own (the translator's StaticSampler), else VK_NULL_HANDLE
} vg_binding;
// The shader's constexpr samplers onto its bindings, from the translator's reflection (VGMTLTexture.m).
void vg_apply_static_samplers(NSDictionary *refl, vg_binding *bindings, int n);
int vg_spirv_bindings(NSData *spv, uint32_t set, vg_binding *out, int max, NSString **error);
NSData *vg_spirv_retarget_set(NSData *spv, uint32_t newSet);
BOOL vg_spirv_has_push_constants(NSData *spv);   // DescriptorSet 0 -> newSet (NV's fragment move)

@interface VGMTLCommandBuffer : NSObject <MTLCommandBuffer> {
@public
    VkCommandBuffer _cb;
    VkCommandBuffer _pendingCb;   // deferred work submitted just ahead of _cb (5c), freed at completion
    NSMutableData *_pendingOwned;
    NSMapTable *_streamWriteBacks;   // separate staging for surfaces handed over before write-back
    int _timePair;   // GPU timestamps (5c), -1 when off
    BOOL _present;          // committed by commitAndWaitUntilSubmitted (Core Animation's display frames)
    BOOL _allTwinned;       // every IOSurface it wrote got a twin copy: waiting for the GPU is enough
    dispatch_semaphore_t _gpuDone;   // signaled once the fence is (before the CPU write-backs)
    dispatch_semaphore_t _wroteBack;   // signaled once the CPU write-backs are in (round 23), before the handlers
    dispatch_group_t _fenced;        // left once the fence is (vg_present_throttle waits on it)
    BOOL _fencedEntered;
    NSMutableData *_twinFrames;      // (surface id, frame) pairs to mark ready once the GPU is done (5c round 3)
    VGMTLTexture *_snapTex;          // a display snapshot asked for (vg_snap_wanted), written once the GPU is done
    int _snapNumber;
    VkDescriptorPool _pools[64];
    void *_setMemo;   // recent descriptor sets by binding contents (5c round 4), see vg_write_set
    VkImage _feedbackImages[8];   // the open render pass's attachments in the feedback loop layout (vg_write_set)
    uint32_t _nfeedback;
    unsigned _setMemoNext;
    int _npools;
    uint32_t _setsInPool;
    NSMutableArray *_keep;   // resources referenced until completion
    NSMutableArray *_handlers;
    NSMutableArray *_scheduledHandlers;   // run once the command buffer is submitted
    dispatch_group_t _statusSet;   // left once its final status is set (before its handlers run)
    VGMTLCommandBuffer *_prev;     // the queue's command buffer committed before it, until its status is set
    dispatch_group_t _done;
    vg_buffer _arena[64];   // setBytes data
    int _narena;
    VkDeviceSize _arenaUsed;
    MTLCommandBufferStatus _status;
    NSError *_error;
    uint64_t _submitted, _completed;
    NSMutableSet *_surfacesWritten;   // VGMTLTexture with an IOSurface, copied out at completion
    NSMutableDictionary *_surfaceDirty;   // each one's written rectangle (x0 y0 x1 y1, int32): only that is copied out
    NSMutableArray *_drawables;       // presented after the copy-out
    NSMutableArray *_signals;         // [event, value]: signaled at completion, after the write-back (5d)
    NSMutableArray *_waits;           // [event, value]: shared events waited for at commit (5d)
    uint64_t _enqSeq;                 // its place in enqueue order (explicit or at commit), for synclog
}
@property(readonly) id<MTLDevice> device;
@property(readonly) id<MTLCommandQueue> commandQueue;
@property(copy, atomic) NSString *label;
- (BOOL)begin;
- (void)fail:(NSString *)why;
- (void)barrier;
- (VkDescriptorSet)allocSet:(VkDescriptorSetLayout)dsl;
- (BOOL)upload:(const void *)bytes length:(NSUInteger)len buffer:(VkBuffer *)buf offset:(VkDeviceSize *)off;
- (BOOL)scratch:(NSUInteger)len buffer:(VkBuffer *)buf offset:(VkDeviceSize *)off;   // like upload, nothing written
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
