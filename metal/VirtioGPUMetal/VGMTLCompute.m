// Stage 4b: Metal compute on Venus (and the command buffer the render encoder of 4c shares). Buffers, command queues and buffers, compute and blit encoders, compute
// pipelines. Deliberately simple: every buffer is host-visible coherent memory (the host GPU is integrated), a command
// buffer is one VkCommandBuffer submitted at commit, a full memory barrier follows every command, and completion is a
// VkFence waited on a background queue.
//
// Kernel dispatch follows the translator's contract (metal2vulkan docs/HOWTO.md, "Configure the stage interface"):
// `[[buffer(n)]]` is set 0 binding n, the local size is specialization constants 0..2, and a ThreadsDynamic kernel
// reads a 48-byte push-constant block (thread grid, thread base, threadgroup base, threadgroup grid) per region of
// KernelDispatch::plan (full groups, then the partial tail of each dimension with its own local size).
#import "objects.h"
#import <mach/mach_time.h>
#import <objc/runtime.h>

// ---- MTLBuffer ---------------------------------------------------------------------------------------------------

@implementation VGMTLBuffer
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)identity { return KERN_SUCCESS; }   // memory accounting (5d)
// The blob resource of this buffer's memory, for tools (5c: tools/blobtest).
- (uint32_t)vgResId { return vg_memory_res_id(_b.memory); }
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (void)dealloc {
    vg_staging_put(&_b);   // back to the pool: a command buffer that used it holds it until it is done (5c round 6)
    if (_deallocator) {
        _deallocator(_host, _length);
    }
}
- (void *)contents { return _host ? _host : _b.map; }
// Textures over the buffer's memory (public, and Core Animation's tiled / linear SPI).
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bpr {
    return vg_new_buffer_texture(self, d, offset, bpr);
}
- (id<MTLTexture>)newTiledTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bpr {
    return vg_new_buffer_texture(self, d, offset, bpr);
}
- (id<MTLTexture>)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset
                                      bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi {
    return vg_new_buffer_texture(self, d, offset, bpr);
}
// Metal's own no-copy path makes [[buffer class] alloc] and sends this (seen from WindowServer, 5b).
- (instancetype)initStandinWithDevice:(id<MTLDevice>)device bytesNoCopy:(void *)pointer length:(NSUInteger)length
                          deallocator:(void (^)(void *, NSUInteger))deallocator {
    if ((self = [super init])) {
        if (vg_vulkan_init() || vg_staging_get(length ? length : 4, &_b)) {
            return nil;
        }
        _length = length;
        _dev = device;
        _host = pointer;
        _deallocator = deallocator;
        if (pointer) {
            memcpy(_b.map, pointer, length);
        } else {
            memset(_b.map, 0, length);   // pooled memory: as new
        }
    }
    return self;
}
- (NSUInteger)length { return _length; }
- (NSUInteger)allocatedSize { return (NSUInteger)_b.size; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_options >> MTLResourceStorageModeShift) & 0xf); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)(_options & 0xf); }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (void)didModifyRange:(NSRange)range { }   // coherent memory
- (uint64_t)gpuAddress { return 0; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return vg_purgeable(self, state); }
- (BOOL)isAliasable { return vg_heap_aliasable(self); }
- (void)makeAliasable { vg_heap_make_aliasable(self); }
- (id<MTLHeap>)heap { return vg_heap_of(self); }
- (NSUInteger)heapOffset { return vg_heap_offset_of(self); }
@end

id<MTLBuffer> vg_new_buffer(id<MTLDevice> device, NSUInteger length, MTLResourceOptions options, const void *bytes) {
    if (vg_vulkan_init()) {
        return nil;
    }
    VGMTLBuffer *b = [VGMTLBuffer new];
    if (vg_staging_get(length ? length : 4, &b->_b)) {   // pooled (5c round 6)
        return nil;
    }
    b->_length = length;
    b->_options = options;
    b->_dev = device;
    if (bytes) {
        memcpy(b->_b.map, bytes, length);
    } else {
        memset(b->_b.map, 0, length);   // pooled memory: as new (Metal's new buffers read as zeros)
    }
    return b;
}

id<MTLBuffer> vg_new_buffer_nocopy(id<MTLDevice> device, void *pointer, NSUInteger length, MTLResourceOptions options,
                                   void (^deallocator)(void *, NSUInteger)) {
    VGMTLBuffer *b = (VGMTLBuffer *)vg_new_buffer(device, length, options, pointer);
    if (b) {
        b->_host = pointer;
        b->_deallocator = deallocator;
    }
    return b;
}

// ---- SPIR-V: what each binding of a set is ----------------------------------------------------------------------

// Reads OpDecorate DescriptorSet/Binding/Block/BufferBlock, the pointer and image types and OpVariable:
// StorageBuffer (and Uniform+BufferBlock) -> storage buffer, Uniform -> uniform buffer, UniformConstant of
// OpTypeImage -> sampled (Sampled 1) or storage (Sampled 2) image, OpTypeSampler -> sampler,
// OpTypeSampledImage -> combined. Arrays of descriptors are refused with a message; push constants aren't
// bindings (vg_spirv_has_push_constants).
int vg_spirv_bindings(NSData *spv, uint32_t wantSet, vg_binding *out, int max, NSString **error) {
    const uint32_t *w = spv.bytes;
    size_t n = spv.length / 4;
    if (n < 5 || w[0] != 0x07230203) {
        *error = @"not SPIR-V";
        return -1;
    }
    size_t bound = w[3];
    uint32_t *set = calloc(bound, 4), *bind = calloc(bound, 4), *ptrType = calloc(bound, 4);
    uint8_t *block = calloc(bound, 1), *hasBind = calloc(bound, 1), *kind = calloc(bound, 1);
    typedef struct { uint32_t id, type, cls; } var;
    var *vars = calloc(bound, sizeof(var));
    size_t nvars = 0;
    enum { kImageSampled = 1, kImageStorage, kSampler, kSampledImage, kArray };
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, len = w[i] >> 16;
        if (!len || i + len > n) {
            break;
        }
        uint32_t id = len > 1 ? w[i + 1] : 0;
        if (op == 71 && len >= 3 && id < bound) {   // OpDecorate id decoration [value]
            uint32_t d = w[i + 2];
            if (d == 34 && len >= 4) {
                set[id] = w[i + 3];
            } else if (d == 33 && len >= 4) {
                bind[id] = w[i + 3];
                hasBind[id] = 1;
            } else if (d == 2) {
                block[id] = 1;
            } else if (d == 3) {
                block[id] = 2;
            }
        } else if (op == 32 && len >= 4 && id < bound) {   // OpTypePointer result class type
            ptrType[id] = w[i + 3];
        } else if (op == 25 && len >= 9 && id < bound) {   // OpTypeImage result sampledType dim depth arrayed ms sampled format
            kind[id] = w[i + 7] == 2 ? kImageStorage : kImageSampled;
        } else if (op == 26 && id < bound) {
            kind[id] = kSampler;
        } else if (op == 27 && id < bound) {
            kind[id] = kSampledImage;
        } else if ((op == 28 || op == 29) && id < bound) {   // OpTypeArray / OpTypeRuntimeArray
            kind[id] = kArray;
        } else if (op == 59 && len >= 4 && w[i + 2] < bound) {   // OpVariable type result class
            vars[nvars++] = (var){w[i + 2], w[i + 1], w[i + 3]};
        }
        i += len;
    }
    int count = 0, rc = *error ? -1 : 0;
    for (size_t v = 0; v < nvars && !rc; v++) {
        uint32_t id = vars[v].id;
        if (!hasBind[id]) {
            continue;
        }
        if (set[id] == 3 && bind[id] >= 192 && bind[id] < 200) {
            continue;   // [[color(n)]] framebuffer fetch: its own set, made by the render code (VGMTLRender.m)
        }
        if (set[id] != wantSet || bind[id] >= 640) {   // the bindless heap (set 2) or the buffer address table (640+)
            *error = [NSString stringWithFormat:@"the module uses set %u binding %u (bindless heap / address table): "
                                                @"not supported yet", set[id], bind[id]];
            rc = -1;
            break;
        }
        uint32_t pointee = vars[v].type < bound ? ptrType[vars[v].type] : 0;
        uint8_t k = pointee < bound ? kind[pointee] : 0;
        VkDescriptorType t;
        if (vars[v].cls == 12) {   // StorageBuffer
            t = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        } else if (vars[v].cls == 2) {   // Uniform
            t = (pointee < bound && block[pointee] == 2) ? VK_DESCRIPTOR_TYPE_STORAGE_BUFFER : VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        } else if (vars[v].cls == 0 && k == kImageSampled) {
            t = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
        } else if (vars[v].cls == 0 && k == kImageStorage) {
            t = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
        } else if (vars[v].cls == 0 && k == kSampler) {
            t = VK_DESCRIPTOR_TYPE_SAMPLER;
        } else if (vars[v].cls == 0 && k == kSampledImage) {
            t = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        } else {
            *error = [NSString stringWithFormat:@"binding %u (storage class %u, kind %u) not supported yet", bind[id],
                                                vars[v].cls, k];
            rc = -1;
            break;
        }
        if (count < max) {
            out[count++] = (vg_binding){bind[id], t};
        }
    }
    free(set), free(bind), free(ptrType), free(block), free(hasBind), free(kind), free(vars);
    return rc ? -1 : count;
}

