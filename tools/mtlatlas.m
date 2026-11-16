// mtlatlas (5d): what RenderBox's icon composites do on a GPU without framebuffer reads -- draw into a wide "atlas"
// texture, then, in the same command buffer, read it back into a smaller target three ways: a constexpr sampler in
// pixel coordinates (linear), one in pixel coordinates (nearest), and an app sampler in normalized coordinates.
// Each in RGBA16Float (RenderBox's) and BGRA8Unorm. Spotlight's icons came out empty reading such an atlas.
//   mtlatlas            (needs the process allow-listed, e.g. VGMTL_ENABLE=1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct V { float4 p [[position]]; };\n"
     "vertex V vs(uint vid [[vertex_id]]) {\n"
     "    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};\n"
     "    V o; o.p = float4(p[vid], 0, 1); return o;\n"
     "}\n"
     "fragment half4 fill(V in [[stage_in]]) { return half4(0.5h, 0.25h, 0.75h, 1.0h); }\n"
     "fragment half4 pix_linear(V in [[stage_in]], texture2d<half> t [[texture(0)]]) {\n"
     "    constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);\n"
     "    return t.sample(s, in.p.xy + float2(48, 0));\n"
     "}\n"
     "fragment half4 pix_nearest(V in [[stage_in]], texture2d<half> t [[texture(0)]]) {\n"
     "    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);\n"
     "    return t.sample(s, in.p.xy + float2(48, 0));\n"
     "}\n"
     "fragment half4 norm_app(V in [[stage_in]], texture2d<half> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
     "    return t.sample(s, (in.p.xy + float2(48, 0)) / float2(t.get_width(), t.get_height()));\n"
     "}\n"
     "fragment half4 read_px(V in [[stage_in]], texture2d<half, access::read> t [[texture(0)]]) {\n"
     "    return t.read(uint2(in.p.xy) + uint2(48, 0));\n"
     "}\n";

static float half_to_float(uint16_t h) {
    uint32_t e = (h >> 10) & 31, m = h & 1023;
    float v = e == 0 ? ldexpf((float)m, -24) : e == 31 ? INFINITY : ldexpf((float)(m | 1024), (int)e - 25);
    return (h & 0x8000) ? -v : v;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("device: %s\n", dev ? dev.name.UTF8String : "(none)");
        if (!dev) {
            return 2;
        }
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:[MTLCompileOptions new] error:&err];
        if (!lib) {
            printf("library: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
        int failures = 0;
        MTLPixelFormat fmts[2] = {MTLPixelFormatRGBA16Float, MTLPixelFormatBGRA8Unorm};
        const char *fnames[2] = {"RGBA16Float", "BGRA8Unorm"};
        NSArray *readers = @[ @"pix_linear", @"pix_nearest", @"norm_app", @"read_px" ];
        for (int fi = 0; fi < 2; fi++) {
            MTLPixelFormat pf = fmts[fi];
            MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
            rd.vertexFunction = [lib newFunctionWithName:@"vs"];
            rd.colorAttachments[0].pixelFormat = pf;
            rd.fragmentFunction = [lib newFunctionWithName:@"fill"];
            id<MTLRenderPipelineState> fillPS = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
            MTLTextureDescriptor *ad = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:224 height:128 mipmapped:NO];
            ad.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            ad.storageMode = MTLStorageModePrivate;
            for (NSString *rname in readers) {
                rd.fragmentFunction = [lib newFunctionWithName:rname];
                id<MTLRenderPipelineState> readPS = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
                if (!fillPS || !readPS) {
                    printf("%-12s %-12s pipeline FAILED: %s\n", fnames[fi], rname.UTF8String, err.localizedDescription.UTF8String);
                    failures++;
                    continue;
                }
                id<MTLTexture> atlas = [dev newTextureWithDescriptor:ad];
                MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:128 height:128 mipmapped:NO];
                od.usage = MTLTextureUsageRenderTarget;
                od.storageMode = MTLStorageModeManaged;
                id<MTLTexture> out = [dev newTextureWithDescriptor:od];
                id<MTLCommandBuffer> cb = [q commandBuffer];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
                rp.colorAttachments[0].texture = atlas;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:fillPS];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];
                rp.colorAttachments[0].texture = out;
                re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:readPS];
                [re setFragmentTexture:atlas atIndex:0];
                [re setFragmentSamplerState:smp atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                [be synchronizeResource:out];
                [be endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                float c[4];
                if (pf == MTLPixelFormatRGBA16Float) {
                    uint16_t h[4];
                    [out getBytes:h bytesPerRow:128 * 8 fromRegion:MTLRegionMake2D(64, 64, 1, 1) mipmapLevel:0];
                    for (int i = 0; i < 4; i++) {
                        c[i] = half_to_float(h[i]);
                    }
                } else {
                    uint8_t b[4];
                    [out getBytes:b bytesPerRow:128 * 4 fromRegion:MTLRegionMake2D(64, 64, 1, 1) mipmapLevel:0];
                    c[0] = b[2] / 255.f, c[1] = b[1] / 255.f, c[2] = b[0] / 255.f, c[3] = b[3] / 255.f;
                }
                BOOL ok = fabsf(c[0] - 0.5f) < 0.02f && fabsf(c[1] - 0.25f) < 0.02f && fabsf(c[2] - 0.75f) < 0.02f &&
                          fabsf(c[3] - 1) < 0.02f;
                failures += !ok;
                printf("%-12s %-12s %s  (%.3f %.3f %.3f %.3f)\n", fnames[fi], rname.UTF8String, ok ? "ok  " : "FAIL", c[0], c[1],
                       c[2], c[3]);
            }
        }
        printf("%s\n", failures ? "FAILED" : "PASS");
        return failures ? 1 : 0;
    }
}
