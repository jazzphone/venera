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
// - Framebuffer fetch ([[color(n)]] reads, Core Animation's shaders in WindowServer): the translator reads color n as an
//   input attachment at set 3, binding 192+n. NV's rewrite (vendor/nullmoth/plugin/nvmtl_fetch_copy.h) turns each such
//   read into a texel fetch of a sampled image at the fragment's position; before a draw with such a pipeline the
//   encoder ends rendering, copies the color attachments to scratch images, resumes rendering (load) and binds the
//   copies at set 3 (NV's "fetch copy"). A [[color(n)]] the pass has no attachment for reads a zeroed scratch image.
// - Tessellation (5d, NullMoth's design, VGMTLTess.c): a post-tessellation vertex function is the evaluation stage, with
//   a generated vertex and control stage in front of it; the control stage pulls the per-control-point and per-patch
//   data from the vertex buffers by device address (a push-constant block), and drawPatches is a patch-list draw.
#import "objects.h"
#import <objc/runtime.h>
#include "nvmtl_fetch_copy.h"
#include "VGMTLTess.h"

// Which [[color(n)]] inputs a fragment module declares (OpDecorate Binding 192+n) and which it reads: a variable some
// OpLoad, OpAccessChain, OpCopyObject or OpFunctionCall uses (5c). Core Animation's specialized shaders can keep the
// declarations after their function constants removed the reads, and a declared-only input needs no copies.
static uint32_t vg_spirv_fetch_mask(NSData *spv, uint32_t *declared) {
    const uint32_t *w = spv.bytes;
    size_t nw = spv.length / 4;
    uint32_t m = 0, d = 0;
    *declared = 0;
    if (nw < 5 || w[0] != 0x07230203u) {
        return 0;
    }
    uint32_t ids[8] = {0};
    for (size_t i = 5; i < nw;) {
        uint32_t wc = w[i] >> 16, op = w[i] & 0xffffu;
        if (!wc || i + wc > nw) {
            break;
        }
        if (op == 71 && wc == 4 && w[i + 2] == 33 && w[i + 3] >= 192 && w[i + 3] < 200) {
            d |= 1u << (w[i + 3] - 192);
            ids[w[i + 3] - 192] = w[i + 1];
        }
        i += wc;
    }
    for (size_t i = 5; d && i < nw;) {
        uint32_t wc = w[i] >> 16, op = w[i] & 0xffffu;
        if (!wc || i + wc > nw) {
            break;
        }
        size_t from = 0, to = 0;   // operand words that may name the variable
        if (op == 61 || op == 65 || op == 66 || op == 83) {   // OpLoad, OpAccessChain, OpInBoundsAccessChain, OpCopyObject
            from = to = 3;
        } else if (op == 57) {   // OpFunctionCall: arguments
            from = 4, to = wc - 1;
        }
        for (size_t k = from; from && k <= to && k < wc; k++) {
            for (uint32_t n = 0; n < 8; n++) {
                if (ids[n] && w[i + k] == ids[n]) {
                    m |= 1u << n;
                }
            }
        }
        i += wc;
    }
    *declared = d;
    return m;
}

// Set 3 for fetch pipelines: sampled images at 192..199 (set 2 is an empty layout so the sets stay numbered).
static VkDescriptorSetLayout gFetchLayout, gEmptyLayout;
static BOOL vg_fetch_layouts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VkDescriptorSetLayoutBinding b[8];
        for (uint32_t i = 0; i < 8; i++) {
            b[i] = (VkDescriptorSetLayoutBinding){192 + i, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL};
        }
        VkDescriptorSetLayoutCreateInfo fi = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 8, b};
        VkDescriptorSetLayoutCreateInfo ei = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 0, NULL};
        if (gVk.vkCreateDescriptorSetLayout(gVk.device, &fi, NULL, &gFetchLayout) != VK_SUCCESS ||
            gVk.vkCreateDescriptorSetLayout(gVk.device, &ei, NULL, &gEmptyLayout) != VK_SUCCESS) {
            gFetchLayout = gEmptyLayout = VK_NULL_HANDLE;
        }
    });
    return gFetchLayout && gEmptyLayout;
}

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
    // the rest of Metal's vertex formats (Memoji's SceneKit-style shaders read half3: 0.1.9); a format the GPU can't
    // fetch is refused at the pipeline (vg_vertex_format_ok)
    case MTLVertexFormatHalf: return VK_FORMAT_R16_SFLOAT;
    case MTLVertexFormatHalf3: return VK_FORMAT_R16G16B16_SFLOAT;
    case MTLVertexFormatInt3: return VK_FORMAT_R32G32B32_SINT;
    case MTLVertexFormatUInt3: return VK_FORMAT_R32G32B32_UINT;
    case MTLVertexFormatUChar: return VK_FORMAT_R8_UINT;
    case MTLVertexFormatUChar2: return VK_FORMAT_R8G8_UINT;
    case MTLVertexFormatUChar3: return VK_FORMAT_R8G8B8_UINT;
    case MTLVertexFormatChar: return VK_FORMAT_R8_SINT;
    case MTLVertexFormatChar2: return VK_FORMAT_R8G8_SINT;
    case MTLVertexFormatChar3: return VK_FORMAT_R8G8B8_SINT;
    case MTLVertexFormatChar4: return VK_FORMAT_R8G8B8A8_SINT;
    case MTLVertexFormatUCharNormalized: return VK_FORMAT_R8_UNORM;
    case MTLVertexFormatUChar2Normalized: return VK_FORMAT_R8G8_UNORM;
    case MTLVertexFormatUChar3Normalized: return VK_FORMAT_R8G8B8_UNORM;
    case MTLVertexFormatCharNormalized: return VK_FORMAT_R8_SNORM;
    case MTLVertexFormatChar2Normalized: return VK_FORMAT_R8G8_SNORM;
    case MTLVertexFormatChar3Normalized: return VK_FORMAT_R8G8B8_SNORM;
    case MTLVertexFormatShort: return VK_FORMAT_R16_SINT;
    case MTLVertexFormatShort3: return VK_FORMAT_R16G16B16_SINT;
    case MTLVertexFormatShort4: return VK_FORMAT_R16G16B16A16_SINT;
    case MTLVertexFormatUShort: return VK_FORMAT_R16_UINT;
    case MTLVertexFormatUShort2: return VK_FORMAT_R16G16_UINT;
    case MTLVertexFormatUShort3: return VK_FORMAT_R16G16B16_UINT;
    case MTLVertexFormatUShort4: return VK_FORMAT_R16G16B16A16_UINT;
    case MTLVertexFormatShortNormalized: return VK_FORMAT_R16_SNORM;
    case MTLVertexFormatShort3Normalized: return VK_FORMAT_R16G16B16_SNORM;
    case MTLVertexFormatShort4Normalized: return VK_FORMAT_R16G16B16A16_SNORM;
    case MTLVertexFormatUShortNormalized: return VK_FORMAT_R16_UNORM;
    case MTLVertexFormatUShort3Normalized: return VK_FORMAT_R16G16B16_UNORM;
    case MTLVertexFormatUShort4Normalized: return VK_FORMAT_R16G16B16A16_UNORM;
    case MTLVertexFormatInt1010102Normalized: return VK_FORMAT_A2B10G10R10_SNORM_PACK32;
    case MTLVertexFormatUInt1010102Normalized: return VK_FORMAT_A2B10G10R10_UNORM_PACK32;
    case MTLVertexFormatFloatRG11B10: return VK_FORMAT_B10G11R11_UFLOAT_PACK32;
    case MTLVertexFormatFloatRGB9E5: return VK_FORMAT_E5B9G9R9_UFLOAT_PACK32;
    default: return VK_FORMAT_UNDEFINED;
    }
}

// the GPU fetches it as a vertex attribute (Venus passes the host's answer; 3-component 8- and 16-bit formats are the
// ones some GPUs lack)
static BOOL vg_vertex_format_ok(VkFormat f) {
    VkFormatProperties fp = {0};
    gVk.vkGetPhysicalDeviceFormatProperties(gVk.physical, f, &fp);
    return (fp.bufferFeatures & VK_FORMAT_FEATURE_VERTEX_BUFFER_BIT) != 0;
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
    VkDescriptorSetLayout _dsl[4];   // 0 vertex, 1 fragment, 2 empty, 3 framebuffer fetch (only with _fetchMask)
    uint32_t _fetchMask;             // [[color(n)]] the fragment stage reads
    uint32_t _fetchDeclared;         // ... and declares (set 3 in the layout; no copies for declared-only ones)
    VkPipelineLayout _layout;
    NSUInteger _samples;             // raster sample count (5d)
    BOOL _alphaToCoverage;
    vg_binding _vb[64], _fb[64];
    int _nvb, _nfb;
    VkVertexInputBindingDescription _vbind[kVGMaxBufferSlots];
    VkVertexInputAttributeDescription _vattr[31];
    uint32_t _nvbind, _nvattr;
    uint32_t _ncolor;
    VkFormat _color[kVGMaxColor], _depthFormat, _stencilFormat;
    VkPipelineColorBlendAttachmentState _blend[kVGMaxColor];
    VkPipeline _pipelines[12];   // points, lines, triangles; the same with depth clamped (MTLDepthClipModeClamp); then all
                                 // six for attachments in the feedback loop layout (5d)
    // Tessellation (5d): _vs is then the evaluation stage, _tvs and _tcs the generated vertex and control stages; the
    // control stage pulls from Metal vertex buffers _tessVb[0.._tessNvb) (vg_tess_push.vb in that order).
    BOOL _tess;
    uint32_t _tessN, _tessCpidx, _tessNvb, _tessVb[VG_TESS_NVB];
    VkShaderModule _tvs, _tcs;
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
    return [self pipelineForClass:cls clamp:NO feedback:NO error:error];
}
- (VkPipeline)pipelineForClass:(int)cls clamp:(BOOL)clamp error:(NSString **)error {
    return [self pipelineForClass:cls clamp:clamp feedback:NO error:error];
}
// clamp (5d): depth clamped instead of clipped (setDepthClipMode:MTLDepthClipModeClamp). RenderBox draws its path
// coverage at depth 2 with clamping on; clipped, nothing of it was drawn (the Dock's icon shadow, Spotlight's icons).
// feedback (5d): drawing while an attachment is in the feedback loop layout -- read in place by a framebuffer fetch, or
// bound as an ordinary texture by the app itself (RenderBox's programmable blending reads its color target as texture(4)).
- (VkPipeline)pipelineForClass:(int)cls clamp:(BOOL)clamp feedback:(BOOL)feedback error:(NSString **)error {
    const int slot = cls + (clamp ? 3 : 0) + (feedback ? 6 : 0);
    @synchronized(self) {
        if (_pipelines[slot]) {
            return _pipelines[slot];
        }
        static const VkPrimitiveTopology kTopology[3] = {VK_PRIMITIVE_TOPOLOGY_POINT_LIST, VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
                                                         VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
        // a tessellation pipeline: the evaluation stage where the vertex stage is, the generated two after the fragment
        VkPipelineShaderStageCreateInfo stages[4] = {
            {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
             _tess ? VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT : VK_SHADER_STAGE_VERTEX_BIT, _vs, "main", NULL},
            {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, _fs, "main", NULL},
            {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, _tvs, "main", NULL},
            {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, _tcs, "main",
             NULL}};
        if (_tess && !_fs) {   // no fragment stage: the generated two move up
            stages[1] = stages[2];
            stages[2] = stages[3];
        }
        VkPipelineVertexInputStateCreateInfo vi = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, NULL, 0,
                                                   _nvbind, _vbind, _nvattr, _vattr};
        VkPipelineInputAssemblyStateCreateInfo ia = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, NULL, 0,
                                                     _tess ? VK_PRIMITIVE_TOPOLOGY_PATCH_LIST : kTopology[cls], VK_FALSE};
        // one control point per patch: the generated vertex stage only passes the patch's position on (VGMTLTess.c)
        VkPipelineTessellationStateCreateInfo ts = {VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO, NULL, 0, 1};
        VkPipelineViewportStateCreateInfo vp = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, NULL, 0, 1, NULL, 1, NULL};
        VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.lineWidth = 1.0f;
        rs.depthClampEnable = clamp;
        VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, NULL, 0,
                                                   _samples > 1 ? (VkSampleCountFlagBits)_samples : VK_SAMPLE_COUNT_1_BIT};
        ms.alphaToCoverageEnable = _alphaToCoverage;
        VkPipelineDepthStencilStateCreateInfo ds = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
        ds.maxDepthBounds = 1.0f;
        VkPipelineColorBlendStateCreateInfo cb = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, NULL, 0,
                                                  VK_FALSE, VK_LOGIC_OP_COPY, _ncolor, _blend};
        static const VkDynamicState kDynamic[] = {
            VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY,
            VK_DYNAMIC_STATE_CULL_MODE, VK_DYNAMIC_STATE_FRONT_FACE, VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE,
            VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE, VK_DYNAMIC_STATE_DEPTH_COMPARE_OP, VK_DYNAMIC_STATE_STENCIL_TEST_ENABLE,
            VK_DYNAMIC_STATE_STENCIL_OP, VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK, VK_DYNAMIC_STATE_STENCIL_WRITE_MASK,
            VK_DYNAMIC_STATE_STENCIL_REFERENCE,
            VK_DYNAMIC_STATE_BLEND_CONSTANTS, VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE};
        VkPipelineDynamicStateCreateInfo dyn = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, NULL, 0,
                                                sizeof(kDynamic) / sizeof(*kDynamic), kDynamic};
        VkPipelineRenderingCreateInfo ri = {VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, NULL, 0, _ncolor, _color,
                                            _depthFormat, _stencilFormat};
        VkGraphicsPipelineCreateInfo gci = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &ri};
        gci.stageCount = (_fs ? 2 : 1) + (_tess ? 2 : 0);
        gci.pStages = stages;
        gci.pVertexInputState = &vi;
        gci.pInputAssemblyState = &ia;
        gci.pTessellationState = _tess ? &ts : NULL;
        gci.pViewportState = &vp;
        gci.pRasterizationState = &rs;
        gci.pMultisampleState = &ms;
        gci.pDepthStencilState = &ds;
        gci.pColorBlendState = &cb;
        gci.pDynamicState = &dyn;
        gci.layout = _layout;
        if ((_fetchMask || feedback) && gVk.feedbackLoop) {
            gci.flags |= VK_PIPELINE_CREATE_COLOR_ATTACHMENT_FEEDBACK_LOOP_BIT_EXT;   // samples its attachment (mode 4)
        }
        VkResult r = gVk.vkCreateGraphicsPipelines(gVk.device, VK_NULL_HANDLE, 1, &gci, NULL, &_pipelines[slot]);
        vg_trace_sync("vkCreateGraphicsPipelines");
        if (r != VK_SUCCESS) {
            *error = [NSString stringWithFormat:@"%@: vkCreateGraphicsPipelines %d", _name, r];
            _pipelines[slot] = VK_NULL_HANDLE;
        }
        return _pipelines[slot];
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

