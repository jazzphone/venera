// Stage 4c: render pipelines and render command encoders on Venus.
//
// - Vertex and fragment functions are translated when the pipeline is made. Both stages' resources come out in
//   descriptor set 0 (buffer n at binding n, texture n at 32+n, sampler n at 160+n); Metal keeps the stages' tables
//   apart, so the fragment module is moved to set 1 (NV does the same, nvmtl_vk.c nvmtl_spirv_retarget_set).
// - A vertex descriptor becomes Vulkan vertex input: attribute n -> location n, layout (buffer) n -> binding n.
// - Rendering is dynamic (VK 1.3 dynamic rendering, no render-pass objects), attachments stay in the GENERAL layout.
// - Metal's clip space has +y up and its framebuffer origin at the top left: a negative-height viewport gives the same
//   picture in Vulkan (NV does the same), and keeps Metal's winding meaning.
// - Topology, cull mode, winding, depth test/write/compare, primitive restart, viewport, scissor and blend color are
//   dynamic state; one VkPipeline per topology class (points, lines, triangles), made at the first draw.
#import "objects.h"

// ---- vertex formats and blending ---------------------------------------------------------------------------------

static VkFormat vg_vertex_format(MTLVertexFormat f) {
    switch (f) {
    case MTLVertexFormatFloat: return VK_FORMAT_R32_SFLOAT;
    case MTLVertexFormatFloat2: return VK_FORMAT_R32G32_SFLOAT;
    case MTLVertexFormatFloat3: return VK_FORMAT_R32G32B32_SFLOAT;
    case MTLVertexFormatFloat4: return VK_FORMAT_R32G32B32A32_SFLOAT;
    case MTLVertexFormatHalf2: return VK_FORMAT_R16G16_SFLOAT;
    case MTLVertexFormatHalf4: return VK_FORMAT_R16G16B16A16_SFLOAT;
    case MTLVertexFormatInt: return VK_FORMAT_R32_SINT;
    case MTLVertexFormatInt2: return VK_FORMAT_R32G32_SINT;
    case MTLVertexFormatInt4: return VK_FORMAT_R32G32B32A32_SINT;
    case MTLVertexFormatUInt: return VK_FORMAT_R32_UINT;
    case MTLVertexFormatUInt2: return VK_FORMAT_R32G32_UINT;
    case MTLVertexFormatUInt4: return VK_FORMAT_R32G32B32A32_UINT;
    case MTLVertexFormatUChar4: return VK_FORMAT_R8G8B8A8_UINT;
    case MTLVertexFormatUChar4Normalized: return VK_FORMAT_R8G8B8A8_UNORM;
    case MTLVertexFormatUChar4Normalized_BGRA: return VK_FORMAT_B8G8R8A8_UNORM;
    case MTLVertexFormatChar4Normalized: return VK_FORMAT_R8G8B8A8_SNORM;
    case MTLVertexFormatShort2: return VK_FORMAT_R16G16_SINT;
    case MTLVertexFormatShort2Normalized: return VK_FORMAT_R16G16_SNORM;
    case MTLVertexFormatUShort2Normalized: return VK_FORMAT_R16G16_UNORM;
    default: return VK_FORMAT_UNDEFINED;
    }
}

