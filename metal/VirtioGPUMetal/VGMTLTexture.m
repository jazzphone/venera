// Stage 4c: textures, samplers, depth-stencil states.
//
// A texture is a VkImage with optimal tiling, kept in VK_IMAGE_LAYOUT_GENERAL for its whole life (set once at
// creation), so it can be sampled, written as storage, rendered to and copied without layout tracking; the price is
// some bandwidth on GPUs that compress attachments. replaceRegion / getBytes are synchronous, as Metal's are: a
// staging buffer and a one-shot command buffer each.
#include <os/lock.h>
#import <objc/runtime.h>
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
    {MTLPixelFormatRG16Unorm, VK_FORMAT_R16G16_UNORM, 4, VK_IMAGE_ASPECT_COLOR_BIT},   // a WindowServer surface (5b)
    {MTLPixelFormatRG16Snorm, VK_FORMAT_R16G16_SNORM, 4, VK_IMAGE_ASPECT_COLOR_BIT},
    {MTLPixelFormatRG16Uint, VK_FORMAT_R16G16_UINT, 4, VK_IMAGE_ASPECT_COLOR_BIT},
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
    // stencil (5d: Core Animation's masks in apps, Spotlight, the Dock); the X formats are stencil views of the combined
    {MTLPixelFormatStencil8, VK_FORMAT_S8_UINT, 1, VK_IMAGE_ASPECT_STENCIL_BIT},
    {MTLPixelFormatDepth24Unorm_Stencil8, VK_FORMAT_D24_UNORM_S8_UINT, 4, VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT},
    {MTLPixelFormatX32_Stencil8, VK_FORMAT_D32_SFLOAT_S8_UINT, 8, VK_IMAGE_ASPECT_STENCIL_BIT},
    {MTLPixelFormatX24_Stencil8, VK_FORMAT_D24_UNORM_S8_UINT, 4, VK_IMAGE_ASPECT_STENCIL_BIT},
};

// A view's component mapping (5d): Metal's swizzle picks from what the format reads as (A8: 0, 0, 0, r). Identity
// (no swizzle, or a format of its own) stays VK_COMPONENT_SWIZZLE_IDENTITY: attachments and storage views need that.
static BOOL vg_swz_identity(MTLTextureSwizzleChannels s) {
    return (s.red == MTLTextureSwizzleRed || s.red == 0) && (s.green == MTLTextureSwizzleGreen || s.green == 0) &&
           (s.blue == MTLTextureSwizzleBlue || s.blue == 0) && (s.alpha == MTLTextureSwizzleAlpha || s.alpha == 0);
}
static VkComponentMapping vg_components(MTLPixelFormat pf, MTLTextureSwizzleChannels s) {
    const BOOL a8 = pf == MTLPixelFormatA8Unorm;
    if (!a8 && vg_swz_identity(s)) {
        return (VkComponentMapping){VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
                                    VK_COMPONENT_SWIZZLE_IDENTITY};
    }
    const VkComponentSwizzle base[4] = {a8 ? VK_COMPONENT_SWIZZLE_ZERO : VK_COMPONENT_SWIZZLE_R,
                                        a8 ? VK_COMPONENT_SWIZZLE_ZERO : VK_COMPONENT_SWIZZLE_G,
                                        a8 ? VK_COMPONENT_SWIZZLE_ZERO : VK_COMPONENT_SWIZZLE_B,
                                        a8 ? VK_COMPONENT_SWIZZLE_R : VK_COMPONENT_SWIZZLE_A};
    MTLTextureSwizzle ch[4] = {s.red ?: MTLTextureSwizzleRed, s.green ?: MTLTextureSwizzleGreen,
                               s.blue ?: MTLTextureSwizzleBlue, s.alpha ?: MTLTextureSwizzleAlpha};
    // all zero (never set) means identity; a real Zero swizzle on every channel isn't meaningful
    if (!s.red && !s.green && !s.blue && !s.alpha) {
        ch[0] = MTLTextureSwizzleRed, ch[1] = MTLTextureSwizzleGreen, ch[2] = MTLTextureSwizzleBlue, ch[3] = MTLTextureSwizzleAlpha;
    }
    VkComponentSwizzle out[4];
    for (int i = 0; i < 4; i++) {
        switch (ch[i]) {
        case MTLTextureSwizzleZero: out[i] = VK_COMPONENT_SWIZZLE_ZERO; break;
        case MTLTextureSwizzleOne: out[i] = VK_COMPONENT_SWIZZLE_ONE; break;
        case MTLTextureSwizzleRed: out[i] = base[0]; break;
        case MTLTextureSwizzleGreen: out[i] = base[1]; break;
        case MTLTextureSwizzleBlue: out[i] = base[2]; break;
        default: out[i] = base[3]; break;
        }
    }
    return (VkComponentMapping){out[0], out[1], out[2], out[3]};
}

// A luminance-alpha IOSurface ('LA08', 'LA16') wrapped as a two-channel texture: Apple's GPUs read it as (L, L, L, A)
// and a render target of it keeps a fragment's red and alpha. RenderBox renders tinted icons' glyph masks into them
// (iconservicesagent) and samples them back; read as plain RG they came out (L, A, 0, 1): yellow-green glyphs, and
// masks opaque everywhere. The image keeps the plane's bytes (R = L, G = A). Sampling goes through a second view,
// swizzled (R, R, R, G) under the texture's own swizzle; a pipeline drawing into one stores alpha in green
// (vg_spirv_alpha_to_green), and its clear color does the same.
static BOOL vg_two_channel(MTLPixelFormat pf) {
    return pf == MTLPixelFormatRG8Unorm || pf == MTLPixelFormatRG8Unorm_sRGB || pf == MTLPixelFormatRG16Unorm ||
           pf == MTLPixelFormatRG16Float;
}
static BOOL vg_surface_is_la(IOSurfaceRef s) {
    OSType f = s ? IOSurfaceGetPixelFormat(s) : 0;
    return f == 'LA08' || f == 'LA16';
}
static VkComponentMapping vg_components_la(MTLTextureSwizzleChannels s) {
    const VkComponentSwizzle base[4] = {VK_COMPONENT_SWIZZLE_R, VK_COMPONENT_SWIZZLE_R, VK_COMPONENT_SWIZZLE_R,
                                        VK_COMPONENT_SWIZZLE_G};
    MTLTextureSwizzle ch[4] = {MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha};
    if (s.red || s.green || s.blue || s.alpha) {
        ch[0] = s.red, ch[1] = s.green, ch[2] = s.blue, ch[3] = s.alpha;
    }
    VkComponentSwizzle out[4];
    for (int i = 0; i < 4; i++) {
        switch (ch[i]) {
        case MTLTextureSwizzleZero: out[i] = VK_COMPONENT_SWIZZLE_ZERO; break;
        case MTLTextureSwizzleOne: out[i] = VK_COMPONENT_SWIZZLE_ONE; break;
        case MTLTextureSwizzleRed: out[i] = base[0]; break;
        case MTLTextureSwizzleGreen: out[i] = base[1]; break;
        case MTLTextureSwizzleBlue: out[i] = base[2]; break;
        default: out[i] = base[3]; break;
        }
    }
    return (VkComponentMapping){out[0], out[1], out[2], out[3]};
}
// t (a whole image, or a view's range in `range`) becomes an LA texture: its sampling view
static void vg_texture_la_view(VGMTLTexture *t, VkImageViewType vtype, VkImageSubresourceRange range) {
    if (t->_sampleView || !vg_two_channel(t->_pixelFormat)) {
        return;
    }
    VkImageViewUsageCreateInfo uci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO, NULL, VK_IMAGE_USAGE_SAMPLED_BIT};
    VkImageViewCreateInfo vci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, &uci, 0, t->_image, vtype, t->_format,
                                 vg_components_la(t->_swz), range};
    if (gVk.vkCreateImageView(gVk.device, &vci, NULL, &t->_sampleView) == VK_SUCCESS) {
        t->_la = YES;
    } else {
        t->_sampleView = VK_NULL_HANDLE;
        vglog("texture: a luminance-alpha surface's sampling view failed (format %lu)", (unsigned long)t->_pixelFormat);
    }
}
// A whole single-image 2D texture of an LA surface's format (a surface's first wrapper, a fetch copy of one)
void vg_texture_make_la(VGMTLTexture *t) {
    if (t && t->_type == MTLTextureType2D) {
        vg_texture_la_view(t, VK_IMAGE_VIEW_TYPE_2D, (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT, 0,
                                                                               (uint32_t)t->_mips, 0, 1});
    }
}

// What a sampling view (and a copy) of a format covers: depth of a depth-stencil format, stencil of a stencil-only one.
static VkImageAspectFlags vg_view_aspect(VkImageAspectFlags a) {
    return (a & VK_IMAGE_ASPECT_DEPTH_BIT) ? VK_IMAGE_ASPECT_DEPTH_BIT : a;
}

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

// ---- display-surface twins (5c) ------------------------------------------------------------------------------------

#import <IOKit/IOKitLib.h>
#include "../../kext/VirtioGPUUserAPI.h"

static io_connect_t vg_twin_conn(void) {
    static io_connect_t conn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kVGUCAccelClass));
        if (s && IOServiceOpen(s, mach_task_self(), kVGUCAccelType, &conn) != KERN_SUCCESS) {
            conn = 0;
        }
        if (s) {
            IOObjectRelease(s);
        }
    });
    return conn;
}

static BOOL vg_twins_on(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("VGMTL_TWIN");
        on = !strcmp(getprogname(), "WindowServer") && !(e && e[0] == '0');
    }
    return on;
}

// Twinned surfaces by id (weak), for snapshots of what the screen shows.
static NSMapTable<NSNumber *, VGMTLTexture *> *gTwinned;
static void vg_twinned_add(VGMTLTexture *t) {
    @synchronized([VGMTLTexture class]) {
        if (!gTwinned) {
            gTwinned = [NSMapTable strongToWeakObjectsMapTable];
        }
        [gTwinned setObject:t forKey:@(IOSurfaceGetID(t->_surface))];
    }
}
VGMTLTexture *vg_twinned_shown(void) {
    static io_service_t accel;
    if (!accel) {
        accel = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kVGUCAccelClass));
    }
    CFTypeRef v = accel ? IORegistryEntryCreateCFProperty(accel, CFSTR("VirtioGPUShownSurface"), NULL, 0) : NULL;
    uint32_t id = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(v, kCFNumberSInt32Type, &id);
    }
    if (v) {
        CFRelease(v);
    }
    @synchronized([VGMTLTexture class]) {
        return id ? [gTwinned objectForKey:@(id)] : nil;
    }
}