BOOL vg_spirv_has_push_constants(NSData *spv) {
    const uint32_t *w = spv.bytes;
    size_t n = spv.length / 4;
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, len = w[i] >> 16;
        if (!len || i + len > n) {
            break;
        }
        if (op == 59 && len >= 4 && w[i + 3] == 9) {   // OpVariable ... PushConstant
            return YES;
        }
        i += len;
    }
    return NO;
}

NSData *vg_spirv_retarget_set(NSData *spv, uint32_t newSet) {
    NSMutableData *m = [spv mutableCopy];
    uint32_t *w = m.mutableBytes;
    size_t n = m.length / 4;
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, len = w[i] >> 16;
        if (!len || i + len > n) {
            break;
        }
        if (op == 71 && len >= 4 && w[i + 2] == 34 && w[i + 3] == 0) {
            w[i + 3] = newSet;
        }
        i += len;
    }
    return m;
}

// ---- descriptors from a stage's argument tables ------------------------------------------------------------------

// What an unbound slot reads (5b): Metal tolerates a declared resource the draw never touches (Core Animation's
// specialized shaders keep declarations whose uses folded away); Vulkan needs something valid in the descriptor.
// A zeroed 64 KB buffer, a 1x1 transparent 2D texture, a linear clamp sampler.
static VkBuffer vg_dummy_buffer(void) {
    static vg_buffer b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!vg_buffer_create(65536, &b)) {
            memset(b.map, 0, 65536);
        }
    });
    return b.buffer;
}
static VGMTLTexture *vg_dummy_texture(id<MTLDevice> dev) {
    static VGMTLTexture *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:1
                                                                                    height:1
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        t = (VGMTLTexture *)vg_new_texture(dev, d);
        uint32_t zero = 0;
        [t replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&zero bytesPerRow:4];
    });
    return t;
}
static VkSampler vg_dummy_sampler(void) {
    static VkSampler s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VkSamplerCreateInfo ci = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
        ci.magFilter = ci.minFilter = VK_FILTER_LINEAR;
        ci.addressModeU = ci.addressModeV = ci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        ci.maxLod = 1000.0f;
        gVk.vkCreateSampler(gVk.device, &ci, NULL, &s);
    });
    return s;
}
static void vg_unbound(NSString *who, const char *what, int slot) {
    static int logged = 0;
    if (logged++ < 10) {
        vglog("%s: nothing bound at %s(%d): a placeholder instead", who.UTF8String, what, slot);
    }
}

// Descriptor pools recycled between command buffers (5c round 4): reset when a command buffer completes, instead of
// destroyed and created again per command buffer.
static pthread_mutex_t gPoolsLock = PTHREAD_MUTEX_INITIALIZER;
static VkDescriptorPool gFreePools[128];
static int gFreePoolCount;
static VkDescriptorPool vg_pool_get(void) {
    VkDescriptorPool p = VK_NULL_HANDLE;
    pthread_mutex_lock(&gPoolsLock);
    if (gFreePoolCount) {
        p = gFreePools[--gFreePoolCount];
    }
    pthread_mutex_unlock(&gPoolsLock);
    return p;
}
static void vg_pool_put(VkDescriptorPool p) {
    gVk.vkResetDescriptorPool(gVk.device, p, 0);
    pthread_mutex_lock(&gPoolsLock);
    if (gFreePoolCount < 128) {
        gFreePools[gFreePoolCount++] = p;
        p = VK_NULL_HANDLE;
    }
    pthread_mutex_unlock(&gPoolsLock);
    if (p) {
        gVk.vkDestroyDescriptorPool(gVk.device, p, NULL);
    }
}

// Descriptor sets are remembered per command buffer by what they hold (5c round 4): Core Animation's draws often bind
// exactly what the previous draw of the same pipeline bound, and every allocation + update is commands Venus' host
// thread decodes and replays (~8 ms of host CPU per WindowServer frame before the GPU even started).
enum { kVGMemoEntries = 16 };
typedef struct {
    VkDescriptorSetLayout dsl;
    int n;
    uint64_t sig[64 * 3];
    VkDescriptorSet set;
} vg_set_memo;

VkDescriptorSet vg_write_set(VGMTLCommandBuffer *cmd, VkDescriptorSetLayout dsl, const vg_binding *bindings, int n,
                             const vg_stage_bindings *t, NSString *who) {
    VkDescriptorSet set = VK_NULL_HANDLE;   // allocated once we know no remembered set has the same contents
    VkDescriptorBufferInfo binfo[64];
    VkDescriptorImageInfo iinfo[64];
    VkWriteDescriptorSet writes[64];
    for (int i = 0; i < n && i < 64; i++) {
        uint32_t b = bindings[i].binding;
        VkDescriptorType type = bindings[i].type;
        writes[i] = (VkWriteDescriptorSet){VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, b, 0, 1, type, NULL, NULL, NULL};
        if (type == VK_DESCRIPTOR_TYPE_STORAGE_BUFFER || type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            VkDeviceSize range = VK_WHOLE_SIZE;
            if (type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
                range = MIN((VkDeviceSize)gVk.props.limits.maxUniformBufferRange, 65536);
            }
            if (b >= kVGMaxBufferSlots || !t->buf[b]) {
                vg_unbound(who, "buffer", (int)b);
                binfo[i] = (VkDescriptorBufferInfo){vg_dummy_buffer(), 0, VK_WHOLE_SIZE};
            } else {
                binfo[i] = (VkDescriptorBufferInfo){t->buf[b], t->off[b], range};
            }
            writes[i].pBufferInfo = &binfo[i];
            continue;
        }
        uint32_t slot;
        if (type == VK_DESCRIPTOR_TYPE_SAMPLER) {
            slot = b - kVGSamplerBase;
            if (b < kVGSamplerBase || slot >= kVGMaxSamplerSlots || !t->smp[slot]) {
                vg_unbound(who, "sampler", (int)b - kVGSamplerBase);
                iinfo[i] = (VkDescriptorImageInfo){vg_dummy_sampler(), VK_NULL_HANDLE, VK_IMAGE_LAYOUT_UNDEFINED};
            } else {
                iinfo[i] = (VkDescriptorImageInfo){t->smp[slot]->_sampler, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_UNDEFINED};
            }
        } else {
            uint32_t base = type == VK_DESCRIPTOR_TYPE_STORAGE_IMAGE ? kVGStorageTextureBase : kVGTextureBase;
            slot = b - base;
            VGMTLTexture *tex = (b >= base && slot < kVGMaxTextureSlots) ? t->tex[slot] : nil;
            if (!tex && type == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE) {
                vg_unbound(who, "texture", (int)b - (int)base);
                tex = vg_dummy_texture(cmd.device);
            }
            if (!tex) {
                [cmd fail:[NSString stringWithFormat:@"%@: nothing bound at texture(%d)", who, (int)b - (int)base]];
                return VK_NULL_HANDLE;
            }
            iinfo[i] = (VkDescriptorImageInfo){VK_NULL_HANDLE, tex->_view, VK_IMAGE_LAYOUT_GENERAL};
            if (type == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
                [cmd fail:[NSString stringWithFormat:@"%@: combined image-samplers aren't supported yet", who]];
                return VK_NULL_HANDLE;
            }
        }
        writes[i].pImageInfo = &iinfo[i];
    }
    // the contents, as compared against the remembered sets
    int m = MIN(n, 64);
    uint64_t sig[64 * 3];
    for (int i = 0; i < m; i++) {
        if (writes[i].pBufferInfo) {
            sig[3 * i] = (uint64_t)binfo[i].buffer, sig[3 * i + 1] = binfo[i].offset, sig[3 * i + 2] = binfo[i].range;
        } else {
            sig[3 * i] = (uint64_t)iinfo[i].sampler, sig[3 * i + 1] = (uint64_t)iinfo[i].imageView,
                    sig[3 * i + 2] = writes[i].descriptorType;
        }
    }
    if (!cmd->_setMemo) {
        cmd->_setMemo = calloc(kVGMemoEntries, sizeof(vg_set_memo));
    }
    vg_set_memo *memo = cmd->_setMemo;
    for (int e = 0; memo && e < kVGMemoEntries; e++) {
        if (memo[e].set && memo[e].dsl == dsl && memo[e].n == m && !memcmp(memo[e].sig, sig, sizeof(uint64_t) * 3 * m)) {
            vg_perf(VG_PERF_SET_REUSED, 0, 0);
            return memo[e].set;
        }
    }
    set = [cmd allocSet:dsl];
    if (!set) {
        [cmd fail:@"no descriptor set"];
        return VK_NULL_HANDLE;
    }
    for (int i = 0; i < m; i++) {
        writes[i].dstSet = set;
    }
    gVk.vkUpdateDescriptorSets(gVk.device, (uint32_t)m, writes, 0, NULL);
    vg_perf(VG_PERF_SET_WRITTEN, 0, 0);
    if (memo) {
        vg_set_memo *e = &memo[cmd->_setMemoNext++ % kVGMemoEntries];
        e->dsl = dsl, e->n = m, e->set = set;
        memcpy(e->sig, sig, sizeof(uint64_t) * 3 * m);
    }
    return set;
}

