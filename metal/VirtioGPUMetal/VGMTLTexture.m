// Stage 4c: textures, samplers, depth-stencil states.
//
// A texture is a VkImage with optimal tiling, kept in VK_IMAGE_LAYOUT_GENERAL for its whole life (set once at
// creation), so it can be sampled, written as storage, rendered to and copied without layout tracking; the price is
// some bandwidth on GPUs that compress attachments. replaceRegion / getBytes are synchronous, as Metal's are: a
// staging buffer and a one-shot command buffer each.
#import "objects.h"

// ---- formats -----------------------------------------------------------------------------------------------------

typedef struct {
    MTLPixelFormat mtl;
    VkFormat vk;
    uint8_t bytes;   // per pixel
    VkImageAspectFlags aspect;
} vg_format;

static const vg_format kFormats[] = {
    {MTLPixelFormatBGRA8Unorm, VK_FORMAT_B8G8R8A8_UNORM, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatBGRA8Unorm_sRGB, VK_FORMAT_B8G8R8A8_SRGB, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRGBA8Unorm, VK_FORMAT_R8G8B8A8_UNORM, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRGBA8Unorm_sRGB, VK_FORMAT_R8G8B8A8_SRGB, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRGBA8Uint, VK_FORMAT_R8G8B8A8_UINT, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRGBA8Snorm, VK_FORMAT_R8G8B8A8_SNORM, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatR8Unorm, VK_FORMAT_R8_UNORM, 1, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatA8Unorm, VK_FORMAT_R8_UNORM, 1, VK_IMAGE_ASPECT_COLOR_BIT},   // sampled as (0, 0, 0, r): the view swizzles
    {MTLPixelFormatR8Uint, VK_FORMAT_R8_UINT, 1, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRG8Unorm, VK_FORMAT_R8G8_UNORM, 2, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatR16Float, VK_FORMAT_R16_SFLOAT, 2, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatR16Unorm, VK_FORMAT_R16_UNORM, 2, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRG16Float, VK_FORMAT_R16G16_SFLOAT, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRGBA16Float, VK_FORMAT_R16G16B16A16_SFLOAT, 8, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRGBA16Unorm, VK_FORMAT_R16G16B16A16_UNORM, 8, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatR32Float, VK_FORMAT_R32_SFLOAT, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatR32Uint, VK_FORMAT_R32_UINT, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatR32Sint, VK_FORMAT_R32_SINT, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRG32Float, VK_FORMAT_R32G32_SFLOAT, 8, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRGBA32Float, VK_FORMAT_R32G32B32A32_SFLOAT, 16, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRGBA32Uint, VK_FORMAT_R32G32B32A32_UINT, 16, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRGB10A2Unorm, VK_FORMAT_A2B10G10R10_UNORM_PACK32, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatBGR10A2Unorm, VK_FORMAT_A2R10G10B10_UNORM_PACK32, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRG11B10Float, VK_FORMAT_B10G11R11_UFLOAT_PACK32, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatDepth16Unorm, VK_FORMAT_D16_UNORM, 2, VK_IMAGE_ASPECT_DEPTH_BIT},
    {MTLPixelFormatDepth32Float, VK_FORMAT_D32_SFLOAT, 4, VK_IMAGE_ASPECT_DEPTH_BIT},
    {MTLPixelFormatDepth32Float_Stencil8, VK_FORMAT_D32_SFLOAT_S8_UINT, 8,
     VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT},
};

static const vg_format *vg_format_of(MTLPixelFormat f) {
    for (size_t i = 0; i < sizeof(kFormats) / sizeof(*kFormats); i++) {
        if (kFormats[i].mtl == f) {
            return &kFormats[i];
        }
    }
    return NULL;
}

NSUInteger vg_bytes_per_pixel(MTLPixelFormat f) {
    const vg_format *v = vg_format_of(f);
    return v ? v->bytes : 0;
}

VkFormat vg_vk_format(MTLPixelFormat f) {
    const vg_format *v = vg_format_of(f);
    return v ? v->vk : VK_FORMAT_UNDEFINED;
}

// ---- one-shot command buffers ------------------------------------------------------------------------------------