// Surfaces WindowServer writes in display command buffers that the display never scans out (round 23, VM 109 at
// 2880x1800 shared over Screen Sharing): a window flattened for an effect ("flattened-surface": the genie, a window
// dragged while the screen is shared), a screenshot's "CaptureSurface", and Selective Sharing. Each got a twin all
// the same, a copy into host memory at every write on top of its write-back, and each new flattened window a fresh
// pair of host allocations: shared, a genie took 66 ms a frame and a window drag 41.5 ms; without these twins, 34-38
// and 18.9 ms. SkyLight's display stream ("DisplayStream surface N/8", what Screen Sharing reads) keeps its twin:
// without it, frames came faster still but a dragged window left trails in what Screen Sharing showed (the VM's own
// screen was clean, and every stream frame was copied back whole); why the twin's copy prevents them is open. The
// flag file VirtioGPUMetal-twinall gives every surface its twin again, and VirtioGPUMetal-twindrop (a piece of a surface
// name a line, e.g. "DisplayStream") takes the twin from those surfaces too, for live A/Bs; both rechecked every 2 s.
static NSArray<NSString *> *gTwinDrop;
static uint32_t gTwinDropEpoch = 1;
static void vg_twindrop_reload(void) {
    NSString *s = [NSString stringWithContentsOfFile:@"/Library/GPUBundles/VirtioGPUMetal-twindrop"
                                            encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        NSString *n = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (n.length) {
            [names addObject:n];
        }
    }
    @synchronized([VGMTLTexture class]) {   // committing threads read it
        if (![names isEqualToArray:gTwinDrop ?: @[]]) {
            gTwinDrop = names.count ? [names copy] : nil;
            gTwinDropEpoch++;
            vglog("twindrop: %s", names.count ? [names componentsJoinedByString:@", "].UTF8String : "(none)");
        }
    }
}
static BOOL vg_surface_never_shown(VGMTLTexture *t) {
    static int all = -1;
    static uint64_t checked;
    const uint64_t now = vg_now();
    if (all < 0 || now - checked > 2000000000ull) {
        all = vg_debug_flag("twinall");
        vg_twindrop_reload();
        checked = now;
    }
    if (all) {
        return NO;
    }
    NSArray<NSString *> *drop;
    uint32_t epoch;
    @synchronized([VGMTLTexture class]) {
        drop = gTwinDrop;
        epoch = gTwinDropEpoch;
    }
    if (t->_neverShown == 0 || t->_neverShownEpoch != epoch) {
        t->_neverShown = -1;
        t->_neverShownEpoch = epoch;
        CFTypeRef nm = IOSurfaceCopyValue(t->_surface, kIOSurfaceName);
        if (nm && CFGetTypeID(nm) == CFStringGetTypeID()) {
            static const CFStringRef kNames[] = {CFSTR("flattened-surface"), CFSTR("CaptureSurface"),
                                                 CFSTR("Selective Sharing")};
            for (size_t i = 0; i < sizeof(kNames) / sizeof(kNames[0]); i++) {
                if (CFStringFind((CFStringRef)nm, kNames[i], 0).location != kCFNotFound) {
                    t->_neverShown = 1;
                    break;
                }
            }
            for (NSString *piece in drop) {
                if (t->_neverShown != 1 && [(__bridge NSString *)nm containsString:piece]) {
                    t->_neverShown = 1;
                }
            }
        }
        if (nm) {
            CFRelease(nm);
        }
    }
    return t->_neverShown == 1;
}

BOOL vg_twin_ensure(VGMTLTexture *t) {
    if (t->_surface && !t->_plane && !t->_parent && vg_surface_never_shown(t)) {
        return NO;   // nothing scans it out: no twin, no copy into one (one made under twinall goes unused)
    }
    if (t->_twinRes) {
        return YES;
    }
    if (!vg_twins_on() || !t->_surface || t->_plane || t->_parent || t->_width < 640 || t->_height < 480 ||
        (t->_pixelFormat != MTLPixelFormatBGRA8Unorm && t->_pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB)) {
        return NO;
    }
    if (t->_twinRefused) {
        return NO;   // refused before: don't try every frame
    }
    const uint32_t stride = (uint32_t)t->_width * 4;
    if (vg_buffer_create((VkDeviceSize)stride * t->_height, &t->_twin)) {
        return NO;
    }
    uint32_t res = vg_memory_res_id(t->_twin.memory), res2 = 0;
    // the second (round 17); one will do. /Library/GPUBundles/VirtioGPUMetal-onetwin keeps to one.
    if (!vg_debug_flag("onetwin") && !vg_buffer_create((VkDeviceSize)stride * t->_height, &t->_twin2)) {
        res2 = vg_memory_res_id(t->_twin2.memory);
    }
    io_connect_t c = vg_twin_conn();
    uint64_t in[6] = {IOSurfaceGetID(t->_surface), res, t->_width, t->_height, stride, res2};
    kern_return_t kr = res && c ? IOConnectCallScalarMethod(c, kVGUCSetTwin, in, 6, NULL, NULL) : KERN_FAILURE;
    vglog("twin for surface %u (%lux%lu): blobs %u %u -> 0x%x", IOSurfaceGetID(t->_surface), (unsigned long)t->_width,
          (unsigned long)t->_height, res, res2, kr);
    if (!res2) {
        vg_buffer_destroy(&t->_twin2);
    }
    if (kr != KERN_SUCCESS) {
        vg_buffer_destroy(&t->_twin);   // not the screen's: keep the write-back, and don't hold 4 MB for nothing
        vg_buffer_destroy(&t->_twin2);
        t->_twinRefused = YES;
        return NO;
    }
    t->_twinRes = res;
    vg_twinned_add(t);
    return YES;
}

// ---- display snapshots (5c round 6) --------------------------------------------------------------------------------
// What the display scans out, as a PNG, for checking a change without anyone looking at the screen: write a number
// to /Library/GPUBundles/VirtioGPUMetal-snap, and at the next display frame the twin the kext flipped to last
// (VirtioGPUShownSurface) is saved as <WindowServer's Darwin cache dir>/local.homelab.VirtioGPUMetal/snap-<number>.png.
#include <zlib.h>

static void vg_png_chunk(FILE *f, const char *type, const uint8_t *data, uint32_t len) {
    uint8_t be[4] = {len >> 24, len >> 16, len >> 8, len};
    fwrite(be, 1, 4, f);
    fwrite(type, 1, 4, f);
    if (len) {
        fwrite(data, 1, len, f);
    }
    uLong crc = crc32(0, (const Bytef *)type, 4);
    crc = crc32(crc, data, len);
    uint8_t c[4] = {crc >> 24, crc >> 16, crc >> 8, crc};
    fwrite(c, 1, 4, f);
}

static void vg_write_png(const char *path, const uint8_t *bgra, uint32_t w, uint32_t h, uint32_t stride) {
    size_t rowBytes = 1 + (size_t)w * 3, rawLen = rowBytes * h;
    uint8_t *raw = malloc(rawLen);
    if (!raw) {
        return;
    }
    for (uint32_t y = 0; y < h; y++) {
        uint8_t *o = raw + y * rowBytes;
        const uint8_t *in = bgra + (size_t)y * stride;
        *o++ = 0;
        for (uint32_t x = 0; x < w; x++, in += 4) {
            *o++ = in[2], *o++ = in[1], *o++ = in[0];
        }
    }
    uLongf zlen = compressBound(rawLen);
    uint8_t *z = malloc(zlen);
    if (z && compress2(z, &zlen, raw, rawLen, 3) == Z_OK) {
        FILE *f = fopen(path, "wb");
        if (f) {
            static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a};
            fwrite(sig, 1, 8, f);
            uint8_t ihdr[13] = {w >> 24, w >> 16, w >> 8, w, h >> 24, h >> 16, h >> 8, h, 8, 2, 0, 0, 0};
            vg_png_chunk(f, "IHDR", ihdr, 13);
            vg_png_chunk(f, "IDAT", z, (uint32_t)zlen);
            vg_png_chunk(f, "IEND", NULL, 0);
            fclose(f);
        }
    }
    free(z);
    free(raw);
}

// The number asked for (0: none), looked at no more than 4 times a second.
int vg_snap_wanted(void) {
    static uint64_t lastCheck;
    static int served = -1;
    uint64_t now = vg_now();
    if (now - lastCheck < 250000000ull) {
        return 0;
    }
    lastCheck = now;
    FILE *f = fopen("/Library/GPUBundles/VirtioGPUMetal-snap", "r");
    if (!f) {
        return 0;
    }
    int n = 0;
    if (fscanf(f, "%d", &n) != 1) {
        n = 0;
    }
    fclose(f);
    if (n <= 0 || n == served) {
        return 0;
    }
    served = n;
    return n;
}

void vg_snap_write(VGMTLTexture *t, int number) {
    char base[PATH_MAX];
    const vg_buffer *tw = t->_twinUse && t->_twin2.map ? &t->_twin2 : &t->_twin;   // the one the last frame went into
    if (!tw->map || !confstr(_CS_DARWIN_USER_CACHE_DIR, base, sizeof(base))) {
        return;
    }
    char path[PATH_MAX + 80];
    snprintf(path, sizeof(path), "%slocal.homelab.VirtioGPUMetal/snap-%d.png", base, number);
    vg_write_png(path, tw->map, (uint32_t)t->_width, (uint32_t)t->_height, (uint32_t)t->_width * 4);
    vglog("snapshot %d: surface %u -> %s", number, IOSurfaceGetID(t->_surface), path);
}

// Returns whether a display transaction has shown the surface yet (core 0.5.5; an older core says no, which keeps
// the CPU write-back: slower, never wrong).
BOOL vg_twin_mark(uint32_t surface, uint32_t frame, BOOL ready, uint32_t *use) {
    if (use) {
        *use = 0;
    }
    io_connect_t c = vg_twin_conn();
    if (c) {
        uint64_t in[3] = {surface, frame, ready ? 1 : 0}, out[2] = {0, 0};
        uint32_t n = 2;
        if (IOConnectCallScalarMethod(c, kVGUCTwinMark, in, 3, out, &n) == KERN_SUCCESS && n >= 1) {
            if (use && n >= 2) {
                *use = (uint32_t)out[1] & 1;   // core 0.5.8; an older one says nothing: the first twin
            }
            return out[0] != 0;
        }
    }
    return NO;
}

void vg_twin_forget(VGMTLTexture *t) {
    if (t->_twinRes && t->_surface) {
        uint64_t in[5] = {IOSurfaceGetID(t->_surface), 0, 0, 0, 0};
        io_connect_t c = vg_twin_conn();
        if (c) {
            IOConnectCallScalarMethod(c, kVGUCSetTwin, in, 5, NULL, NULL);
        }
    }
    t->_twinRes = 0;
    t->_twinUse = 0;
    vg_buffer_destroy(&t->_twin);   // destroying the blob also takes it off the screen (the kext)
    vg_buffer_destroy(&t->_twin2);
}

// ---- staging pool (5c) ---------------------------------------------------------------------------------------------

// Buffers too (5c round 6): Core Animation makes and drops buffers and surface textures every frame while an app
// scrolls, and creating one costs a host-visible allocation plus a map (vn_MapMemory, ~35 % of WindowServer's thread).
enum { kPoolMax = 160 };
static const VkDeviceSize kPoolBytesMax = 256ull << 20;
static pthread_mutex_t gPoolLock = PTHREAD_MUTEX_INITIALIZER;
static vg_buffer gPool[kPoolMax];
static int gPoolN;
static VkDeviceSize gPoolBytes;

int vg_staging_get(VkDeviceSize size, vg_buffer *out) {
    pthread_mutex_lock(&gPoolLock);
    int best = -1;
    for (int i = 0; i < gPoolN; i++) {   // the smallest that fits, and not more than twice the size
        if (gPool[i].size >= size && gPool[i].size <= 2 * size + (size < 65536 ? 4096 : 65536) &&
            (best < 0 || gPool[i].size < gPool[best].size)) {
            best = i;
        }
    }
    if (best >= 0) {
        *out = gPool[best];
        gPoolBytes -= out->size;
        memmove(&gPool[best], &gPool[best + 1], sizeof(gPool[0]) * (size_t)(--gPoolN - best));
        pthread_mutex_unlock(&gPoolLock);
        vg_perf(VG_PERF_POOL_HIT, size, 0);
        return 0;
    }
    int poolN = gPoolN;
    VkDeviceSize poolBytes = gPoolBytes;
    pthread_mutex_unlock(&gPoolLock);
    static _Atomic int missLogged;
    if (missLogged < 30 && vg_perf_on()) {
        missLogged++;
        vglog("pool miss: %llu bytes (pool %d buffers, %llu MB)", (unsigned long long)size, poolN,
              (unsigned long long)(poolBytes >> 20));
    }
    // sizes repeat (surfaces, glyph uploads): round, small ones to a power of two from 4 KB
    VkDeviceSize rounded = (size + 65535) & ~(VkDeviceSize)65535;
    if (size < 65536) {
        rounded = 4096;
        while (rounded < size) {
            rounded <<= 1;
        }
    }
    uint64_t t0 = vg_now();
    int r = vg_buffer_create(rounded, out);
    vg_perf(VG_PERF_POOL_MISS, rounded, vg_now() - t0);
    return r;
}