static VkBlendFactor vg_blend_factor(MTLBlendFactor f) {
    switch (f) {
    case MTLBlendFactorZero: return VK_BLEND_FACTOR_ZERO;
    case MTLBlendFactorOne: return VK_BLEND_FACTOR_ONE;
    case MTLBlendFactorSourceColor: return VK_BLEND_FACTOR_SRC_COLOR;
    case MTLBlendFactorOneMinusSourceColor: return VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR;
    case MTLBlendFactorSourceAlpha: return VK_BLEND_FACTOR_SRC_ALPHA;
    case MTLBlendFactorOneMinusSourceAlpha: return VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    case MTLBlendFactorDestinationColor: return VK_BLEND_FACTOR_DST_COLOR;
    case MTLBlendFactorOneMinusDestinationColor: return VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR;
    case MTLBlendFactorDestinationAlpha: return VK_BLEND_FACTOR_DST_ALPHA;
    case MTLBlendFactorOneMinusDestinationAlpha: return VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA;
    case MTLBlendFactorSourceAlphaSaturated: return VK_BLEND_FACTOR_SRC_ALPHA_SATURATE;
    case MTLBlendFactorBlendColor: return VK_BLEND_FACTOR_CONSTANT_COLOR;
    case MTLBlendFactorOneMinusBlendColor: return VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR;
    case MTLBlendFactorBlendAlpha: return VK_BLEND_FACTOR_CONSTANT_ALPHA;
    case MTLBlendFactorOneMinusBlendAlpha: return VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA;
    case MTLBlendFactorSource1Color: return VK_BLEND_FACTOR_SRC1_COLOR;
    case MTLBlendFactorOneMinusSource1Color: return VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR;
    case MTLBlendFactorSource1Alpha: return VK_BLEND_FACTOR_SRC1_ALPHA;
    case MTLBlendFactorOneMinusSource1Alpha: return VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA;
    default: return VK_BLEND_FACTOR_ONE;
    }
}

static VkBlendOp vg_blend_op(MTLBlendOperation o) {
    switch (o) {
    case MTLBlendOperationSubtract: return VK_BLEND_OP_SUBTRACT;
    case MTLBlendOperationReverseSubtract: return VK_BLEND_OP_REVERSE_SUBTRACT;
    case MTLBlendOperationMin: return VK_BLEND_OP_MIN;
    case MTLBlendOperationMax: return VK_BLEND_OP_MAX;
    default: return VK_BLEND_OP_ADD;
    }
}

// ---- MTLRenderPipelineState --------------------------------------------------------------------------------------

enum { kVGMaxColor = 8 };

@interface VGMTLRenderPipelineState : NSObject <MTLRenderPipelineState> {
@public
    NSString *_name;
    VkShaderModule _vs, _fs;
    VkDescriptorSetLayout _dsl[2];   // 0 vertex, 1 fragment
    VkPipelineLayout _layout;
    vg_binding _vb[64], _fb[64];
    int _nvb, _nfb;
    VkVertexInputBindingDescription _vbind[kVGMaxBufferSlots];
    VkVertexInputAttributeDescription _vattr[31];
    uint32_t _nvbind, _nvattr;
    uint32_t _ncolor;
    VkFormat _color[kVGMaxColor], _depthFormat, _stencilFormat;
    VkPipelineColorBlendAttachmentState _blend[kVGMaxColor];
    VkPipeline _pipelines[3];   // points, lines, triangles
    id<MTLDevice> _dev;
}
@property(readonly) id<MTLDevice> device;
@property(readonly) NSString *label;
@end

@implementation VGMTLRenderPipelineState
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){0}; }
- (NSUInteger)maxTotalThreadsPerObjectThreadgroup { return 0; }
- (NSUInteger)maxTotalThreadsPerMeshThreadgroup { return 0; }
- (NSUInteger)objectThreadExecutionWidth { return 0; }
- (NSUInteger)meshThreadExecutionWidth { return 0; }