BOOL vg_one_shot(void (^record)(VkCommandBuffer cb)) {
    VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, gVk.pool,
                                      VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb = VK_NULL_HANDLE;
    pthread_mutex_lock(&gVk.lock);
    VkResult r = gVk.vkAllocateCommandBuffers(gVk.device, &ai, &cb);
    pthread_mutex_unlock(&gVk.lock);
    if (r != VK_SUCCESS) {
        return NO;
    }
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                   VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    gVk.vkBeginCommandBuffer(cb, &bi);
    // Whatever earlier command buffers did is visible to this one, and this one's writes to the host.
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT,
                          VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT};
    gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &mb, 0,
                             NULL, 0, NULL);
    record(cb);
    VkMemoryBarrier hb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT,
                          VK_ACCESS_HOST_READ_BIT | VK_ACCESS_MEMORY_READ_BIT};
    gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                             VK_PIPELINE_STAGE_HOST_BIT | VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &hb, 0, NULL, 0, NULL);
    gVk.vkEndCommandBuffer(cb);
    vgtrace("one-shot: submit");
    VkFence fence = VK_NULL_HANDLE;
    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    gVk.vkCreateFence(gVk.device, &fci, NULL, &fence);
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cb, 0, NULL};
    pthread_mutex_lock(&gVk.lock);
    r = gVk.vkQueueSubmit(gVk.queue, 1, &si, fence);
    pthread_mutex_unlock(&gVk.lock);
    if (r == VK_SUCCESS) {
        gVk.vkWaitForFences(gVk.device, 1, &fence, VK_TRUE, UINT64_MAX);
    }
    gVk.vkDestroyFence(gVk.device, fence, NULL);
    vgtrace("one-shot: done (%d)", r);
    pthread_mutex_lock(&gVk.lock);
    gVk.vkFreeCommandBuffers(gVk.device, gVk.pool, 1, &cb);
    pthread_mutex_unlock(&gVk.lock);
    return r == VK_SUCCESS;
}

// ---- MTLTexture --------------------------------------------------------------------------------------------------

@implementation VGMTLTexture
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (void)dealloc {
    if (_surface) {
        CFRelease(_surface);
    }
    vg_buffer_destroy(&_staging);
    if (_view) {
        gVk.vkDestroyImageView(gVk.device, _view, NULL);
    }
    if (_parent) {
        return;   // a view: the image and its memory are the parent's
    }
    if (_image) {
        gVk.vkDestroyImage(gVk.device, _image, NULL);
    }
    if (_memory) {
        gVk.vkFreeMemory(gVk.device, _memory, NULL);
    }
}
- (MTLTextureType)textureType { return _type; }
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pf {
    return vg_texture_view(self, pf, _type, NSMakeRange(0, _mips), NSMakeRange(0, _layers));
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pf textureType:(MTLTextureType)type levels:(NSRange)levels
                                         slices:(NSRange)slices {
    return vg_texture_view(self, pf, type, levels, slices);
}
- (id<MTLTexture>)parentTexture { return _parent; }
- (NSUInteger)parentRelativeLevel { return 0; }
- (NSUInteger)parentRelativeSlice { return 0; }
- (MTLPixelFormat)pixelFormat { return _pixelFormat; }
- (NSUInteger)width { return _width; }
- (NSUInteger)height { return _height; }
- (NSUInteger)depth { return _depth; }
- (NSUInteger)mipmapLevelCount { return _mips; }
- (NSUInteger)arrayLength { return _layers; }
- (NSUInteger)sampleCount { return 1; }
- (MTLTextureUsage)usage { return _usage; }
- (MTLStorageMode)storageMode { return _storage; }
- (MTLCPUCacheMode)cpuCacheMode { return MTLCPUCacheModeDefaultCache; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLResourceOptions)resourceOptions { return (MTLResourceOptions)_storage << MTLResourceStorageModeShift; }
- (BOOL)isFramebufferOnly { return NO; }
- (BOOL)allowGPUOptimizedContents { return YES; }
- (BOOL)isShareable { return NO; }
- (IOSurfaceRef)iosurface { return _parent ? _parent->_surface : _surface; }
- (NSUInteger)iosurfacePlane { return _parent ? _parent->_plane : _plane; }
- (id<MTLTexture>)rootResource { return nil; }
- (id<MTLBuffer>)buffer { return _srcBuffer; }
- (NSUInteger)bufferOffset { return _srcOffset; }
- (NSUInteger)bufferBytesPerRow { return _srcBpr; }
- (NSUInteger)allocatedSize { return _width * _height * _depth * _layers * MAX(vg_format_of(_pixelFormat)->bytes, 1); }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return vg_purgeable(self, state); }
- (BOOL)isAliasable { return vg_heap_aliasable(self); }
- (void)makeAliasable { vg_heap_make_aliasable(self); }
- (id<MTLHeap>)heap { return vg_heap_of(self); }
- (NSUInteger)heapOffset { return vg_heap_offset_of(self); }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){0}; }
- (MTLTextureSwizzleChannels)swizzle {
    return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
                                         MTLTextureSwizzleAlpha);
}