// ---- MTLComputePipelineState -------------------------------------------------------------------------------------

// One translation (the threadgroup-memory lengths are baked into the SPIR-V) and its layout; pipelines per local size.
@interface VGComputeVariant : NSObject {
@public
    VkShaderModule module;
    VkDescriptorSetLayout dsl;
    VkPipelineLayout layout;
    vg_binding bindings[64];
    int nbindings;
    NSMutableDictionary<NSString *, NSValue *> *pipelines;   // "x,y,z" -> VkPipeline
}
@end
@implementation VGComputeVariant
@end

@interface VGMTLComputePipelineState : NSObject <MTLComputePipelineState> {
@public
    NSString *_ll;
    NSDictionary<NSNumber *, NSData *> *_fc;
    NSString *_name;
    BOOL _dynamic;          // ThreadsDynamic: the 48-byte region block at _pushOffset; otherwise Workgroups
    uint32_t _pushOffset;
    uint32_t _maxThreads;
    NSMutableDictionary<NSString *, VGComputeVariant *> *_variants;   // threadgroup-length key -> variant
    NSObject *_lock;
    id<MTLDevice> _dev;
}
@property(readonly) id<MTLDevice> device;
@property(readonly) NSString *label;
@end

@implementation VGMTLComputePipelineState
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _maxThreads; }
- (NSUInteger)threadExecutionWidth { return 32; }   // Metal's simdgroup width, which the translator keeps
- (NSUInteger)staticThreadgroupMemoryLength { return 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){0}; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d { return 0; }

- (VGComputeVariant *)variantFor:(const uint32_t *)tg error:(NSString **)error {
    NSMutableString *key = [NSMutableString string];
    for (int i = 0; i < kVGMaxThreadgroupSlots; i++) {
        if (tg[i]) {
            [key appendFormat:@"%d=%u,", i, tg[i]];
        }
    }
    @synchronized(_lock) {
        VGComputeVariant *v = _variants[key];
        if (v) {
            return v;
        }
        uint64_t t0 = mach_absolute_time();
        NSData *spv = vg_translate(_ll, "kernel", _fc, tg, kVGMaxThreadgroupSlots, error);
        if (!spv) {
            return nil;
        }
        v = [VGComputeVariant new];
        v->pipelines = [NSMutableDictionary dictionary];
        v->nbindings = vg_spirv_bindings(spv, 0, v->bindings, 64, error);
        if (v->nbindings < 0) {
            return nil;
        }
        VkShaderModuleCreateInfo smci = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, spv.length, spv.bytes};
        VkResult r = gVk.vkCreateShaderModule(gVk.device, &smci, NULL, &v->module);
        VkDescriptorSetLayoutBinding lb[64];
        for (int i = 0; i < v->nbindings; i++) {
            lb[i] = (VkDescriptorSetLayoutBinding){v->bindings[i].binding, v->bindings[i].type, 1,
                                                   VK_SHADER_STAGE_COMPUTE_BIT, NULL};
        }
        VkDescriptorSetLayoutCreateInfo dci = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0,
                                               (uint32_t)v->nbindings, lb};
        if (r == VK_SUCCESS) {
            r = gVk.vkCreateDescriptorSetLayout(gVk.device, &dci, NULL, &v->dsl);
        }
        VkPushConstantRange pcr = {VK_SHADER_STAGE_COMPUTE_BIT, 0, _pushOffset + 48};
        VkPipelineLayoutCreateInfo plci = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &v->dsl,
                                           _dynamic ? 1u : 0u, &pcr};
        if (r == VK_SUCCESS) {
            r = gVk.vkCreatePipelineLayout(gVk.device, &plci, NULL, &v->layout);
        }
        if (r != VK_SUCCESS) {
            *error = [NSString stringWithFormat:@"shader module / layout: VkResult %d", r];
            return nil;
        }
        vglog("pipeline %s: translated (%s) to %lu bytes of SPIR-V, %d bindings, in %.1f ms", _name.UTF8String,
              key.length ? key.UTF8String : "no threadgroup memory", (unsigned long)spv.length, v->nbindings,
              (mach_absolute_time() - t0) / 1e6);
        _variants[key] = v;
        return v;
    }
}

- (VkPipeline)pipelineFor:(VGComputeVariant *)v local:(const uint32_t *)ls error:(NSString **)error {
    NSString *key = [NSString stringWithFormat:@"%u,%u,%u", ls[0], ls[1], ls[2]];
    @synchronized(_lock) {
        NSValue *have = v->pipelines[key];
        if (have) {
            return (VkPipeline)have.pointerValue;
        }
        VkSpecializationMapEntry me[3] = {{0, 0, 4}, {1, 4, 4}, {2, 8, 4}};
        VkSpecializationInfo si = {3, me, 12, ls};
        VkComputePipelineCreateInfo cpci = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
        cpci.stage = (VkPipelineShaderStageCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
                                                       VK_SHADER_STAGE_COMPUTE_BIT, v->module, "main", &si};
        cpci.layout = v->layout;
        VkPipeline p = VK_NULL_HANDLE;
        uint64_t t0 = mach_absolute_time();
        VkResult r = gVk.vkCreateComputePipelines(gVk.device, VK_NULL_HANDLE, 1, &cpci, NULL, &p);
        if (r != VK_SUCCESS) {
            *error = [NSString stringWithFormat:@"vkCreateComputePipelines %d", r];
            return VK_NULL_HANDLE;
        }
        vglog("pipeline %s: local size %s built in %.1f ms", _name.UTF8String, key.UTF8String,
              (mach_absolute_time() - t0) / 1e6);
        v->pipelines[key] = [NSValue valueWithPointer:p];
        return p;
    }
}
@end

id<MTLComputePipelineState> vg_new_compute_pipeline(id<MTLDevice> device, id<MTLFunction> function, NSError **error) {
    if (error) {
        *error = nil;
    }
    NSString *why = nil;
    NSDictionary *refl = nil;
    if (![(NSObject *)function respondsToSelector:@selector(vgLL)] || ![[(NSObject *)function vgStage] isEqual:@"kernel"]) {
        why = @"not a VirtioGPUMetal kernel function";
    } else if (vg_vulkan_init()) {
        why = @"Venus is down";
    } else {
        refl = vg_reflect([(NSObject *)function vgLL], "kernel", [(NSObject *)function vgFC], &why);
    }
    VGMTLComputePipelineState *p = nil;
    if (refl) {
        p = [VGMTLComputePipelineState new];
        p->_dev = device;
        p->_name = function.name;
        p->_ll = [(NSObject *)function vgLL];
        p->_fc = [(NSObject *)function vgFC];
        p->_variants = [NSMutableDictionary dictionary];
        p->_lock = [NSObject new];
        id kd = refl[@"kernel_dispatch"];
        if ([kd isKindOfClass:[NSDictionary class]] && kd[@"ThreadsDynamic"]) {
            p->_dynamic = YES;
            p->_pushOffset = [kd[@"ThreadsDynamic"][@"offset"] unsignedIntValue];
        } else if ([kd isKindOfClass:[NSString class]] && [kd isEqual:@"Workgroups"]) {
            p->_dynamic = NO;
        } else {
            why = [NSString stringWithFormat:@"kernel dispatch %@ not supported yet", kd];
            p = nil;
        }
        id mx = refl[@"max_work_group_size"];
        if (p) {
            p->_maxThreads = [mx isKindOfClass:[NSNumber class]] ? MIN([mx unsignedIntValue], 1024u) : 1024u;
        }
        for (NSDictionary *b in refl[@"bindings"]) {
            NSString *kind = b[@"kind"];
            if (p && ![@[ @"Buffer", @"ThreadgroupBuffer", @"Texture", @"StorageImage", @"Sampler" ] containsObject:kind]) {
                why = [NSString stringWithFormat:@"binding kind %@ not supported yet", kind];
                p = nil;
            }
        }
    }
    if (!p) {
        vglog("pipeline %s: refused: %s", function.name.UTF8String, why.UTF8String);
        if (error) {
            *error = [NSError errorWithDomain:@"VirtioGPUMetal" code:1 userInfo:@{NSLocalizedDescriptionKey : why ?: @"?"}];
        }
    }
    return p;
}