// A post-tessellation vertex function's pipeline (5d, VGMTLTess.c; NullMoth's NVMTLDevice.m reads the descriptor the same
// way): checks what the device and the descriptor need, reads the reflected control-point count and [[instance_id]]
// Location, describes the vertex descriptor and builds the stages. Returns the evaluation module (vs with the
// descriptor's spacing and vertex order) and the generated vertex and control modules, or nil with why.
static NSData *vg_tess_pipeline(VGMTLRenderPipelineState *p, MTLRenderPipelineDescriptor *d, NSObject *vf, NSData *vs,
                                uint32_t patchType, uint32_t cps, NSData **tvs, NSData **tcs, NSString **why) {
    if (!gVk.tessellation || !gVk.int64 || !gVk.bufferAddresses) {
        *why = [NSString stringWithFormat:@"tessellation: this device lacks %s",
                                          !gVk.tessellation ? "tessellationShader" : !gVk.int64 ? "shaderInt64"
                                          : gVk.deviceAddress ? "buffers with device addresses (VirtioGPUMetal-nobda)"
                                                              : "bufferDeviceAddress"];
        return nil;
    }
    if (d.tessellationFactorFormat != MTLTessellationFactorFormatHalf) {
        *why = [NSString stringWithFormat:@"tessellation: factor format %lu (only Half is carried)",
                                          (unsigned long)d.tessellationFactorFormat];
        return nil;
    }
    NSString *rerr = nil;
    NSDictionary *tr = vg_reflect([vf vgLL], "vertex", [vf vgFC], &rerr)[@"tessellation"];
    if (![tr isKindOfClass:[NSDictionary class]]) {
        tr = nil;
    }
    NSNumber *rn = [tr[@"control_point_count"] isKindOfClass:[NSNumber class]] ? tr[@"control_point_count"] : nil;
    NSDictionary *ri = [tr[@"instance_id"] isKindOfClass:[NSDictionary class]] ? tr[@"instance_id"] : nil;
    NSNumber *rl = [ri[@"location"] isKindOfClass:[NSNumber class]] ? ri[@"location"] : nil;
    uint32_t n = rn.unsignedIntValue ? rn.unsignedIntValue : cps;
    if (rn.unsignedIntValue && cps && rn.unsignedIntValue != cps) {
        *why = [NSString stringWithFormat:@"tessellation: %@ reflects %u control points and its module reads %u",
                                          ((id<MTLFunction>)vf).name, rn.unsignedIntValue, cps];
        return nil;
    }
    if (!n || n > 32) {
        *why = [NSString stringWithFormat:@"tessellation: %@ has no control-point count in 1..32 (%u)", ((id<MTLFunction>)vf).name, n];
        return nil;
    }
    if (!tr) {
        vglog("tessellation: %s has no reflection (%s): its instance_id Location is inferred from the interface",
              ((id<MTLFunction>)vf).name.UTF8String, rerr.UTF8String ?: "-");
    }
    float maxf = (float)d.maxTessellationFactor;
    maxf = MIN(MAX(maxf, 1.0f), MIN(64.0f, (float)gVk.props.limits.maxTessellationGenerationLevel));
    vg_tess_desc td = {patchType, n, (uint32_t)d.tessellationPartitionMode, (uint32_t)d.tessellationOutputWindingOrder,
                       (uint32_t)d.tessellationFactorStepFunction, d.tessellationFactorScaleEnabled ? 1u : 0u,
                       (uint32_t)d.tessellationControlPointIndexType, maxf, rl ? rl.intValue : -1};
    // the vertex descriptor as the control stage reads it (attribute n at Location n)
    vg_tess_input vin;
    memset(&vin, 0, sizeof(vin));
    MTLVertexDescriptor *vd = d.vertexDescriptor;
    for (uint32_t a = 0; a < VG_TESS_NATTR && vd; a++) {
        MTLVertexAttributeDescriptor *ad = vd.attributes[a];
        if (ad.format == MTLVertexFormatInvalid) {
            continue;
        }
        if (ad.bufferIndex >= VG_TESS_NATTR) {
            *why = [NSString stringWithFormat:@"tessellation: vertex attribute %u reads buffer %lu", a, (unsigned long)ad.bufferIndex];
            return nil;
        }
        vin.attr[vin.nattr++] = (typeof(vin.attr[0])){a, (uint32_t)ad.bufferIndex, (uint32_t)ad.format, (uint32_t)ad.offset};
        MTLVertexBufferLayoutDescriptor *ld = vd.layouts[ad.bufferIndex];
        vin.layout[ad.bufferIndex].stride = ld.stride > UINT32_MAX ? VG_TESS_STRIDE_DYNAMIC : (uint32_t)ld.stride;
        vin.layout[ad.bufferIndex].step = (uint32_t)ld.stepFunction;
        vin.layout[ad.bufferIndex].rate = (uint32_t)ld.stepRate;
    }
    vg_tess_modules m;
    char reason[256] = "";
    if (vg_tess_build(vs.bytes, vs.length / 4, &td, &vin, &m, reason, sizeof(reason))) {
        *why = [NSString stringWithFormat:@"tessellation: %s", reason];
        return nil;
    }
    p->_tess = YES;
    p->_tessN = n;
    p->_tessCpidx = td.cpidx;
    p->_tessNvb = m.nvb;
    memcpy(p->_tessVb, m.vbmap, sizeof(p->_tessVb));
    *tvs = [NSData dataWithBytesNoCopy:m.vs length:m.vsWords * 4 freeWhenDone:YES];
    *tcs = [NSData dataWithBytesNoCopy:m.tcs length:m.tcsWords * 4 freeWhenDone:YES];
    vglog("tessellation: %s: %s patch, %u control points, partition %u, winding %u, factor step %u, scale %u, "
          "control-point index %u, max %.0f, %u vertex buffer(s) pulled, patch_id at Location %d, instance_id Location %d",
          ((id<MTLFunction>)vf).name.UTF8String, patchType == 2 ? "quad" : "triangle", n, td.partition, td.winding, td.stepfn,
          td.scale_en, td.cpidx, (double)td.maxf, m.nvb, (int)m.pidloc, (int)td.inst_loc);
    return [NSData dataWithBytesNoCopy:m.tese length:m.teseWords * 4 freeWhenDone:YES];
}