// Copies between the image and a staging buffer laid out with Metal's bytesPerRow / bytesPerImage.
- (BOOL)copyRegion:(MTLRegion)region level:(NSUInteger)level slice:(NSUInteger)slice bytes:(void *)bytes
       bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi toImage:(BOOL)toImage {
    const vg_format *f = vg_format_of(_pixelFormat);
    if (!f || !region.size.width || !region.size.height || !region.size.depth) {
        return NO;
    }
    if (bpr % f->bytes) {
        vglog("texture: bytesPerRow %lu isn't a whole number of %u-byte pixels", (unsigned long)bpr, f->bytes);
        return NO;
    }
    NSUInteger rows = region.size.height, depth = region.size.depth;
    if (!bpi) {
        bpi = bpr * rows;
    }
    NSUInteger size = bpi * (depth - 1) + bpr * (rows - 1) + region.size.width * f->bytes;
    vg_buffer staging;
    if (vg_buffer_create(size, &staging)) {
        return NO;
    }
    if (toImage) {
        memcpy(staging.map, bytes, size);
    }
    VkBufferImageCopy c = {0, (uint32_t)(bpr / f->bytes), (uint32_t)(bpi / bpr),
                           {f->aspect & ~VK_IMAGE_ASPECT_STENCIL_BIT, (uint32_t)level, (uint32_t)slice, 1},
                           {(int32_t)region.origin.x, (int32_t)region.origin.y, (int32_t)region.origin.z},
                           {(uint32_t)region.size.width, (uint32_t)rows, (uint32_t)depth}};
    VkImage image = _image;
    vgtrace("texture: %s %ux%u level %lu, row length %u, %lu staging bytes", toImage ? "upload" : "readback",
            c.imageExtent.width, c.imageExtent.height, (unsigned long)level, c.bufferRowLength, (unsigned long)size);
    BOOL ok = vg_one_shot(^(VkCommandBuffer cb) {
        if (toImage) {
            gVk.vkCmdCopyBufferToImage(cb, staging.buffer, image, VK_IMAGE_LAYOUT_GENERAL, 1, &c);
        } else {
            gVk.vkCmdCopyImageToBuffer(cb, image, VK_IMAGE_LAYOUT_GENERAL, staging.buffer, 1, &c);
        }
    });
    if (ok && !toImage) {
        memcpy(bytes, staging.map, size);
    }
    vg_buffer_destroy(&staging);
    return ok;
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes
          bytesPerRow:(NSUInteger)bpr {
    if (_surface && level == 0) {   // the surface is the truth for its texture: write it, then the image follows
        const NSUInteger px = vg_format_of(_pixelFormat)->bytes;
        IOSurfaceLock(_surface, 0, NULL);
        uint8_t *base = IOSurfaceGetBaseAddressOfPlane(_surface, _plane);
        for (NSUInteger y = 0; y < region.size.height; y++) {
            memcpy(base + (region.origin.y + y) * _surfaceBpr + region.origin.x * px, (const uint8_t *)bytes + y * bpr,
                   region.size.width * px);
        }
        IOSurfaceUnlock(_surface, 0, NULL);
        vg_surface_pull(self);
        return;
    }
    [self copyRegion:region level:level slice:0 bytes:(void *)bytes bytesPerRow:bpr bytesPerImage:0 toImage:YES];
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
            withBytes:(const void *)bytes bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi {
    [self copyRegion:region level:level slice:slice bytes:(void *)bytes bytesPerRow:bpr bytesPerImage:bpi toImage:YES];
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level {
    vg_surface_pull(self);
    [self copyRegion:region level:level slice:0 bytes:bytes bytesPerRow:bpr bytesPerImage:0 toImage:NO];
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi fromRegion:(MTLRegion)region
     mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {
    [self copyRegion:region level:level slice:slice bytes:bytes bytesPerRow:bpr bytesPerImage:bpi toImage:NO];
}
@end

id<MTLTexture> vg_new_texture(id<MTLDevice> device, MTLTextureDescriptor *d) {
    const vg_format *f = vg_format_of(d.pixelFormat);
    if (vg_vulkan_init() || !f) {
        vglog("texture: pixel format %lu not supported yet", (unsigned long)d.pixelFormat);
        return nil;
    }
    VkImageType itype;
    VkImageViewType vtype;
    switch (d.textureType) {
    case MTLTextureType1D: itype = VK_IMAGE_TYPE_1D, vtype = VK_IMAGE_VIEW_TYPE_1D; break;
    case MTLTextureType2D: itype = VK_IMAGE_TYPE_2D, vtype = VK_IMAGE_VIEW_TYPE_2D; break;
    case MTLTextureType2DArray: itype = VK_IMAGE_TYPE_2D, vtype = VK_IMAGE_VIEW_TYPE_2D_ARRAY; break;
    case MTLTextureType3D: itype = VK_IMAGE_TYPE_3D, vtype = VK_IMAGE_VIEW_TYPE_3D; break;
    default:
        vglog("texture: type %lu not supported yet", (unsigned long)d.textureType);
        return nil;
    }
    if (d.sampleCount > 1) {
        vglog("texture: multisampling not supported yet");
        return nil;
    }
    VkFormatProperties fp;
    gVk.vkGetPhysicalDeviceFormatProperties(gVk.physical, f->vk, &fp);
    VkFormatFeatureFlags ff = fp.optimalTilingFeatures;
    VkImageUsageFlags usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (ff & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) {
        usage |= VK_IMAGE_USAGE_SAMPLED_BIT;
    }
    if ((ff & VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT) && (d.usage & (MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead))) {
        usage |= VK_IMAGE_USAGE_STORAGE_BIT;
    }
    if (ff & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT) {
        usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    }
    if (ff & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) {
        usage |= VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    }
    if ((d.usage & MTLTextureUsageShaderWrite) && !(usage & VK_IMAGE_USAGE_STORAGE_BIT)) {
        vglog("texture: pixel format %lu can't be a storage image here (shaderWrite will fail)", (unsigned long)d.pixelFormat);
    }
    VGMTLTexture *t = [VGMTLTexture new];
    t->_dev = device;
    t->_pixelFormat = d.pixelFormat;
    t->_format = f->vk;
    t->_aspect = f->aspect;
    t->_type = d.textureType;
    t->_width = MAX(d.width, 1);
    t->_height = d.textureType == MTLTextureType1D ? 1 : MAX(d.height, 1);
    t->_depth = d.textureType == MTLTextureType3D ? MAX(d.depth, 1) : 1;
    t->_mips = MAX(d.mipmapLevelCount, 1);
    t->_layers = d.textureType == MTLTextureType2DArray ? MAX(d.arrayLength, 1) : 1;
    t->_usage = d.usage;
    t->_storage = d.storageMode;
    VkImageCreateInfo ici = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    ici.imageType = itype;
    ici.format = f->vk;
    ici.extent = (VkExtent3D){(uint32_t)t->_width, (uint32_t)t->_height, (uint32_t)t->_depth};
    ici.mipLevels = (uint32_t)t->_mips;
    ici.arrayLayers = (uint32_t)t->_layers;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = usage;
    if (f->aspect == VK_IMAGE_ASPECT_COLOR_BIT) {
        ici.flags |= VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;   // texture views may reinterpret the format (5b)
    }
    t->_imageUsage = usage;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    vgtrace("texture: vkCreateImage %lux%lu format %d usage 0x%x", (unsigned long)t->_width, (unsigned long)t->_height, f->vk, usage);
    VkResult r = gVk.vkCreateImage(gVk.device, &ici, NULL, &t->_image);
    if (r != VK_SUCCESS) {
        vglog("texture: vkCreateImage %d", r);
        return nil;
    }
    VkMemoryRequirements req;
    gVk.vkGetImageMemoryRequirements(gVk.device, t->_image, &req);
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size,
                                vg_memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
    vgtrace("texture: %llu bytes, memory type bits 0x%x -> type %u", (unsigned long long)req.size, req.memoryTypeBits,
            mai.memoryTypeIndex);
    r = gVk.vkAllocateMemory(gVk.device, &mai, NULL, &t->_memory);
    if (r == VK_SUCCESS) {
        r = gVk.vkBindImageMemory(gVk.device, t->_image, t->_memory, 0);
    }
    const BOOL alpha8 = f->mtl == MTLPixelFormatA8Unorm;
    VkImageViewCreateInfo vci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, NULL, 0, t->_image, vtype, f->vk,
                                 {alpha8 ? VK_COMPONENT_SWIZZLE_ZERO : VK_COMPONENT_SWIZZLE_IDENTITY,
                                  alpha8 ? VK_COMPONENT_SWIZZLE_ZERO : VK_COMPONENT_SWIZZLE_IDENTITY,
                                  alpha8 ? VK_COMPONENT_SWIZZLE_ZERO : VK_COMPONENT_SWIZZLE_IDENTITY,
                                  alpha8 ? VK_COMPONENT_SWIZZLE_R : VK_COMPONENT_SWIZZLE_IDENTITY},
                                 {f->aspect & ~VK_IMAGE_ASPECT_STENCIL_BIT, 0, (uint32_t)t->_mips, 0, (uint32_t)t->_layers}};
    if (r == VK_SUCCESS) {
        vgtrace("texture: bound (%d), vkCreateImageView", r);
        r = gVk.vkCreateImageView(gVk.device, &vci, NULL, &t->_view);
    }
    vgtrace("texture: view %d, layout transition", r);
    if (r != VK_SUCCESS) {
        vglog("texture: memory / view %d", r);
        return nil;
    }
    VkImage image = t->_image;
    VkImageAspectFlags aspect = f->aspect;
    uint32_t mips = (uint32_t)t->_mips, layers = (uint32_t)t->_layers;
    BOOL ok = vg_one_shot(^(VkCommandBuffer cb) {   // UNDEFINED -> GENERAL, for life
        VkImageMemoryBarrier ib = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0,
                                   VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT, VK_IMAGE_LAYOUT_UNDEFINED,
                                   VK_IMAGE_LAYOUT_GENERAL, VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, image,
                                   {aspect, 0, mips, 0, layers}};
        gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0,
                                 NULL, 1, &ib);
    });
    return ok ? t : nil;
}

// ---- MTLSamplerState ---------------------------------------------------------------------------------------------

@implementation VGMTLSamplerState
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){0}; }
- (void)dealloc {
    if (_sampler) {
        gVk.vkDestroySampler(gVk.device, _sampler, NULL);
    }
}
@end