- (VkPipeline)pipelineForClass:(int)cls error:(NSString **)error {
    @synchronized(self) {
        if (_pipelines[cls]) {
            return _pipelines[cls];
        }
        static const VkPrimitiveTopology kTopology[3] = {VK_PRIMITIVE_TOPOLOGY_POINT_LIST, VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
                                                         VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
        VkPipelineShaderStageCreateInfo stages[2] = {
            {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, _vs, "main", NULL},
            {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, _fs, "main", NULL}};
        VkPipelineVertexInputStateCreateInfo vi = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, NULL, 0,
                                                   _nvbind, _vbind, _nvattr, _vattr};
        VkPipelineInputAssemblyStateCreateInfo ia = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, NULL, 0,
                                                     kTopology[cls], VK_FALSE};
        VkPipelineViewportStateCreateInfo vp = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, NULL, 0, 1, NULL, 1, NULL};
        VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.lineWidth = 1.0f;
        VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, NULL, 0,
                                                   VK_SAMPLE_COUNT_1_BIT};
        VkPipelineDepthStencilStateCreateInfo ds = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
        ds.maxDepthBounds = 1.0f;
        VkPipelineColorBlendStateCreateInfo cb = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, NULL, 0,
                                                  VK_FALSE, VK_LOGIC_OP_COPY, _ncolor, _blend};
        static const VkDynamicState kDynamic[] = {
            VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY,
            VK_DYNAMIC_STATE_CULL_MODE, VK_DYNAMIC_STATE_FRONT_FACE, VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE,
            VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE, VK_DYNAMIC_STATE_DEPTH_COMPARE_OP, VK_DYNAMIC_STATE_STENCIL_TEST_ENABLE,
            VK_DYNAMIC_STATE_BLEND_CONSTANTS, VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE};
        VkPipelineDynamicStateCreateInfo dyn = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, NULL, 0,
                                                sizeof(kDynamic) / sizeof(*kDynamic), kDynamic};
        VkPipelineRenderingCreateInfo ri = {VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, NULL, 0, _ncolor, _color,
                                            _depthFormat, _stencilFormat};
        VkGraphicsPipelineCreateInfo gci = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &ri};
        gci.stageCount = _fs ? 2 : 1;
        gci.pStages = stages;
        gci.pVertexInputState = &vi;
        gci.pInputAssemblyState = &ia;
        gci.pViewportState = &vp;
        gci.pRasterizationState = &rs;
        gci.pMultisampleState = &ms;
        gci.pDepthStencilState = &ds;
        gci.pColorBlendState = &cb;
        gci.pDynamicState = &dyn;
        gci.layout = _layout;
        VkResult r = gVk.vkCreateGraphicsPipelines(gVk.device, VK_NULL_HANDLE, 1, &gci, NULL, &_pipelines[cls]);
        vg_trace_sync("vkCreateGraphicsPipelines");
        if (r != VK_SUCCESS) {
            *error = [NSString stringWithFormat:@"%@: vkCreateGraphicsPipelines %d", _name, r];
            _pipelines[cls] = VK_NULL_HANDLE;
        }
        return _pipelines[cls];
    }
}
@end

static VkDescriptorSetLayout vg_set_layout(const vg_binding *b, int n, VkShaderStageFlags stage) {
    VkDescriptorSetLayoutBinding lb[64];
    for (int i = 0; i < n; i++) {
        lb[i] = (VkDescriptorSetLayoutBinding){b[i].binding, b[i].type, 1, stage, NULL};
    }
    VkDescriptorSetLayoutCreateInfo ci = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, (uint32_t)n, lb};
    VkDescriptorSetLayout l = VK_NULL_HANDLE;
    gVk.vkCreateDescriptorSetLayout(gVk.device, &ci, NULL, &l);
    return l;
}

static VkShaderModule vg_module(NSData *spv) {
    VkShaderModuleCreateInfo ci = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, spv.length, spv.bytes};
    VkShaderModule m = VK_NULL_HANDLE;
    gVk.vkCreateShaderModule(gVk.device, &ci, NULL, &m);
    return m;
}