void vg_staging_put(vg_buffer *b) {
    if (!b->buffer) {
        return;
    }
    // A full pool makes room by dropping its oldest buffers (5d): it used to destroy the one coming back, so once an
    // app's mix of sizes had filled it (WebKit's GPU process), the sizes it needed every frame were made again each
    // time (~9 ms each through Venus) while ones nobody asked for sat in the pool.
    vg_buffer evict[kPoolMax];
    int nevict = 0;
    pthread_mutex_lock(&gPoolLock);
    if (b->size <= kPoolBytesMax / 4) {
        while (gPoolN > 0 && (gPoolN >= kPoolMax || gPoolBytes + b->size > kPoolBytesMax)) {
            evict[nevict++] = gPool[0];
            gPoolBytes -= gPool[0].size;
            memmove(&gPool[0], &gPool[1], sizeof(gPool[0]) * (size_t)(--gPoolN));
        }
        gPool[gPoolN++] = *b;   // newest last: eviction takes from the front
        gPoolBytes += b->size;
        pthread_mutex_unlock(&gPoolLock);
        memset(b, 0, sizeof(*b));
        for (int i = 0; i < nevict; i++) {
            vg_buffer_destroy(&evict[i]);
        }
        return;
    }
    pthread_mutex_unlock(&gPoolLock);
    vg_buffer_destroy(b);
}

// ---- deferred work (5c) --------------------------------------------------------------------------------------------

typedef struct {
    int kind;   // 0 init, 1 copy, 2 image -> staging -> image (round 23)
    VkImage image;
    VkImageAspectFlags aspect;
    uint32_t mips, layers;
    VkBuffer src;
    VkBufferImageCopy copy;
    vg_buffer staging;   // owned when .buffer is set
    VkImage from;        // kind 2: the source image, read into staging by copy0; then staging -> image by copy
    VkBufferImageCopy copy0;
    void *fromOwner;     // kind 2: the source image's texture, retained until the copy has run
} vg_pending_op;

static pthread_mutex_t gPendingLock = PTHREAD_MUTEX_INITIALIZER;
static vg_pending_op *gPending;
static size_t gPendingCount, gPendingCap;

static void vg_pending_push(const vg_pending_op *op) {
    pthread_mutex_lock(&gPendingLock);
    if (gPendingCount == gPendingCap) {
        gPendingCap = gPendingCap ? gPendingCap * 2 : 64;
        gPending = realloc(gPending, gPendingCap * sizeof(*gPending));
    }
    gPending[gPendingCount++] = *op;
    pthread_mutex_unlock(&gPendingLock);
}

void vg_pending_init_image(VkImage image, VkImageAspectFlags aspect, uint32_t mips, uint32_t layers) {
    vg_pending_op op = {0, image, aspect, mips, layers};
    vg_pending_push(&op);
}

void vg_pending_copy(VkBuffer src, VkImage dst, const VkBufferImageCopy *c, const vg_buffer *staging) {
    vg_pending_op op = {1, dst};
    op.src = src;
    op.copy = *c;
    if (staging) {
        op.staging = *staging;
    }
    vg_pending_push(&op);
}

void vg_pending_image_copy(VkImage from, id srcOwner, VkImage dst, const VkBufferImageCopy *c1,
                           const VkBufferImageCopy *c2, const vg_buffer *staging) {
    vg_pending_op op = {2, dst};
    op.from = from;
    op.copy0 = *c1;
    op.copy = *c2;
    op.staging = *staging;
    op.src = staging->buffer;
    op.fromOwner = (__bridge_retained void *)srcOwner;
    vg_pending_push(&op);
}

// Taking the deferred work and submitting it are one step under this lock (see vg_submit and vg.h).
static pthread_mutex_t gSubmitLock = PTHREAD_MUTEX_INITIALIZER;

void vg_pending_forget(VkImage image) {
    // source textures released outside the lock (their dealloc comes back here)
    __attribute__((objc_precise_lifetime)) NSMutableArray *drop = [NSMutableArray array];
    // Under the submit lock too: work taken for a submit that fails goes back on the list (vg_submit), and an image
    // forgotten in between would come back with it.
    pthread_mutex_lock(&gSubmitLock);
    pthread_mutex_lock(&gPendingLock);
    size_t w = 0;
    for (size_t i = 0; i < gPendingCount; i++) {
        if (gPending[i].image == image) {
            vg_staging_put(&gPending[i].staging);
            if (gPending[i].fromOwner) {
                [drop addObject:(__bridge_transfer id)gPending[i].fromOwner];
            }
        } else {
            gPending[w++] = gPending[i];
        }
    }
    gPendingCount = w;
    pthread_mutex_unlock(&gPendingLock);
    pthread_mutex_unlock(&gSubmitLock);
}

// Everything waiting, off the list (NULL when nothing is).
static vg_pending_op *vg_pending_take(size_t *count) {
    pthread_mutex_lock(&gPendingLock);
    size_t n = gPendingCount;
    vg_pending_op *ops = n ? malloc(n * sizeof(*ops)) : NULL;
    if (n) {
        memcpy(ops, gPending, n * sizeof(*ops));
    }
    gPendingCount = 0;
    pthread_mutex_unlock(&gPendingLock);
    *count = n;
    return ops;
}

// Taken work back at the head of the list, ahead of what came since, for the next submit: the ops own their stagings
// and source textures again (vg_pending_record_ops handed both to *owned, which the caller drops unreleased).
static void vg_pending_restore(vg_pending_op *ops, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (ops[i].kind == 2 && ops[i].fromOwner) {
            CFRetain(ops[i].fromOwner);
        }
    }
    pthread_mutex_lock(&gPendingLock);
    if (gPendingCount + n > gPendingCap) {
        gPendingCap = gPendingCount + n + 64;
        gPending = realloc(gPending, gPendingCap * sizeof(*gPending));
    }
    memmove(gPending + n, gPending, gPendingCount * sizeof(*gPending));
    memcpy(gPending, ops, n * sizeof(*ops));
    gPendingCount += n;
    pthread_mutex_unlock(&gPendingLock);
}

// Records ops into cb (barriers around it); the stagings to destroy after cb completes go to *owned (an array of
// vg_buffer the caller frees with vg_pending_release), with the source textures kept alive until then.
static void vg_pending_record_ops(VkCommandBuffer cb, const vg_pending_op *ops, size_t n, NSMutableData **owned) {
    // Inits first (UNDEFINED -> GENERAL for life), then whatever came before this point is visible to the copies.
    for (size_t i = 0; i < n; i++) {
        if (ops[i].kind != 0) {
            continue;
        }
        VkImageMemoryBarrier ib = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0,
                                   VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT, VK_IMAGE_LAYOUT_UNDEFINED,
                                   VK_IMAGE_LAYOUT_GENERAL, VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ops[i].image,
                                   {ops[i].aspect, 0, ops[i].mips, 0, ops[i].layers}};
        gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0,
                                 NULL, 1, &ib);
    }
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT | VK_ACCESS_HOST_WRITE_BIT,
                          VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT};
    gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT,
                             VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
    NSMutableData *keep = [NSMutableData data];
    NSMutableArray *owners = nil;
    for (size_t i = 0; i < n; i++) {
        if (ops[i].kind == 2) {
            // Between images of one surface (round 23): whatever was copied before is in (a CPU pull of the source,
            // say), the source into staging, then staging into the image, and the copies after see it.
            VkMemoryBarrier b0 = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT,
                                  VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT};
            gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &b0,
                                     0, NULL, 0, NULL);
            gVk.vkCmdCopyImageToBuffer(cb, ops[i].from, VK_IMAGE_LAYOUT_GENERAL, ops[i].src, 1, &ops[i].copy0);
            VkMemoryBarrier b1 = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT,
                                  VK_ACCESS_TRANSFER_READ_BIT};
            gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &b1, 0,
                                     NULL, 0, NULL);
            gVk.vkCmdCopyBufferToImage(cb, ops[i].src, ops[i].image, VK_IMAGE_LAYOUT_GENERAL, 1, &ops[i].copy);
            VkMemoryBarrier b2 = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT,
                                  VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT};
            gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &b2, 0,
                                     NULL, 0, NULL);
            [keep appendBytes:&ops[i].staging length:sizeof(vg_buffer)];
            if (!owners) {
                owners = [NSMutableArray array];
            }
            [owners addObject:(__bridge_transfer id)ops[i].fromOwner];
        } else if (ops[i].kind == 1) {
            gVk.vkCmdCopyBufferToImage(cb, ops[i].src, ops[i].image, VK_IMAGE_LAYOUT_GENERAL, 1, &ops[i].copy);
            if (ops[i].staging.buffer) {
                [keep appendBytes:&ops[i].staging length:sizeof(vg_buffer)];
            }
        }
    }
    if (owners) {   // the source textures live as long as the stagings do: until the command buffer has run
        objc_setAssociatedObject(keep, &gPendingLock, owners, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    VkMemoryBarrier after = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT,
                             VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT};
    gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &after, 0,
                             NULL, 0, NULL);
    vg_perf(VG_PERF_DEFERRED, n, 0);
    *owned = keep.length || owners ? keep : nil;
}

void vg_pending_release(NSMutableData *owned) {
    vg_buffer *b = owned.mutableBytes;
    for (NSUInteger i = 0; i < owned.length / sizeof(vg_buffer); i++) {
        vg_staging_put(&b[i]);
    }
}

// ---- command pools and submission -----------------------------------------------------------------------------

static pthread_mutex_t gCmdPoolLock = PTHREAD_MUTEX_INITIALIZER;
static VkCommandPool gCmdPools[32];   // free pools; more in flight at once are made, and destroyed beyond these
static int gNCmdPools;

VkCommandPool vg_cmdpool_get(void) {
    pthread_mutex_lock(&gCmdPoolLock);
    if (gNCmdPools) {
        VkCommandPool p = gCmdPools[--gNCmdPools];
        pthread_mutex_unlock(&gCmdPoolLock);
        return p;
    }
    pthread_mutex_unlock(&gCmdPoolLock);
    VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
                                   VK_COMMAND_POOL_CREATE_TRANSIENT_BIT, gVk.queueFamily};
    VkCommandPool p = VK_NULL_HANDLE;
    VkResult r = gVk.vkCreateCommandPool(gVk.device, &pci, NULL, &p);
    if (r != VK_SUCCESS) {
        vglog("vulkan: vkCreateCommandPool %d", r);
        return VK_NULL_HANDLE;
    }
    return p;
}