static VkSamplerAddressMode vg_address(MTLSamplerAddressMode m) {
    switch (m) {
    case MTLSamplerAddressModeRepeat: return VK_SAMPLER_ADDRESS_MODE_REPEAT;
    case MTLSamplerAddressModeMirrorRepeat: return VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;
    case MTLSamplerAddressModeMirrorClampToEdge: return VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE;
    case MTLSamplerAddressModeClampToZero:
    case MTLSamplerAddressModeClampToBorderColor: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    default: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    }
}

static VkCompareOp vg_compare(MTLCompareFunction f) {
    switch (f) {
    case MTLCompareFunctionNever: return VK_COMPARE_OP_NEVER;
    case MTLCompareFunctionLess: return VK_COMPARE_OP_LESS;
    case MTLCompareFunctionEqual: return VK_COMPARE_OP_EQUAL;
    case MTLCompareFunctionLessEqual: return VK_COMPARE_OP_LESS_OR_EQUAL;
    case MTLCompareFunctionGreater: return VK_COMPARE_OP_GREATER;
    case MTLCompareFunctionNotEqual: return VK_COMPARE_OP_NOT_EQUAL;
    case MTLCompareFunctionGreaterEqual: return VK_COMPARE_OP_GREATER_OR_EQUAL;
    default: return VK_COMPARE_OP_ALWAYS;
    }
}