// ---- MTLCommandBuffer and encoders -----------------------------------------------------------------------------

@class VGMTLCommandQueue;

// Command buffers of one queue complete in commit order on the queue's serial queue (one VkQueue runs them in that
// order anyway), and their completed handlers run in that order on the caller's completion queue when it set one
// (Core Animation does, -setCompletionQueue:, and keeps fence bookkeeping that isn't safe from concurrent handlers).
@interface VGMTLCommandQueue : NSObject <MTLCommandQueue> {
@public
    dispatch_queue_t _serial;
    dispatch_queue_t _userCompletion;
}
@property(readonly) id<MTLDevice> device;
@property(copy, atomic) NSString *label;
@end

@implementation VGMTLCommandQueue
@synthesize device = _device, label = _label;
// Priorities (5d: Core Image, WebKit): one Vulkan queue, so accepted and not applied.
- (BOOL)setBackgroundGPUPriority:(NSUInteger)priority { return YES; }
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
        // USER_INTERACTIVE (5c round 3): Venus waits for a fence with short sleeps, which macOS stretches at lower
        // classes; completions gate what WindowServer shows next.
        _serial = dispatch_queue_create("local.homelab.VirtioGPUMetal.completion",
                                        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                QOS_CLASS_USER_INTERACTIVE, 0));
    }
    return self;
}
- (void)setCompletionQueue:(dispatch_queue_t)q { _userCompletion = q; }
- (void)setSubmissionQueue:(dispatch_queue_t)q { }
- (void)setGPUPriority:(NSUInteger)p { }
- (id<MTLCommandBuffer>)commandBuffer;
{
    VGMTLCommandBuffer *c = [VGMTLCommandBuffer new];
    [c setValue:_device forKey:@"device"];
    [c setValue:self forKey:@"commandQueue"];
    VGCALL("queue %p commandBuffer -> %p", self, c);
    return c;
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)d { return [self commandBuffer]; }
- (void)insertDebugCaptureBoundary { }
@end

id<MTLCommandQueue> vg_new_queue(id<MTLDevice> device) {
    return vg_vulkan_init() ? nil : [[VGMTLCommandQueue alloc] initWithDevice:device];
}

@implementation VGEncoder
@synthesize device = _device, label = _label;
- (instancetype)initWithCommandBuffer:(VGMTLCommandBuffer *)cmd {
    if ((self = [super init])) {
        _owner = cmd;
        _device = cmd.device;
    }
    return self;
}
- (void)endEncoding {
    VGCALL("encoder %p (%s) endEncoding", self, object_getClassName(self));
    vg_callstack("endEncoding");
}
// Fences (5d): nothing to do. Every encoder ends with a full barrier and every queue submits to the one Vulkan queue in
// order, so whatever a fence orders is already ordered.
- (void)updateFence:(id<MTLFence>)fence { }
- (void)waitForFence:(id<MTLFence>)fence { }
- (void)updateFence:(id<MTLFence>)fence afterStages:(MTLRenderStages)stages { }
- (void)waitForFence:(id<MTLFence>)fence beforeStages:(MTLRenderStages)stages { }
- (uint64_t)globalTraceObjectID { return 0; }
- (void)insertDebugSignpost:(NSString *)s { }
- (void)pushDebugGroup:(NSString *)s { }
- (void)popDebugGroup { }
@end

VkBuffer vg_vkbuffer(id<MTLBuffer> b) {
    if (![(NSObject *)b isKindOfClass:[VGMTLBuffer class]]) {
        return VK_NULL_HANDLE;
    }
    VGMTLBuffer *vb = (VGMTLBuffer *)b;
    if (vb->_host) {
        memcpy(vb->_b.map, vb->_host, vb->_length);   // a no-copy buffer: what the CPU wrote, at bind time
    }
    return vb->_b.buffer;
}

@interface VGComputeEncoder : VGEncoder <MTLComputeCommandEncoder> {
@public
    VGMTLComputePipelineState *_pso;
    vg_stage_bindings _t;
    uint32_t _tg[kVGMaxThreadgroupSlots];
}
@end

@implementation VGComputeEncoder
- (MTLDispatchType)dispatchType { return MTLDispatchTypeSerial; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state {
    _pso = (VGMTLComputePipelineState *)state;
    if (state) {
        [_owner->_keep addObject:state];
    }
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (index >= kVGMaxBufferSlots) {
        return;
    }
    _t.buf[index] = vg_vkbuffer(buffer);
    _t.off[index] = offset;
    if (buffer) {
        [_owner->_keep addObject:buffer];
    }
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    if (index < kVGMaxTextureSlots) {
        _t.tex[index] = [(NSObject *)texture isKindOfClass:[VGMTLTexture class]] ? (VGMTLTexture *)texture : nil;
        if (texture) {
            [_owner->_keep addObject:texture];
            vg_surface_pull(_t.tex[index]);
            if (texture.usage & MTLTextureUsageShaderWrite) {
                vg_cmd_wrote(_owner, _t.tex[index]);
            }
        }
    }
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (index < kVGMaxSamplerSlots) {
        _t.smp[index] = (VGMTLSamplerState *)sampler;
        if (sampler) {
            [_owner->_keep addObject:sampler];
        }
    }
}
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (index < kVGMaxBufferSlots) {
        _t.off[index] = offset;
    }
}
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained[])buffers offsets:(const NSUInteger[])offsets withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) {
        [self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
    }
}
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index {
    if (index >= kVGMaxBufferSlots) {
        return;
    }
    if (![_owner upload:bytes length:length buffer:&_t.buf[index] offset:&_t.off[index]]) {
        [_owner fail:@"setBytes: no upload memory"];
    }
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index {
    if (index < kVGMaxThreadgroupSlots) {
        _tg[index] = (uint32_t)length;
    }
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u { }
- (void)useResources:(const id<MTLResource> __unsafe_unretained[])r count:(NSUInteger)n usage:(MTLResourceUsage)u { }
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope { }   // every dispatch is followed by a full barrier
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained[])r count:(NSUInteger)n { }

// The translator's KernelDispatch::plan, here: per dimension the full groups, then the tail as one smaller group.
- (void)dispatchGrid:(MTLSize)threads local:(MTLSize)tptg {
    VGCALL("cb %p dispatch %s %lux%lux%lu local %lux%lux%lu", _owner, _pso ? _pso->_name.UTF8String : "(no pipeline)",
           (unsigned long)threads.width, (unsigned long)threads.height, (unsigned long)threads.depth,
           (unsigned long)tptg.width, (unsigned long)tptg.height, (unsigned long)tptg.depth);
    if (!_pso) {
        [_owner fail:@"dispatch without a compute pipeline"];
        return;
    }
    uint32_t grid[3] = {(uint32_t)threads.width, (uint32_t)threads.height, (uint32_t)threads.depth};
    uint32_t nominal[3] = {(uint32_t)tptg.width, (uint32_t)tptg.height, (uint32_t)tptg.depth};
    if (!grid[0] || !grid[1] || !grid[2]) {
        return;
    }
    if (!nominal[0] || !nominal[1] || !nominal[2] || (uint64_t)nominal[0] * nominal[1] * nominal[2] > _pso->_maxThreads) {
        [_owner fail:[NSString stringWithFormat:@"threadgroup %ux%ux%u", nominal[0], nominal[1], nominal[2]]];
        return;
    }
    NSString *why = nil;
    VGComputeVariant *v = [_pso variantFor:_tg error:&why];
    if (!v || ![_owner begin]) {
        [_owner fail:why ?: @"no command buffer"];
        return;
    }
    // One descriptor set for every region: the same resources.
    VkDescriptorSet set = vg_write_set(_owner, v->dsl, v->bindings, v->nbindings, &_t, _pso->_name);
    if (!set) {
        return;
    }
    uint32_t groups[3];
    for (int d = 0; d < 3; d++) {
        groups[d] = (grid[d] + nominal[d] - 1) / nominal[d];
    }
    for (unsigned mask = 0; mask < 8; mask++) {
        uint32_t local[3], count[3], tbase[3] = {0}, gbase[3] = {0};
        BOOL nonempty = YES;
        for (int d = 0; d < 3; d++) {
            uint32_t full = grid[d] / nominal[d], tail = grid[d] % nominal[d];
            local[d] = nominal[d];
            if (!(mask & (1u << d))) {
                count[d] = full;
            } else if (!tail) {
                nonempty = NO;
                count[d] = 0;
            } else {
                local[d] = tail;
                count[d] = 1;
                tbase[d] = full * nominal[d];
                gbase[d] = full;
            }
            nonempty = nonempty && count[d];
        }
        if (!nonempty) {
            continue;
        }
        if (!_pso->_dynamic && mask) {
            [_owner fail:@"a whole-workgroup kernel dispatched with a partial threadgroup"];
            return;
        }
        VkPipeline p = [_pso pipelineFor:v local:local error:&why];
        if (!p) {
            [_owner fail:why];
            return;
        }
        gVk.vkCmdBindPipeline(_owner->_cb, VK_PIPELINE_BIND_POINT_COMPUTE, p);
        gVk.vkCmdBindDescriptorSets(_owner->_cb, VK_PIPELINE_BIND_POINT_COMPUTE, v->layout, 0, 1, &set, 0, NULL);
        if (_pso->_dynamic) {
            uint32_t pc[12] = {grid[0], grid[1], grid[2], tbase[0], tbase[1], tbase[2],
                               gbase[0], gbase[1], gbase[2], groups[0], groups[1], groups[2]};
            gVk.vkCmdPushConstants(_owner->_cb, v->layout, VK_SHADER_STAGE_COMPUTE_BIT, _pso->_pushOffset, sizeof(pc), pc);
        }
        gVk.vkCmdDispatch(_owner->_cb, count[0], count[1], count[2]);
    }
    [_owner barrier];
}
- (void)dispatchThreads:(MTLSize)threads threadsPerThreadgroup:(MTLSize)tptg {
    [self dispatchGrid:threads local:tptg];
}
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)tptg {
    [self dispatchGrid:MTLSizeMake(groups.width * tptg.width, groups.height * tptg.height, groups.depth * tptg.depth)
                 local:tptg];
}
@end