void vg_cmdpool_put(VkCommandPool pool) {
    if (!pool) {
        return;
    }
    pthread_mutex_lock(&gCmdPoolLock);
    if (gNCmdPools < (int)(sizeof(gCmdPools) / sizeof(gCmdPools[0]))) {
        gCmdPools[gNCmdPools++] = pool;
        pthread_mutex_unlock(&gCmdPoolLock);
        return;
    }
    pthread_mutex_unlock(&gCmdPoolLock);
    gVk.vkDestroyCommandPool(gVk.device, pool, NULL);
}

VkResult vg_submit(VkCommandPool pool, const VkCommandBuffer *cbs, uint32_t count, VkFence fence,
                   VkCommandBuffer *pendingCb, NSMutableData **owned) {
    VkCommandBuffer all[8];
    if (count > 7) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    // The flag files VirtioGPUMetal-failpendingalloc and -failpendingsubmit (one line per process name, as every
    // flag) make the first submit with deferred work in such a process fail: its command buffer can't be allocated,
    // or the submit itself fails after the work was recorded. tools/mtlorder's allocfail case.
    static int failOnce = -1, failSubmitOnce = -1;
    uint32_t n = 0;
    *pendingCb = VK_NULL_HANDLE;
    *owned = nil;
    NSMutableData *taken = nil;   // dropped outside the lock: it may hold the last reference to a texture
    pthread_mutex_lock(&gSubmitLock);
    if (failOnce < 0) {
        failOnce = vg_debug_flag("failpendingalloc") ? 1 : 0;
        failSubmitOnce = vg_debug_flag("failpendingsubmit") ? 1 : 0;
    }
    size_t nops = 0;
    vg_pending_op *ops = vg_pending_take(&nops);
    VkCommandBuffer pcb = VK_NULL_HANDLE;
    if (nops) {
        VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool,
                                          VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
        VkResult ar = failOnce == 1 ? VK_ERROR_OUT_OF_HOST_MEMORY : gVk.vkAllocateCommandBuffers(gVk.device, &ai, &pcb);
        failOnce = failOnce == 1 ? 0 : failOnce;
        if (ar != VK_SUCCESS) {
            // Without the deferred work the command buffers after it could read an image with no pixels yet (or not
            // even initialized) and still complete: none of it is submitted, and the work waits for the next submit.
            vg_pending_restore(ops, nops);
            pthread_mutex_unlock(&gSubmitLock);
            free(ops);
            vglog("submit: no command buffer for %zu deferred operation(s) (%d): not submitted, the work kept", nops, ar);
            return ar;
        }
        VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                       VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
        gVk.vkBeginCommandBuffer(pcb, &bi);
        vg_pending_record_ops(pcb, ops, nops, &taken);
        gVk.vkEndCommandBuffer(pcb);
        all[n++] = pcb;
    }
    memcpy(all + n, cbs, count * sizeof(*cbs));
    n += count;
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, n, all, 0, NULL};
    VkResult r = VK_ERROR_OUT_OF_DEVICE_MEMORY;
    if (nops && failSubmitOnce == 1) {
        failSubmitOnce = 0;
    } else {
        pthread_mutex_lock(&gVk.lock);
        r = gVk.vkQueueSubmit(gVk.queue, 1, &si, fence);
        pthread_mutex_unlock(&gVk.lock);
    }
    if (r != VK_SUCCESS && nops) {
        vg_pending_restore(ops, nops);   // for the next submit; nothing of it ran
    }
    pthread_mutex_unlock(&gSubmitLock);
    free(ops);
    if (r != VK_SUCCESS) {
        if (nops) {
            vglog("submit: vkQueueSubmit %d: %zu deferred operation(s) kept for the next submit", r, nops);
            gVk.vkFreeCommandBuffers(gVk.device, pool, 1, &pcb);
        }
        taken = nil;   // the ops own their stagings and source textures again
        return r;
    }
    *pendingCb = pcb;
    *owned = taken;
    return r;
}

// ---- one-shot command buffers ------------------------------------------------------------------------------------

BOOL vg_one_shot(void (^record)(VkCommandBuffer cb)) {
    uint64_t t0 = vg_now();
    VkCommandPool pool = vg_cmdpool_get();
    if (!pool) {
        return NO;
    }
    VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool,
                                      VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb = VK_NULL_HANDLE;
    VkResult r = gVk.vkAllocateCommandBuffers(gVk.device, &ai, &cb);
    if (r != VK_SUCCESS) {
        vg_cmdpool_put(pool);
        return NO;
    }
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                   VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    gVk.vkBeginCommandBuffer(cb, &bi);
    // Whatever earlier command buffers did (the deferred work vg_submit puts just ahead of this one included) is
    // visible to this one, and this one's writes to the host.
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
    VkCommandBuffer pendingCb = VK_NULL_HANDLE;
    NSMutableData *owned = nil;
    r = vg_submit(pool, &cb, 1, fence, &pendingCb, &owned);
    if (r == VK_SUCCESS) {
        gVk.vkWaitForFences(gVk.device, 1, &fence, VK_TRUE, UINT64_MAX);
    }
    gVk.vkDestroyFence(gVk.device, fence, NULL);
    vgtrace("one-shot: done (%d)", r);
    gVk.vkFreeCommandBuffers(gVk.device, pool, 1, &cb);
    if (pendingCb) {
        gVk.vkFreeCommandBuffers(gVk.device, pool, 1, &pendingCb);
    }
    vg_cmdpool_put(pool);
    vg_pending_release(owned);
    vg_perf(VG_PERF_ONESHOT, 0, vg_now() - t0);
    return r == VK_SUCCESS;
}

// ---- MTLTexture --------------------------------------------------------------------------------------------------

@implementation VGMTLTexture
@synthesize label = _label;
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)identity { return KERN_SUCCESS; }   // memory accounting (5d)
- (void)didModifyData { }   // IOSurface contents are pulled by seed anyway
- (id<MTLDevice>)device { return _dev; }
- (void)dealloc {
    if (_twin.buffer) {
        vg_twin_forget(self);
    }
    if (!_parent && _shareRes) {
        vg_texture_share_dealloc(self);   // its image memory goes with it: no longer offered to other processes
    }
    if (_surface) {
        CFRelease(_surface);
    }
    vg_staging_put(&_staging);   // back to the pool (5c round 6)
    if (_view) {
        gVk.vkDestroyImageView(gVk.device, _view, NULL);
    }
    if (_attView) {
        gVk.vkDestroyImageView(gVk.device, _attView, NULL);
    }
    if (_sampleView) {
        gVk.vkDestroyImageView(gVk.device, _sampleView, NULL);
    }
    if (_parent) {
        return;   // a view: the image and its memory are the parent's
    }
    if (_image) {
        vg_pending_forget(_image);
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
- (NSUInteger)arrayLength {
    return _type == MTLTextureTypeCube ? 1 : _type == MTLTextureTypeCubeArray ? _layers / 6 : _layers;
}
- (NSUInteger)sampleCount { return _parent ? MAX(_parent->_samples, 1) : MAX(_samples, 1); }
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
    if (!_swz.red && !_swz.green && !_swz.blue && !_swz.alpha) {
        return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
                                             MTLTextureSwizzleAlpha);
    }
    return _swz;
}
- (uint32_t)swizzleKey {   // 5d: Apple's GL renderer
    MTLTextureSwizzleChannels c = [self swizzle];
    return (uint32_t)c.red | (uint32_t)c.green << 8 | (uint32_t)c.blue << 16 | (uint32_t)c.alpha << 24;
}
- (BOOL)isWriteComplete { return YES; }   // reads wait for writes themselves (getBytes)
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pf textureType:(MTLTextureType)type levels:(NSRange)levels
                                         slices:(NSRange)slices swizzle:(MTLTextureSwizzleChannels)swz {
    return vg_texture_view_swz(self, pf, type, levels, slices, swz);
}