id<MTLRenderPipelineState> vg_new_render_pipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor *d, NSError **error) {
    NSString *why = nil;
    NSObject *vf = (NSObject *)d.vertexFunction, *ff = (NSObject *)d.fragmentFunction;
    VGMTLRenderPipelineState *p = nil;
    if (![vf respondsToSelector:@selector(vgLL)] || ![[vf vgStage] isEqual:@"vertex"] ||
        (ff && (![ff respondsToSelector:@selector(vgLL)] || ![[ff vgStage] isEqual:@"fragment"]))) {
        why = @"not VirtioGPUMetal vertex/fragment functions";
    } else if (d.rasterSampleCount > 1) {
        why = @"multisampling isn't supported yet";
    } else if (vg_vulkan_init()) {
        why = @"Venus is down";
    } else {
        p = [VGMTLRenderPipelineState new];
        p->_dev = device;
        p->_name = [NSString stringWithFormat:@"%@+%@", d.vertexFunction.name, d.fragmentFunction.name ?: @"-"];
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSData *vs = vg_translate([vf vgLL], "vertex", NULL, 0, &why);
        NSData *fs = ff && vs ? vg_translate([ff vgLL], "fragment", NULL, 0, &why) : nil;
        if (fs) {
            fs = vg_spirv_retarget_set(fs, 1);
        }
        if (!vs || (ff && !fs)) {
            p = nil;
        } else if (vg_spirv_has_push_constants(vs) || (fs && vg_spirv_has_push_constants(fs))) {
            why = @"a render stage with push constants of its own isn't supported yet";
            p = nil;
        } else if ((p->_nvb = vg_spirv_bindings(vs, 0, p->_vb, 64, &why)) < 0 ||
                   (fs && (p->_nfb = vg_spirv_bindings(fs, 1, p->_fb, 64, &why)) < 0)) {
            p = nil;
        } else {
            p->_vs = vg_module(vs);
            p->_fs = fs ? vg_module(fs) : VK_NULL_HANDLE;
            p->_dsl[0] = vg_set_layout(p->_vb, p->_nvb, VK_SHADER_STAGE_VERTEX_BIT);
            p->_dsl[1] = vg_set_layout(p->_fb, p->_nfb, VK_SHADER_STAGE_FRAGMENT_BIT);
            VkPipelineLayoutCreateInfo plci = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 2, p->_dsl, 0, NULL};
            vg_trace_sync("shader modules + set layouts");
            gVk.vkCreatePipelineLayout(gVk.device, &plci, NULL, &p->_layout);
            vg_trace_sync("pipeline layout");
            vglog("render pipeline %s: translated in %.1f ms (%lu + %lu bytes of SPIR-V, %d + %d bindings)",
                  p->_name.UTF8String, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, (unsigned long)vs.length,
                  (unsigned long)fs.length, p->_nvb, p->_nfb);
        }
    }
    if (p) {
        // Vertex input from the vertex descriptor.
        MTLVertexDescriptor *vd = d.vertexDescriptor;
        BOOL used[kVGMaxBufferSlots] = {NO};
        for (uint32_t a = 0; a < 31 && vd; a++) {
            MTLVertexAttributeDescriptor *ad = vd.attributes[a];
            if (ad.format == MTLVertexFormatInvalid) {
                continue;
            }
            VkFormat f = vg_vertex_format(ad.format);
            if (!f || ad.bufferIndex >= kVGMaxBufferSlots) {
                why = [NSString stringWithFormat:@"vertex attribute %u: format %lu not supported yet", a, (unsigned long)ad.format];
                p = nil;
                break;
            }
            p->_vattr[p->_nvattr++] = (VkVertexInputAttributeDescription){a, (uint32_t)ad.bufferIndex, f, (uint32_t)ad.offset};
            used[ad.bufferIndex] = YES;
        }
        for (uint32_t b = 0; p && b < kVGMaxBufferSlots; b++) {
            if (!used[b]) {
                continue;
            }
            MTLVertexBufferLayoutDescriptor *ld = vd.layouts[b];
            if (ld.stepFunction != MTLVertexStepFunctionPerVertex && ld.stepFunction != MTLVertexStepFunctionPerInstance) {
                why = @"vertex step functions other than per vertex / per instance aren't supported yet";
                p = nil;
                break;
            }
            p->_vbind[p->_nvbind++] = (VkVertexInputBindingDescription){
                b, (uint32_t)ld.stride,
                ld.stepFunction == MTLVertexStepFunctionPerInstance ? VK_VERTEX_INPUT_RATE_INSTANCE : VK_VERTEX_INPUT_RATE_VERTEX};
        }
    }
    if (p) {
        // Attachments and blending.
        for (uint32_t i = 0; i < kVGMaxColor; i++) {
            MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
            VkFormat f = c.pixelFormat == MTLPixelFormatInvalid ? VK_FORMAT_UNDEFINED : vg_vk_format(c.pixelFormat);
            if (c.pixelFormat != MTLPixelFormatInvalid && !f) {
                why = [NSString stringWithFormat:@"color attachment %u: pixel format %lu not supported yet", i, (unsigned long)c.pixelFormat];
                p = nil;
                break;
            }
            p->_color[i] = f;
            if (f) {
                p->_ncolor = i + 1;
            }
            MTLColorWriteMask m = c.writeMask;
            p->_blend[i] = (VkPipelineColorBlendAttachmentState){
                c.blendingEnabled, vg_blend_factor(c.sourceRGBBlendFactor), vg_blend_factor(c.destinationRGBBlendFactor),
                vg_blend_op(c.rgbBlendOperation), vg_blend_factor(c.sourceAlphaBlendFactor),
                vg_blend_factor(c.destinationAlphaBlendFactor), vg_blend_op(c.alphaBlendOperation),
                ((m & MTLColorWriteMaskRed) ? VK_COLOR_COMPONENT_R_BIT : 0) |
                    ((m & MTLColorWriteMaskGreen) ? VK_COLOR_COMPONENT_G_BIT : 0) |
                    ((m & MTLColorWriteMaskBlue) ? VK_COLOR_COMPONENT_B_BIT : 0) |
                    ((m & MTLColorWriteMaskAlpha) ? VK_COLOR_COMPONENT_A_BIT : 0)};
        }
    }
    if (p) {
        p->_depthFormat = d.depthAttachmentPixelFormat == MTLPixelFormatInvalid ? VK_FORMAT_UNDEFINED
                                                                                : vg_vk_format(d.depthAttachmentPixelFormat);
        p->_stencilFormat = d.stencilAttachmentPixelFormat == MTLPixelFormatInvalid ? VK_FORMAT_UNDEFINED
                                                                                    : vg_vk_format(d.stencilAttachmentPixelFormat);
        // Build the triangle pipeline now, so a bad combination fails here rather than at the first draw.
        if (![p pipelineForClass:2 error:&why]) {
            p = nil;
        }
    }
    if (!p) {
        vglog("render pipeline %s+%s: refused: %s", d.vertexFunction.name.UTF8String, d.fragmentFunction.name.UTF8String,
              why.UTF8String);
        if (error) {
            *error = [NSError errorWithDomain:@"VirtioGPUMetal" code:2 userInfo:@{NSLocalizedDescriptionKey : why ?: @"?"}];
        }
    }
    return p;
}