static BOOL vg_passlog(void);
id<MTLRenderPipelineState> vg_new_render_pipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor *d, NSError **error) {
    if (error) {
        *error = nil;
    }
    NSString *why = nil;
    NSObject *vf = (NSObject *)d.vertexFunction, *ff = (NSObject *)d.fragmentFunction;
    VGMTLRenderPipelineState *p = nil;
    if (![vf respondsToSelector:@selector(vgLL)] || ![[vf vgStage] isEqual:@"vertex"] ||
        (ff && (![ff respondsToSelector:@selector(vgLL)] || ![[ff vgStage] isEqual:@"fragment"]))) {
        why = @"not VirtioGPUMetal vertex/fragment functions";
    } else if (d.rasterSampleCount > 1 && !(gVk.props.limits.framebufferColorSampleCounts & d.rasterSampleCount)) {
        why = [NSString stringWithFormat:@"%lu samples aren't supported", (unsigned long)d.rasterSampleCount];
    } else if (vg_vulkan_init()) {
        why = @"Venus is down";
    } else {
        p = [VGMTLRenderPipelineState new];
        p->_dev = device;
        p->_name = [NSString stringWithFormat:@"%@+%@", d.vertexFunction.name, d.fragmentFunction.name ?: @"-"];
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        p->_samples = MAX(d.rasterSampleCount, 1);
        p->_alphaToCoverage = d.alphaToCoverageEnabled;
        vg_translate_set_samples((uint32_t)p->_samples);
        NSData *vs = vg_translate([vf vgLL], "vertex", [vf vgFC], NULL, 0, &why);
        NSData *fs = ff && vs ? vg_translate([ff vgLL], "fragment", [ff vgFC], NULL, 0, &why) : nil;
        vg_translate_set_samples(0);
        uint32_t declared = 0, fetch = fs ? vg_spirv_fetch_mask(fs, &declared) : 0;
        if (declared) {
            vglog("render pipeline %s: framebuffer inputs declared 0x%x, read 0x%x%s", p->_name.UTF8String, declared, fetch,
                  fetch ? "" : " (no copies)");
        }
        if (declared) {
            size_t nw = 0;
            uint32_t *rw = nvmtl_spirv_fetch_to_texture(fs.bytes, fs.length / 4, &nw);
            if (rw && vg_fetch_layouts()) {
                // Rewritten either way (declared inputs become sampled images at set 3); copies only for the read ones.
                fs = [NSData dataWithBytesNoCopy:rw length:nw * 4 freeWhenDone:YES];
                p->_fetchMask = fetch;
                p->_fetchDeclared = declared;
            } else {
                free(rw);
                why = @"framebuffer fetch: the fragment module couldn't be rewritten for copies";
                fs = nil;
            }
        }
        if (fs) {
            fs = vg_spirv_retarget_set(fs, 1);
        }
        uint32_t tessType = 0, tessCps = 0;
        NSData *tvs = nil, *tcs = nil;
        if (vs && vg_spirv_tess_info(vs.bytes, vs.length, &tessType, &tessCps)) {
            vs = vg_tess_pipeline(p, d, vf, vs, tessType, tessCps, &tvs, &tcs, &why);
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
            for (int i = 0; i < p->_nvb; i++) {   // constexpr samplers, from the (cached) reflection
                if (p->_vb[i].type == VK_DESCRIPTOR_TYPE_SAMPLER) {
                    vg_apply_static_samplers(vg_reflect([vf vgLL], "vertex", [vf vgFC], &(NSString *__autoreleasing){nil}), p->_vb, p->_nvb);
                    break;
                }
            }
            for (int i = 0; i < p->_nfb; i++) {
                if (p->_fb[i].type == VK_DESCRIPTOR_TYPE_SAMPLER) {
                    vg_apply_static_samplers(vg_reflect([ff vgLL], "fragment", [ff vgFC], &(NSString *__autoreleasing){nil}), p->_fb, p->_nfb);
                    break;
                }
            }
            p->_vs = vg_module(vs);
            p->_fs = fs ? vg_module(fs) : VK_NULL_HANDLE;
            if (p->_tess) {
                p->_tvs = vg_module(tvs);
                p->_tcs = vg_module(tcs);
            }
            // set 0 is the vertex function's: the evaluation stage's in a tessellation pipeline (the generated stages
            // bind nothing)
            p->_dsl[0] = vg_set_layout(p->_vb, p->_nvb,
                                       p->_tess ? VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT : VK_SHADER_STAGE_VERTEX_BIT);
            p->_dsl[1] = vg_set_layout(p->_fb, p->_nfb, VK_SHADER_STAGE_FRAGMENT_BIT);
            p->_dsl[2] = gEmptyLayout;
            p->_dsl[3] = gFetchLayout;
            // Render stages have no push constants of their own (refused above); a tessellation pipeline's control
            // stage reads vg_tess_push from offset 0.
            VkPushConstantRange tessRange = {VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, 0, VG_TESS_PC_BYTES};
            VkPipelineLayoutCreateInfo plci = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, p->_fetchDeclared ? 4 : 2,
                                               p->_dsl, p->_tess ? 1 : 0, p->_tess ? &tessRange : NULL};
            vg_trace_sync("shader modules + set layouts");
            gVk.vkCreatePipelineLayout(gVk.device, &plci, NULL, &p->_layout);
            vg_trace_sync("pipeline layout");
            vglog("render pipeline %s: translated in %.1f ms (%lu + %lu bytes of SPIR-V, %d + %d bindings%s%s)",
                  p->_name.UTF8String, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, (unsigned long)vs.length,
                  (unsigned long)fs.length, p->_nvb, p->_nfb, p->_fetchMask ? ", framebuffer fetch by copies" : "",
                  p->_tess ? ", tessellation" : "");
            if (p->_tess && (!p->_vs || !p->_tvs || !p->_tcs)) {
                why = @"tessellation: vkCreateShaderModule failed for a stage";
                p = nil;
            }
        }
    }
    if (p) {
        // Vertex input from the vertex descriptor (none in a tessellation pipeline: its control stage pulls it).
        MTLVertexDescriptor *vd = p->_tess ? nil : d.vertexDescriptor;
        BOOL used[kVGMaxBufferSlots] = {NO};
        for (uint32_t a = 0; a < 31 && vd; a++) {
            MTLVertexAttributeDescriptor *ad = vd.attributes[a];
            if (ad.format == MTLVertexFormatInvalid) {
                continue;
            }
            VkFormat f = vg_vertex_format(ad.format);
            if (!f || ad.bufferIndex >= kVGMaxBufferSlots || !vg_vertex_format_ok(f)) {
                why = [NSString stringWithFormat:@"vertex attribute %u: format %lu not supported %s", a, (unsigned long)ad.format,
                       f ? "by this GPU as a vertex format" : "yet"];
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
            // Constant (5d: OpenGL's glVertexAttrib values through Apple's GL renderer): every vertex reads the same
            // element, which is a per-vertex binding with stride 0 in Vulkan.
            BOOL constant = ld.stepFunction == MTLVertexStepFunctionConstant;
            if (!constant && ld.stepFunction != MTLVertexStepFunctionPerVertex && ld.stepFunction != MTLVertexStepFunctionPerInstance) {
                why = [NSString stringWithFormat:@"vertex buffer %u: step function %lu (only per vertex, per instance and constant "
                                                 @"are supported yet), stride %lu, rate %lu", b, (unsigned long)ld.stepFunction,
                                                 (unsigned long)ld.stride, (unsigned long)ld.stepRate];
                p = nil;
                break;
            }
            p->_vbind[p->_nvbind++] = (VkVertexInputBindingDescription){
                b, constant ? 0 : (uint32_t)ld.stride,
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
        if (vg_passlog()) {   // debugging: the attachments' blending
            NSMutableString *bl = [NSMutableString string];
            for (uint32_t i = 0; i < p->_ncolor; i++) {
                MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
                [bl appendFormat:@" c%u pf%lu wm%lx blend%d rgb(%lu,%lu op%lu) a(%lu,%lu op%lu)", i, (unsigned long)c.pixelFormat,
                                 (unsigned long)c.writeMask, c.blendingEnabled, (unsigned long)c.sourceRGBBlendFactor,
                                 (unsigned long)c.destinationRGBBlendFactor, (unsigned long)c.rgbBlendOperation,
                                 (unsigned long)c.sourceAlphaBlendFactor, (unsigned long)c.destinationAlphaBlendFactor,
                                 (unsigned long)c.alphaBlendOperation];
            }
            static int pipeN;
            int myN = ++pipeN;
            vglog("pipelog #%d %s+%s:%s fetch 0x%x", myN, d.vertexFunction.name.UTF8String, d.fragmentFunction.name.UTF8String,
                  bl.UTF8String, p->_fetchMask);
            NSString *vg_disk_dir(void);
            NSString *dir = vg_disk_dir();
            id vf0 = d.vertexFunction;
            if (dir && [vf0 respondsToSelector:@selector(vgLL)]) {
                [(NSString *)[vf0 performSelector:@selector(vgLL)] writeToFile:[dir stringByAppendingFormat:@"/vert-%@.ll", [vf0 name]]
                                                                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                NSDictionary *vfc = [vf0 respondsToSelector:@selector(vgFC)] ? [vf0 performSelector:@selector(vgFC)] : nil;
                NSMutableData *vd = [NSMutableData data];
                for (NSNumber *k in vfc) {
                    uint32_t hdr[2] = {k.unsignedIntValue, (uint32_t)[vfc[k] length]};
                    [vd appendBytes:hdr length:8];
                    [vd appendData:vfc[k]];
                }
                [vd writeToFile:[dir stringByAppendingFormat:@"/vert-%@-%d.fc", [vf0 name], myN] atomically:YES];
            }
            id ff = d.fragmentFunction;
            if (dir && [ff respondsToSelector:@selector(vgLL)]) {
                [(NSString *)[ff performSelector:@selector(vgLL)] writeToFile:[dir stringByAppendingFormat:@"/frag-%@.ll", [ff name]]
                                                                   atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                // and its function constants: index (u32), size (u32), bytes, one after another
                NSDictionary *fcs = [ff respondsToSelector:@selector(vgFC)] ? [ff performSelector:@selector(vgFC)] : nil;
                NSMutableData *fcd = [NSMutableData data];
                for (NSNumber *k in fcs) {
                    NSData *v = fcs[k];
                    uint32_t hdr[2] = {k.unsignedIntValue, (uint32_t)v.length};
                    [fcd appendBytes:hdr length:8];
                    [fcd appendData:v];
                }
                [fcd writeToFile:[dir stringByAppendingFormat:@"/frag-%@-%d.fc", [ff name], myN] atomically:YES];
            }
        }
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
    uint32_t _stencilRef[2];   // front, back (5d)
    BOOL _depthClamp;          // setDepthClipMode: clamp (5d)
    int32_t _drawn[4];         // what the draws could touch (their scissors' union, x0 y0 x1 y1): a surface's written part
    float _blend[4];
    BOOL _open;
    // the pass, kept so rendering can be ended and resumed around a framebuffer-fetch copy
    VGMTLTexture *_colorTex[kVGMaxColor], *_depthTex, *_stencilTex;
    VkRenderingAttachmentInfo _colorInfo[kVGMaxColor], _depthInfo, _stencilInfo;
    uint32_t _ncolor;
    VGMTLTexture *_fetchCopy[kVGMaxColor];   // scratch copies, made at the first fetch draw of the encoder
    BOOL _feedback[kVGMaxColor];             // in the feedback loop layout since a fetch split (mode 4)
    NSMutableOrderedSet *_dbgPipes;          // debugging (VirtioGPUMetal-passlog): what this pass drew with
    uint32_t _dbgDraws, _dbgRefused, _dbgSplits;
    NSMutableArray *_dbgUniforms;   // (name, stage, VkBuffer, offset) of each draw's buffer 0, copied out at endEncoding
    NSMutableString *_dbgSeq;
    // DRAWDIFF (debugging): a band of color attachment 0 copied before the first draw and after each, compared at
    // completion: what each draw changed
    VGMTLTexture *_ddTex;
    int32_t _ddY0, _ddY1;
    NSMutableArray *_ddBufs;   // NSValue(vg_buffer *)
    NSMutableArray *_ddInfo;   // a description of each draw
    BOOL _ddEach;              // after each draw (else only before the first and at the end)
    NSMutableString *_ddSeq;   // the pass's draws, in each-pass mode
    // Tessellation (5d): the buffer object behind each vertex slot (nil for setVertexBytes, whose memory is the command
    // buffer's arena), for its device address; the factor buffer and scale; a patch draw in progress (prepareDraw).
    __unsafe_unretained VGMTLBuffer *_vobj[kVGMaxBufferSlots];
    id<MTLBuffer> _tfb;
    NSUInteger _tfbOff, _tfbStride;
    float _tfScale;
    BOOL _tfScaleSet;
    BOOL _tessDraw;
    // What this encoder last put into the command buffer (5c round 4): a draw sends state only when it changes. Vulkan
    // keeps dynamic state, the bound pipeline, sets and vertex buffers across render pass instances (the fetch
    // copies' end/resume), so this stays valid for the whole encoder.
    struct {
        BOOL valid;
        VkPipeline pipe;
        VkPipelineLayout layout;
        VkDescriptorSet sets[2], fetch;
        int topo, restart;
        VkViewport viewport;
        VkRect2D scissor;
        VkCullModeFlags cull;
        VkFrontFace front;
        VkBool32 dtest, dwrite;
        VkCompareOp dcmp;
        VGMTLDepthStencilState *sds;   // the stencil state last sent (5d)
        uint32_t sref[2];
        BOOL stencilSet;
        float blend[4];
        VkBuffer vb[kVGMaxBufferSlots];
        VkDeviceSize vboff[kVGMaxBufferSlots];
    } _last;
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
            vg_surface_pull(t->tex[i]);   // synchronous, before this command buffer runs
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
static void vg_track_vertex(VGRenderEncoder *e, id<MTLBuffer> b, NSUInteger i) {
    if (i < kVGMaxBufferSlots) {
        e->_vobj[i] = [(NSObject *)b isKindOfClass:[VGMTLBuffer class]] ? (VGMTLBuffer *)b : nil;
    }
}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {
    vg_set_buffer(_owner, &_vt, b, o, i);
    vg_track_vertex(self, b, i);
}
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
        vg_track_vertex(self, b[k], r.location + k);
    }
}
- (void)setFragmentBuffers:(const id<MTLBuffer> __unsafe_unretained[])b offsets:(const NSUInteger[])o withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) {
        vg_set_buffer(_owner, &_ft, b[k], o[k], r.location + k);
    }
}
- (void)setVertexBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i {
    vg_set_bytes(_owner, &_vt, p, n, i);
    vg_track_vertex(self, nil, i);
}
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i { vg_set_bytes(_owner, &_ft, p, n, i); }
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { vg_set_texture(_owner, &_vt, t, i); }
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { vg_set_texture(_owner, &_ft, t, i); }
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { vg_set_sampler(_owner, &_vt, s, i); }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { vg_set_sampler(_owner, &_ft, s, i); }
// LOD clamps from the encoder (5d: WebKit): the sampler's own clamps apply; these are rarely narrower.
- (void)setVertexSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)a lodMaxClamp:(float)b atIndex:(NSUInteger)i {
    vg_set_sampler(_owner, &_vt, s, i);
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)a lodMaxClamp:(float)b atIndex:(NSUInteger)i {
    vg_set_sampler(_owner, &_ft, s, i);
}
- (void)setViewport:(MTLViewport)v {
    _viewport = (VkViewport){(float)v.originX, (float)(v.originY + v.height), (float)v.width, -(float)v.height,
                             (float)v.znear, (float)v.zfar};
}
// Several viewports or scissors (5d: Maps) take effect for viewport 0 only: shaders that pick another
// ([[viewport_array_index]]) would need multiViewport, and Maps passes one.
- (void)setViewports:(const MTLViewport *)v count:(NSUInteger)n {
    if (n) {
        [self setViewport:v[0]];
    }
}
- (void)setScissorRects:(const MTLScissorRect *)r count:(NSUInteger)n {
    if (n) {
        [self setScissorRect:r[0]];
    }
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
- (void)setStencilReferenceValue:(uint32_t)v { _stencilRef[0] = _stencilRef[1] = v; }
// Store actions decided after the pass began (5d: Apple's GL renderer): every attachment is stored anyway.
- (void)setColorStoreAction:(MTLStoreAction)a atIndex:(NSUInteger)i { }
- (void)setLineWidth:(float)w { }   // wide lines aren't a dynamic state here; GL's are 1 wide
- (void)setDepthStoreAction:(MTLStoreAction)a { }
- (void)setStencilStoreAction:(MTLStoreAction)a { }
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)o atIndex:(NSUInteger)i { }
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)o { }
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)o { }
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b { _stencilRef[0] = f, _stencilRef[1] = b; }
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)c { }
- (void)setDepthClipMode:(MTLDepthClipMode)m { _depthClamp = m == MTLDepthClipModeClamp; }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)s { }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u { }
// A render-target barrier (5d): what the pass has drawn so far becomes readable as a texture by the draws after it.
// RenderBox on a GPU without framebuffer reads (ours: isFramebufferReadSupported NO) binds its coverage attachment as
// texture(5) and asks for this between draws; a no-op here left those reads seeing nothing, so the Dock's Calendar
// icon, drawn by RenderBox in com.apple.dock.extra, came out fully transparent. The pass is ended, everything it wrote
// is made visible to every later stage, and it resumes loading each attachment.
- (void)vgSplitPass {
    if (!_open) {
        return;
    }
    VkCommandBuffer cb = _owner->_cb;
    _dbgSplits++;
    [_dbgSeq appendString:@" |"];
    gVk.vkCmdEndRendering(cb);
    [_owner barrier];
    if (vg_passlog()) {
        [_dbgSeq appendFormat:@"(read %d)", vg_dbg_next_read()];
        [self dbgReadBack];   // what the attachments hold at this barrier
    }
    VkRenderingAttachmentInfo color[kVGMaxColor];
    for (uint32_t i = 0; i < _ncolor; i++) {
        color[i] = _colorInfo[i];
        if (color[i].imageView) {
            color[i].loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        }
    }
    VkRenderingAttachmentInfo depth = _depthInfo, stencil = _stencilInfo;
    depth.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    stencil.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, _area, 1, 0, _ncolor, color, _depthTex ? &depth : NULL,
                          _stencilTex ? &stencil : NULL};
    gVk.vkCmdBeginRendering(cb, &ri);
    static int said;
    if (said++ < 3) {
        vglog("render: render-target barrier: pass split (%ux%u)", _area.extent.width, _area.extent.height);
    }
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)a beforeStages:(MTLRenderStages)b {
    if (scope & (MTLBarrierScopeRenderTargets | MTLBarrierScopeTextures)) {
        [self vgSplitPass];
    }
}
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained *)resources count:(NSUInteger)count
                       afterStages:(MTLRenderStages)a beforeStages:(MTLRenderStages)b {
    for (NSUInteger i = 0; i < count; i++) {
        for (uint32_t k = 0; k < _ncolor; k++) {
            if (resources[i] == (id)_colorTex[k]) {
                [self vgSplitPass];
                return;
            }
        }
    }
}
- (void)textureBarrier { [self vgSplitPass]; }