// Copies between the image and a staging buffer laid out with Metal's bytesPerRow / bytesPerImage.
- (BOOL)copyRegion:(MTLRegion)region level:(NSUInteger)level slice:(NSUInteger)slice bytes:(void *)bytes
       bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi toImage:(BOOL)toImage {
    const vg_format *f = vg_format_of(_pixelFormat);
    if (!f || !region.size.width || !region.size.height || !region.size.depth) {
        return NO;
    }
    if (!bpr) {   // Metal allows 0 for 1D textures
        bpr = region.size.width * f->bytes;
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
    if (vg_staging_get(size, &staging)) {
        return NO;
    }
    if (toImage) {
        memcpy(staging.map, bytes, size);
    }
    VkBufferImageCopy c = {0, (uint32_t)(bpr / f->bytes), (uint32_t)(bpi / bpr),
                           {vg_view_aspect(f->aspect), (uint32_t)level, (uint32_t)slice, 1},
                           {(int32_t)region.origin.x, (int32_t)region.origin.y, (int32_t)region.origin.z},
                           {(uint32_t)region.size.width, (uint32_t)rows, (uint32_t)depth}};
    VkImage image = _image;
    vgtrace("texture: %s %ux%u level %lu, row length %u, %lu staging bytes", toImage ? "upload" : "readback",
            c.imageExtent.width, c.imageExtent.height, (unsigned long)level, c.bufferRowLength, (unsigned long)size);
    if (toImage) {
        // An upload: the bytes are in staging now (replaceRegion's contract), the GPU copy waits for the next submit.
        vg_pending_copy(staging.buffer, image, &c, &staging);
        vg_perf(VG_PERF_UPLOAD, size, 0);
        return YES;
    }
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
    vg_staging_put(&staging);
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

static BOOL vg_surface_tagged(VGMTLTexture *t, uint32_t seed);
static void vg_surface_tag(VGMTLTexture *t, uint32_t seed);
// External memory for the next vg_new_texture on this thread (5d sharing): 0 none, 1 exportable, 2 imported from fd.
static __thread int gVgExt;
static __thread int gVgImportFd = -1;
static __thread const uint64_t *gVgImportParams;

static VGMTLTexture *vg_new_texture_impl(id<MTLDevice> device, MTLTextureDescriptor *d, BOOL clearColor) {
    const vg_format *f = vg_format_of(d.pixelFormat);
    if (vg_vulkan_init() || !f) {
        vglog("texture: pixel format %lu not supported yet", (unsigned long)d.pixelFormat);
        return nil;
    }
    VkImageType itype;
    VkImageViewType vtype;
    switch (d.textureType) {
    case MTLTextureType1D: itype = VK_IMAGE_TYPE_1D, vtype = VK_IMAGE_VIEW_TYPE_1D; break;
    case MTLTextureType1DArray: itype = VK_IMAGE_TYPE_1D, vtype = VK_IMAGE_VIEW_TYPE_1D_ARRAY; break;   // CoreDisplay's LUTs
    case MTLTextureType2D: itype = VK_IMAGE_TYPE_2D, vtype = VK_IMAGE_VIEW_TYPE_2D; break;
    case MTLTextureType2DArray: itype = VK_IMAGE_TYPE_2D, vtype = VK_IMAGE_VIEW_TYPE_2D_ARRAY; break;
    case MTLTextureType3D: itype = VK_IMAGE_TYPE_3D, vtype = VK_IMAGE_VIEW_TYPE_3D; break;
    case MTLTextureType2DMultisample: itype = VK_IMAGE_TYPE_2D, vtype = VK_IMAGE_VIEW_TYPE_2D; break;   // 5d
    case MTLTextureType2DMultisampleArray: itype = VK_IMAGE_TYPE_2D, vtype = VK_IMAGE_VIEW_TYPE_2D_ARRAY; break;
    // A cube: six layers (+X -X +Y -Y +Z -Z, Metal's slice order and Vulkan's), seen as a cube (the Memoji's lighting)
    case MTLTextureTypeCube: itype = VK_IMAGE_TYPE_2D, vtype = VK_IMAGE_VIEW_TYPE_CUBE; break;
    case MTLTextureTypeCubeArray: itype = VK_IMAGE_TYPE_2D, vtype = VK_IMAGE_VIEW_TYPE_CUBE_ARRAY; break;
    default:
        vglog("texture: type %lu not supported yet", (unsigned long)d.textureType);
        return nil;
    }
    // Multisampling (5d): a sample count the device renders with for this kind of attachment.
    NSUInteger samples = 0;
    if (d.sampleCount > 1) {
        VkSampleCountFlags have = (f->aspect & VK_IMAGE_ASPECT_COLOR_BIT) ? gVk.props.limits.framebufferColorSampleCounts
                                                                           : gVk.props.limits.framebufferDepthSampleCounts;
        if (!(have & d.sampleCount) || d.mipmapLevelCount > 1) {
            vglog("texture: %lu samples not supported for format %lu", (unsigned long)d.sampleCount, (unsigned long)d.pixelFormat);
            return nil;
        }
        samples = d.sampleCount;
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
    const VkImageUsageFlags rw = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    // MTLTextureUsageUnknown (0) allows every use, a render target's included: such a texture drawn into and read in
    // place without this bit stays compressed on the Iris Xe, and its reads come back as the compression's blocks.
    if (gVk.feedbackLoop && (usage & rw) == rw &&
        ((d.usage & MTLTextureUsageRenderTarget) || d.usage == MTLTextureUsageUnknown)) {
        usage |= VK_IMAGE_USAGE_ATTACHMENT_FEEDBACK_LOOP_BIT_EXT;   // framebuffer fetch in place (mode 4)
    }
    VGMTLTexture *t = [VGMTLTexture new];
    t->_samples = samples;
    t->_swz = d.swizzle;
    t->_dev = device;
    t->_pixelFormat = d.pixelFormat;
    t->_format = f->vk;
    t->_aspect = f->aspect;
    t->_type = d.textureType;
    t->_width = MAX(d.width, 1);
    t->_height = d.textureType == MTLTextureType1D || d.textureType == MTLTextureType1DArray ? 1 : MAX(d.height, 1);
    t->_depth = d.textureType == MTLTextureType3D ? MAX(d.depth, 1) : 1;
    t->_mips = MAX(d.mipmapLevelCount, 1);
    t->_layers = d.textureType == MTLTextureType2DArray || d.textureType == MTLTextureType1DArray ? MAX(d.arrayLength, 1)
                 : d.textureType == MTLTextureTypeCube                                             ? 6
                 : d.textureType == MTLTextureTypeCubeArray                                        ? 6 * MAX(d.arrayLength, 1)
                                                                                                   : 1;
    t->_usage = d.usage;
    t->_storage = d.storageMode;
    VkImageCreateInfo ici = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    VkExternalMemoryImageCreateInfo emi = {VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, NULL,
                                           VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT};
    if (gVgExt) {   // shared with another process (5d, vg_new_surface_texture)
        ici.pNext = &emi;
    }
    ici.imageType = itype;
    ici.format = f->vk;
    ici.extent = (VkExtent3D){(uint32_t)t->_width, (uint32_t)t->_height, (uint32_t)t->_depth};
    ici.mipLevels = (uint32_t)t->_mips;
    ici.arrayLayers = (uint32_t)t->_layers;
    ici.samples = t->_samples > 1 ? (VkSampleCountFlagBits)t->_samples : VK_SAMPLE_COUNT_1_BIT;
    if (t->_samples > 1) {
        usage &= ~VK_IMAGE_USAGE_STORAGE_BIT;   // no multisample storage images
        ici.usage = usage;
    }
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = usage;
    if (f->aspect == VK_IMAGE_ASPECT_COLOR_BIT) {
        ici.flags |= VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;   // texture views may reinterpret the format (5b)
    }
    if (vtype == VK_IMAGE_VIEW_TYPE_CUBE || vtype == VK_IMAGE_VIEW_TYPE_CUBE_ARRAY) {
        ici.flags |= VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT;
    }
    t->_imageUsage = usage;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (gVgExt == 2) {   // importing: the creator's image exactly, or not at all
        const uint64_t *p = gVgImportParams;
        uint32_t fl = (uint32_t)ici.flags | (ici.tiling == VK_IMAGE_TILING_LINEAR ? 0x80000000u : 0);
        if (p[2] != (uint64_t)ici.format || p[3] != ici.extent.width || p[4] != ici.extent.height || p[5] != usage ||
            p[6] != fl) {
            vglog("share: surface image differs from its creator's (format %llu/%d, %llux%llu/%ux%u, usage 0x%llx/0x%x, "
                  "flags 0x%llx/0x%x): not imported",
                  p[2], ici.format, p[3], p[4], ici.extent.width, ici.extent.height, p[5], usage, p[6], fl);
            return nil;
        }
    }
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
    VkMemoryDedicatedAllocateInfo ded = {VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, NULL, t->_image, VK_NULL_HANDLE};
    VkExportMemoryAllocateInfo exp = {VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO, &ded,
                                      VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT};
    VkImportMemoryFdInfoKHR imp = {VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, &ded,
                                   VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, gVgImportFd};
    if (gVgExt == 1) {
        mai.pNext = &exp;
    } else if (gVgExt == 2) {
        if (gVgImportParams[1] < req.size) {
            vglog("share: the creator's memory (%llu B) is smaller than this image needs (%llu B)", gVgImportParams[1],
                  (unsigned long long)req.size);
            gVk.vkDestroyImage(gVk.device, t->_image, NULL);
            t->_image = VK_NULL_HANDLE;
            return nil;
        }
        mai.allocationSize = gVgImportParams[1];
        mai.pNext = &imp;
    }
    vgtrace("texture: %llu bytes, memory type bits 0x%x -> type %u", (unsigned long long)req.size, req.memoryTypeBits,
            mai.memoryTypeIndex);
    r = gVk.vkAllocateMemory(gVk.device, &mai, NULL, &t->_memory);
    if (gVgExt == 2) {
        gVgImportFd = r == VK_SUCCESS ? -1 : gVgImportFd;   // Venus closed it; on failure the caller does
    }
    if (r == VK_SUCCESS) {
        r = gVk.vkBindImageMemory(gVk.device, t->_image, t->_memory, 0);
    }
    VkImageViewCreateInfo vci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, NULL, 0, t->_image, vtype, f->vk,
                                 vg_components(f->mtl, d.swizzle),
                                 {vg_view_aspect(f->aspect), 0, (uint32_t)t->_mips, 0, (uint32_t)t->_layers}};
    if (r == VK_SUCCESS) {
        vgtrace("texture: bound (%d), vkCreateImageView", r);
        r = gVk.vkCreateImageView(gVk.device, &vci, NULL, &t->_view);
    }
    if (r == VK_SUCCESS && (f->aspect & VK_IMAGE_ASPECT_DEPTH_BIT) && (f->aspect & VK_IMAGE_ASPECT_STENCIL_BIT)) {
        // a depth-stencil attachment views both aspects (5d); sampling views depth only
        vci.subresourceRange.aspectMask = f->aspect;
        r = gVk.vkCreateImageView(gVk.device, &vci, NULL, &t->_attView);
    }
    vgtrace("texture: view %d, layout transition", r);
    if (r != VK_SUCCESS) {
        vglog("texture: memory / view %d", r);
        return nil;
    }
    VkImage image = t->_image;
    VkImageAspectFlags aspect = f->aspect;
    uint32_t mips = (uint32_t)t->_mips, layers = (uint32_t)t->_layers;
    if (gVgExt == 2) {   // the creator's image is already in GENERAL, holding its pixels: no transition
        return t;
    }
    if (gVgExt == 1) {
        t->_shareParams[0] = ici.format, t->_shareParams[1] = ici.extent.width, t->_shareParams[2] = ici.extent.height;
        t->_shareParams[3] = usage;
        t->_shareParams[4] = (uint32_t)ici.flags | (ici.tiling == VK_IMAGE_TILING_LINEAR ? 0x80000000u : 0);
        t->_shareSize = mai.allocationSize;
        t->_shareable = YES;   // initialized with the next submit like any image; offered at its first write-back
    }
    if (clearColor) {
        VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, mips, 0, layers};
        if (!vg_one_shot(^(VkCommandBuffer cb) {
                VkImageMemoryBarrier init = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0,
                                             VK_ACCESS_TRANSFER_WRITE_BIT, VK_IMAGE_LAYOUT_UNDEFINED,
                                             VK_IMAGE_LAYOUT_GENERAL, VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
                                             image, range};
                gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                                         0, NULL, 0, NULL, 1, &init);
                VkClearColorValue zero = {0};
                gVk.vkCmdClearColorImage(cb, image, VK_IMAGE_LAYOUT_GENERAL, &zero, 1, &range);
            })) {
            return nil;
        }
    } else {
        vg_pending_init_image(image, aspect, mips, layers);   // UNDEFINED -> GENERAL for life, ahead of the next submit
    }
    return t;
}

id<MTLTexture> vg_new_texture(id<MTLDevice> device, MTLTextureDescriptor *d) {
    return vg_new_texture_impl(device, d, NO);
}

VGMTLTexture *vg_new_zero_color_texture(id<MTLDevice> device, MTLTextureDescriptor *descriptor) {
    return vg_new_texture_impl(device, descriptor, YES);
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
    if (sci.unnormalizedCoordinates) {
        static int said;
        if (said++ < 3) {
            vglog("sampler: an app sampler in pixel coordinates (%s)", d.label.UTF8String ?: "unlabeled");
        }   // what Vulkan allows with pixel coordinates (Metal's own rules are the same)
        sci.minFilter = sci.magFilter;
        sci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        sci.minLod = sci.maxLod = 0;
        sci.anisotropyEnable = VK_FALSE;
        sci.compareEnable = VK_FALSE;
        VkSamplerAddressMode *m[2] = {&sci.addressModeU, &sci.addressModeV};
        for (int k = 0; k < 2; k++) {
            if (*m[k] != VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE && *m[k] != VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER) {
                *m[k] = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            }
        }
    }
    VGMTLSamplerState *s = [VGMTLSamplerState new];
    s->_dev = device;
    if (gVk.vkCreateSampler(gVk.device, &sci, NULL, &s->_sampler) != VK_SUCCESS) {
        return nil;
    }
    return s;
}