id<MTLSamplerState> vg_new_sampler(id<MTLDevice> device, MTLSamplerDescriptor *d) {
    if (vg_vulkan_init()) {
        return nil;
    }
    VkSamplerCreateInfo sci = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
    sci.magFilter = d.magFilter == MTLSamplerMinMagFilterLinear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST;
    sci.minFilter = d.minFilter == MTLSamplerMinMagFilterLinear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST;
    sci.mipmapMode = d.mipFilter == MTLSamplerMipFilterLinear ? VK_SAMPLER_MIPMAP_MODE_LINEAR : VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sci.addressModeU = vg_address(d.sAddressMode);
    sci.addressModeV = vg_address(d.tAddressMode);
    sci.addressModeW = vg_address(d.rAddressMode);
    sci.maxAnisotropy = (float)MAX(d.maxAnisotropy, 1);
    sci.anisotropyEnable = d.maxAnisotropy > 1;
    sci.compareEnable = d.compareFunction != MTLCompareFunctionNever;
    sci.compareOp = vg_compare(d.compareFunction);
    sci.minLod = d.lodMinClamp;
    sci.maxLod = d.mipFilter == MTLSamplerMipFilterNotMipmapped ? 0.25f : d.lodMaxClamp;
    sci.borderColor = d.borderColor == MTLSamplerBorderColorOpaqueWhite   ? VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE
                      : d.borderColor == MTLSamplerBorderColorOpaqueBlack ? VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK
                                                                          : VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
    sci.unnormalizedCoordinates = !d.normalizedCoordinates;
    VGMTLSamplerState *s = [VGMTLSamplerState new];
    s->_dev = device;
    if (gVk.vkCreateSampler(gVk.device, &sci, NULL, &s->_sampler) != VK_SUCCESS) {
        return nil;
    }
    return s;
}