// The pass log is rechecked every 2 s, so it can be switched on in a running WindowServer; each time it comes on, its
// 400-pass budget starts over (vg_passlog_epoch).
static int vg_passlog_epoch;
static BOOL vg_passlog(void) {
    static int on = -1;
    static uint64_t last;
    uint64_t now = vg_now();
    if (on < 0 || now - last > 2000000000ull) {
        BOOL vg_debug_flag(const char *name);
        int was = on;
        last = now;
        on = vg_debug_flag("passlog");
        if (on && was != 1) {
            vg_passlog_epoch++;
        }
    }
    return on;
}
// DRAWDIFF: the flag file VirtioGPUMetal-drawdiff, rechecked every 2 s: line 1 a piece of a surface name, line 2 the
// band's rows "y0 y1", line 3 how many passes to look at while it is on (default 60), line 4 "draws" (a copy after
// every draw, not only around the pass) or "dropfinal" (no copy at the pass's end: tests the one-snapshot clean-up).
static NSString *gDDName;
static int32_t gDDY0, gDDY1;
static int gDDLeft, gDDDraws, gDDDropFinal;
static void vg_dd_reload(void) {
    static uint64_t checked;
    uint64_t now = vg_now();
    if (checked && now - checked < 2000000000ull) {
        return;
    }
    checked = now;
    NSString *s = [NSString stringWithContentsOfFile:@"/Library/GPUBundles/VirtioGPUMetal-drawdiff"
                                            encoding:NSUTF8StringEncoding error:NULL];
    NSArray<NSString *> *l = [s componentsSeparatedByString:@"\n"];
    NSString *name = l.count > 0 && l[0].length ? l[0] : nil;
    @synchronized([VGRenderEncoder class]) {
        if (!name) {
            gDDName = nil;
            return;
        }
        if (![name isEqualToString:gDDName ?: @""]) {
            gDDName = name;
            gDDY0 = 0, gDDY1 = INT32_MAX;
            if (l.count > 1) {
                sscanf(l[1].UTF8String, "%d %d", &gDDY0, &gDDY1);
            }
            gDDLeft = l.count > 2 && l[2].intValue > 0 ? l[2].intValue : 60;
            gDDDraws = l.count > 3 && [l[3] hasPrefix:@"draws"];
            gDDDropFinal = l.count > 3 && [l[3] hasPrefix:@"dropfinal"];   // tests the one-snapshot clean-up
            vglog("drawdiff: '%s' rows %d-%d, %d passes, %s", name.UTF8String, gDDY0, gDDY1, gDDLeft,
                  gDDDraws ? "each draw" : "each pass");
        }
    }
}
- (void)ddBegin {
    vg_dd_reload();
    VGMTLTexture *t = _colorTex[0];
    while (t && t->_parent) {
        t = t->_parent;
    }
    if (!t || !t->_surface || t->_pixelFormat != MTLPixelFormatBGRA8Unorm) {
        return;
    }
    @synchronized([VGRenderEncoder class]) {
        if (!gDDName || gDDLeft <= 0) {
            return;
        }
        CFTypeRef nm = IOSurfaceCopyValue(t->_surface, kIOSurfaceName);
        BOOL match = nm && CFGetTypeID(nm) == CFStringGetTypeID() && [(__bridge NSString *)nm containsString:gDDName];
        if (nm) {
            CFRelease(nm);
        }
        if (!match) {
            return;
        }
        gDDLeft--;
        _ddY0 = MAX(gDDY0, 0), _ddY1 = MIN(gDDY1, (int32_t)t->_height);
    }
    if (_ddY1 <= _ddY0) {
        return;
    }
    _ddTex = _colorTex[0];
    _ddEach = gDDDraws;
    _ddBufs = [NSMutableArray array];
    _ddInfo = [NSMutableArray array];
}
// the band as it is now (rendering ended and resumed around the copy)
- (void)ddSnap:(NSString *)what {
    if (!_ddTex || !_open || _ddBufs.count >= 200) {
        return;
    }
    VGMTLTexture *t = _ddTex;
    vg_buffer *b = calloc(1, sizeof(*b));
    if (vg_staging_get((VkDeviceSize)t->_width * (_ddY1 - _ddY0) * 4, b)) {
        free(b);
        return;
    }
    VkCommandBuffer cb = _owner->_cb;
    gVk.vkCmdEndRendering(cb);
    [_owner barrier];
    VkImageMemoryBarrier ib = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT,
                               VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
                               VK_IMAGE_LAYOUT_ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT, VK_IMAGE_LAYOUT_GENERAL,
                               VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, t->_image,
                               {VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0, VK_REMAINING_ARRAY_LAYERS}};
    if (_feedback[0]) {   // a fetch split left it in the feedback loop layout: GENERAL around the copy
        gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL,
                                 0, NULL, 1, &ib);
    }
    VkBufferImageCopy c = {0, 0, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, _ddY0, 0},
                           {(uint32_t)t->_width, (uint32_t)(_ddY1 - _ddY0), 1}};
    gVk.vkCmdCopyImageToBuffer(cb, t->_image, VK_IMAGE_LAYOUT_GENERAL, b->buffer, 1, &c);
    [_owner barrier];
    if (_feedback[0]) {
        ib.oldLayout = VK_IMAGE_LAYOUT_GENERAL, ib.newLayout = VK_IMAGE_LAYOUT_ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT;
        gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL,
                                 0, NULL, 1, &ib);
    }
    VkRenderingAttachmentInfo color[kVGMaxColor];
    for (uint32_t i = 0; i < _ncolor; i++) {
        color[i] = _colorInfo[i];
        if (color[i].imageView) {
            color[i].loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        }
    }
    VkRenderingAttachmentInfo depth = _depthInfo, stencil = _stencilInfo;
    depth.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    stencil.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, _area, 1, 0, _ncolor, color, _depthTex ? &depth : NULL,
                          _stencilTex ? &stencil : NULL};
    gVk.vkCmdBeginRendering(cb, &ri);
    [_ddBufs addObject:[NSValue valueWithPointer:b]];
    [_ddInfo addObject:what];
}
- (void)ddDraw:(NSString *)what {
    if (!_ddTex) {
        return;
    }
    if (!_ddEach) {
        if (!_ddSeq) {
            _ddSeq = [NSMutableString string];
        }
        [_ddSeq appendFormat:@" %@ <%d,%d %ux%u>;", what, _scissor.offset.x, _scissor.offset.y, _scissor.extent.width,
                             _scissor.extent.height];
        return;
    }
    [self ddSnap:[NSString stringWithFormat:@"%@ %@ scissor <%d,%d %ux%u> viewport <%.1f,%.1f %.1fx%.1f>%s", _pso->_name ?: @"?",
                                            what, _scissor.offset.x, _scissor.offset.y, _scissor.extent.width,
                                            _scissor.extent.height, _viewport.x, _viewport.y, _viewport.width,
                                            _viewport.height, _ds ? " ds" : ""]];
}
- (void)ddEnd {
    if (_ddTex && !_ddEach && _ddBufs.count == 1 && !gDDDropFinal) {
        [self ddSnap:[NSString stringWithFormat:@"pass of%@", _ddSeq ?: @""]];
    }
    _ddSeq = nil;
    if (!_ddTex || _ddBufs.count < 2) {
        // Nothing to compare (the final copy's staging couldn't be had, or dropfinal), but a copy into the first one
        // is recorded in the command buffer: it goes back to the pool only once the command buffer is done, or the
        // next taker's contents would be overwritten by it. (A command buffer never committed keeps it.)
        NSArray *bufs = _ddBufs;
        _ddBufs = nil, _ddTex = nil;
        if (bufs.count) {
            static _Atomic int lone;
            const int k = ++lone;
            [_owner addCompletedHandler:^(id<MTLCommandBuffer> cbuf) {
              for (NSValue *v in bufs) {
                  vg_staging_put(v.pointerValue);
                  free(v.pointerValue);
              }
              if (k <= 20) {
                  vglog("drawdiff: a pass with %lu snapshot, its staging back to the pool at completion (%d)",
                        (unsigned long)bufs.count, k);
              }
            }];
        }
        return;
    }
    NSArray *bufs = _ddBufs, *info = _ddInfo;
    const size_t w = _ddTex->_width, h = (size_t)(_ddY1 - _ddY0);
    const int32_t y0 = _ddY0;
    const uint32_t sid = IOSurfaceGetID(_ddTex->_surface);
    static _Atomic int passes;
    const int pass = ++passes;
    VGMTLCommandBuffer *owner = _owner;
    [_owner addCompletedHandler:^(id<MTLCommandBuffer> cbuf) {
      vglog("drawdiff pass %d: cb %p surface %u, %lu draws, rows %d-%zu", pass, owner, sid, (unsigned long)bufs.count - 1,
            y0, y0 + h);
      for (NSUInteger k = 1; k < bufs.count; k++) {
          const uint32_t *a = ((vg_buffer *)[bufs[k - 1] pointerValue])->map, *b = ((vg_buffer *)[bufs[k] pointerValue])->map;
          size_t x0 = w, yy0 = h, x1 = 0, yy1 = 0, n = 0;
          for (size_t y = 0; y < h; y++) {
              if (!memcmp(a + y * w, b + y * w, w * 4)) {
                  continue;
              }
              for (size_t x = 0; x < w; x++) {
                  if (a[y * w + x] != b[y * w + x]) {
                      n++;
                      x0 = MIN(x0, x), x1 = MAX(x1, x + 1), yy0 = MIN(yy0, y), yy1 = MAX(yy1, y + 1);
                  }
              }
          }
          if (n) {
              vglog("drawdiff pass %d draw %lu: changed %zu px in %zu,%zu-%zu,%zu: %s", pass, (unsigned long)k, n, x0,
                    yy0 + y0, x1, yy1 + y0, [info[k] UTF8String]);
          } else {
              vglog("drawdiff pass %d draw %lu: nothing changed: %s", pass, (unsigned long)k, [info[k] UTF8String]);
          }
      }
      for (NSValue *v in bufs) {
          vg_staging_put(v.pointerValue);
          free(v.pointerValue);
      }
    }];
    _ddBufs = nil, _ddTex = nil;
}
- (BOOL)prepareDraw:(MTLPrimitiveType)type {
    {
        int32_t x0 = MAX(_scissor.offset.x, 0), y0 = MAX(_scissor.offset.y, 0);
        int32_t x1 = MIN(_scissor.offset.x + (int32_t)_scissor.extent.width, (int32_t)_area.extent.width);
        int32_t y1 = MIN(_scissor.offset.y + (int32_t)_scissor.extent.height, (int32_t)_area.extent.height);
        if (x1 > x0 && y1 > y0) {
            _drawn[0] = MIN(_drawn[0], x0), _drawn[1] = MIN(_drawn[1], y0);
            _drawn[2] = MAX(_drawn[2], x1), _drawn[3] = MAX(_drawn[3], y1);
        }
    }
    if (vg_passlog()) {
        if (!_dbgPipes) {
            _dbgPipes = [NSMutableOrderedSet orderedSet];
        }
        [_dbgPipes addObject:_pso->_name ?: @"(none)"];
        _dbgDraws++;
        if (!_dbgSeq) {
            _dbgSeq = [NSMutableString string];
        }
        NSUInteger pi = [_dbgPipes indexOfObject:_pso->_name ?: @"(none)"];
        uint32_t wm = 0;
        for (uint32_t i = 0; i < _pso->_ncolor && i < 2; i++) {
            wm |= (uint32_t)_pso->_blend[i].colorWriteMask << (4 * i);
        }
        [_dbgSeq appendFormat:@" d%lu/wm%x<%d,%d %ux%u>", (unsigned long)pi, wm, _scissor.offset.x, _scissor.offset.y,
                               _scissor.extent.width, _scissor.extent.height];
        if (!_dbgUniforms) {
            _dbgUniforms = [NSMutableArray array];
        }
        if (_dbgUniforms.count < 16) {
            if (_vt.buf[0]) {
                [_dbgUniforms addObject:@[ _pso->_name ?: @"", @"v", @((uint64_t)_vt.buf[0]), @(_vt.off[0]) ]];
            }
            if (_ft.buf[0]) {
                [_dbgUniforms addObject:@[ _pso->_name ?: @"", @"f", @((uint64_t)_ft.buf[0]), @(_ft.off[0]) ]];
            }
            if (_vt.buf[1] && [_pso->_name hasPrefix:@"path_exterior"]) {
                [_dbgUniforms addObject:@[ _pso->_name ?: @"", @"v1", @((uint64_t)_vt.buf[1]), @(_vt.off[1]) ]];
            }
        }
        for (int k = 0; k < _pso->_nfb; k++) {
            uint32_t b = _pso->_fb[k].binding;
            if (_pso->_fb[k].type == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE && b >= 32 && b < 160) {
                VGMTLTexture *tx = _ft.tex[b - 32];
                [_dbgSeq appendFormat:@"[t%u=%p %lux%lu]", b - 32, tx, tx ? (unsigned long)tx->_width : 0,
                                      tx ? (unsigned long)tx->_height : 0];
            }
        }
        BOOL ok = [self prepareDrawInner:type];
        _dbgRefused += !ok;
        return ok;
    }
    return [self prepareDrawInner:type];
}
- (BOOL)prepareDrawInner:(MTLPrimitiveType)type {
    if (!_open || !_pso) {
        [_owner fail:_open ? @"draw without a render pipeline" : @"draw after endEncoding"];
        return NO;
    }
    if (_pso->_tess != _tessDraw) {   // Metal's rule: a tessellation pipeline draws patches, and only it does
        static int said;
        if (said++ < 8) {
            vglog("render: %s on %s, which %s a post-tessellation vertex function: NOT drawn",
                  _tessDraw ? "a patch draw" : "a primitive draw", _pso->_name.UTF8String, _pso->_tess ? "has" : "has no");
        }
        return NO;
    }
    int cls = type == MTLPrimitiveTypePoint ? 0 : (type == MTLPrimitiveTypeLine || type == MTLPrimitiveTypeLineStrip) ? 1 : 2;
    if (_tessDraw) {
        cls = 2;   // one patch-list pipeline, made in the triangles' slot
    }
    NSString *why = nil;
    // An attachment the fragment stage also has bound as a texture (5d): RenderBox, without framebuffer reads, blends
    // by reading its own color target as texture(4) (and its coverage as texture(5)) right after a render-target
    // barrier. Sampling an attachment of the open pass outside the feedback loop layout is undefined in Vulkan; on the
    // Iris Xe it read the color target's compressed blocks, and the Dock's menus came out in vertical stripes.
    if (gVk.feedbackLoop) {
        uint32_t selfRead = 0;
        for (int k = 0; k < _pso->_nfb; k++) {
            uint32_t b = _pso->_fb[k].binding;
            if ((_pso->_fb[k].type == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE || _pso->_fb[k].type == VK_DESCRIPTOR_TYPE_STORAGE_IMAGE) &&
                b >= 32 && b < 32 + kVGMaxTextureSlots) {
                VGMTLTexture *tx = _ft.tex[b - 32];
                for (uint32_t i = 0; tx && i < _ncolor; i++) {
                    if (_colorTex[i] && _colorInfo[i].imageView && _colorTex[i]->_image == tx->_image &&
                        vg_can_feedback(_colorTex[i], "bound as a texture")) {
                        selfRead |= 1u << i;
                    }
                }
            }
        }
        uint32_t fresh = 0;
        for (uint32_t i = 0; i < _ncolor; i++) {
            if ((selfRead & (1u << i)) && !_feedback[i]) {
                fresh |= 1u << i;
            }
        }
        if (fresh) {
            [self enterFeedback:fresh];
        }
    }
    BOOL anyFeedback = NO;
    _owner->_nfeedback = 0;
    for (uint32_t i = 0; i < _ncolor; i++) {
        if (_feedback[i] && _colorTex[i]) {
            anyFeedback = YES;
            if (_owner->_nfeedback < 8) {
                _owner->_feedbackImages[_owner->_nfeedback++] = _colorTex[i]->_image;
            }
        }
    }
    VkPipeline pipe = [_pso pipelineForClass:cls clamp:_depthClamp feedback:anyFeedback error:&why];
    if (!pipe) {
        [_owner fail:why];
        return NO;
    }
    VkDescriptorSet sets[2], fetchSet = VK_NULL_HANDLE;
    sets[0] = vg_write_set(_owner, _pso->_dsl[0], _pso->_vb, _pso->_nvb, &_vt, _pso->_name);
    sets[1] = sets[0] ? vg_write_set(_owner, _pso->_dsl[1], _pso->_fb, _pso->_nfb, &_ft, _pso->_name) : VK_NULL_HANDLE;
    if (!sets[1]) {
        return NO;
    }
    if (_pso->_fetchMask && !(fetchSet = [self fetchCopy:_pso->_fetchMask])) {
        return NO;
    }
    VkCommandBuffer cb = _owner->_cb;
    int skipped = 0;
#define VG_CHANGED(cond) ((!_last.valid || (cond)) ? 1 : (skipped++, 0))
    if (VG_CHANGED(_last.pipe != pipe)) {
        gVk.vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
        _last.pipe = pipe;
    }
    BOOL layoutChanged = !_last.valid || _last.layout != _pso->_layout;   // other sets may be disturbed: rebind
    if (layoutChanged || _last.sets[0] != sets[0] || _last.sets[1] != sets[1]) {
        gVk.vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, _pso->_layout, 0, 2, sets, 0, NULL);
        _last.sets[0] = sets[0], _last.sets[1] = sets[1];
    } else {
        skipped++;
    }
    if (fetchSet && (layoutChanged || _last.fetch != fetchSet)) {
        gVk.vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, _pso->_layout, 3, 1, &fetchSet, 0, NULL);
        _last.fetch = fetchSet;
    }
    _last.layout = _pso->_layout;
    for (uint32_t i = 0; i < _pso->_nvbind; i++) {
        uint32_t b = _pso->_vbind[i].binding;
        if (!_vt.buf[b]) {
            [_owner fail:[NSString stringWithFormat:@"%@: no vertex buffer at index %u", _pso->_name, b]];
            return NO;
        }
        if (VG_CHANGED(_last.vb[b] != _vt.buf[b] || _last.vboff[b] != _vt.off[b])) {
            gVk.vkCmdBindVertexBuffers(cb, b, 1, &_vt.buf[b], &_vt.off[b]);
            _last.vb[b] = _vt.buf[b], _last.vboff[b] = _vt.off[b];
        }
    }
    static const VkPrimitiveTopology kTopo[] = {
        [MTLPrimitiveTypePoint] = VK_PRIMITIVE_TOPOLOGY_POINT_LIST, [MTLPrimitiveTypeLine] = VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
        [MTLPrimitiveTypeLineStrip] = VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
        [MTLPrimitiveTypeTriangle] = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        [MTLPrimitiveTypeTriangleStrip] = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP};
    int topo = _tessDraw ? (int)VK_PRIMITIVE_TOPOLOGY_PATCH_LIST
                         : (int)kTopo[type <= MTLPrimitiveTypeTriangleStrip ? type : MTLPrimitiveTypeTriangle];
    int restart = !_tessDraw && (type == MTLPrimitiveTypeLineStrip || type == MTLPrimitiveTypeTriangleStrip);
    if (VG_CHANGED(_last.topo != topo)) {
        gVk.vkCmdSetPrimitiveTopology(cb, (VkPrimitiveTopology)topo);
        _last.topo = topo;
    }
    if (VG_CHANGED(_last.restart != restart)) {
        gVk.vkCmdSetPrimitiveRestartEnable(cb, (VkBool32)restart);
        _last.restart = restart;
    }
    if (VG_CHANGED(memcmp(&_last.viewport, &_viewport, sizeof(_viewport)))) {
        gVk.vkCmdSetViewport(cb, 0, 1, &_viewport);
        _last.viewport = _viewport;
    }
    if (VG_CHANGED(memcmp(&_last.scissor, &_scissor, sizeof(_scissor)))) {
        gVk.vkCmdSetScissor(cb, 0, 1, &_scissor);
        _last.scissor = _scissor;
    }
    if (VG_CHANGED(_last.cull != _cull)) {
        gVk.vkCmdSetCullMode(cb, _cull);
        _last.cull = _cull;
    }
    if (VG_CHANGED(_last.front != _front)) {
        gVk.vkCmdSetFrontFace(cb, _front);
        _last.front = _front;
    }
    VkBool32 dtest = _ds ? _ds->_test : VK_FALSE, dwrite = _ds ? _ds->_write : VK_FALSE;
    VkCompareOp dcmp = _ds ? _ds->_compare : VK_COMPARE_OP_ALWAYS;
    if (VG_CHANGED(_last.dtest != dtest)) {
        gVk.vkCmdSetDepthTestEnable(cb, dtest);
        _last.dtest = dtest;
    }
    if (VG_CHANGED(_last.dwrite != dwrite)) {
        gVk.vkCmdSetDepthWriteEnable(cb, dwrite);
        _last.dwrite = dwrite;
    }
    if (VG_CHANGED(_last.dcmp != dcmp)) {
        gVk.vkCmdSetDepthCompareOp(cb, dcmp);
        _last.dcmp = dcmp;
    }
    // stencil (5d): test, ops and masks from the depth-stencil state, the reference from the encoder
    VGMTLDepthStencilState *sds = _ds && _ds->_stencil ? _ds : nil;
    if (VG_CHANGED(!_last.stencilSet || _last.sds != sds)) {
        gVk.vkCmdSetStencilTestEnable(cb, sds ? VK_TRUE : VK_FALSE);
        if (sds) {
            const VkStencilOpState *f = &sds->_sfront, *b = &sds->_sback;
            gVk.vkCmdSetStencilOp(cb, VK_STENCIL_FACE_FRONT_BIT, f->failOp, f->passOp, f->depthFailOp, f->compareOp);
            gVk.vkCmdSetStencilOp(cb, VK_STENCIL_FACE_BACK_BIT, b->failOp, b->passOp, b->depthFailOp, b->compareOp);
            gVk.vkCmdSetStencilCompareMask(cb, VK_STENCIL_FACE_FRONT_BIT, f->compareMask);
            gVk.vkCmdSetStencilCompareMask(cb, VK_STENCIL_FACE_BACK_BIT, b->compareMask);
            gVk.vkCmdSetStencilWriteMask(cb, VK_STENCIL_FACE_FRONT_BIT, f->writeMask);
            gVk.vkCmdSetStencilWriteMask(cb, VK_STENCIL_FACE_BACK_BIT, b->writeMask);
        }
        _last.stencilSet = YES;
        _last.sds = sds;
        _last.sref[0] = _stencilRef[0] + 1;   // the reference goes again below
    }
    if (sds && VG_CHANGED(_last.sref[0] != _stencilRef[0] || _last.sref[1] != _stencilRef[1])) {
        gVk.vkCmdSetStencilReference(cb, VK_STENCIL_FACE_FRONT_BIT, _stencilRef[0]);
        gVk.vkCmdSetStencilReference(cb, VK_STENCIL_FACE_BACK_BIT, _stencilRef[1]);
        _last.sref[0] = _stencilRef[0], _last.sref[1] = _stencilRef[1];
    }
    if (VG_CHANGED(memcmp(_last.blend, _blend, sizeof(_blend)))) {
        gVk.vkCmdSetBlendConstants(cb, _blend);
        memcpy(_last.blend, _blend, sizeof(_blend));
    }
