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
}
@property(readonly) id<MTLDevice> device;
@property(copy, atomic) NSString *label;
@end

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
    MTLTextureUsage _usage;
    MTLStorageMode _storage;
    id<MTLDevice> _dev;
    // IOSurface-backed (stage 4d): the image is a private GPU copy; _staging is laid out like the surface's plane.
    IOSurfaceRef _surface;
    NSUInteger _plane, _surfaceBpr;
    uint32_t _syncedSeed;   // the surface seed the image matches (after a pull or our own copy-out)
    BOOL _neverSynced;
    vg_buffer _staging;
}
@property(readonly) id<MTLDevice> device;
@property(copy, atomic) NSString *label;
@end

// The surface's CPU contents -> the image, when the surface changed since the image last matched it (synchronous).
void vg_surface_pull(VGMTLTexture *t);
// Records that `cmd` writes texture `t`: a surface texture is copied back to its IOSurface when `cmd` completes.
void vg_cmd_wrote(id cmd, VGMTLTexture *t);
id<MTLTexture> vg_new_surface_texture(id<MTLDevice> device, MTLTextureDescriptor *d, IOSurfaceRef surface, NSUInteger plane);

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
    VkDescriptorPool _pools[64];
    int _npools;
    uint32_t _setsInPool;
    NSMutableArray *_keep;   // resources referenced until completion
    NSMutableArray *_handlers;
    dispatch_group_t _done;
    vg_buffer _arena[64];   // setBytes data
    int _narena;
    VkDeviceSize _arenaUsed;
    MTLCommandBufferStatus _status;
    NSError *_error;
    uint64_t _submitted, _completed;
    NSMutableSet *_surfacesWritten;   // VGMTLTexture with an IOSurface, copied out at completion
    NSMutableArray *_drawables;       // presented after the copy-out
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
id<MTLSamplerState> vg_new_sampler(id<MTLDevice> device, MTLSamplerDescriptor *d);
id<MTLDepthStencilState> vg_new_depth_stencil(id<MTLDevice> device, MTLDepthStencilDescriptor *d);
id<MTLRenderPipelineState> vg_new_render_pipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor *d, NSError **error);
VkFormat vg_vk_format(MTLPixelFormat f);
// Runs `record` in a one-time command buffer and waits for it (texture uploads, readbacks, layout setup).
BOOL vg_one_shot(void (^record)(VkCommandBuffer cb));