// ---- MTLDepthStencilState ----------------------------------------------------------------------------------------

@implementation VGMTLDepthStencilState
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){0}; }
@end

id<MTLDepthStencilState> vg_new_depth_stencil(id<MTLDevice> device, MTLDepthStencilDescriptor *d) {
    VGMTLDepthStencilState *s = [VGMTLDepthStencilState new];
    s->_dev = device;
    s->_write = d.depthWriteEnabled;
    s->_compare = vg_compare(d.depthCompareFunction);
    s->_test = d.depthCompareFunction != MTLCompareFunctionAlways || d.depthWriteEnabled;
    if (d.frontFaceStencil || d.backFaceStencil) {
        vglog("depth-stencil: stencil isn't supported yet (ignored)");
    }
    return s;
}

// ---- IOSurface-backed textures (stage 4d) -------------------------------------------------------------------------
//
// Venus can't put a guest IOSurface's pages under a host image, so a surface texture is NV's headless path: a private
// VkImage plus a staging buffer laid out like the surface plane. The surface's seed says when the CPU (or another
// process) changed it: before the GPU reads the texture, a changed surface is pulled into the image; when a command
// buffer wrote the texture, the image is copied to the staging buffer at the end of it and into the surface when it
// completes (VGMTLCompute.m), and the seed after that write is remembered as ours.

