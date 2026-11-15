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

// ---- MTLBuffer ---------------------------------------------------------------------------------------------------

@implementation VGMTLBuffer
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (void)dealloc { vg_buffer_destroy(&_b); }
- (void *)contents { return _b.map; }
- (NSUInteger)length { return _length; }
- (NSUInteger)allocatedSize { return (NSUInteger)_b.size; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_options >> MTLResourceStorageModeShift) & 0xf); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)(_options & 0xf); }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (void)didModifyRange:(NSRange)range { }   // coherent memory
- (uint64_t)gpuAddress { return 0; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return MTLPurgeableStateNonVolatile; }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable { }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
@end

id<MTLBuffer> vg_new_buffer(id<MTLDevice> device, NSUInteger length, MTLResourceOptions options, const void *bytes) {
    if (vg_vulkan_init()) {
        return nil;
    }
    VGMTLBuffer *b = [VGMTLBuffer new];
    if (vg_buffer_create(length, &b->_b)) {
        return nil;
    }
    b->_length = length;
    b->_options = options;
    b->_dev = device;
    if (bytes) {
        memcpy(b->_b.map, bytes, length);
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

VkDescriptorSet vg_write_set(VGMTLCommandBuffer *cmd, VkDescriptorSetLayout dsl, const vg_binding *bindings, int n,
                             const vg_stage_bindings *t, NSString *who) {
    VkDescriptorSet set = [cmd allocSet:dsl];
    if (!set) {
        [cmd fail:@"no descriptor set"];
        return VK_NULL_HANDLE;
    }
    VkDescriptorBufferInfo binfo[64];
    VkDescriptorImageInfo iinfo[64];
    VkWriteDescriptorSet writes[64];
    for (int i = 0; i < n && i < 64; i++) {
        uint32_t b = bindings[i].binding;
        VkDescriptorType type = bindings[i].type;
        writes[i] = (VkWriteDescriptorSet){VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, b, 0, 1, type, NULL, NULL, NULL};
        if (type == VK_DESCRIPTOR_TYPE_STORAGE_BUFFER || type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            if (b >= kVGMaxBufferSlots || !t->buf[b]) {
                [cmd fail:[NSString stringWithFormat:@"%@: nothing bound at buffer(%u)", who, b]];
                return VK_NULL_HANDLE;
            }
            VkDeviceSize range = VK_WHOLE_SIZE;
            if (type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
                range = MIN((VkDeviceSize)gVk.props.limits.maxUniformBufferRange, 65536);
            }
            binfo[i] = (VkDescriptorBufferInfo){t->buf[b], t->off[b], range};
            writes[i].pBufferInfo = &binfo[i];
            continue;
        }
        uint32_t slot;
        if (type == VK_DESCRIPTOR_TYPE_SAMPLER) {
            slot = b - kVGSamplerBase;
            if (b < kVGSamplerBase || slot >= kVGMaxSamplerSlots || !t->smp[slot]) {
                [cmd fail:[NSString stringWithFormat:@"%@: nothing bound at sampler(%d)", who, (int)b - kVGSamplerBase]];
                return VK_NULL_HANDLE;
            }
            iinfo[i] = (VkDescriptorImageInfo){t->smp[slot]->_sampler, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_UNDEFINED};
        } else {
            uint32_t base = type == VK_DESCRIPTOR_TYPE_STORAGE_IMAGE ? kVGStorageTextureBase : kVGTextureBase;
            slot = b - base;
            if (b < base || slot >= kVGMaxTextureSlots || !t->tex[slot]) {
                [cmd fail:[NSString stringWithFormat:@"%@: nothing bound at texture(%d)", who, (int)b - (int)base]];
                return VK_NULL_HANDLE;
            }
            iinfo[i] = (VkDescriptorImageInfo){VK_NULL_HANDLE, t->tex[slot]->_view, VK_IMAGE_LAYOUT_GENERAL};
            if (type == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
                [cmd fail:[NSString stringWithFormat:@"%@: combined image-samplers aren't supported yet", who]];
                return VK_NULL_HANDLE;
            }
        }
        writes[i].pImageInfo = &iinfo[i];
    }
    gVk.vkUpdateDescriptorSets(gVk.device, (uint32_t)MIN(n, 64), writes, 0, NULL);
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

@interface VGMTLCommandQueue : NSObject <MTLCommandQueue>
@property(readonly) id<MTLDevice> device;
@property(copy, atomic) NSString *label;
@end

@implementation VGMTLCommandQueue
@synthesize device = _device, label = _label;
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
    }
    return self;
}
- (id<MTLCommandBuffer>)commandBuffer;
{
    VGMTLCommandBuffer *c = [VGMTLCommandBuffer new];
    [c setValue:_device forKey:@"device"];
    [c setValue:self forKey:@"commandQueue"];
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
- (void)endEncoding { }
- (void)insertDebugSignpost:(NSString *)s { }
- (void)pushDebugGroup:(NSString *)s { }
- (void)popDebugGroup { }
@end

VkBuffer vg_vkbuffer(id<MTLBuffer> b) {
    return [(NSObject *)b isKindOfClass:[VGMTLBuffer class]] ? ((VGMTLBuffer *)b)->_b.buffer : VK_NULL_HANDLE;
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
- (void)synchronizeResource:(id<MTLResource>)r { }   // coherent memory
@end

@implementation VGMTLCommandBuffer
@synthesize device = _device, commandQueue = _commandQueue, label = _label;

- (instancetype)init {
    if ((self = [super init])) {
        _keep = [NSMutableArray array];
        _handlers = [NSMutableArray array];
        _done = dispatch_group_create();
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
        if (gVk.vkCreateDescriptorPool(gVk.device, &pci, NULL, &_pools[_npools]) != VK_SUCCESS) {
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
        if (_narena == 64 || vg_buffer_create(MAX(65536, len), &_arena[_narena])) {
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
    return [[VGComputeEncoder alloc] initWithCommandBuffer:self];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)t {
    return [self computeCommandEncoder];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)d {
    return [self computeCommandEncoder];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder { return [[VGBlitEncoder alloc] initWithCommandBuffer:self]; }
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)d {
    return [self blitCommandEncoder];
}

- (void)addCompletedHandler:(MTLCommandBufferHandler)block {
    @synchronized(self) {
        [_handlers addObject:[block copy]];
    }
}
- (void)addScheduledHandler:(MTLCommandBufferHandler)block {
    block(self);   // scheduled as soon as it's submitted; good enough until something waits on the order
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

- (void)finishWith:(MTLCommandBufferStatus)status fence:(VkFence)fence {
    if (fence) {
        gVk.vkWaitForFences(gVk.device, 1, &fence, VK_TRUE, UINT64_MAX);
        gVk.vkDestroyFence(gVk.device, fence, NULL);
    }
    _completed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (_cb) {
        pthread_mutex_lock(&gVk.lock);
        gVk.vkFreeCommandBuffers(gVk.device, gVk.pool, 1, &_cb);
        pthread_mutex_unlock(&gVk.lock);
        _cb = VK_NULL_HANDLE;
    }
    for (int i = 0; i < _npools; i++) {
        gVk.vkDestroyDescriptorPool(gVk.device, _pools[i], NULL);
    }
    _npools = 0;
    for (int i = 0; i < _narena; i++) {
        vg_buffer_destroy(&_arena[i]);
    }
    _narena = 0;
    if (status == MTLCommandBufferStatusCompleted) {
        for (VGMTLTexture *t in _surfacesWritten) {
            IOSurfaceLock(t->_surface, 0, NULL);
            memcpy(IOSurfaceGetBaseAddressOfPlane(t->_surface, t->_plane), t->_staging.map, t->_surfaceBpr * t->_height);
            uint32_t seed = 0;
            IOSurfaceUnlock(t->_surface, 0, &seed);
            t->_syncedSeed = seed;   // our own write: no pull needed for it
            t->_neverSynced = NO;
        }
    }
    [_surfacesWritten removeAllObjects];
    for (id<MTLDrawable> d in _drawables) {
        [d present];
    }
    [_drawables removeAllObjects];
    _status = status;
    NSArray *handlers;
    @synchronized(self) {
        handlers = [_handlers copy];
        [_handlers removeAllObjects];
    }
    for (MTLCommandBufferHandler h in handlers) {
        h(self);
    }
    [_keep removeAllObjects];
}

- (void)commit {
    [self enqueue];
    _status = MTLCommandBufferStatusCommitted;
    dispatch_group_enter(_done);
    _submitted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    VkFence fence = VK_NULL_HANDLE;
    if (_cb && !_error) {
        // IOSurface textures this command buffer wrote: image -> staging, written into the surface at completion.
        for (VGMTLTexture *t in _surfacesWritten) {
            [self barrier];
            NSUInteger px = IOSurfaceGetBytesPerElementOfPlane(t->_surface, t->_plane);
            VkBufferImageCopy c = {0, (uint32_t)(t->_surfaceBpr / px), (uint32_t)t->_height,
                                   {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {(uint32_t)t->_width, (uint32_t)t->_height, 1}};
            gVk.vkCmdCopyImageToBuffer(_cb, t->_image, VK_IMAGE_LAYOUT_GENERAL, t->_staging.buffer, 1, &c);
        }
        if (_surfacesWritten.count) {
            [self barrier];
        }
        gVk.vkEndCommandBuffer(_cb);
        VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        gVk.vkCreateFence(gVk.device, &fci, NULL, &fence);
        VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &_cb, 0, NULL};
        pthread_mutex_lock(&gVk.lock);
        VkResult r = gVk.vkQueueSubmit(gVk.queue, 1, &si, fence);
        pthread_mutex_unlock(&gVk.lock);
        if (r != VK_SUCCESS) {
            [self fail:[NSString stringWithFormat:@"vkQueueSubmit %d", r]];
            gVk.vkDestroyFence(gVk.device, fence, NULL);
            fence = VK_NULL_HANDLE;
        }
    }
    _status = MTLCommandBufferStatusScheduled;
    MTLCommandBufferStatus end = _error ? MTLCommandBufferStatusError : MTLCommandBufferStatusCompleted;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self finishWith:end fence:fence];
        dispatch_group_leave(self->_done);
    });
}

- (void)waitUntilScheduled { }
- (void)waitUntilCompleted {
    if (_status >= MTLCommandBufferStatusCommitted) {
        dispatch_group_wait(_done, DISPATCH_TIME_FOREVER);
    }
}
@end

void vg_cmd_wrote(id cmd, VGMTLTexture *t) {
    if (t && t->_surface) {
        [((VGMTLCommandBuffer *)cmd)->_surfacesWritten addObject:t];
    }
}