// ---- MTLRenderCommandEncoder -------------------------------------------------------------------------------------

@interface VGRenderEncoder : VGEncoder <MTLRenderCommandEncoder> {
@public
    VGMTLRenderPipelineState *_pso;
    vg_stage_bindings _vt, _ft;
    VkViewport _viewport;
    VkRect2D _scissor, _area;
    VkCullModeFlags _cull;
    VkFrontFace _front;
    VGMTLDepthStencilState *_ds;
    float _blend[4];
    BOOL _open;
}
@end

static void vg_set_buffer(VGMTLCommandBuffer *cmd, vg_stage_bindings *t, id<MTLBuffer> b, NSUInteger off, NSUInteger i) {
    if (i < kVGMaxBufferSlots) {
        t->buf[i] = vg_vkbuffer(b);
        t->off[i] = off;
        if (b) {
            [cmd->_keep addObject:b];
        }
    }
}
static void vg_set_bytes(VGMTLCommandBuffer *cmd, vg_stage_bindings *t, const void *bytes, NSUInteger len, NSUInteger i) {
    if (i < kVGMaxBufferSlots && ![cmd upload:bytes length:len buffer:&t->buf[i] offset:&t->off[i]]) {
        [cmd fail:@"setBytes: no upload memory"];
    }
}
static void vg_set_texture(VGMTLCommandBuffer *cmd, vg_stage_bindings *t, id<MTLTexture> tex, NSUInteger i) {
    if (i < kVGMaxTextureSlots) {
        t->tex[i] = [(NSObject *)tex isKindOfClass:[VGMTLTexture class]] ? (VGMTLTexture *)tex : nil;
        if (tex) {
            [cmd->_keep addObject:tex];
        }
    }
}
static void vg_set_sampler(VGMTLCommandBuffer *cmd, vg_stage_bindings *t, id<MTLSamplerState> s, NSUInteger i) {
    if (i < kVGMaxSamplerSlots) {
        t->smp[i] = (VGMTLSamplerState *)s;
        if (s) {
            [cmd->_keep addObject:s];
        }
    }
}