@interface VGBlitEncoder : VGEncoder <MTLBlitCommandEncoder>
@end

@implementation VGBlitEncoder
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)dst
     destinationOffset:(NSUInteger)doff size:(NSUInteger)size {
    VkBuffer s = vg_vkbuffer(src), d = vg_vkbuffer(dst);
    if (!s || !d || ![_owner begin]) {
        [_owner fail:@"copyFromBuffer: not our buffers"];
        return;
    }
    [_owner->_keep addObject:src];
    [_owner->_keep addObject:dst];
    if (size) {
        VkBufferCopy region = {so, doff, size};
        gVk.vkCmdCopyBuffer(_owner->_cb, s, d, 1, &region);
        [_owner barrier];
    }
}
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
    VkBuffer b = vg_vkbuffer(buffer);
    if (!b || ![_owner begin]) {
        [_owner fail:@"fillBuffer: not our buffer"];
        return;
    }
    if ((range.location | range.length) & 3) {
        [_owner fail:@"fillBuffer: range not 4-byte aligned (not supported yet)"];
        return;
    }
    [_owner->_keep addObject:buffer];
    if (range.length) {
        gVk.vkCmdFillBuffer(_owner->_cb, b, range.location, range.length, value * 0x01010101u);
        [_owner barrier];
    }
}
- (void)synchronizeResource:(id<MTLResource>)r { VGCALL("cb %p synchronizeResource %p", _owner, r); }   // coherent memory
- (void)synchronizeTexture:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l { }
// Each level from the one above with a linear blit (5d: WebKit's canvas and WebGL). Images live in GENERAL; a barrier
// between levels orders each read after the previous write.
static VGMTLTexture *vg_blit_texture(VGMTLCommandBuffer *cmd, id<MTLTexture> t, BOOL writes);
- (void)generateMipmapsForTexture:(id<MTLTexture>)t {
    VGMTLTexture *x = vg_blit_texture(_owner, t, YES);
    if (!x || x->_mips < 2 || ![_owner begin]) {
        return;
    }
    VkCommandBuffer cb = _owner->_cb;
    [_owner barrier];
    int32_t w = (int32_t)x->_width, h = (int32_t)x->_height, d = (int32_t)MAX(x->_depth, 1);
    for (uint32_t l = 1; l < x->_mips; l++) {
        int32_t nw = MAX(w / 2, 1), nh = MAX(h / 2, 1), nd = MAX(d / 2, 1);
        VkImageBlit b = {{x->_aspect, l - 1, 0, (uint32_t)x->_layers}, {{0, 0, 0}, {w, h, d}},
                         {x->_aspect, l, 0, (uint32_t)x->_layers}, {{0, 0, 0}, {nw, nh, nd}}};
        gVk.vkCmdBlitImage(cb, x->_image, VK_IMAGE_LAYOUT_GENERAL, x->_image, VK_IMAGE_LAYOUT_GENERAL, 1, &b,
                           VK_FILTER_LINEAR);
        [_owner barrier];
        w = nw, h = nh, d = nd;
    }
}
- (uint64_t)globalTraceObjectID { return 0; }

// ---- texture copies (5b: Core Animation and MPS in WindowServer) ----
static VGMTLTexture *vg_blit_texture(VGMTLCommandBuffer *cmd, id<MTLTexture> t, BOOL writes) {
    if (![(NSObject *)t isKindOfClass:[VGMTLTexture class]]) {
        return nil;
    }
    VGMTLTexture *v = (VGMTLTexture *)t;
    [cmd->_keep addObject:v];
    if (writes) {
        vg_cmd_wrote(cmd, v);
    } else {
        vg_surface_pull(v);
    }
    return v;
}
static VkImageSubresourceLayers vg_layers(VGMTLTexture *t, NSUInteger slice, NSUInteger level) {
    return (VkImageSubresourceLayers){t->_aspect & ~VK_IMAGE_ASPECT_STENCIL_BIT, (uint32_t)level, (uint32_t)slice, 1};
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)bpr
    destinationBytesPerImage:(NSUInteger)bpi options:(MTLBlitOption)opt {
    VGMTLTexture *s = vg_blit_texture(_owner, src, NO);
    VkBuffer d = vg_vkbuffer(dst);
    NSUInteger bpp = s ? vg_bytes_per_pixel(s->_pixelFormat) : 0;
    if (!s || !d || !bpp || ![_owner begin]) {
        [_owner fail:@"copyFromTexture:toBuffer: not our objects or format"];
        return;
    }
    [_owner->_keep addObject:dst];
    VkBufferImageCopy r = {doff, (uint32_t)(bpr / bpp), bpr ? (uint32_t)(bpi / bpr) : 0, vg_layers(s, ss, sl),
                           {(int32_t)so.x, (int32_t)so.y, (int32_t)so.z},
                           {(uint32_t)size.width, (uint32_t)size.height, (uint32_t)MAX(size.depth, 1u)}};
    gVk.vkCmdCopyImageToBuffer(_owner->_cb, s->_image, VK_IMAGE_LAYOUT_GENERAL, d, 1, &r);
    [_owner barrier];
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)bpr
    destinationBytesPerImage:(NSUInteger)bpi {
    [self copyFromTexture:src sourceSlice:ss sourceLevel:sl sourceOrigin:so sourceSize:size toBuffer:dst
        destinationOffset:doff destinationBytesPerRow:bpr destinationBytesPerImage:bpi options:MTLBlitOptionNone];
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)soff sourceBytesPerRow:(NSUInteger)bpr
    sourceBytesPerImage:(NSUInteger)bpi sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg
                options:(MTLBlitOption)opt {
    VkBuffer s = vg_vkbuffer(src);
    VGMTLTexture *d = vg_blit_texture(_owner, dst, YES);
    NSUInteger bpp = d ? vg_bytes_per_pixel(d->_pixelFormat) : 0;
    if (!s || !d || !bpp || ![_owner begin]) {
        [_owner fail:@"copyFromBuffer:toTexture: not our objects or format"];
        return;
    }
    [_owner->_keep addObject:src];
    VkBufferImageCopy r = {soff, (uint32_t)(bpr / bpp), bpr ? (uint32_t)(bpi / bpr) : 0, vg_layers(d, ds, dl),
                           {(int32_t)dorg.x, (int32_t)dorg.y, (int32_t)dorg.z},
                           {(uint32_t)size.width, (uint32_t)size.height, (uint32_t)MAX(size.depth, 1u)}};
    gVk.vkCmdCopyBufferToImage(_owner->_cb, s, d->_image, VK_IMAGE_LAYOUT_GENERAL, 1, &r);
    [_owner barrier];
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)soff sourceBytesPerRow:(NSUInteger)bpr
    sourceBytesPerImage:(NSUInteger)bpi sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg {
    [self copyFromBuffer:src sourceOffset:soff sourceBytesPerRow:bpr sourceBytesPerImage:bpi sourceSize:size
               toTexture:dst destinationSlice:ds destinationLevel:dl destinationOrigin:dorg options:MTLBlitOptionNone];
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg {
    VGMTLTexture *s = vg_blit_texture(_owner, src, NO), *d = vg_blit_texture(_owner, dst, YES);
    if (!s || !d || ![_owner begin]) {
        [_owner fail:@"copyFromTexture:toTexture: not our textures"];
        return;
    }
    VkImageCopy r = {vg_layers(s, ss, sl), {(int32_t)so.x, (int32_t)so.y, (int32_t)so.z}, vg_layers(d, ds, dl),
                     {(int32_t)dorg.x, (int32_t)dorg.y, (int32_t)dorg.z},
                     {(uint32_t)size.width, (uint32_t)size.height, (uint32_t)MAX(size.depth, 1u)}};
    gVk.vkCmdCopyImage(_owner->_cb, s->_image, VK_IMAGE_LAYOUT_GENERAL, d->_image, VK_IMAGE_LAYOUT_GENERAL, 1, &r);
    [_owner barrier];
}
- (void)copyFromTexture:(id<MTLTexture>)src toTexture:(id<MTLTexture>)dst {
    VGMTLTexture *s = (VGMTLTexture *)src;
    if (![(NSObject *)src isKindOfClass:[VGMTLTexture class]]) {
        [_owner fail:@"copyFromTexture:toTexture: not our textures"];
        return;
    }
    [self copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(s->_width, s->_height, MAX(s->_depth, 1u)) toTexture:dst destinationSlice:0
         destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
}
@end

@implementation VGMTLCommandBuffer
@synthesize device = _device, commandQueue = _commandQueue, label = _label;

- (instancetype)init {
    if ((self = [super init])) {
        _keep = [NSMutableArray array];
        _handlers = [NSMutableArray array];
        _scheduledHandlers = [NSMutableArray array];
        _done = dispatch_group_create();
        _fenced = dispatch_group_create();
        _status = MTLCommandBufferStatusNotEnqueued;
        _surfacesWritten = [NSMutableSet set];
        _drawables = [NSMutableArray array];
    }
    return self;
}

- (void)fail:(NSString *)why {
    vglog("command buffer: %s", why.UTF8String);
    if (!_error) {
        _error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorInternal
                                 userInfo:@{NSLocalizedDescriptionKey : why ?: @"?"}];
    }
}

- (BOOL)begin {
    if (_cb) {
        return YES;
    }
    VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, gVk.pool,
                                      VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    pthread_mutex_lock(&gVk.lock);
    VkResult r = gVk.vkAllocateCommandBuffers(gVk.device, &ai, &_cb);
    pthread_mutex_unlock(&gVk.lock);
    if (r != VK_SUCCESS) {
        _cb = VK_NULL_HANDLE;
        return NO;
    }
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                   VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    gVk.vkBeginCommandBuffer(_cb, &bi);
    _timePair = vg_gpu_time_begin(_cb);
    return YES;
}

- (void)barrier {
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL,
                          VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_HOST_WRITE_BIT |
                              VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                          VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT |
                              VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_HOST_READ_BIT | VK_ACCESS_UNIFORM_READ_BIT |
                              VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
                              VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT |
                              VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | VK_ACCESS_INDEX_READ_BIT |
                              VK_ACCESS_INDIRECT_COMMAND_READ_BIT};
    gVk.vkCmdPipelineBarrier(_cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                             VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0,
                             NULL);
}