// A view of another texture: same VkImage, its own VkImageView (format, type, levels, slices). Core Animation makes
// them in its compute passes (calculate_average_luma) and blur chains.
id<MTLTexture> vg_texture_view(VGMTLTexture *p, MTLPixelFormat pf, MTLTextureType type, NSRange levels, NSRange slices) {
    while (p->_parent) {
        p = p->_parent;
    }
    const vg_format *f = vg_format_of(pf);
    VkImageViewType vtype;
    switch (type) {
    case MTLTextureType1D: vtype = VK_IMAGE_VIEW_TYPE_1D; break;
    case MTLTextureType2D: vtype = VK_IMAGE_VIEW_TYPE_2D; break;
    case MTLTextureType2DArray: vtype = VK_IMAGE_VIEW_TYPE_2D_ARRAY; break;
    case MTLTextureType3D: vtype = VK_IMAGE_VIEW_TYPE_3D; break;
    default: vtype = VK_IMAGE_VIEW_TYPE_MAX_ENUM; break;
    }
    if (!f || vtype == VK_IMAGE_VIEW_TYPE_MAX_ENUM || levels.location + levels.length > p->_mips ||
        slices.location + slices.length > p->_layers || !levels.length || !slices.length) {
        vglog("texture view: format %lu type %lu levels %lu+%lu slices %lu+%lu of a %lu-level %lu-layer texture: not supported",
              (unsigned long)pf, (unsigned long)type, (unsigned long)levels.location, (unsigned long)levels.length,
              (unsigned long)slices.location, (unsigned long)slices.length, (unsigned long)p->_mips, (unsigned long)p->_layers);
        return nil;
    }
    VkFormatProperties fp;
    gVk.vkGetPhysicalDeviceFormatProperties(gVk.physical, f->vk, &fp);
    VkImageUsageFlags usage = p->_imageUsage & (VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    if (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) {
        usage |= p->_imageUsage & VK_IMAGE_USAGE_SAMPLED_BIT;
    }
    if (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT) {
        usage |= p->_imageUsage & VK_IMAGE_USAGE_STORAGE_BIT;
    }
    if (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT) {
        usage |= p->_imageUsage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    }
    VkImageViewUsageCreateInfo uci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO, NULL, usage};
    const BOOL alpha8 = pf == MTLPixelFormatA8Unorm;
    VkImageViewCreateInfo vci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, &uci, 0, p->_image, vtype, f->vk,
                                 {alpha8 ? VK_COMPONENT_SWIZZLE_ZERO : VK_COMPONENT_SWIZZLE_IDENTITY,
                                  alpha8 ? VK_COMPONENT_SWIZZLE_ZERO : VK_COMPONENT_SWIZZLE_IDENTITY,
                                  alpha8 ? VK_COMPONENT_SWIZZLE_ZERO : VK_COMPONENT_SWIZZLE_IDENTITY,
                                  alpha8 ? VK_COMPONENT_SWIZZLE_R : VK_COMPONENT_SWIZZLE_IDENTITY},
                                 {f->aspect & ~VK_IMAGE_ASPECT_STENCIL_BIT, (uint32_t)levels.location, (uint32_t)levels.length,
                                  (uint32_t)slices.location, (uint32_t)slices.length}};
    VGMTLTexture *t = [VGMTLTexture new];
    if (gVk.vkCreateImageView(gVk.device, &vci, NULL, &t->_view) != VK_SUCCESS) {
        vglog("texture view: vkCreateImageView failed (format %lu)", (unsigned long)pf);
        return nil;
    }
    VGCALL("texture view of %p: format %lu type %lu -> %p", p, (unsigned long)pf, (unsigned long)type, t);
    t->_parent = p;
    t->_dev = p->_dev;
    t->_image = p->_image;
    t->_imageUsage = p->_imageUsage;
    t->_pixelFormat = pf;
    t->_format = f->vk;
    t->_aspect = f->aspect;
    t->_type = type;
    t->_width = MAX(p->_width >> levels.location, 1u);
    t->_height = MAX(p->_height >> levels.location, 1u);
    t->_depth = MAX(p->_depth >> levels.location, 1u);
    t->_mips = levels.length;
    t->_layers = slices.length;
    t->_usage = p->_usage;
    t->_storage = p->_storage;
    return t;
}

void vg_surface_pull(VGMTLTexture *t) {
    if (t && t->_parent) {
        t = t->_parent;   // a view reads what its texture's surface or buffer holds
    }
    if (t && t->_srcBuffer) {
        // a buffer-backed texture: what the buffer holds now -> the image (synchronous, every time)
        const vg_format *bf = vg_format_of(t->_pixelFormat);
        VkBuffer buf = vg_vkbuffer(t->_srcBuffer);   // also brings a no-copy buffer's CPU writes over
        if (!bf || !buf) {
            return;
        }
        VkBufferImageCopy c = {t->_srcOffset, (uint32_t)(t->_srcBpr / bf->bytes), (uint32_t)t->_height,
                               {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0},
                               {(uint32_t)t->_width, (uint32_t)t->_height, 1}};
        VkImage image = t->_image;
        vg_one_shot(^(VkCommandBuffer cb) {
            gVk.vkCmdCopyBufferToImage(cb, buf, image, VK_IMAGE_LAYOUT_GENERAL, 1, &c);
        });
        return;
    }
    if (!t || !t->_surface) {
        return;
    }
    uint32_t seed = IOSurfaceGetSeed(t->_surface);
    if (!t->_neverSynced && seed == t->_syncedSeed) {
        return;
    }
    const vg_format *f = vg_format_of(t->_pixelFormat);
    NSUInteger rows = t->_height;
    IOSurfaceLock(t->_surface, kIOSurfaceLockReadOnly, &seed);
    memcpy(t->_staging.map, IOSurfaceGetBaseAddressOfPlane(t->_surface, t->_plane), t->_surfaceBpr * rows);
    IOSurfaceUnlock(t->_surface, kIOSurfaceLockReadOnly, NULL);
    VkBufferImageCopy c = {0, (uint32_t)(t->_surfaceBpr / f->bytes), (uint32_t)rows,
                           {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0},
                           {(uint32_t)t->_width, (uint32_t)rows, 1}};
    VkBuffer buf = t->_staging.buffer;
    VkImage image = t->_image;
    vgtrace("surface %u: pull (seed %u, had %u)", IOSurfaceGetID(t->_surface), seed, t->_syncedSeed);
    vg_one_shot(^(VkCommandBuffer cb) {
        gVk.vkCmdCopyBufferToImage(cb, buf, image, VK_IMAGE_LAYOUT_GENERAL, 1, &c);
    });
    t->_syncedSeed = seed;
    t->_neverSynced = NO;
}