// A shader's constexpr sampler (5d), as the translator reflects it (its StaticSampler bindings): one immutable sampler per
// distinct state, kept for the process. Before this, such a binding read whatever sampler the app had bound at that
// index, or a placeholder: RenderBox's blur samples in pixel coordinates through one, read off the image with a
// normalized placeholder, and drew nothing (the Dock's and Spotlight's Calendar icons, among others).
static MTLSamplerAddressMode vg_ss_address(NSString *m) {
    return [m isEqual:@"Repeat"]               ? MTLSamplerAddressModeRepeat
           : [m isEqual:@"MirroredRepeat"]     ? MTLSamplerAddressModeMirrorRepeat
           : [m isEqual:@"ClampToBorder"]      ? MTLSamplerAddressModeClampToBorderColor
           : [m isEqual:@"ClampToZero"]        ? MTLSamplerAddressModeClampToZero
           : [m isEqual:@"MirrorClampToEdge"]  ? MTLSamplerAddressModeMirrorClampToEdge
                                               : MTLSamplerAddressModeClampToEdge;
}
static MTLCompareFunction vg_ss_compare(NSString *c) {
    NSArray *names = @[ @"Never", @"Less", @"Equal", @"LessEqual", @"Greater", @"NotEqual", @"GreaterEqual", @"Always" ];
    NSUInteger i = [names indexOfObject:c ?: @"Never"];
    return i == NSNotFound ? MTLCompareFunctionNever : (MTLCompareFunction)i;
}
static VkSampler vg_static_sampler(NSDictionary *ss) {
    static NSMutableDictionary *cache;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      cache = [NSMutableDictionary dictionary];
      lock = [NSObject new];
    });
    NSString *key = [ss[@"raw_words"] description] ?: [ss description];
    @synchronized(lock) {
        VGMTLSamplerState *hit = cache[key];
        if (hit) {
            return hit->_sampler;
        }
        MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
        d.minFilter = [ss[@"min_filter"] isEqual:@"Linear"] ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        d.magFilter = [ss[@"mag_filter"] isEqual:@"Linear"] ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        NSString *mip = ss[@"mip_filter"];
        d.mipFilter = [mip isEqual:@"Linear"]    ? MTLSamplerMipFilterLinear
                      : [mip isEqual:@"Nearest"] ? MTLSamplerMipFilterNearest
                                                 : MTLSamplerMipFilterNotMipmapped;
        d.sAddressMode = vg_ss_address(ss[@"address_mode_s"]);
        d.tAddressMode = vg_ss_address(ss[@"address_mode_t"]);
        d.rAddressMode = vg_ss_address(ss[@"address_mode_r"]);
        // Always normalized: for a pixel-coordinate sampler the translator divides by the texture's size itself and
        // samples through a normalized sampler with the same filter and addressing.
        d.normalizedCoordinates = YES;
        d.compareFunction = vg_ss_compare(ss[@"compare_function"]);
        d.maxAnisotropy = MAX([ss[@"max_anisotropy"] unsignedIntegerValue], 1);
        d.lodMinClamp = [ss[@"lod_min_clamp"] floatValue];
        d.lodMaxClamp = ss[@"lod_max_clamp"] ? [ss[@"lod_max_clamp"] floatValue] : FLT_MAX;
        NSString *bc = ss[@"border_color"];
        d.borderColor = [bc isEqual:@"OpaqueWhite"]   ? MTLSamplerBorderColorOpaqueWhite
                        : [bc isEqual:@"OpaqueBlack"] ? MTLSamplerBorderColorOpaqueBlack
                                                      : MTLSamplerBorderColorTransparentBlack;
        VGMTLSamplerState *s = (VGMTLSamplerState *)vg_new_sampler(nil, d);
        if (!s) {
            return VK_NULL_HANDLE;
        }
        cache[key] = s;
        static int said;
        if (said++ < 4) {
            vglog("sampler: a shader's constexpr sampler (%s, %s coordinates)", [ss[@"min_filter"] UTF8String],
                  [ss[@"coordinates"] UTF8String]);
        }
        return s->_sampler;
    }
}
void vg_apply_static_samplers(NSDictionary *refl, vg_binding *bindings, int n) {
    for (NSDictionary *b in refl[@"bindings"]) {
        if (![b isKindOfClass:[NSDictionary class]] || ![b[@"kind"] isEqual:@"StaticSampler"] ||
            ![b[@"static_sampler"] isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        uint32_t at = [b[@"descriptor"][@"binding"] unsignedIntValue];
        for (int i = 0; i < n; i++) {
            if (bindings[i].binding == at && bindings[i].type == VK_DESCRIPTOR_TYPE_SAMPLER) {
                bindings[i].fixed = vg_static_sampler(b[@"static_sampler"]);
            }
        }
    }
}

// ---- MTLDepthStencilState ----------------------------------------------------------------------------------------

@implementation VGMTLDepthStencilState
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){0}; }
- (BOOL)readsDepth { return _test; }       // 5d: Apple's GL renderer asks
- (BOOL)writesDepth { return _write; }
- (BOOL)readsStencil { return _stencil; }
- (BOOL)writesStencil { return _stencil && (_sfront.writeMask || _sback.writeMask); }
@end

id<MTLDepthStencilState> vg_new_depth_stencil(id<MTLDevice> device, MTLDepthStencilDescriptor *d) {
    VGMTLDepthStencilState *s = [VGMTLDepthStencilState new];
    s->_dev = device;
    s->_write = d.depthWriteEnabled;
    s->_compare = vg_compare(d.depthCompareFunction);
    s->_test = d.depthCompareFunction != MTLCompareFunctionAlways || d.depthWriteEnabled;
    // Stencil (5d). MTLStencilOperation and VkStencilOp number their operations alike; a face without a descriptor
    // always passes and keeps.
    s->_stencil = d.frontFaceStencil || d.backFaceStencil;
    MTLStencilDescriptor *faces[2] = {d.frontFaceStencil, d.backFaceStencil};
    VkStencilOpState *out[2] = {&s->_sfront, &s->_sback};
    for (int i = 0; i < 2; i++) {
        MTLStencilDescriptor *f = faces[i];
        *out[i] = f ? (VkStencilOpState){(VkStencilOp)f.stencilFailureOperation, (VkStencilOp)f.depthStencilPassOperation,
                                         (VkStencilOp)f.depthFailureOperation, vg_compare(f.stencilCompareFunction),
                                         f.readMask, f.writeMask, 0}
                    : (VkStencilOpState){VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP,
                                         VK_COMPARE_OP_ALWAYS, 0xff, 0, 0};
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
    return vg_texture_view_swz(p, pf, type, levels, slices, (MTLTextureSwizzleChannels){0, 0, 0, 0});
}
id<MTLTexture> vg_texture_view_swz(VGMTLTexture *p, MTLPixelFormat pf, MTLTextureType type, NSRange levels, NSRange slices,
                                   MTLTextureSwizzleChannels swz) {
    while (p->_parent) {
        p = p->_parent;
    }
    const vg_format *f = vg_format_of(pf);
    VkImageViewType vtype;
    switch (type) {
    case MTLTextureType1D: vtype = VK_IMAGE_VIEW_TYPE_1D; break;
    case MTLTextureType1DArray: vtype = VK_IMAGE_VIEW_TYPE_1D_ARRAY; break;
    case MTLTextureType2D: vtype = VK_IMAGE_VIEW_TYPE_2D; break;
    case MTLTextureType2DArray: vtype = VK_IMAGE_VIEW_TYPE_2D_ARRAY; break;
    case MTLTextureType3D: vtype = VK_IMAGE_VIEW_TYPE_3D; break;
    case MTLTextureType2DMultisample: vtype = VK_IMAGE_VIEW_TYPE_2D; break;
    case MTLTextureType2DMultisampleArray: vtype = VK_IMAGE_VIEW_TYPE_2D_ARRAY; break;
    case MTLTextureTypeCube: vtype = slices.length == 6 ? VK_IMAGE_VIEW_TYPE_CUBE : VK_IMAGE_VIEW_TYPE_MAX_ENUM; break;
    case MTLTextureTypeCubeArray: vtype = slices.length % 6 ? VK_IMAGE_VIEW_TYPE_MAX_ENUM : VK_IMAGE_VIEW_TYPE_CUBE_ARRAY; break;
    default: vtype = VK_IMAGE_VIEW_TYPE_MAX_ENUM; break;
    }
    BOOL cubeImage = p->_type == MTLTextureTypeCube || p->_type == MTLTextureTypeCubeArray;   // made cube-compatible
    if ((vtype == VK_IMAGE_VIEW_TYPE_CUBE || vtype == VK_IMAGE_VIEW_TYPE_CUBE_ARRAY) && !cubeImage) {
        vtype = VK_IMAGE_VIEW_TYPE_MAX_ENUM;
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
        usage |= p->_imageUsage & (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_ATTACHMENT_FEEDBACK_LOOP_BIT_EXT);
    }
    VkImageViewUsageCreateInfo uci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO, NULL, usage};
    VkImageViewCreateInfo vci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, &uci, 0, p->_image, vtype, f->vk,
                                 vg_components(pf, swz),
                                 {vg_view_aspect(f->aspect), (uint32_t)levels.location, (uint32_t)levels.length,
                                  (uint32_t)slices.location, (uint32_t)slices.length}};
    VGMTLTexture *t = [VGMTLTexture new];
    if (gVk.vkCreateImageView(gVk.device, &vci, NULL, &t->_view) != VK_SUCCESS) {
        vglog("texture view: vkCreateImageView failed (format %lu)", (unsigned long)pf);
        return nil;
    }
    VGCALL("texture view of %p: format %lu type %lu -> %p", p, (unsigned long)pf, (unsigned long)type, t);
    t->_parent = p;
    t->_swz = swz;
    t->_dev = p->_dev;
    t->_image = p->_image;
    t->_imageUsage = p->_imageUsage;
    t->_pixelFormat = pf;
    t->_format = f->vk;
    t->_aspect = f->aspect;
    if (p->_la && (p->_imageUsage & VK_IMAGE_USAGE_SAMPLED_BIT)) {   // a view of a luminance-alpha surface's image
        vg_texture_la_view(t, vtype, vci.subresourceRange);
    }
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

os_unfair_lock gVgSurfaceSync = OS_UNFAIR_LOCK_INIT;
static void vg_surface_pull_locked(VGMTLTexture *t);
static void vg_sibling_sync_locked(VGMTLTexture *t);
static BOOL vg_siblings_on(void);

// The images of one surface plane in this process (round 23). A wrapper in another size or texel size than the first
// one is an image of its own: VideoToolbox's Metal transfer reads a 512-wide BGRA plane as a 128-wide RGBA32Uint
// texture (the same 2048-byte rows). Kept in step only through the surface's CPU copy, such an image read before a
// sibling's GPU write was written back got stale pixels (0.1.10's striped Memoji). Now each submitted GPU write
// numbers its image as the group's newest, and an image behind it is copied from it on the GPU before its next use.
// The fields are guarded by gVgSurfaceSync; the group lives as long as one of its images (each holds it).
@interface VGSurfaceGroup : NSObject {
@public
    NSHashTable<VGMTLTexture *> *roots;   // weak
    uint64_t gen;                         // GPU writes submitted so far, to any of them
}
@end
@implementation VGSurfaceGroup
@end

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
        vg_pending_copy(buf, t->_image, &c, NULL);   // ahead of the next submit (the one that reads it)
        return;
    }
    if (!t || !t->_surface) {
        return;
    }
    // One lock for every surface's sync state (round 21): a write-back takes it from reading the seed to recording
    // the one its unlock made, so this check never sees the seed its write lock bumped before it is recorded (that
    // half-done state read as someone else's write, and the pull it caused put an older frame over a newer one).
    os_unfair_lock_lock(&gVgSurfaceSync);
    vg_surface_pull_locked(t);
    vg_sibling_sync_locked(t);
    os_unfair_lock_unlock(&gVgSurfaceSync);
}

void vg_surface_gpu_wrote(VGMTLTexture *t) {
    while (t && t->_parent) {
        t = t->_parent;
    }
    if (!t || !t->_group) {
        return;
    }
    os_unfair_lock_lock(&gVgSurfaceSync);
    VGSurfaceGroup *g = t->_group;
    t->_gpuGen = ++g->gen;
    os_unfair_lock_unlock(&gVgSurfaceSync);
}