- (VkDescriptorSet)allocSet:(VkDescriptorSetLayout)dsl {
    const uint32_t perPool = 64;
    if (!_npools || _setsInPool == perPool) {
        if (_npools == 64) {
            return VK_NULL_HANDLE;
        }
        VkDescriptorPoolSize sizes[5] = {{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, perPool * 32},
                                         {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, perPool * 32},
                                         {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, perPool * 32},
                                         {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, perPool * 16},
                                         {VK_DESCRIPTOR_TYPE_SAMPLER, perPool * 16}};
        VkDescriptorPoolCreateInfo pci = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, perPool, 5, sizes};
        _pools[_npools] = vg_pool_get();   // a recycled pool, reset (5c round 4)
        if (!_pools[_npools] && gVk.vkCreateDescriptorPool(gVk.device, &pci, NULL, &_pools[_npools]) != VK_SUCCESS) {
            return VK_NULL_HANDLE;
        }
        _npools++;
        _setsInPool = 0;
    }
    VkDescriptorSetAllocateInfo ai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, _pools[_npools - 1], 1, &dsl};
    VkDescriptorSet set = VK_NULL_HANDLE;
    if (gVk.vkAllocateDescriptorSets(gVk.device, &ai, &set) != VK_SUCCESS) {
        return VK_NULL_HANDLE;
    }
    _setsInPool++;
    return set;
}

- (BOOL)upload:(const void *)bytes length:(NSUInteger)len buffer:(VkBuffer *)buf offset:(VkDeviceSize *)off {
    VkDeviceSize align = MAX(gVk.props.limits.minStorageBufferOffsetAlignment, gVk.props.limits.minUniformBufferOffsetAlignment);
    align = MAX(align, 16);
    VkDeviceSize at = (_arenaUsed + align - 1) & ~(align - 1);
    if (!_narena || at + len > _arena[_narena - 1].size) {
        if (_narena == 64 || vg_staging_get(MAX(65536, len), &_arena[_narena])) {
            return NO;
        }
        _narena++;
        at = 0;
    }
    memcpy((uint8_t *)_arena[_narena - 1].map + at, bytes, len);
    *buf = _arena[_narena - 1].buffer;
    *off = at;
    _arenaUsed = at + len;
    return YES;
}

- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    VGCALL("cb %p computeCommandEncoder", self);
    return [[VGComputeEncoder alloc] initWithCommandBuffer:self];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)t {
    return [self computeCommandEncoder];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)d {
    return [self computeCommandEncoder];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
    VGCALL("cb %p blitCommandEncoder", self);
    vg_callstack("blitCommandEncoder");
    return [[VGBlitEncoder alloc] initWithCommandBuffer:self];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)d {
    return [self blitCommandEncoder];
}

- (void)addCompletedHandler:(MTLCommandBufferHandler)block {
    VGCALL("cb %p addCompletedHandler (status %lu)", self, (unsigned long)_status);
    @synchronized(self) {
        [_handlers addObject:[block copy]];
    }
}
- (void)addScheduledHandler:(MTLCommandBufferHandler)block {
    @synchronized(self) {
        if (_status < MTLCommandBufferStatusScheduled) {
            [_scheduledHandlers addObject:[block copy]];
            return;
        }
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        block(self);   // already scheduled: still not on the caller's thread
    });
}
- (void)enqueue {
    if (_status == MTLCommandBufferStatusNotEnqueued) {
        _status = MTLCommandBufferStatusEnqueued;
    }
}
- (MTLCommandBufferStatus)status { return _status; }
- (NSError *)error { return _error; }
- (BOOL)retainedReferences { return YES; }
- (CFTimeInterval)GPUStartTime { return _submitted / 1e9; }
- (CFTimeInterval)GPUEndTime { return _completed / 1e9; }
- (CFTimeInterval)kernelStartTime { return _submitted / 1e9; }
- (CFTimeInterval)kernelEndTime { return _completed / 1e9; }
- (void)presentDrawable:(id<MTLDrawable>)d {
    if (d) {
        [_drawables addObject:d];
    }
}
- (void)presentDrawable:(id<MTLDrawable>)d atTime:(CFTimeInterval)t { [self presentDrawable:d]; }
- (void)presentDrawable:(id<MTLDrawable>)d afterMinimumDuration:(CFTimeInterval)t { [self presentDrawable:d]; }
- (void)pushDebugGroup:(NSString *)s { }
- (void)popDebugGroup { }