id<MTLTexture> vg_new_buffer_texture(id<MTLBuffer> buffer, MTLTextureDescriptor *d, NSUInteger offset, NSUInteger bpr) {
    const vg_format *f = vg_format_of(d.pixelFormat);
    if (!f || (f->aspect & ~VK_IMAGE_ASPECT_COLOR_BIT) || d.textureType != MTLTextureType2D || d.mipmapLevelCount > 1 ||
        !bpr || bpr % f->bytes || offset + bpr * (d.height - 1) + d.width * f->bytes > buffer.length) {
        vglog("buffer texture: %lux%lu format %lu at %lu, %lu bytes per row doesn't fit a %lu-byte buffer (2D color only)",
              (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.pixelFormat, (unsigned long)offset,
              (unsigned long)bpr, (unsigned long)buffer.length);
        return nil;
    }
    VGMTLTexture *t = (VGMTLTexture *)vg_new_texture(buffer.device, d);
    if (t) {
        t->_srcBuffer = buffer;
        t->_srcOffset = offset;
        t->_srcBpr = bpr;
    }
    return t;
}

id<MTLTexture> vg_new_surface_texture(id<MTLDevice> device, MTLTextureDescriptor *d, IOSurfaceRef surface, NSUInteger plane) {
    const vg_format *f = vg_format_of(d.pixelFormat);
    if (!surface || !f || (f->aspect & ~VK_IMAGE_ASPECT_COLOR_BIT) || d.textureType != MTLTextureType2D ||
        d.mipmapLevelCount > 1) {
        vglog("surface texture: only single-level 2D color textures (format %lu, type %lu)", (unsigned long)d.pixelFormat,
              (unsigned long)d.textureType);
        return nil;
    }
    size_t bpr = IOSurfaceGetBytesPerRowOfPlane(surface, plane);
    size_t sw = IOSurfaceGetWidthOfPlane(surface, plane), sh = IOSurfaceGetHeightOfPlane(surface, plane);
    if (d.width > sw || d.height > sh || bpr % f->bytes || IOSurfaceGetBytesPerElementOfPlane(surface, plane) != f->bytes) {
        vglog("surface texture: %lux%lu format %lu doesn't fit surface %zux%zu, %zu bytes per row, %zu per element",
              (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.pixelFormat, sw, sh, bpr,
              IOSurfaceGetBytesPerElementOfPlane(surface, plane));
        return nil;
    }
    VGMTLTexture *t = (VGMTLTexture *)vg_new_texture(device, d);
    if (!t || vg_buffer_create(bpr * d.height, &t->_staging)) {
        return nil;
    }
    t->_surface = (IOSurfaceRef)CFRetain(surface);
    t->_plane = plane;
    t->_surfaceBpr = bpr;
    t->_neverSynced = YES;
    vg_surface_pull(t);
    vglog("surface texture: IOSurface %u plane %lu, %lux%lu, %zu bytes per row", IOSurfaceGetID(surface),
          (unsigned long)plane, (unsigned long)d.width, (unsigned long)d.height, bpr);
    return t;
}