void vg_surface_siblings_synced(VGMTLTexture *t, uint32_t before, uint32_t seed) {
    VGSurfaceGroup *g = t->_group;
    if (!g || g->roots.count < 2 || !vg_siblings_on()) {
        return;
    }
    for (VGMTLTexture *s in g->roots) {
        if (s != t && !s->_neverSynced && s->_syncedSeed == before) {
            s->_syncedSeed = seed;   // t's write: s gets t's pixels on the GPU (vg_sibling_sync_locked), not a pull
        }
    }
}

static size_t vg_gcd(size_t a, size_t b) {
    while (b) {
        size_t r = a % b;
        a = b, b = r;
    }
    return a;
}

// t is about to be used: if a sibling holds a newer GPU write, copy it in on the GPU, ahead of the next submit (the
// write was submitted already, so it runs before; a write and a sibling's read in the same command buffer aren't
// covered). A sibling that someone else's write has overtaken since (its seed no longer the surface's) is passed
// over: t has pulled those bytes.
// The VirtioGPUMetal-nosibling flag file turns it off (0.1.10's regroupings, synced through the CPU only), to compare.
static BOOL vg_siblings_on(void) {
    static int on = -1;
    if (on < 0) {
        on = !vg_debug_flag("nosibling");
    }
    return on;
}
static void vg_sibling_sync_locked(VGMTLTexture *t) {
    VGSurfaceGroup *g = t->_group;
    if (!g || g->gen == t->_gpuGen || !vg_siblings_on()) {
        return;
    }
    VGMTLTexture *n = nil;
    for (VGMTLTexture *s in g->roots) {
        if (s != t && s->_gpuGen > t->_gpuGen && (!n || s->_gpuGen > n->_gpuGen)) {
            n = s;
        }
    }
    if (!n) {
        t->_gpuGen = g->gen;
        return;
    }
    const uint32_t seed = IOSurfaceGetSeed(t->_surface);
    const vg_format *nf = vg_format_of(n->_pixelFormat), *tf = vg_format_of(t->_pixelFormat);
    if (n->_neverSynced || n->_syncedSeed != seed || !nf || !tf || !nf->bytes || !tf->bytes) {
        t->_gpuGen = n->_gpuGen;
        return;
    }
    // the bytes both images cover: the narrower one's rows, in whole texels of each
    size_t nb = nf->bytes, tb = tf->bytes, unit = nb / vg_gcd(nb, tb) * tb;
    size_t rowBytes = MIN(n->_width * nb, t->_width * tb);
    rowBytes -= rowBytes % unit;
    uint32_t rows = (uint32_t)MIN(n->_height, t->_height);
    vg_buffer st;
    if (!rowBytes || !rows || t->_surfaceBpr % nb || t->_surfaceBpr % tb ||
        vg_staging_get(t->_surfaceBpr * rows, &st)) {
        return;   // tried again at the next use
    }
    VkBufferImageCopy c1 = {0, (uint32_t)(t->_surfaceBpr / nb), rows, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0},
                            {(uint32_t)(rowBytes / nb), rows, 1}};
    VkBufferImageCopy c2 = {0, (uint32_t)(t->_surfaceBpr / tb), rows, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0},
                            {(uint32_t)(rowBytes / tb), rows, 1}};
    vg_pending_image_copy(n->_image, n, t->_image, &c1, &c2, &st);
    if (vg_synclog()) {
        vglog("synclog sibling: surface %u %lux%lu pf%lu <- %lux%lu pf%lu (generation %llu, had %llu)",
              IOSurfaceGetID(t->_surface), (unsigned long)t->_width, (unsigned long)t->_height,
              (unsigned long)t->_pixelFormat, (unsigned long)n->_width, (unsigned long)n->_height,
              (unsigned long)n->_pixelFormat, (unsigned long long)n->_gpuGen, (unsigned long long)t->_gpuGen);
    }
    t->_gpuGen = n->_gpuGen;
}

static void vg_surface_pull_locked(VGMTLTexture *t) {
    uint32_t seed = IOSurfaceGetSeed(t->_surface);
    if (!t->_neverSynced && seed == t->_syncedSeed) {
        return;
    }
    if (!t->_neverSynced && vg_surface_tagged(t, seed)) {   // the other process's GPU frame, already in our image (5d)
        t->_syncedSeed = seed;
        vg_perf(VG_PERF_PULL_COPY, 0, 0);
        return;
    }
    const vg_format *f = vg_format_of(t->_pixelFormat);
    NSUInteger rows = t->_height;
    static int logged;
    if (logged < 40 && !strcmp(getprogname(), "WindowServer")) {
        logged++;
        vglog("pull: surface %u %lux%lu (seed %u, synced %u%s)", IOSurfaceGetID(t->_surface), (unsigned long)t->_width,
              (unsigned long)t->_height, seed, t->_syncedSeed, t->_neverSynced ? ", new" : "");
    }
    // The surface's bytes go into a staging buffer of their own now; the GPU copy waits for the next submit (5c: it
    // was a one-shot, ~9 ms of WindowServer's time per pulled frame). t->_staging stays the write-back's.
    uint64_t t0 = vg_now();
    vg_buffer up;
    if (vg_staging_get(t->_surfaceBpr * rows, &up)) {
        return;
    }
    IOSurfaceLock(t->_surface, kIOSurfaceLockReadOnly, &seed);
    memcpy(up.map, IOSurfaceGetBaseAddressOfPlane(t->_surface, t->_plane), t->_surfaceBpr * rows);
    IOSurfaceUnlock(t->_surface, kIOSurfaceLockReadOnly, NULL);
    vg_perf(VG_PERF_PULL_COPY, t->_surfaceBpr * rows, vg_now() - t0);
    VkBufferImageCopy c = {0, (uint32_t)(t->_surfaceBpr / f->bytes), (uint32_t)rows,
                           {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0},
                           {(uint32_t)t->_width, (uint32_t)rows, 1}};
    vgtrace("surface %u: pull (seed %u, had %u)", IOSurfaceGetID(t->_surface), seed, t->_syncedSeed);
    if (vg_synclog()) {
        vglog("synclog pull: surface %u %lux%lu seed %u synced %u%s", IOSurfaceGetID(t->_surface),
              (unsigned long)t->_width, (unsigned long)t->_height, seed, t->_syncedSeed, t->_neverSynced ? " new" : "");
    }
    if (t->_shareRes) {
        // A shared image (5d): uploaded now. Left for our next submit, it could land after the other process put a
        // newer frame in the same image, and take it back to this older one.
        VkImage img = t->_image;
        VkBuffer ub = up.buffer;
        BOOL ok = vg_one_shot(^(VkCommandBuffer cb) {
          VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_HOST_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
                                VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT};
          gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT,
                                   VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
          gVk.vkCmdCopyBufferToImage(cb, ub, img, VK_IMAGE_LAYOUT_GENERAL, 1, &c);
          VkMemoryBarrier after = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT,
                                   VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT};
          gVk.vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &after,
                                   0, NULL, 0, NULL);
        });
        if (ok) {
            vg_staging_put(&up);
            vg_surface_tag(t, seed);   // uploaded and done: the other process needn't upload this frame too
        } else {
            vg_pending_copy(up.buffer, t->_image, &c, &up);
        }
    } else {
        vg_pending_copy(up.buffer, t->_image, &c, &up);
    }
    t->_syncedSeed = seed;
    t->_neverSynced = NO;
}