// Events (5d). A signal is set when the command buffer completes, after its surfaces are written back: WebKit signals a
// shared event when a canvas frame is done, and the consumer reads the IOSurface once it sees the value. A wait on a
// shared event that isn't there yet holds the commit (at most a second, then it goes on and says so); a plain MTLEvent
// needs nothing, since every queue submits to the one Vulkan queue in order.
- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value {
    if (!event) {
        return;
    }
    if (!_signals) {
        _signals = [NSMutableArray array];
    }
    [_signals addObject:@[ event, @(value) ]];
}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value {
    if (!event || ![(NSObject *)event respondsToSelector:@selector(signaledValue)]) {
        return;
    }
    if (!_waits) {
        _waits = [NSMutableArray array];
    }
    [_waits addObject:@[ event, @(value) ]];
}
static void vg_events_signal(NSArray *signals) {
    for (NSArray *s in signals) {
        id e = s[0];
        uint64_t v = [s[1] unsignedLongLongValue];
        if ([e respondsToSelector:@selector(setSignaledValue:)]) {
            if ([(id<MTLSharedEvent>)e signaledValue] < v) {
                [(id<MTLSharedEvent>)e setSignaledValue:v];
            }
        } else {
            static int logged = 0;
            if (logged++ < 3) {
                vglog("event: %s can't be signaled from the CPU (value %llu)", object_getClassName(e), v);
            }
        }
    }
}
static void vg_events_wait(NSArray *waits) {
    for (NSArray *w in waits) {
        id<MTLSharedEvent> e = w[0];
        uint64_t v = [w[1] unsignedLongLongValue], t0 = vg_now();
        while (e.signaledValue < v) {
            if (vg_now() - t0 > 1000000000ull) {
                vglog("event: waited 1 s for %s to reach %llu (at %llu): going on", object_getClassName(e), v,
                      e.signaledValue);
                break;
            }
            usleep(200);
        }
    }
}
- (void)finishWith:(MTLCommandBufferStatus)status fence:(VkFence)fence {
    VGCALL("cb %p completing, status %lu", self, (unsigned long)status);
    uint64_t dequeued = vg_now();
    if (_submitted) {
        vg_perf(VG_PERF_CB_QUEUE, 0, dequeued - _submitted);
    }
    if (fence) {
        gVk.vkWaitForFences(gVk.device, 1, &fence, VK_TRUE, UINT64_MAX);
        gVk.vkDestroyFence(gVk.device, fence, NULL);
        uint64_t observed = vg_now();
        vg_perf(VG_PERF_CB_WAIT, 0, observed - dequeued);
        if (_cb) {
            vg_gpu_time_collect(_timePair, _submitted, observed);
        }
    }
    if (_snapNumber) {
        VGMTLTexture *shown = vg_twinned_shown();
        if (shown) {
            vg_snap_write(shown, _snapNumber);
        }
        _snapNumber = 0;
    }
    if (_twinFrames) {   // the twins are written: the kext may flip to these frames
        const uint32_t *pair = _twinFrames.bytes;
        for (NSUInteger i = 0; i < _twinFrames.length / (2 * sizeof(uint32_t)); i++) {
            vg_twin_mark(pair[2 * i], pair[2 * i + 1], YES);
        }
        _twinFrames = nil;
    }
    if (_gpuDone) {
        dispatch_semaphore_signal(_gpuDone);
    }
    if (_fencedEntered) {
        _fencedEntered = NO;
        dispatch_group_leave(_fenced);   // vg_present_throttle waits for this, not for the handlers
    }
    _completed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (_cb) {
        pthread_mutex_lock(&gVk.lock);
        gVk.vkFreeCommandBuffers(gVk.device, gVk.pool, 1, &_cb);
        pthread_mutex_unlock(&gVk.lock);
        _cb = VK_NULL_HANDLE;
    }
    if (_pendingCb) {
        pthread_mutex_lock(&gVk.lock);
        gVk.vkFreeCommandBuffers(gVk.device, gVk.pool, 1, &_pendingCb);
        pthread_mutex_unlock(&gVk.lock);
        _pendingCb = VK_NULL_HANDLE;
    }
    vg_pending_release(_pendingOwned);
    _pendingOwned = nil;
    for (int i = 0; i < _npools; i++) {
        vg_pool_put(_pools[i]);
    }
    _npools = 0;
    free(_setMemo);
    _setMemo = NULL;
    for (int i = 0; i < _narena; i++) {
        vg_staging_put(&_arena[i]);   // back to the pool (5c)
    }
    _narena = 0;
    if (_submitted) {
        vg_perf(VG_PERF_CB, 0, _completed - _submitted);
    }
    if (status == MTLCommandBufferStatusCompleted) {
        for (VGMTLTexture *t in _surfacesWritten) {
            if (!t->_staging.map) {
                continue;   // its staging couldn't be had at commit
            }
            uint64_t t0 = vg_now();
            IOSurfaceLock(t->_surface, 0, NULL);
            memcpy(IOSurfaceGetBaseAddressOfPlane(t->_surface, t->_plane), t->_staging.map, t->_surfaceBpr * t->_height);
            uint32_t seed = 0;
            IOSurfaceUnlock(t->_surface, 0, &seed);
            vg_perf(VG_PERF_WB_COPY, t->_surfaceBpr * t->_height, vg_now() - t0);
            t->_syncedSeed = seed;   // our own write: no pull needed for it
            t->_neverSynced = NO;
        }
    }
    [_surfacesWritten removeAllObjects];
    for (id<MTLDrawable> d in _drawables) {
        [d present];
    }
    [_drawables removeAllObjects];
    if (_signals) {
        vg_events_signal(_signals);
        _signals = nil;
    }
    _status = status;
    NSArray *handlers;
    @synchronized(self) {
        handlers = [_handlers copy];
        [_handlers removeAllObjects];
    }
    VGMTLCommandQueue *q = [(NSObject *)self.commandQueue isKindOfClass:[VGMTLCommandQueue class]]
                               ? (VGMTLCommandQueue *)self.commandQueue
                               : nil;
    if (q && q->_userCompletion) {
        dispatch_async(q->_userCompletion, ^{
            for (MTLCommandBufferHandler h in handlers) {
                h(self);
            }
            [self->_keep removeAllObjects];
        });
        return;
    }
    for (MTLCommandBufferHandler h in handlers) {
        h(self);
    }
    [_keep removeAllObjects];
}

- (void)commit {
    VGCALL("cb %p commit (%lu completed, %lu scheduled handlers, error %s)", self, (unsigned long)_handlers.count,
           (unsigned long)_scheduledHandlers.count, _error ? _error.localizedDescription.UTF8String : "none");
    vg_callstack("commit");
    if (_waits) {
        vg_events_wait(_waits);
        _waits = nil;
    }
    [self enqueue];
    _status = MTLCommandBufferStatusCommitted;
    dispatch_group_enter(_done);
    dispatch_group_enter(_fenced);
    _fencedEntered = YES;
    _submitted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    VkFence fence = VK_NULL_HANDLE;
    if (_cb && !_error) {
        // IOSurface textures this command buffer wrote: image -> staging, written into the surface at completion.
        _allTwinned = _present && _surfacesWritten.count > 0;
        static int writeBackTwins = -1;
        if (writeBackTwins < 0) {
            const char *e = getenv("VGMTL_TWIN_WRITEBACK");
            writeBackTwins = e && e[0] == '1';
        }
        NSMutableSet *noWriteBack = nil;
        for (VGMTLTexture *t in _surfacesWritten) {
            [self barrier];
            // A display frame: into the surface's twin, which the kext scans out (5c). Such a surface is only read on
            // the GPU (Core Animation) and from the twin (the display), so its CPU write-back is skipped
            // (VGMTL_TWIN_WRITEBACK=1 keeps it).
            BOOL twinned = (_present || t->_twinRes) && vg_twin_ensure(t);
            if (twinned) {
                VkBufferImageCopy tc = {0, (uint32_t)t->_width, (uint32_t)t->_height, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                        {0, 0, 0}, {(uint32_t)t->_width, (uint32_t)t->_height, 1}};
                gVk.vkCmdCopyImageToBuffer(_cb, t->_image, VK_IMAGE_LAYOUT_GENERAL, t->_twin.buffer, 1, &tc);
                // number this copy: submitted now, ready when the fence is (the kext flips only to a ready frame)
                uint32_t pair[2] = {IOSurfaceGetID(t->_surface), ++t->_twinGen};
                BOOL shown = vg_twin_mark(pair[0], pair[1], NO);
                if (!_twinFrames) {
                    _twinFrames = [NSMutableData data];
                }
                [_twinFrames appendBytes:pair length:sizeof(pair)];
                if (_present && !_snapNumber) {
                    _snapNumber = vg_snap_wanted();   // served at completion, from what the screen shows then
                }
                // Only a surface the display has shown skips its CPU write-back (5c round 6): Core Animation renders
                // other screen-sized surfaces in display command buffers too, and some are read on the CPU right after
                // commitAndWaitUntilSubmitted (a Cmd-Shift-3 screenshot came out blank, then blank one time in three
                // without the wait). Those keep the write-back and the wait for it, except a surface written by every
                // frame (one GPU-only intermediate a frame): after 10 such frames in a row it is waited for no more.
                uint64_t nowNs = vg_now();
                t->_hotWrites = t->_hotLast && nowNs - t->_hotLast < 100000000ull ? t->_hotWrites + 1 : 1;
                t->_hotLast = nowNs;
                if (!shown && t->_hotWrites < 10) {
                    _allTwinned = NO;
                }
                if (shown && !writeBackTwins) {
                    if (!noWriteBack) {
                        noWriteBack = [NSMutableSet set];
                    }
                    [noWriteBack addObject:t];
                    continue;
                }
            } else {
                _allTwinned = NO;
            }
            if (!t->_staging.buffer && vg_staging_get(t->_surfaceBpr * t->_height, &t->_staging)) {
                continue;   // no memory for its write-back (logged by the pool)
            }
            NSUInteger px = IOSurfaceGetBytesPerElementOfPlane(t->_surface, t->_plane);
            VkBufferImageCopy c = {0, (uint32_t)(t->_surfaceBpr / px), (uint32_t)t->_height,
                                   {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {(uint32_t)t->_width, (uint32_t)t->_height, 1}};
            gVk.vkCmdCopyImageToBuffer(_cb, t->_image, VK_IMAGE_LAYOUT_GENERAL, t->_staging.buffer, 1, &c);
        }
        if (noWriteBack) {
            [_surfacesWritten minusSet:noWriteBack];   // no CPU copy at completion either
        }
        if (_surfacesWritten.count) {
            [self barrier];
        }
        vg_gpu_time_end(_cb, _timePair);
        gVk.vkEndCommandBuffer(_cb);
        // Deferred work (new images, uploads, buffer-texture refreshes) in its own command buffer, ahead of ours.
        VkCommandBuffer cbs[2];
        uint32_t ncb = 0;
        VkCommandBufferAllocateInfo pai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, gVk.pool,
                                           VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
        pthread_mutex_lock(&gVk.lock);
        VkResult pr = gVk.vkAllocateCommandBuffers(gVk.device, &pai, &_pendingCb);
        pthread_mutex_unlock(&gVk.lock);
        if (pr == VK_SUCCESS) {
            VkCommandBufferBeginInfo pbi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                            VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
            gVk.vkBeginCommandBuffer(_pendingCb, &pbi);
            NSMutableData *owned = nil;
            BOOL any = vg_pending_record(_pendingCb, &owned);
            _pendingOwned = owned;
            gVk.vkEndCommandBuffer(_pendingCb);
            if (any) {
                cbs[ncb++] = _pendingCb;
            } else {
                pthread_mutex_lock(&gVk.lock);
                gVk.vkFreeCommandBuffers(gVk.device, gVk.pool, 1, &_pendingCb);
                pthread_mutex_unlock(&gVk.lock);
                _pendingCb = VK_NULL_HANDLE;
            }
        } else {
            _pendingCb = VK_NULL_HANDLE;
        }
        cbs[ncb++] = _cb;
        VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        gVk.vkCreateFence(gVk.device, &fci, NULL, &fence);
        VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, ncb, cbs, 0, NULL};
        pthread_mutex_lock(&gVk.lock);
        VkResult r = gVk.vkQueueSubmit(gVk.queue, 1, &si, fence);
        pthread_mutex_unlock(&gVk.lock);
        if (r != VK_SUCCESS) {
            [self fail:[NSString stringWithFormat:@"vkQueueSubmit %d", r]];
            gVk.vkDestroyFence(gVk.device, fence, NULL);
            fence = VK_NULL_HANDLE;
        }
    }
    NSArray *scheduled;
    @synchronized(self) {
        _status = MTLCommandBufferStatusScheduled;
        scheduled = [_scheduledHandlers copy];
        [_scheduledHandlers removeAllObjects];
    }
    MTLCommandBufferStatus end = _error ? MTLCommandBufferStatusError : MTLCommandBufferStatusCompleted;
    VGMTLCommandQueue *q = [(NSObject *)self.commandQueue isKindOfClass:[VGMTLCommandQueue class]]
                               ? (VGMTLCommandQueue *)self.commandQueue
                               : nil;
    // Scheduled handlers run asynchronously, as Metal's do, and before the completed ones on the same queue: Core
    // Animation releases surfaces from them (set_surface_volatile), which must not happen inside its own frame on the
    // committing thread (5b).
    if (scheduled.count) {
        dispatch_queue_t sq = q && q->_userCompletion ? q->_userCompletion : dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
        dispatch_async(sq, ^{
            for (MTLCommandBufferHandler h in scheduled) {
                h(self);
            }
        });
    }
    // In order on the queue's serial queue when the caller named a completion queue; otherwise as before (a handler
    // that waits for a later command buffer of the same queue must not deadlock behind it).
    dispatch_async(q && q->_userCompletion ? q->_serial : dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        [self finishWith:end fence:fence];
        dispatch_group_leave(self->_done);
    });
}