@implementation VGRenderEncoder
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)state {
    _pso = (VGMTLRenderPipelineState *)state;
    if (state) {
        [_owner->_keep addObject:state];
    }
}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { vg_set_buffer(_owner, &_vt, b, o, i); }
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { vg_set_buffer(_owner, &_ft, b, o, i); }
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {
    if (i < kVGMaxBufferSlots) {
        _vt.off[i] = o;
    }
}
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {
    if (i < kVGMaxBufferSlots) {
        _ft.off[i] = o;
    }
}
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained[])b offsets:(const NSUInteger[])o withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) {
        vg_set_buffer(_owner, &_vt, b[k], o[k], r.location + k);
    }
}
- (void)setFragmentBuffers:(const id<MTLBuffer> __unsafe_unretained[])b offsets:(const NSUInteger[])o withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) {
        vg_set_buffer(_owner, &_ft, b[k], o[k], r.location + k);
    }
}
- (void)setVertexBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i { vg_set_bytes(_owner, &_vt, p, n, i); }
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i { vg_set_bytes(_owner, &_ft, p, n, i); }
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { vg_set_texture(_owner, &_vt, t, i); }
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { vg_set_texture(_owner, &_ft, t, i); }
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { vg_set_sampler(_owner, &_vt, s, i); }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { vg_set_sampler(_owner, &_ft, s, i); }
- (void)setViewport:(MTLViewport)v {
    _viewport = (VkViewport){(float)v.originX, (float)(v.originY + v.height), (float)v.width, -(float)v.height,
                             (float)v.znear, (float)v.zfar};
}
- (void)setScissorRect:(MTLScissorRect)r {
    _scissor = (VkRect2D){{(int32_t)r.x, (int32_t)r.y}, {(uint32_t)r.width, (uint32_t)r.height}};
}
- (void)setCullMode:(MTLCullMode)m {
    _cull = m == MTLCullModeFront ? VK_CULL_MODE_FRONT_BIT : m == MTLCullModeBack ? VK_CULL_MODE_BACK_BIT : VK_CULL_MODE_NONE;
}
- (void)setFrontFacingWinding:(MTLWinding)w {
    _front = w == MTLWindingClockwise ? VK_FRONT_FACE_CLOCKWISE : VK_FRONT_FACE_COUNTER_CLOCKWISE;
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)s {
    _ds = (VGMTLDepthStencilState *)s;
    if (s) {
        [_owner->_keep addObject:s];
    }
}
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
    _blend[0] = r, _blend[1] = g, _blend[2] = b, _blend[3] = a;
}
- (void)setTriangleFillMode:(MTLTriangleFillMode)m {
    if (m != MTLTriangleFillModeFill) {
        vglog("render: line fill mode not supported yet (filled)");
    }
}
- (void)setStencilReferenceValue:(uint32_t)v { }
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)c { }
- (void)setDepthClipMode:(MTLDepthClipMode)m { }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)s { }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u { }
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)a beforeStages:(MTLRenderStages)b { }