id<MTLTexture> vg_new_buffer_texture(id<MTLBuffer> buffer, MTLTextureDescriptor *d, NSUInteger offset, NSUInteger bpr) {
    const vg_format *f = vg_format_of(d.pixelFormat);
    // Mip levels (round 11: WindowServer makes a 54x54 one with 6, and it was refused -- nothing drew): taken, as one.
    if (!f || (f->aspect & ~VK_IMAGE_ASPECT_COLOR_BIT) || d.textureType != MTLTextureType2D || !bpr || bpr % f->bytes || offset + bpr * (d.height - 1) + d.width * f->bytes > buffer.length) {
        vglog("buffer texture: %lux%lu format %lu type %lu, %lu levels, at %lu, %lu bytes per row doesn't fit a %lu-byte "
              "buffer (2D color only)",
              (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.pixelFormat, (unsigned long)d.textureType,
              (unsigned long)d.mipmapLevelCount, (unsigned long)offset, (unsigned long)bpr, (unsigned long)buffer.length);
        return nil;
    }
    // One level only: the image's other levels were filled by nothing (Core Animation doesn't generate them for this
    // texture, and the buffer holds level 0), and a badge's number drawn smaller than the texture sampled them: the
    // Dock's badges showed their red circle without the number. One level is always the buffer's pixels.
    if (d.mipmapLevelCount > 1) {
        d = [d copy];
        d.mipmapLevelCount = 1;
    }
    VGMTLTexture *t = (VGMTLTexture *)vg_new_texture(buffer.device, d);
    if (t) {
        t->_srcBuffer = buffer;
        t->_srcOffset = offset;
        t->_srcBpr = bpr;
    }
    return t;
}

// Surface roots stay alive 2 s after their last wrapper (5c): Core Animation makes a new texture for an app's drawable
// every frame, so with only the weak map the root died in between and each frame built a new host image (369 times in
// 5 min for one window). Called with the roots lock held.
static NSMutableDictionary<NSString *, VGMTLTexture *> *gKept;
static NSMutableDictionary<NSString *, NSNumber *> *gKeptAt;
// Roots stay alive 2 s after their last use (Core Animation wraps a surface again for each frame it shows; a new root
// is a new image and a full upload). Over budget, the least recently used go first -- the sweep used to drop entries in
// dictionary order once there were more than 96, and WebGL's buffers in WindowServer and Safari's GPU process were
// rebuilt about five times a second each (5d).
static void vg_root_keep(NSString *key, VGMTLTexture *root) {
    if (!gKept) {
        gKept = [NSMutableDictionary dictionary];
        gKeptAt = [NSMutableDictionary dictionary];
    }
    uint64_t now = vg_now();
    gKept[key] = root;
    gKeptAt[key] = @(now);
    static uint64_t lastSweep;
    if (now - lastSweep < 500000000ull) {
        return;
    }
    lastSweep = now;
    const uint64_t budget = 512ull << 20;   // bytes of kept images beyond what is in use anyway
    uint64_t bytes = 0;
    NSArray *keys = [gKeptAt keysSortedByValueUsingSelector:@selector(compare:)];   // oldest first
    for (NSString *k in keys) {
        VGMTLTexture *t = gKept[k];
        bytes += (uint64_t)t->_width * t->_height * MAX(t->_surfaceBpr / MAX(t->_width, 1), 4);
    }
    for (NSString *k in keys) {
        VGMTLTexture *t = gKept[k];
        BOOL old = now - gKeptAt[k].unsignedLongLongValue > 2000000000ull;
        if (!old && bytes <= budget && gKept.count <= 512) {
            break;   // the rest are newer
        }
        bytes -= MIN(bytes, (uint64_t)t->_width * t->_height * MAX(t->_surfaceBpr / MAX(t->_width, 1), 4));
        [gKept removeObjectForKey:k];
        [gKeptAt removeObjectForKey:k];
    }
}

// ---- surfaces shared between processes (5d, core 0.5.6) ------------------------------------------------------------
// One image per IOSurface for the whole system instead of one per process: the first process to wrap a surface makes
// its image on exportable memory and registers it with the kext (kVGUCShareSurface); every other process imports that
// memory (vn_macos_import_surface) and makes the same image over it. WindowServer then reads an app's frames where the
// app drew them, without pulling the surface's CPU memory (a memcpy and an upload per frame, per window). The CPU
// write-back stays, for CPU readers; it tags the surface with its seed and resource, and a process whose image is that
// resource skips the pull the new seed would otherwise cause. Opt-in: the flag file VirtioGPUMetal-share turns it on.
static NSString *const kVgSeedTag = @"VeneraSeed";
static void vg_surface_tag(VGMTLTexture *t, uint32_t seed) {
    if (!t->_shareRes) {
        return;
    }
    uint64_t v = (uint64_t)t->_shareRes << 32 | seed;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &v);
    IOSurfaceSetValue(t->_surface, (__bridge CFStringRef)kVgSeedTag, n);
    CFRelease(n);
}
static BOOL vg_share_register(VGMTLTexture *t, uint32_t surface);
// After a write-back at completion: the image holds a GPU frame and has been initialized, so it can be offered now (an
// image offered at creation had its first transition and uploads raced the other process's use of it).
void vg_surface_wrote_back(VGMTLTexture *t, uint32_t seed) {
    if (t->_shareable && !t->_shareRes && gVgSharing && t->_surface) {
        t->_shareable = vg_share_register(t, IOSurfaceGetID(t->_surface));   // NO after a refusal: not again
    }
    vg_surface_tag(t, seed);
}
// YES when the surface's current contents are a frame our shared image already holds.
static BOOL vg_surface_tagged(VGMTLTexture *t, uint32_t seed) {
    if (!t->_shareRes) {
        return NO;
    }
    CFTypeRef v = IOSurfaceCopyValue(t->_surface, (__bridge CFStringRef)kVgSeedTag);
    uint64_t tag = 0;
    BOOL ok = v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue(v, kCFNumberSInt64Type, &tag);
    if (v) {
        CFRelease(v);
    }
    return ok && (uint32_t)(tag >> 32) == t->_shareRes && (uint32_t)tag == seed;
}
static BOOL vg_share_register(VGMTLTexture *t, uint32_t surface) {
    uint32_t res = vg_memory_res_id(t->_memory);
    io_connect_t c = vg_twin_conn();
    if (!res || !c) {
        return NO;
    }
    uint64_t in[8] = {surface, res, t->_shareSize, t->_shareParams[0], t->_shareParams[1], t->_shareParams[2],
                      t->_shareParams[3], t->_shareParams[4]};
    kern_return_t kr = IOConnectCallScalarMethod(c, 11 /* kVGUCShareSurface */, in, 8, NULL, NULL);
    if (kr == kIOReturnUnsupported) {
        static int said;
        if (!said++) {
            vglog("share: the kext can't share surfaces (core before 0.5.6)");
        }
        gVgSharing = NO;
    }
    if (kr != KERN_SUCCESS) {
        return NO;
    }
    t->_shareRes = res;
    return YES;
}
static void vg_share_forget(VGMTLTexture *t) {
    if (t->_shareRes && !t->_shareImported && t->_surface) {
        uint64_t in[8] = {IOSurfaceGetID(t->_surface), 0, 0, 0, 0, 0, 0, 0};
        IOConnectCallScalarMethod(vg_twin_conn(), 11, in, 8, NULL, NULL);
    }
}
void vg_texture_share_dealloc(VGMTLTexture *t) { vg_share_forget(t); }
// The root image of a surface wrapper: imported, else made shareable and registered, else private.
static VGMTLTexture *vg_surface_root_image(id<MTLDevice> device, MTLTextureDescriptor *rd, IOSurfaceRef surface,
                                           NSUInteger plane) {
    VGMTLTexture *t = nil;
    uint32_t sid = IOSurfaceGetID(surface);
    BOOL eligible = gVgSharing && plane == 0 && rd.sampleCount <= 1 && rd.width >= 16 && rd.height >= 16;
    if (eligible) {
        uint64_t out[7] = {0};
        int fd = vg_import_surface(sid, out);
        if (fd >= 0) {
            gVgExt = 2, gVgImportFd = fd, gVgImportParams = out;
            t = (VGMTLTexture *)vg_new_texture(device, rd);
            if (gVgImportFd >= 0) {
                close(gVgImportFd);   // not taken by Venus
            }
            gVgExt = 0, gVgImportFd = -1, gVgImportParams = NULL;
            if (t) {
                t->_shareRes = (uint32_t)out[0];
                t->_shareImported = YES;
                static int said;
                if (said++ < 8) {
                    vglog("share: surface %u imported (resource %u, %lux%lu)", sid, t->_shareRes,
                          (unsigned long)t->_width, (unsigned long)t->_height);
                }
                return t;
            }
        }
        gVgExt = 1;
        t = (VGMTLTexture *)vg_new_texture(device, rd);
        gVgExt = 0;
        if (t) {
            return t;   // registered at its first GPU write-back: surfaces only the CPU draws stay unshared
        }
    }
    return (VGMTLTexture *)vg_new_texture(device, rd);
}

static BOOL vg_format_is_integer(MTLPixelFormat pf) {
    switch (pf) {
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
    // A plane's rows in its own elements, or regrouped into bigger integer ones: VideoToolbox's Metal transfer
    // (VTMTSComputeFunction) reads a 512-wide BGRA plane as a 128-wide RGBA32Uint texture (the same 2048-byte rows)
    // to convert a user's picture for the login screen's list of users; refused, it converts on the CPU, and that
    // list showed no pictures. Integer texels carry the bits as they are. Such a regrouping is an image of its own,
    // kept in step with the plane's other images on the GPU (VGSurfaceGroup, round 23): 0.1.10 took them with only the
    // CPU copy between them, and the Memoji picker's stickers came out striped and mixed up. A regrouping into
    // normalized or float texels stays refused (VideoToolbox's 10-bit copy into RGBA16Unorm texels came out wrong).
    size_t eb = IOSurfaceGetBytesPerElementOfPlane(surface, plane);
    BOOL fits = eb == f->bytes ? d.width <= sw
                               : (vg_format_is_integer(d.pixelFormat) && eb && d.width * f->bytes <= sw * eb);
    if (!fits || d.height > sh || bpr % f->bytes) {
        vglog("surface texture: %lux%lu format %lu doesn't fit surface %zux%zu, %zu bytes per row, %zu per element",
              (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.pixelFormat, sw, sh, bpr,
              IOSurfaceGetBytesPerElementOfPlane(surface, plane));
        return nil;
    }
    // One GPU image per IOSurface plane in this process (5c). Every wrapper Core Animation makes of the same surface
    // is a view of the first one, so GPU reads see GPU writes in queue order. With a private image per wrapper, synced
    // only through the surface's CPU memory, a second wrapper could be read before the first one's write-back landed:
    // WindowServer copied stale pixels forward (old window pieces left behind, flicker) once frames overlapped.
    static NSMapTable<NSString *, VGMTLTexture *> *roots;
    static pthread_mutex_t rootsLock = PTHREAD_MUTEX_INITIALIZER;
    // (and the texel size: a regrouping's image can't have views in the plane's own texels, round 23)
    NSString *key = [NSString stringWithFormat:@"%u/%lu/%lux%lu%@", IOSurfaceGetID(surface), (unsigned long)plane,
                                               (unsigned long)d.width, (unsigned long)d.height,
                                               f->bytes == eb ? @"" : [NSString stringWithFormat:@"/%u", (unsigned)f->bytes]];
    pthread_mutex_lock(&rootsLock);
    if (!roots) {
        roots = [NSMapTable strongToWeakObjectsMapTable];
    }
    VGMTLTexture *root = [roots objectForKey:key];
    // The same surface by id, not by IOSurfaceRef: Core Animation passes a surface between processes by mach port, and
    // each lookup can make a new IOSurfaceRef for it -- compared by pointer, WebGL's buffers got a new image (and a full
    // upload) about five times a second each in WindowServer and Safari's GPU process (5d). The root keeps its surface
    // alive, so its id can't have been reused for another one.
    if (root && root->_surface && IOSurfaceGetID(root->_surface) == IOSurfaceGetID(surface)) {
        vg_root_keep(key, root);
        pthread_mutex_unlock(&rootsLock);
        id<MTLTexture> v = vg_texture_view(root, d.pixelFormat, MTLTextureType2D, NSMakeRange(0, 1), NSMakeRange(0, 1));
        if (v) {
            ((VGMTLTexture *)v)->_usage = d.usage;
            vg_surface_pull(root);   // what the surface holds now, if someone else changed it
        }
        return v;
    }
    // The first wrapper: its image can be anything a later wrapper needs (render target, storage, other formats).
    MTLTextureDescriptor *rd = [d copy];
    rd.usage = d.usage | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    VGMTLTexture *t = vg_surface_root_image(device, rd, surface, plane);
    if (!t) {   // its write-back staging comes from the pool when a command buffer first writes it (5c round 6)
        pthread_mutex_unlock(&rootsLock);
        return nil;
    }
    t->_usage = d.usage;
    [roots setObject:t forKey:key];
    vg_root_keep(key, t);
    // its siblings: the plane's images in other sizes or texel sizes (round 23)
    static NSMapTable<NSString *, VGSurfaceGroup *> *groups;
    if (!groups) {
        groups = [NSMapTable strongToWeakObjectsMapTable];
    }
    NSString *gkey = [NSString stringWithFormat:@"%u/%lu", IOSurfaceGetID(surface), (unsigned long)plane];
    VGSurfaceGroup *group = [groups objectForKey:gkey];
    if (!group) {
        group = [VGSurfaceGroup new];
        group->roots = [NSHashTable weakObjectsHashTable];
        [groups setObject:group forKey:gkey];
    }
    pthread_mutex_unlock(&rootsLock);
    t->_surface = (IOSurfaceRef)CFRetain(surface);
    if (vg_surface_is_la(surface)) {
        vg_texture_make_la(t);
    }
    t->_scanout = -1;   // looked at the first time a display frame writes it
    t->_plane = plane;
    t->_surfaceBpr = bpr;
    t->_neverSynced = YES;
    if (t->_shareImported && vg_surface_tagged(t, IOSurfaceGetSeed(surface))) {
        t->_neverSynced = NO;   // the creator's image holds what the surface does: nothing to pull
        t->_syncedSeed = IOSurfaceGetSeed(surface);
    }
    os_unfair_lock_lock(&gVgSurfaceSync);
    [group->roots addObject:t];
    t->_group = group;
    t->_gpuGen = 0;   // what the CPU holds; a sibling's newer GPU write is copied in at the pull below
    os_unfair_lock_unlock(&gVgSurfaceSync);
    vg_surface_pull(t);
    static int said;
    if (said++ < 60) {
        OSType sf = IOSurfaceGetPixelFormat(surface);
        char fc[5] = {(char)(sf >> 24), (char)(sf >> 16), (char)(sf >> 8), (char)sf, 0};
        for (int i = 0; i < 4; i++) {
            if (fc[i] < 32 || fc[i] > 126) {
                fc[i] = '?';
            }
        }
        vglog("surface texture: IOSurface %u plane %lu, %lux%lu, %zu bytes per row (key %s, kept %lu, roots %lu); surface "
              "'%s' (0x%x) %zux%zu, %zu bytes an element of %zux%zu, %zu planes, alloc %zu; texture pf%lu",
              IOSurfaceGetID(surface), (unsigned long)plane, (unsigned long)d.width, (unsigned long)d.height, bpr,
              key.UTF8String, (unsigned long)gKept.count, (unsigned long)roots.count, fc, (unsigned)sf,
              IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), IOSurfaceGetBytesPerElement(surface),
              IOSurfaceGetElementWidth(surface), IOSurfaceGetElementHeight(surface), IOSurfaceGetPlaneCount(surface),
              IOSurfaceGetAllocSize(surface), (unsigned long)d.pixelFormat);
    }
    return t;
}