- (void)waitUntilScheduled { }
// Core Animation in WindowServer commits this way (5b: lenient mode swallowed it, and its frames were never submitted).
// ... and then hands the frame's IOSurface to the display pipe, which copies the surface's CPU memory: the write-back
// must have landed by then (5c: when it returned at once, the pipe could show a surface before its last frame was in
// it, and pieces of old frames stayed on screen). So a command buffer that wrote IOSurfaces returns only once they
// are written back. VGMTL_NOWAIT_SUBMIT=1 returns at once again.
// Display frames in flight (5c round 3): the oldest present beyond the depth is waited for (its fence, not its
// completion handlers). WindowServer makes ~3 such calls per display frame (its composite flush, then the display
// surface's), so the depth counts command buffers, not frames: at depth 1 each call waited ~10 ms for the call before
// it and a frame took ~30 ms (5c round 6). VGMTL_PRESENT_DEPTH sets the start; /Library/GPUBundles/VirtioGPUMetal-depth
// (a number, 1-16) overrides it and is read again at most once a second, so it can be tuned without a restart.
static int vg_present_depth(void) {
    static int envDepth = -1, fileDepth = 0;
    static uint64_t checked;
    if (envDepth < 0) {
        const char *e = getenv("VGMTL_PRESENT_DEPTH");
        envDepth = e && atoi(e) > 0 ? atoi(e) : 6;   // 6: the best drag, scroll and resize pacing (5c round 6)
    }
    uint64_t now = vg_now();
    if (!checked || now - checked > 1000000000ull) {
        checked = now;
        int d = 0;
        FILE *f = fopen("/Library/GPUBundles/VirtioGPUMetal-depth", "r");
        if (f) {
            if (fscanf(f, "%d", &d) != 1) {
                d = 0;
            }
            fclose(f);
        }
        d = d >= 1 && d <= 16 ? d : 0;
        if (d != fileDepth) {
            fileDepth = d;
            vglog("present: at most %d display command buffer(s) in flight", fileDepth ? fileDepth : envDepth);
        }
    }
    return fileDepth ? fileDepth : envDepth;
}

static void vg_present_throttle(VGMTLCommandBuffer *cb) {
    static NSMutableArray<VGMTLCommandBuffer *> *inflight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inflight = [NSMutableArray array];
    });
    NSMutableArray<VGMTLCommandBuffer *> *wait = [NSMutableArray array];
    @synchronized(inflight) {
        int depth = vg_present_depth();
        [inflight addObject:cb];
        while ((int)inflight.count > depth) {
            [wait addObject:inflight[0]];
            [inflight removeObjectAtIndex:0];
        }
    }
    for (VGMTLCommandBuffer *oldest in wait) {
        dispatch_group_wait(oldest->_fenced, DISPATCH_TIME_FOREVER);
    }
}

- (void)commitAndWaitUntilSubmitted {
    static int nowait = -1;
    if (nowait < 0) {
        const char *e = getenv("VGMTL_NOWAIT_SUBMIT");
        nowait = e && e[0] == '1';
    }
    BOOL wroteSurfaces = _surfacesWritten.count > 0;
    _present = YES;
    _gpuDone = wroteSurfaces ? dispatch_semaphore_create(0) : nil;
    [self commit];
    static int twinWait = -1;
    if (twinWait < 0) {
        const char *e = getenv("VGMTL_TWIN_WAIT");
        twinWait = e && e[0] == '1';
    }
    if (wroteSurfaces && !nowait) {
        uint64_t t0 = vg_now();
        if (_allTwinned) {
            // every surface has a twin the kext scans out, and the kext flips to a frame only once it is marked
            // ready (finishWith), so this frame needn't be waited for (5c round 3: that wait was 18.5 ms per frame,
            // 12 s of WindowServer's thread in a 40 s scroll). But without any wait WindowServer ran ahead of the GPU
            // and the screen fell further and further behind (a dragged window trailing the pointer): at most
            // VGMTL_PRESENT_DEPTH (default 2) display frames in flight, i.e. wait for the one before this.
            // VGMTL_TWIN_WAIT=1 waits for this frame as before.
            if (twinWait) {
                dispatch_semaphore_wait(_gpuDone, DISPATCH_TIME_FOREVER);
            } else {
                vg_present_throttle(self);
            }
        } else {
            dispatch_group_wait(_done, DISPATCH_TIME_FOREVER);
        }
        vg_perf(VG_PERF_SUBMIT_WAIT, 0, vg_now() - t0);
    }
}
- (NSMutableDictionary *)userDictionary {
    @synchronized(self) {
        NSMutableDictionary *d = objc_getAssociatedObject(self, @selector(userDictionary));
        if (!d) {
            d = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(self, @selector(userDictionary), d, OBJC_ASSOCIATION_RETAIN);
        }
        return d;
    }
}
- (void)waitUntilCompleted {
    if (_status >= MTLCommandBufferStatusCommitted) {
        uint64_t t0 = vg_now();
        dispatch_group_wait(_done, DISPATCH_TIME_FOREVER);
        vg_perf(VG_PERF_WAIT_COMPLETED, 0, vg_now() - t0);
    }
}
@end

void vg_cmd_wrote(id cmd, VGMTLTexture *t) {
    while (t && t->_parent) {
        t = t->_parent;   // a view writes its texture
    }
    if (t && t->_surface) {
        [((VGMTLCommandBuffer *)cmd)->_surfacesWritten addObject:t];
    }
}