- (BOOL)prepareDraw:(MTLPrimitiveType)type {
    if (!_open || !_pso) {
        [_owner fail:_open ? @"draw without a render pipeline" : @"draw after endEncoding"];
        return NO;
    }
    int cls = type == MTLPrimitiveTypePoint ? 0 : (type == MTLPrimitiveTypeLine || type == MTLPrimitiveTypeLineStrip) ? 1 : 2;
    NSString *why = nil;
    VkPipeline pipe = [_pso pipelineForClass:cls error:&why];
    if (!pipe) {
        [_owner fail:why];
        return NO;
    }
    VkDescriptorSet sets[2];
    sets[0] = vg_write_set(_owner, _pso->_dsl[0], _pso->_vb, _pso->_nvb, &_vt, _pso->_name);
    sets[1] = sets[0] ? vg_write_set(_owner, _pso->_dsl[1], _pso->_fb, _pso->_nfb, &_ft, _pso->_name) : VK_NULL_HANDLE;
    if (!sets[1]) {
        return NO;
    }
    VkCommandBuffer cb = _owner->_cb;
    gVk.vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    gVk.vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, _pso->_layout, 0, 2, sets, 0, NULL);
    for (uint32_t i = 0; i < _pso->_nvbind; i++) {
        uint32_t b = _pso->_vbind[i].binding;
        if (!_vt.buf[b]) {
            [_owner fail:[NSString stringWithFormat:@"%@: no vertex buffer at index %u", _pso->_name, b]];
            return NO;
        }
        gVk.vkCmdBindVertexBuffers(cb, b, 1, &_vt.buf[b], &_vt.off[b]);
    }
    static const VkPrimitiveTopology kTopo[] = {
        [MTLPrimitiveTypePoint] = VK_PRIMITIVE_TOPOLOGY_POINT_LIST, [MTLPrimitiveTypeLine] = VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
        [MTLPrimitiveTypeLineStrip] = VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
        [MTLPrimitiveTypeTriangle] = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        [MTLPrimitiveTypeTriangleStrip] = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP};
    gVk.vkCmdSetPrimitiveTopology(cb, kTopo[type <= MTLPrimitiveTypeTriangleStrip ? type : MTLPrimitiveTypeTriangle]);
    gVk.vkCmdSetPrimitiveRestartEnable(cb, type == MTLPrimitiveTypeLineStrip || type == MTLPrimitiveTypeTriangleStrip);
    gVk.vkCmdSetViewport(cb, 0, 1, &_viewport);
    gVk.vkCmdSetScissor(cb, 0, 1, &_scissor);
    gVk.vkCmdSetCullMode(cb, _cull);
    gVk.vkCmdSetFrontFace(cb, _front);
    gVk.vkCmdSetDepthTestEnable(cb, _ds ? _ds->_test : VK_FALSE);
    gVk.vkCmdSetDepthWriteEnable(cb, _ds ? _ds->_write : VK_FALSE);
    gVk.vkCmdSetDepthCompareOp(cb, _ds ? _ds->_compare : VK_COMPARE_OP_ALWAYS);
    gVk.vkCmdSetStencilTestEnable(cb, VK_FALSE);
    gVk.vkCmdSetBlendConstants(cb, _blend);
    return YES;
}

- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
         instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    if (count && instances && [self prepareDraw:type]) {
        gVk.vkCmdDraw(_owner->_cb, (uint32_t)count, (uint32_t)instances, (uint32_t)start, (uint32_t)base);
    }
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
         instanceCount:(NSUInteger)instances {
    [self drawPrimitives:type vertexStart:start vertexCount:count instanceCount:instances baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count {
    [self drawPrimitives:type vertexStart:start vertexCount:count instanceCount:1 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)itype
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)off instanceCount:(NSUInteger)instances
                   baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)base {
    VkBuffer b = vg_vkbuffer(ib);
    if (!b) {
        [_owner fail:@"drawIndexedPrimitives: not our index buffer"];
        return;
    }
    if (count && instances && [self prepareDraw:type]) {
        [_owner->_keep addObject:ib];
        gVk.vkCmdBindIndexBuffer(_owner->_cb, b, off,
                                 itype == MTLIndexTypeUInt16 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32);
        gVk.vkCmdDrawIndexed(_owner->_cb, (uint32_t)count, (uint32_t)instances, 0, (int32_t)baseVertex, (uint32_t)base);
    }
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)itype
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)off instanceCount:(NSUInteger)instances {
    [self drawIndexedPrimitives:type indexCount:count indexType:itype indexBuffer:ib indexBufferOffset:off
                  instanceCount:instances baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)itype
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)off {
    [self drawIndexedPrimitives:type indexCount:count indexType:itype indexBuffer:ib indexBufferOffset:off
                  instanceCount:1 baseVertex:0 baseInstance:0];
}