#undef VG_CHANGED
    _last.valid = YES;
    if (skipped) {
        vg_perf(VG_PERF_STATE_SKIPPED, (uint64_t)skipped, 0);
    }
    return YES;
}

// Framebuffer fetch by copies: end the pass, copy each read color attachment to its scratch image, resume the pass
// (load), and return set 3 naming the copies. The command buffer's full barrier orders draw -> copy -> sample.
// How a fetch split is done, for measurements (5c round 5; /Library/GPUBundles/VirtioGPUMetal-fetchmode holds the
// digit): 0 copies with full barriers (the default until round 6), 1 no copy and 2 no split at all (both draw wrong pixels: they only show what
// the copies and the splits cost), 3 targeted barriers, 4 in place (the default; 5c round 6: the pass still ends and resumes, but
// the draw samples the attachment itself, in VK_EXT_attachment_feedback_loop_layout's layout, instead of a copy). Measured in WindowServer under mtlwindow: GPU time per
// command buffer 2.55 / 1.85 / 1.77 / 2.52 ms, frame rate the same in all four (the copies are ~27 % of the GPU time,
// the splits and barriers almost nothing, and GPU time doesn't limit the frame rate).
// Default 4 in WindowServer since 5c round 6, 0 elsewhere since round 11 (falls back to copies when Venus lacks the extension): visually the same as copies in
// pixel comparisons, deterministic, WindowServer's command buffers done ~8 ms sooner (12 vs 20 ms commit -> done
// during a drag), ~70 MB less memory (no scratch copies); a 10-minute soak without a crash. A file holding 0 goes
// back to copies.
int vg_fetch_mode(void) {
    static int mode = -1;
    if (mode < 0) {
        // In place only in WindowServer (round 11): reading the attachment in place is right when each pixel is drawn
        // once per draw; Vulkan on the Iris Xe has no raster-order guarantee (Metal on Apple's GPUs does), and Core
        // Animation in Safari's GPU process, drawing software-decoded video, came out with wrong colors and stale
        // blocks after a while. Copies there drew it right at the same frame rate. WindowServer's composition was
        // compared pixel for pixel (5c round 6) and gains ~8 ms per frame from it.
        mode = !strcmp(getprogname(), "WindowServer") ? 4 : 0;
        // The file: a digit for every process, and/or lines "NAME DIGIT" for processes whose name starts with NAME
        // (the last match wins), e.g. "com.apple.WebKit.GPU 0".
        FILE *f = fopen("/Library/GPUBundles/VirtioGPUMetal-fetchmode", "r");
        const char *me = getprogname();
        char line[128];
        while (f && fgets(line, sizeof(line), f)) {
            line[strcspn(line, "\r\n")] = 0;
            char *sp = strrchr(line, ' ');
            if (!sp && line[0] >= '0' && line[0] <= '4' && !line[1]) {
                mode = line[0] - '0';
            } else if (sp && sp[1] >= '0' && sp[1] <= '4' && !sp[2]) {
                *sp = 0;
                if (line[0] && !strncmp(me, line, strlen(line))) {
                    mode = sp[1] - '0';
                }
            }
        }
        if (f) {
            fclose(f);
        }
        vglog("framebuffer fetch: mode %d", mode);
    }
    return mode;
}

static void vg_fetch_barrier(VkCommandBuffer cb, BOOL beforeCopy) {
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER};
    VkPipelineStageFlags src, dst;
    if (beforeCopy) {   // what the pass drew -> the copy reads it
        mb.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        mb.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT;
        src = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT |
              VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;   // the previous fetch draw sampled the scratch (WAR)
        dst = VK_PIPELINE_STAGE_TRANSFER_BIT;
    } else {   // the copy -> the fetch draw samples it; the pass then writes the attachment again (WAR)
        mb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        mb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                           VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        src = VK_PIPELINE_STAGE_TRANSFER_BIT;
        dst = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
              VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
    }
    gVk.vkCmdPipelineBarrier(cb, src, dst, 0, 1, &mb, 0, NULL, 0, NULL);
}

// Whether an attachment can be in the feedback loop layout: its image was made for it (VK_IMAGE_USAGE_ATTACHMENT_
// FEEDBACK_LOOP_BIT_EXT). One that wasn't keeps the Iris Xe's compression, and reads of it in that layout return
// compressed blocks (Safari's software-decoded video came out with wrong colors and blocky smears): it gets copies.
static BOOL vg_can_feedback(VGMTLTexture *t, const char *why) {
    if (t && (t->_imageUsage & VK_IMAGE_USAGE_ATTACHMENT_FEEDBACK_LOOP_BIT_EXT)) {
        return YES;
    }
    static int logged;
    if (t && logged++ < 5) {
        vglog("render: %s: an attachment (format %lu, %lux%lu, usage 0x%x) wasn't made for the feedback loop: copies",
              why, (unsigned long)t->_pixelFormat, (unsigned long)t->_width, (unsigned long)t->_height, t->_imageUsage);
    }
    return NO;
}

// End the pass, move the attachments in `mask` into the feedback loop layout (their writes so far -> the fragment
// shader's reads) and resume the pass in that layout (5d: an attachment the app binds as a texture).
- (void)enterFeedback:(uint32_t)mask {
    VkCommandBuffer cb = _owner->_cb;
    gVk.vkCmdEndRendering(cb);
    VkImageMemoryBarrier ib[kVGMaxColor];
    uint32_t nb = 0;
    for (uint32_t i = 0; i < _ncolor; i++) {
        VGMTLTexture *t = _colorTex[i];
        if (!(mask & (1u << i)) || !t || !_colorInfo[i].imageView || _feedback[i]) {
            continue;
        }
        ib[nb++] = (VkImageMemoryBarrier){VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
                                          VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                                          VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                                              VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                                          VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT,
                                          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, t->_image,
                                          {VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0,
                                           VK_REMAINING_ARRAY_LAYERS}};
        _feedback[i] = YES;
        _colorInfo[i].imageLayout = VK_IMAGE_LAYOUT_ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT;
    }
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL,
                          VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                          VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                              VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                              VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT};
    gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                             VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                                 VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                             VK_DEPENDENCY_BY_REGION_BIT, 1, &mb, 0, NULL, nb, ib);
    VkRenderingAttachmentInfo color[kVGMaxColor];
    for (uint32_t i = 0; i < _ncolor; i++) {
        color[i] = _colorInfo[i];
        if (color[i].imageView) {
            color[i].loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        }
    }
    VkRenderingAttachmentInfo depth = _depthInfo, stencil = _stencilInfo;
    depth.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    stencil.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, _area, 1, 0, _ncolor, color, _depthTex ? &depth : NULL,
                          _stencilTex ? &stencil : NULL};
    gVk.vkCmdBeginRendering(cb, &ri);
    _last.sds = nil;   // ARC's release first: the memset below would leave it retained (the stencil state leaked)
    memset((void *)&_last, 0, sizeof(_last));   // a new rendering scope: dynamic state is sent again
    static int logged;
    if (logged++ < 3) {
        vglog("render: an attachment bound as a texture: feedback loop layout (mask 0x%x, %ux%u)", mask,
              _area.extent.width, _area.extent.height);
    }
}

static VGMTLTexture *vg_fetch_image(id<MTLDevice> dev, MTLPixelFormat format, uint32_t width, uint32_t height, BOOL zero) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                               width:width
                                                                              height:height
                                                                           mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    return zero ? vg_new_zero_color_texture(dev, d) : (VGMTLTexture *)vg_new_texture(dev, d);
}