- (void)endEncoding {
    if (_open) {
        gVk.vkCmdEndRendering(_owner->_cb);
        [_owner barrier];
        _open = NO;
    }
}
@end

// The protocol method lives in a category so the render code stays in this file.
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation VGMTLCommandBuffer (Render)

static VkAttachmentLoadOp vg_load(MTLLoadAction a) {
    return a == MTLLoadActionClear ? VK_ATTACHMENT_LOAD_OP_CLEAR
           : a == MTLLoadActionLoad ? VK_ATTACHMENT_LOAD_OP_LOAD
                                    : VK_ATTACHMENT_LOAD_OP_DONT_CARE;
}
static VkAttachmentStoreOp vg_store(MTLStoreAction a) {
    return a == MTLStoreActionDontCare ? VK_ATTACHMENT_STORE_OP_DONT_CARE : VK_ATTACHMENT_STORE_OP_STORE;
}

- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
    if (![self begin]) {
        [self fail:@"no command buffer"];
        return nil;
    }
    VkRenderingAttachmentInfo color[kVGMaxColor];
    uint32_t ncolor = 0, w = UINT32_MAX, h = UINT32_MAX;
    for (uint32_t i = 0; i < kVGMaxColor; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
        color[i] = (VkRenderingAttachmentInfo){VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO};
        color[i].imageLayout = VK_IMAGE_LAYOUT_GENERAL;
        VGMTLTexture *t = (VGMTLTexture *)c.texture;
        if (!t) {
            continue;
        }
        if (![t isKindOfClass:[VGMTLTexture class]] || c.level || c.slice || c.depthPlane || c.resolveTexture) {
            [self fail:@"color attachment: only level 0 / slice 0 of our own textures, no resolve, yet"];
            return nil;
        }
        [_keep addObject:t];
        color[i].imageView = t->_view;
        color[i].loadOp = vg_load(c.loadAction);
        color[i].storeOp = vg_store(c.storeAction);
        MTLClearColor cc = c.clearColor;
        color[i].clearValue.color = (VkClearColorValue){{(float)cc.red, (float)cc.green, (float)cc.blue, (float)cc.alpha}};
        ncolor = i + 1;
        w = MIN(w, (uint32_t)t->_width);
        h = MIN(h, (uint32_t)t->_height);
    }
    VkRenderingAttachmentInfo depth = {VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO};
    VGMTLTexture *dt = (VGMTLTexture *)d.depthAttachment.texture;
    if (dt) {
        [_keep addObject:dt];
        depth.imageView = dt->_view;
        depth.imageLayout = VK_IMAGE_LAYOUT_GENERAL;
        depth.loadOp = vg_load(d.depthAttachment.loadAction);
        depth.storeOp = vg_store(d.depthAttachment.storeAction);
        depth.clearValue.depthStencil = (VkClearDepthStencilValue){(float)d.depthAttachment.clearDepth, 0};
        w = MIN(w, (uint32_t)dt->_width);
        h = MIN(h, (uint32_t)dt->_height);
    }
    if (w == UINT32_MAX) {
        w = (uint32_t)MAX(d.renderTargetWidth, 1);
        h = (uint32_t)MAX(d.renderTargetHeight, 1);
    }
    VGRenderEncoder *e = [[VGRenderEncoder alloc] initWithCommandBuffer:self];
    e->_area = (VkRect2D){{0, 0}, {w, h}};
    e->_scissor = e->_area;
    e->_viewport = (VkViewport){0, (float)h, (float)w, -(float)h, 0, 1};
    e->_front = VK_FRONT_FACE_CLOCKWISE;   // Metal's default winding
    e->_cull = VK_CULL_MODE_NONE;
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, e->_area, 1, 0, ncolor, color, dt ? &depth : NULL, NULL};
    gVk.vkCmdBeginRendering(_cb, &ri);
    e->_open = YES;
    return e;
}
@end