static VGMTLTexture *vg_fetch_blank(id<MTLDevice> dev, uint32_t width, uint32_t height) {
    if (strcmp(getprogname(), "WindowServer")) {
        return vg_fetch_image(dev, MTLPixelFormatBGRA8Unorm, width, height, NO);
    }
    // Fragment coordinates address this image directly. Missing attachments can share one cleared image large enough
    // for the pass. At Retina, allocating a blank per encoder made i915 allocate and zero pages during submission.
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static VGMTLTexture *blank;
    pthread_mutex_lock(&lock);
    VGMTLTexture *result = blank;
    if (!result || result->_width < width || result->_height < height) {
        result = vg_fetch_image(dev, MTLPixelFormatBGRA8Unorm, width, height, YES);
        if (result) {
            blank = result;
        }
    }
    pthread_mutex_unlock(&lock);
    return result;
}

// Mode 4: end the pass, move each read attachment into the feedback loop layout (its writes so far -> the fragment
// shader's reads), resume the pass in that layout and point set 3 at the attachments themselves. A fragment reads its
// own pixel before this draw writes it, as with a copy; later draws are ordered by the next split's barrier.
- (VkDescriptorSet)fetchInPlace:(uint32_t)mask {
    VkCommandBuffer cb = _owner->_cb;
    gVk.vkCmdEndRendering(cb);
    VkImageMemoryBarrier ib[kVGMaxColor];
    uint32_t nb = 0;
    for (uint32_t i = 0; i < _ncolor; i++) {
        VGMTLTexture *t = _colorTex[i];
        if (!(mask & (1u << i)) || !t || !_colorInfo[i].imageView) {
            continue;
        }
        ib[nb++] = (VkImageMemoryBarrier){VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
                                          VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                                          VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                                              VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                                          _feedback[i] ? VK_IMAGE_LAYOUT_ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT
                                                       : VK_IMAGE_LAYOUT_GENERAL,
                                          VK_IMAGE_LAYOUT_ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT,
                                          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, t->_image,
                                          {VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0,
                                           VK_REMAINING_ARRAY_LAYERS}};
        _feedback[i] = YES;
        _colorInfo[i].imageLayout = VK_IMAGE_LAYOUT_ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT;
    }
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL,
                          VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                          VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                              VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                              VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT};
    gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                             VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                                 VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                             VK_DEPENDENCY_BY_REGION_BIT, 1, &mb, 0, NULL, nb, ib);
    VkRenderingAttachmentInfo color[kVGMaxColor];
    for (uint32_t i = 0; i < _ncolor; i++) {
        color[i] = _colorInfo[i];
        if (color[i].imageView) {
            color[i].loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        }
    }
    VkRenderingAttachmentInfo depth = _depthInfo, stencil = _stencilInfo;
    depth.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    stencil.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, _area, 1, 0, _ncolor, color, _depthTex ? &depth : NULL,
                          _stencilTex ? &stencil : NULL};
    gVk.vkCmdBeginRendering(cb, &ri);
    VkDescriptorImageInfo ii[8];
    VkWriteDescriptorSet wr[8];
    uint32_t nw = 0;
    for (uint32_t i = 0; i < 8; i++) {
        if (!(mask & (1u << i))) {
            continue;
        }
        VkImageView view = VK_NULL_HANDLE;
        VkImageLayout layout = VK_IMAGE_LAYOUT_GENERAL;
        if (i < _ncolor && _feedback[i]) {
            view = _colorInfo[i].imageView;
            layout = VK_IMAGE_LAYOUT_ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT;
        } else {   // no attachment for this [[color(n)]]: a zeroed scratch image, as with copies
            if (!_fetchCopy[i]) {
                _fetchCopy[i] = vg_fetch_blank(_owner.device, _area.extent.width, _area.extent.height);
                if (!_fetchCopy[i]) {
                    [_owner fail:@"framebuffer fetch: no scratch image"];
                    return VK_NULL_HANDLE;
                }
                [_owner->_keep addObject:_fetchCopy[i]];
            }
            view = _fetchCopy[i]->_view;
        }
        ii[nw] = (VkDescriptorImageInfo){VK_NULL_HANDLE, view, layout};
        wr[nw] = (VkWriteDescriptorSet){VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, VK_NULL_HANDLE, 192 + i, 0, 1,
                                        VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, &ii[nw], NULL, NULL};
        nw++;
    }
    VkDescriptorSet set = [_owner allocSet:gFetchLayout];
    if (!set) {
        [_owner fail:@"framebuffer fetch: no descriptor set"];
        return VK_NULL_HANDLE;
    }
    for (uint32_t k = 0; k < nw; k++) {
        wr[k].dstSet = set;
    }
    gVk.vkUpdateDescriptorSets(gVk.device, nw, wr, 0, NULL);
    static int logged = 0;
    if (logged++ < 3) {
        vglog("render: framebuffer fetch in place (mask 0x%x, %ux%u)", mask, _area.extent.width, _area.extent.height);
    }
    vg_perf(VG_PERF_FETCH, 0, 0);
    return set;
}

- (VkDescriptorSet)fetchCopy:(uint32_t)mask {
    VkCommandBuffer cb = _owner->_cb;
    const int mode = vg_fetch_mode();
    BOOL inPlace = mode == 4 && gVk.feedbackLoop;
    for (uint32_t i = 0; inPlace && i < _ncolor; i++) {
        if ((mask & (1u << i)) && _colorTex[i] && _colorInfo[i].imageView && !_feedback[i]) {
            inPlace = vg_can_feedback(_colorTex[i], "framebuffer fetch");
        }
    }
    if (inPlace) {
        return [self fetchInPlace:mask];
    }
    if (mode != 2) {
        gVk.vkCmdEndRendering(cb);
        if (mode == 3) {
            vg_fetch_barrier(cb, YES);
        } else {
            [_owner barrier];
        }
    }
    VkDescriptorImageInfo ii[8];
    VkWriteDescriptorSet wr[8];
    uint32_t nw = 0;
    for (uint32_t i = 0; i < 8; i++) {
        if (!(mask & (1u << i))) {
            continue;
        }
        VGMTLTexture *src = i < kVGMaxColor ? _colorTex[i] : nil;
        VGMTLTexture *dst = _fetchCopy[i];
        if (!dst) {
            dst = src ? vg_fetch_image(_owner.device, src->_pixelFormat, _area.extent.width, _area.extent.height, NO) :
                        vg_fetch_blank(_owner.device, _area.extent.width, _area.extent.height);
            if (!dst) {
                [_owner fail:@"framebuffer fetch: no scratch image"];
                return VK_NULL_HANDLE;
            }
            _fetchCopy[i] = dst;
            [_owner->_keep addObject:dst];
        }
        if (src) {
            // Only the scissor's pixels (5c): a fetch reads the fragment's own position, and fragments stay inside the
            // scissor, so the rest of the scratch image is never read by this draw. Core Animation scissors its fetch
            // draws to the layer; a full-screen copy per draw was most of a WindowServer frame.
            int32_t x0 = MAX(_scissor.offset.x, 0), y0 = MAX(_scissor.offset.y, 0);
            int32_t x1 = MIN(_scissor.offset.x + (int32_t)_scissor.extent.width,
                             MIN((int32_t)src->_width, (int32_t)_area.extent.width));
            int32_t y1 = MIN(_scissor.offset.y + (int32_t)_scissor.extent.height,
                             MIN((int32_t)src->_height, (int32_t)_area.extent.height));
            if (x1 > x0 && y1 > y0 && mode != 1 && mode != 2) {
                VkImageCopy r = {{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {x0, y0, 0}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                 {x0, y0, 0}, {(uint32_t)(x1 - x0), (uint32_t)(y1 - y0), 1}};
                gVk.vkCmdCopyImage(cb, src->_image, VK_IMAGE_LAYOUT_GENERAL, dst->_image, VK_IMAGE_LAYOUT_GENERAL, 1, &r);
                vg_perf(VG_PERF_FETCH, (uint64_t)(x1 - x0) * (y1 - y0) * 4, 0);
            }
        }
        ii[nw] = (VkDescriptorImageInfo){VK_NULL_HANDLE, dst->_view, VK_IMAGE_LAYOUT_GENERAL};
        wr[nw] = (VkWriteDescriptorSet){VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, VK_NULL_HANDLE, 192 + i, 0, 1,
                                        VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, &ii[nw], NULL, NULL};
        nw++;
    }
    if (mode == 3) {
        vg_fetch_barrier(cb, NO);
    } else if (mode != 2) {
        [_owner barrier];
    }
    // resume: everything loads what the pass has drawn so far
    VkRenderingAttachmentInfo color[kVGMaxColor];
    for (uint32_t i = 0; i < _ncolor; i++) {
        color[i] = _colorInfo[i];
        if (color[i].imageView) {
            color[i].loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        }
    }
    VkRenderingAttachmentInfo depth = _depthInfo, stencil = _stencilInfo;
    depth.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    stencil.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, _area, 1, 0, _ncolor, color, _depthTex ? &depth : NULL,
                          _stencilTex ? &stencil : NULL};
    if (mode != 2) {
        gVk.vkCmdBeginRendering(cb, &ri);
    }
    VkDescriptorSet set = [_owner allocSet:gFetchLayout];
    if (!set) {
        [_owner fail:@"framebuffer fetch: no descriptor set"];
        return VK_NULL_HANDLE;
    }
    for (uint32_t k = 0; k < nw; k++) {
        wr[k].dstSet = set;
    }
    gVk.vkUpdateDescriptorSets(gVk.device, nw, wr, 0, NULL);
    static int logged = 0;
    if (logged++ < 3) {
        vglog("render: framebuffer fetch by copies (mask 0x%x, %ux%u)", mask, _area.extent.width, _area.extent.height);
    }
    return set;
}

- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
         instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    if (vg_passlog()) {
        [_dbgSeq appendFormat:@"{t%lu s%lu n%lu i%lu b%lu}", (unsigned long)type, (unsigned long)start, (unsigned long)count,
                              (unsigned long)instances, (unsigned long)base];
    }
    if (count && instances && [self prepareDraw:type]) {
        if (_ddTex && !_ddBufs.count) {
            [self ddSnap:@"(before)"];
            [self prepareDraw:type];   // the resumed rendering needs its state again
        }
        gVk.vkCmdDraw(_owner->_cb, (uint32_t)count, (uint32_t)instances, (uint32_t)start, (uint32_t)base);
        if (_ddTex) {
            [self ddDraw:[NSString stringWithFormat:@"draw t%lu s%lu n%lu i%lu", (unsigned long)type,
                                                    (unsigned long)start, (unsigned long)count, (unsigned long)instances]];
        }
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
    if (vg_passlog()) {
        [_dbgSeq appendFormat:@"{t%lu idx n%lu i%lu bv%ld b%lu}", (unsigned long)type, (unsigned long)count,
                              (unsigned long)instances, (long)baseVertex, (unsigned long)base];
    }
    VkBuffer b = vg_vkbuffer(ib);
    if (!b) {
        [_owner fail:@"drawIndexedPrimitives: not our index buffer"];
        return;
    }
    if (vg_passlog() && _pso && [_pso->_name hasPrefix:@"path_exterior"]) {
        if (!_dbgUniforms) {
            _dbgUniforms = [NSMutableArray array];
        }
        [_dbgUniforms addObject:@[ _pso->_name, itype == MTLIndexTypeUInt16 ? @"ib16" : @"ib32", @((uint64_t)b), @(off) ]];
    }
    if (count && instances && [self prepareDraw:type]) {
        [_owner->_keep addObject:ib];
        gVk.vkCmdBindIndexBuffer(_owner->_cb, b, off,
                                 itype == MTLIndexTypeUInt16 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32);
        if (_ddTex && !_ddBufs.count) {
            [self ddSnap:@"(before)"];
            [self prepareDraw:type];
            gVk.vkCmdBindIndexBuffer(_owner->_cb, b, off,
                                     itype == MTLIndexTypeUInt16 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32);
        }
        gVk.vkCmdDrawIndexed(_owner->_cb, (uint32_t)count, (uint32_t)instances, 0, (int32_t)baseVertex, (uint32_t)base);
        if (_ddTex) {
            [self ddDraw:[NSString stringWithFormat:@"idx n%lu i%lu bv%ld", (unsigned long)count,
                                                    (unsigned long)instances, (long)baseVertex]];
        }
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

// ---- tessellation (5d) ---------------------------------------------------------------------------------------------
// After NullMoth's NVMTLObjects.m (setTessellationFactorBuffer..., nvmtlTessAddress, nvmtlPatches, drawPatches...,
// drawIndexedPatches...; PolyForm Noncommercial 1.0.0, Copyright (c) 2026 NullMoth Systems): the checks and the draw are
// theirs, the device addresses come from vg_buffer_address.

- (void)setTessellationFactorBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset instanceStride:(NSUInteger)instanceStride {
    if (buffer && ![(NSObject *)buffer isKindOfClass:[VGMTLBuffer class]]) {
        vglog("setTessellationFactorBuffer: not our buffer (%s): ignored", object_getClassName(buffer));
        buffer = nil;
    }
    if (buffer) {
        [_owner->_keep addObject:buffer];
    }
    _tfb = buffer;
    _tfbOff = offset;
    _tfbStride = instanceStride;
}
- (void)setTessellationFactorScale:(float)scale {
    _tfScale = scale;
    _tfScaleSet = YES;
}
// The device address of buf + off (0 and YES for no buffer). NO, logged, when it isn't ours, the offset is outside it,
// it has no address, or the address isn't aligned.
- (BOOL)vgTessAddress:(id<MTLBuffer>)buf offset:(NSUInteger)off align:(uint64_t)al what:(const char *)what out:(uint64_t *)out {
    *out = 0;
    if (!buf) {
        return YES;
    }
    if (![(NSObject *)buf isKindOfClass:[VGMTLBuffer class]]) {
        vglog("tessellation draw: the %s is not our buffer (%s): NOT drawn", what, object_getClassName(buf));
        return NO;
    }
    VGMTLBuffer *vb = (VGMTLBuffer *)buf;
    if (off >= vb->_length) {
        vglog("tessellation draw: %s offset %lu is outside its %lu bytes: NOT drawn", what, (unsigned long)off,
              (unsigned long)vb->_length);
        return NO;
    }
    vg_vkbuffer(buf);   // a no-copy buffer's CPU contents, now
    [_owner->_keep addObject:buf];
    uint64_t a = vg_buffer_address(&vb->_b);
    if (!a) {
        vglog("tessellation draw: the %s has no device address: NOT drawn", what);
        return NO;
    }
    a += off;
    if (a & (al - 1)) {
        vglog("tessellation draw: the %s at offset %lu is not %llu-byte aligned: NOT drawn", what, (unsigned long)off,
              (unsigned long long)al);
        return NO;
    }
    *out = a;
    return YES;
}
// The device address of what vertex slot i has bound (a buffer, or setVertexBytes' arena), 0 if nothing or no address.
- (uint64_t)vgVertexAddress:(NSUInteger)i {
    VkBuffer b = _vt.buf[i];
    if (!b) {
        return 0;
    }
    uint64_t a = 0;
    if (_vobj[i] && _vobj[i]->_b.buffer == b) {
        a = vg_buffer_address(&_vobj[i]->_b);
    } else {
        for (int k = 0; k < _owner->_narena && !a; k++) {
            if (_owner->_arena[k].buffer == b) {
                a = vg_buffer_address(&_owner->_arena[k]);
            }
        }
    }
    return a ? a + _vt.off[i] : 0;
}
- (void)vgPatches:(NSUInteger)n start:(NSUInteger)start count:(NSUInteger)count pib:(id<MTLBuffer>)pib pibOff:(NSUInteger)pibOff
             cpib:(id<MTLBuffer>)cpib cpibOff:(NSUInteger)cpibOff indexed:(BOOL)indexed instances:(NSUInteger)instances
             base:(NSUInteger)base indirect:(id<MTLBuffer>)ind indOff:(NSUInteger)indOff {
    if (vg_passlog()) {
        [_dbgSeq appendFormat:@"{patches%s n%lu s%lu c%lu i%lu%s}", indexed ? " idx" : "", (unsigned long)n, (unsigned long)start,
                              (unsigned long)count, (unsigned long)instances, ind ? " indirect" : ""];
    }
    if (!_open || !_pso) {
        [_owner fail:_open ? @"patch draw without a render pipeline" : @"patch draw after endEncoding"];
        return;
    }
    static int said;
    const BOOL tell = said < 16;
    if (!_pso->_tess) {
        if (tell) {
            said++;
            vglog("tessellation draw: %s has no post-tessellation vertex function: NOT drawn", _pso->_name.UTF8String);
        }
        return;
    }
    if (!ind && (!count || !instances)) {
        return;
    }
    const char *refuse = NULL;
    if (n != _pso->_tessN) {
        refuse = "the draw's control points per patch differ from the function's";
    } else if (!_tfb) {
        refuse = "no tessellation factor buffer is set";
    } else if (indexed != (_pso->_tessCpidx != 0)) {
        refuse = indexed ? "an indexed draw on a pipeline with no control-point index type"
                         : "a non-indexed draw on a pipeline with a control-point index type";
    } else if (indexed && !cpib) {
        refuse = "drawIndexedPatches with no control-point index buffer";
    } else if (_tfbStride & 3) {
        refuse = "the factor buffer's instance stride is not a multiple of 4";
    } else if (ind && (indOff & 3)) {
        refuse = "the indirect buffer offset is not a multiple of 4";
    }
    if (refuse) {
        if (tell) {
            said++;
            vglog("tessellation draw: %s (%s, %lu control points, the function takes %u): NOT drawn", refuse,
                  _pso->_name.UTF8String, (unsigned long)n, _pso->_tessN);
        }
        return;
    }
    vg_tess_push pc;
    memset(&pc, 0, sizeof(pc));
    if (![self vgTessAddress:_tfb offset:_tfbOff align:4 what:"tessellation factor buffer" out:&pc.fac] ||
        ![self vgTessAddress:pib offset:pibOff align:4 what:"patch index buffer" out:&pc.pix] ||
        ![self vgTessAddress:cpib offset:cpibOff align:(_pso->_tessCpidx == 1 ? 2 : 4) what:"control-point index buffer"
                         out:&pc.cpx]) {
        return;
    }
    for (uint32_t k = 0; k < _pso->_tessNvb && k < VG_TESS_NVB; k++) {
        uint32_t i = _pso->_tessVb[k];
        pc.vb[k] = i < kVGMaxBufferSlots ? [self vgVertexAddress:i] : 0;
        if (!pc.vb[k] || (pc.vb[k] & 3)) {
            if (tell) {
                said++;
                vglog("tessellation draw: vertex buffer %u, which %s pulls from, is %s: NOT drawn", i, _pso->_name.UTF8String,
                      !pc.vb[k] ? (_vt.buf[i] ? "a buffer without a device address" : "not bound")
                                : "bound at an offset that is not 4-byte aligned");
            }
            return;
        }
    }
    pc.istride = (uint32_t)_tfbStride;
    pc.scale = _tfScaleSet ? _tfScale : 1.0f;
    VkBuffer indBuf = ind ? vg_vkbuffer(ind) : VK_NULL_HANDLE;
    if (ind && !indBuf) {
        vglog("tessellation draw: the indirect buffer is not our buffer: NOT drawn");
        return;
    }
    _tessDraw = YES;
    BOOL ok = [self prepareDraw:MTLPrimitiveTypeTriangle];
    _tessDraw = NO;
    if (!ok) {
        return;
    }
    VkCommandBuffer cb = _owner->_cb;
    gVk.vkCmdPushConstants(cb, _pso->_layout, VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, 0, sizeof(pc), &pc);
    if (ind) {
        // MTLDrawPatchIndirectArguments (patchCount, instanceCount, patchStart, baseInstance) is VkDrawIndirectCommand
        [_owner->_keep addObject:ind];
        gVk.vkCmdDrawIndirect(cb, indBuf, indOff, 1, 0);
    } else {
        gVk.vkCmdDraw(cb, (uint32_t)count, (uint32_t)instances, (uint32_t)start, (uint32_t)base);
    }
    static int told;
    if (!told++) {
        vglog("tessellation: first patch draw in this process (%s, %s)", _pso->_name.UTF8String, ind ? "indirect" : "direct");
    }
}
- (void)drawPatches:(NSUInteger)n patchStart:(NSUInteger)start patchCount:(NSUInteger)count patchIndexBuffer:(id<MTLBuffer>)pib
    patchIndexBufferOffset:(NSUInteger)pibOff instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    [self vgPatches:n start:start count:count pib:pib pibOff:pibOff cpib:nil cpibOff:0 indexed:NO instances:instances base:base
           indirect:nil indOff:0];
}
- (void)drawPatches:(NSUInteger)n patchIndexBuffer:(id<MTLBuffer>)pib patchIndexBufferOffset:(NSUInteger)pibOff
      indirectBuffer:(id<MTLBuffer>)ind indirectBufferOffset:(NSUInteger)indOff {
    if (!ind) {
        vglog("drawPatches:indirectBuffer: nil");
        return;
    }
    [self vgPatches:n start:0 count:0 pib:pib pibOff:pibOff cpib:nil cpibOff:0 indexed:NO instances:0 base:0 indirect:ind
             indOff:indOff];
}
- (void)drawIndexedPatches:(NSUInteger)n patchStart:(NSUInteger)start patchCount:(NSUInteger)count
          patchIndexBuffer:(id<MTLBuffer>)pib patchIndexBufferOffset:(NSUInteger)pibOff
   controlPointIndexBuffer:(id<MTLBuffer>)cpib controlPointIndexBufferOffset:(NSUInteger)cpibOff
             instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    [self vgPatches:n start:start count:count pib:pib pibOff:pibOff cpib:cpib cpibOff:cpibOff indexed:YES instances:instances
               base:base indirect:nil indOff:0];
}
- (void)drawIndexedPatches:(NSUInteger)n patchIndexBuffer:(id<MTLBuffer>)pib patchIndexBufferOffset:(NSUInteger)pibOff
    controlPointIndexBuffer:(id<MTLBuffer>)cpib controlPointIndexBufferOffset:(NSUInteger)cpibOff
             indirectBuffer:(id<MTLBuffer>)ind indirectBufferOffset:(NSUInteger)indOff {
    if (!ind) {
        vglog("drawIndexedPatches:indirectBuffer: nil");
        return;
    }
    [self vgPatches:n start:0 count:0 pib:pib pibOff:pibOff cpib:cpib cpibOff:cpibOff indexed:YES instances:0 base:0
           indirect:ind indOff:indOff];
}

static float vg_half(uint16_t h) {
    uint32_t e = (h >> 10) & 31, m = h & 1023;
    float v = e == 0 ? ldexpf((float)m, -24) : e == 31 ? INFINITY : ldexpf((float)(m | 1024), (int)e - 25);
    return (h & 0x8000) ? -v : v;
}
// Debugging (VirtioGPUMetal-passlog): each color attachment's pixels after the pass, summarized at completion.
- (void)dbgUniformsBack {
    static int n;
    for (NSArray *u in _dbgUniforms) {
        if (n >= 300) {
            break;
        }
        vg_buffer *b = calloc(1, sizeof(*b));
        VkDeviceSize sz = [u[1] isEqual:@"v1"] ? 2048 : 256;
        if (vg_buffer_create(sz, b)) {
            free(b);
            continue;
        }
        int k = ++n;
        VkBufferCopy c = {[u[3] unsignedLongLongValue], 0, sz};
        [_owner barrier];
        gVk.vkCmdCopyBuffer(_owner->_cb, (VkBuffer)[u[2] unsignedLongLongValue], b->buffer, 1, &c);
        [_owner barrier];
        NSString *name = u[0], *stage = u[1];
        [_owner addCompletedHandler:^(id<MTLCommandBuffer> cb) {
          const float *f = b->map;
          NSMutableString *line = [NSMutableString string];
          if ([stage hasPrefix:@"ib"]) {
              for (int i = 0; i < 64; i++) {
                  [line appendFormat:@" %u", [stage isEqual:@"ib16"] ? ((const uint16_t *)f)[i] : ((const uint32_t *)f)[i]];
              }
          } else if ([stage isEqual:@"v1"]) {   // CubicSegment: int count, float recip_n, float2 p1, p2, p3
              for (int i = 0; i < 8; i++) {
                  const float *g = f + i * 8;
                  [line appendFormat:@" [%d %g (%g,%g) (%g,%g) (%g,%g)]", ((const int *)g)[0], g[1], g[2], g[3], g[4], g[5],
                                     g[6], g[7]];
              }
          } else {
              for (int i = 0; i < 48; i++) {
                  [line appendFormat:@" %g", f[i]];
              }
          }
          vglog("uniform %d %s %s:%s", k, name.UTF8String, stage.UTF8String, line.UTF8String);
          NSString *vg_disk_dir(void);
          if ([name hasPrefix:@"path_exterior"] && vg_disk_dir()) {   // the raw inputs, for a test harness
              [[NSData dataWithBytes:b->map length:sz] writeToFile:[vg_disk_dir() stringByAppendingFormat:@"/pe-%d-%@.bin", k, stage]
                                                       atomically:NO];
          }
          vg_buffer_destroy(b);
          free(b);
        }];
    }
    _dbgUniforms = nil;
}
static int gDbgReads;
static int vg_dbg_next_read(void) { return gDbgReads + 1; }
// Debugging (with the pass log on): the stored color attachments of a pass whose pipelines' names contain a line of
// /Library/GPUBundles/VirtioGPUMetal-passdump, written raw (any format) into the process's cache folder as
// dump-N-PIPELINE-pfF-WxH.raw, up to 80 files.
- (void)dbgPassDump {
    static int saved;
    if (saved >= 80) {
        return;
    }
    NSString *want = [NSString stringWithContentsOfFile:@"/Library/GPUBundles/VirtioGPUMetal-passdump" encoding:NSUTF8StringEncoding
                                                  error:NULL];
    NSString *hit = nil;
    for (NSString *w in [want componentsSeparatedByString:@"\n"]) {
        NSString *t = [w stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        for (NSString *name in _dbgPipes) {
            if (t.length && [name containsString:t]) {
                hit = name;
            }
        }
    }
    NSString *vg_disk_dir(void);
    NSString *dir = vg_disk_dir();
    if (!hit || !dir) {
        return;
    }
    NSUInteger vg_bytes_per_pixel(MTLPixelFormat f);
    for (uint32_t i = 0; i < _ncolor && saved < 80; i++) {
        VGMTLTexture *t = _colorTex[i];
        if (!t || _colorInfo[i].storeOp != VK_ATTACHMENT_STORE_OP_STORE) {
            continue;
        }
        NSUInteger pf = t->_pixelFormat, bpp = vg_bytes_per_pixel(pf);
        if (!bpp) {
            continue;
        }
        vg_buffer *b = calloc(1, sizeof(*b));
        if (vg_buffer_create(t->_width * t->_height * bpp, b)) {
            free(b);
            continue;
        }
        int k = ++saved;
        [_owner barrier];
        VkBufferImageCopy c = {0, 0, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {(uint32_t)t->_width, (uint32_t)t->_height, 1}};
        gVk.vkCmdCopyImageToBuffer(_owner->_cb, t->_image, VK_IMAGE_LAYOUT_GENERAL, b->buffer, 1, &c);
        [_owner barrier];
        size_t w = t->_width, h = t->_height, n = w * h * bpp;
        NSString *path = [dir stringByAppendingFormat:@"/dump-%d-%@-c%u-%p-pf%lu-%zux%zu.raw", k,
                                                      [hit stringByReplacingOccurrencesOfString:@"+" withString:@"~"], i, t,
                                                      (unsigned long)pf, w, h];
        [_owner addCompletedHandler:^(id<MTLCommandBuffer> cb) {
          [[NSData dataWithBytes:b->map length:n] writeToFile:path atomically:NO];
          vg_buffer_destroy(b);
          free(b);
        }];
    }
}
- (void)dbgReadBack {
    for (uint32_t i = 0; i < _ncolor && gDbgReads < 400; i++) {
        VGMTLTexture *t = _colorTex[i];
        if (!t || _colorInfo[i].storeOp != VK_ATTACHMENT_STORE_OP_STORE) {
            continue;
        }
        NSUInteger pf = t->_pixelFormat;
        size_t bpp = pf == MTLPixelFormatRGBA16Float ? 8 : (pf == MTLPixelFormatRG16Float || pf == 70 || pf == 71 || pf == 80 || pf == 81 || pf == 90) ? 4 : 0;
        if (!bpp) {
            continue;
        }
        vg_buffer *b = calloc(1, sizeof(*b));
        if (vg_buffer_create(t->_width * t->_height * bpp, b)) {
            free(b);
            continue;
        }
        int k = ++gDbgReads;
        [_owner barrier];
        VkBufferImageCopy c = {0, 0, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {(uint32_t)t->_width, (uint32_t)t->_height, 1}};
        gVk.vkCmdCopyImageToBuffer(_owner->_cb, t->_image, VK_IMAGE_LAYOUT_GENERAL, b->buffer, 1, &c);
        [_owner barrier];
        size_t w = t->_width, h = t->_height;
        [_owner addCompletedHandler:^(id<MTLCommandBuffer> cb) {
          double sum[4] = {0};
          size_t nz = 0;
          for (size_t p = 0; p < w * h; p++) {
              float v[4] = {0};
              if (pf == MTLPixelFormatRGBA16Float) {
                  const uint16_t *q = (const uint16_t *)b->map + p * 4;
                  for (int j = 0; j < 4; j++) v[j] = vg_half(q[j]);
              } else if (pf == MTLPixelFormatRG16Float) {
                  const uint16_t *q = (const uint16_t *)b->map + p * 2;
                  v[0] = vg_half(q[0]), v[1] = vg_half(q[1]), v[3] = 1;
              } else {
                  const uint8_t *q = (const uint8_t *)b->map + p * 4;
                  for (int j = 0; j < 4; j++) v[j] = q[j] / 255.f;
              }
              nz += v[3] != 0 && (v[0] != 0 || v[1] != 0 || v[2] != 0 || pf != MTLPixelFormatRG16Float);
              for (int j = 0; j < 4; j++) sum[j] += v[j];
          }
          double px = w * h;
          vglog("passread %d: c%u %p pf%lu %zux%zu: %.0f%% nonzero, mean %.3f %.3f %.3f %.3f", k, i, t, (unsigned long)pf,
                w, h, nz * 100 / px, sum[0] / px, sum[1] / px, sum[2] / px, sum[3] / px);
          static int saved;
          NSString *vg_disk_dir(void);
          if ((pf == MTLPixelFormatRGBA16Float || pf == MTLPixelFormatRG16Float) && saved < 120 && vg_disk_dir()) {
              saved++;
              [[NSData dataWithBytes:b->map length:w * h * bpp]
                  writeToFile:[vg_disk_dir() stringByAppendingFormat:@"/pass-%d-%p-%zux%zu.%@", k, t, w, h,
                                                                      pf == MTLPixelFormatRG16Float ? @"rg16f" : @"rgba16f"]
                   atomically:NO];
          }
          vg_buffer_destroy(b);
          free(b);
        }];
    }
}
- (void)endEncoding {
    if (_open) {
        [self ddEnd];
    }
    if (_open && _drawn[2] > _drawn[0]) {
        for (uint32_t i = 0; i < _ncolor; i++) {
            if (_colorTex[i] && _colorInfo[i].storeOp != VK_ATTACHMENT_STORE_OP_DONT_CARE) {
                vg_cmd_wrote_rect(_owner, _colorTex[i], _drawn[0], _drawn[1], _drawn[2], _drawn[3]);
            }
        }
    }
    if (_open && vg_passlog()) {
        static int n, epoch;
        if (epoch != vg_passlog_epoch) {
            epoch = vg_passlog_epoch, n = 0;
        }
        if (n++ < 400) {
            NSMutableString *a = [NSMutableString string];
            for (uint32_t i = 0; i < _ncolor; i++) {
                VGMTLTexture *t = _colorTex[i];
                if (!t) {
                    continue;
                }
                VkClearColorValue cc = _colorInfo[i].clearValue.color;
                [a appendFormat:@" c%u=%p %lux%lu pf%lu%@ load%d store%d clear(%.2f %.2f %.2f %.2f)", i, t,
                                (unsigned long)t->_width, (unsigned long)t->_height, (unsigned long)t->_pixelFormat,
                                t->_surface ? [NSString stringWithFormat:@" surf%u", IOSurfaceGetID(t->_surface)] : @"",
                                (int)_colorInfo[i].loadOp, (int)_colorInfo[i].storeOp, cc.float32[0], cc.float32[1],
                                cc.float32[2], cc.float32[3]];
            }
            vglog("passlog %d: cb %p%s; %u draws (%u refused, %u barriers):%s: %s", n, _owner, a.UTF8String, _dbgDraws,
                  _dbgRefused, _dbgSplits, _dbgSeq.UTF8String, [[_dbgPipes.array componentsJoinedByString:@","] UTF8String]);
        }
    }
    if (_open) {
        gVk.vkCmdEndRendering(_owner->_cb);
        [_owner barrier];
        // attachments a fetch split moved into the feedback loop layout go back to GENERAL, where everything else
        // expects them (mode 4)
        VkImageMemoryBarrier ib[kVGMaxColor];
        uint32_t nb = 0;
        for (uint32_t i = 0; i < _ncolor; i++) {
            if (_feedback[i] && _colorTex[i]) {
                ib[nb++] = (VkImageMemoryBarrier){VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
                                                  VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_SHADER_READ_BIT,
                                                  VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
                                                  VK_IMAGE_LAYOUT_ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT,
                                                  VK_IMAGE_LAYOUT_GENERAL, VK_QUEUE_FAMILY_IGNORED,
                                                  VK_QUEUE_FAMILY_IGNORED, _colorTex[i]->_image,
                                                  {VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0,
                                                   VK_REMAINING_ARRAY_LAYERS}};
                _feedback[i] = NO;
            }
        }
        if (nb) {
            gVk.vkCmdPipelineBarrier(_owner->_cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0,
                                     0, NULL, 0, NULL, nb, ib);
        }
        if (vg_passlog()) {
            [self dbgReadBack];
            [self dbgUniformsBack];
            [self dbgPassDump];
        }
        _owner->_nfeedback = 0;   // back in GENERAL: later descriptor sets say so
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
// Always store: a pass may be ended and resumed for a framebuffer-fetch copy, and "don't care" allows storing anyway.
static BOOL vg_integer_format(MTLPixelFormat f) {
    switch ((NSUInteger)f) {
    case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint:
    case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint: case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint:
    case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
    case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA16Uint:
    case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint:
        return YES;
    default:
        return NO;
    }
}
static VkAttachmentStoreOp vg_store(MTLStoreAction a) {
    (void)a;
    return VK_ATTACHMENT_STORE_OP_STORE;
}

- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
    VGCALL("cb %p renderCommandEncoder (%lux%lu)", self, (unsigned long)d.colorAttachments[0].texture.width, (unsigned long)d.colorAttachments[0].texture.height);
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
        if (![t isKindOfClass:[VGMTLTexture class]] || c.depthPlane ||
            (c.resolveTexture && ![(NSObject *)c.resolveTexture isKindOfClass:[VGMTLTexture class]]) ||
            ((c.level || c.slice) && t->_parent)) {
            [self fail:[NSString stringWithFormat:@"color attachment %u: %@ level %lu slice %lu depth plane %lu resolve %@ "
                                                  @"(only our own textures, levels and slices of a texture that is not a "
                                                  @"view, no resolve, yet)",
                                                  i, NSStringFromClass([t class]), (unsigned long)c.level,
                                                  (unsigned long)c.slice, (unsigned long)c.depthPlane,
                                                  c.resolveTexture ? @"yes" : @"no"]];
            return nil;
        }
        [_keep addObject:t];
        // A level or slice (CoreDisplay renders its display pipe's LUTs into slices of a 1D array, 5b): a view of just
        // that level and slice to render into; surface syncing still goes by the texture itself.
        // A cube's face is a slice too: a cube view can't be rendered into.
        VGMTLTexture *target = t;
        if (c.level || c.slice || t->_type == MTLTextureTypeCube || t->_type == MTLTextureTypeCubeArray) {
            MTLTextureType vt = t->_type == MTLTextureType1D || t->_type == MTLTextureType1DArray ? MTLTextureType1D
                                                                                                   : MTLTextureType2D;
            target = (VGMTLTexture *)vg_texture_view(t, t->_pixelFormat, vt, NSMakeRange(c.level, 1), NSMakeRange(c.slice, 1));
            if (!target) {
                [self fail:@"color attachment: no view of that level and slice"];
                return nil;
            }
            [_keep addObject:target];
        }
        // A surface's attachment with "don't care" keeps what it holds (5d): the pass may draw only part of it, and
        // the write-back copies the whole rectangle its draws could touch, so the rest of that must be what the
        // surface holds, not leftovers.
        // (An immediate-mode GPU's "don't care" keeps the pixels too, and apps written on one can count on it.)
        const BOOL surfaceKeep = c.loadAction == MTLLoadActionDontCare && (t->_surface || (t->_parent && t->_parent->_surface));
        if (c.loadAction == MTLLoadActionLoad || surfaceKeep) {
            vg_surface_pull(t);
        }
        color[i].imageView = target->_view;
        color[i].loadOp = surfaceKeep ? VK_ATTACHMENT_LOAD_OP_LOAD : vg_load(c.loadAction);
        color[i].storeOp = vg_store(c.storeAction);
        // Multisample resolve (5d): into the resolve texture (its level and slice), averaged, or sample 0 for integers
        if (c.resolveTexture && (c.storeAction == MTLStoreActionMultisampleResolve ||
                                 c.storeAction == MTLStoreActionStoreAndMultisampleResolve)) {
            VGMTLTexture *rt = (VGMTLTexture *)c.resolveTexture, *rv = rt;
            if (c.resolveLevel || c.resolveSlice) {
                rv = (VGMTLTexture *)vg_texture_view(rt, rt->_pixelFormat, MTLTextureType2D, NSMakeRange(c.resolveLevel, 1),
                                                     NSMakeRange(c.resolveSlice, 1));
            }
            if (!rv) {
                [self fail:@"color attachment: no view of the resolve level and slice"];
                return nil;
            }
            [_keep addObject:rt];
            [_keep addObject:rv];
            color[i].resolveMode = vg_integer_format(t->_pixelFormat) ? VK_RESOLVE_MODE_SAMPLE_ZERO_BIT : VK_RESOLVE_MODE_AVERAGE_BIT;
            color[i].resolveImageView = rv->_view;
            color[i].resolveImageLayout = VK_IMAGE_LAYOUT_GENERAL;
            vg_cmd_wrote(self, rt);
        }
        MTLClearColor cc = c.clearColor;
        color[i].clearValue.color = (VkClearColorValue){{(float)cc.red, (float)cc.green, (float)cc.blue, (float)cc.alpha}};
        ncolor = i + 1;
        w = MIN(w, (uint32_t)target->_width);
        h = MIN(h, (uint32_t)target->_height);
    }
    VkRenderingAttachmentInfo depth = {VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO};
    VGMTLTexture *dt = (VGMTLTexture *)d.depthAttachment.texture;
    if (dt) {
        [_keep addObject:dt];
        depth.imageView = dt->_attView ? dt->_attView : dt->_view;
        depth.imageLayout = VK_IMAGE_LAYOUT_GENERAL;
        depth.loadOp = vg_load(d.depthAttachment.loadAction);
        depth.storeOp = vg_store(d.depthAttachment.storeAction);
        depth.clearValue.depthStencil = (VkClearDepthStencilValue){(float)d.depthAttachment.clearDepth, 0};
        VGMTLTexture *drt = (VGMTLTexture *)d.depthAttachment.resolveTexture;
        if ([drt isKindOfClass:[VGMTLTexture class]] &&
            (d.depthAttachment.storeAction == MTLStoreActionMultisampleResolve ||
             d.depthAttachment.storeAction == MTLStoreActionStoreAndMultisampleResolve)) {
            [_keep addObject:drt];
            depth.resolveMode = VK_RESOLVE_MODE_SAMPLE_ZERO_BIT;   // Metal's default depth resolve filter
            depth.resolveImageView = drt->_view;
            depth.resolveImageLayout = VK_IMAGE_LAYOUT_GENERAL;
        }
        w = MIN(w, (uint32_t)dt->_width);
        h = MIN(h, (uint32_t)dt->_height);
    }
    // the stencil attachment (5d): Vulkan wants the depth attachment's view when both are the same image
    VkRenderingAttachmentInfo stencil = {VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO};
    VGMTLTexture *st = (VGMTLTexture *)d.stencilAttachment.texture;
    if (st && (![st isKindOfClass:[VGMTLTexture class]] || (dt && st != dt))) {
        static int logged;
        if (logged++ < 3) {
            vglog("render pass: a stencil texture apart from the depth texture isn't supported (stencil ignored)");
        }
        st = nil;
    }
    if (st) {
        [_keep addObject:st];
        stencil.imageView = st->_attView ? st->_attView : st->_view;
        stencil.imageLayout = VK_IMAGE_LAYOUT_GENERAL;
        stencil.loadOp = vg_load(d.stencilAttachment.loadAction);
        stencil.storeOp = vg_store(d.stencilAttachment.storeAction);
        stencil.clearValue.depthStencil = (VkClearDepthStencilValue){(float)d.depthAttachment.clearDepth,
                                                                     d.stencilAttachment.clearStencil};
        depth.clearValue.depthStencil.stencil = d.stencilAttachment.clearStencil;
        w = MIN(w, (uint32_t)st->_width);
        h = MIN(h, (uint32_t)st->_height);
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
    for (uint32_t i = 0; i < ncolor; i++) {
        e->_colorInfo[i] = color[i];
        e->_colorTex[i] = (VGMTLTexture *)d.colorAttachments[i].texture;
    }
    e->_ncolor = ncolor;
    // A surface's written part (5d): a cleared one all of the pass's area, a loaded one what the draws touch (added at
    // endEncoding). Writing back more put stale pixels over what the CPU drew there meanwhile.
    e->_drawn[0] = e->_drawn[1] = INT32_MAX, e->_drawn[2] = e->_drawn[3] = INT32_MIN;
    for (uint32_t i = 0; i < ncolor; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
        if (c.texture && c.storeAction != MTLStoreActionDontCare) {
            BOOL all = c.loadAction == MTLLoadActionClear;
            vg_cmd_wrote_rect(self, (VGMTLTexture *)c.texture, 0, 0, all ? (int32_t)w : 0, all ? (int32_t)h : 0);
        }
    }
    e->_depthInfo = depth;
    e->_depthTex = dt;
    e->_stencilInfo = stencil;
    e->_stencilTex = st;
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, e->_area, 1, 0, ncolor, color, dt ? &depth : NULL,
                          st ? &stencil : NULL};
    gVk.vkCmdBeginRendering(_cb, &ri);
    e->_open = YES;
    [e ddBegin];
    return e;
}
@end
