// mtlface: [[front_facing]] in a fragment shader (RenderBox fills paths by adding +1 or -1 by it). A quad drawn once
// clockwise and once counterclockwise into a 64x16 RG16Float target with additive blending, the shader writing
// front_facing ? +1 : -1 into green: every pixel should read the same sign per draw.
//   mtlface [MASK BLEND FORMAT]   MASK g|rg|rgba, BLEND 0|1, FORMAT rg16f|rgba16f|rg32f (default g 1 rg16f)
//                                 (needs the process allow-listed, e.g. VGMTL_ENABLE=1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint vid [[vertex_id]], constant float2 *pts [[buffer(0)]]) { V o; o.p = float4(pts[vid], 0, 1); return o; }\n"
    "struct O { half2 c [[color(1)]]; half4 dummy [[color(0)]]; };\n"
    "fragment O fs(bool ff [[front_facing]]) { O o; o.c = half2(0, ff ? 1.0h : -1.0h); o.dummy = half4(0); return o; }\n";

static float h2f(uint16_t h) {
    uint32_t e = (h >> 10) & 31, m = h & 1023;
    float v = e == 0 ? ldexpf((float)m, -24) : ldexpf((float)(m | 1024), (int)e - 25);
    return (h & 0x8000) ? -v : v;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *maskName = argc > 1 ? argv[1] : "g", *fmtName = argc > 3 ? argv[3] : "rg16f";
        BOOL blend = argc > 2 ? atoi(argv[2]) : YES;
        MTLColorWriteMask wm = !strcmp(maskName, "rg") ? (MTLColorWriteMaskRed | MTLColorWriteMaskGreen)
                               : !strcmp(maskName, "rgba") ? MTLColorWriteMaskAll : MTLColorWriteMaskGreen;
        MTLPixelFormat pf = !strcmp(fmtName, "rgba16f") ? MTLPixelFormatRGBA16Float
                            : !strcmp(fmtName, "rg32f") ? MTLPixelFormatRG32Float : MTLPixelFormatRG16Float;
        int bpp = pf == MTLPixelFormatRGBA16Float ? 8 : pf == MTLPixelFormatRG32Float ? 8 : 4;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
        if (!lib) {
            printf("%s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"vs"];
        rd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatR16Float;
        rd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
        rd.colorAttachments[1].pixelFormat = pf;
        rd.colorAttachments[1].writeMask = wm;
        rd.colorAttachments[1].blendingEnabled = blend;
        rd.colorAttachments[1].sourceRGBBlendFactor = rd.colorAttachments[1].destinationRGBBlendFactor = MTLBlendFactorOne;
        rd.colorAttachments[1].sourceAlphaBlendFactor = rd.colorAttachments[1].destinationAlphaBlendFactor = MTLBlendFactorOne;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
        if (!ps) {
            printf("pipeline: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        int failures = 0;
        for (int cw = 0; cw < 2; cw++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:64 height:16 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> acc = [dev newTextureWithDescriptor:td];
            td.pixelFormat = MTLPixelFormatR16Float;
            id<MTLTexture> c0 = [dev newTextureWithDescriptor:td];
            // two triangles covering the target, both wound the same way
            float a[12] = {-1, -1, 1, -1, -1, 1, 1, -1, 1, 1, -1, 1};
            float b[12] = {-1, -1, -1, 1, 1, -1, 1, -1, -1, 1, 1, 1};
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
            rp.colorAttachments[0].texture = c0;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[1].texture = acc;
            rp.colorAttachments[1].loadAction = MTLLoadActionClear;
            rp.colorAttachments[1].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:ps];
            [e setVertexBytes:cw ? b : a length:48 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            uint8_t raw[64 * 16 * 8];
            [acc getBytes:raw bytesPerRow:64 * bpp fromRegion:MTLRegionMake2D(0, 0, 64, 16) mipmapLevel:0];
            float gv[64 * 16];
            for (int i = 0; i < 64 * 16; i++) {
                if (pf == MTLPixelFormatRG32Float) {
                    memcpy(&gv[i], raw + i * 8 + 4, 4);
                } else {
                    uint16_t hh;
                    memcpy(&hh, raw + i * bpp + 2, 2);
                    gv[i] = h2f(hh);
                }
            }
            int plus = 0, minus = 0, other = 0;
            for (int i = 0; i < 64 * 16; i++) {
                float g = gv[i];
                plus += g == 1, minus += g == -1, other += g != 1 && g != -1;
            }
            int bad = other || (plus && minus);
            failures += bad;
            printf("%s quad: %d pixels +1, %d pixels -1, %d other%s; row 8:", cw ? "second" : "first", plus, minus, other,
                   bad ? " WRONG" : "");
            for (int x = 0; x < 12; x++) {
                printf(" %g", gv[8 * 64 + x]);
            }
            printf("\n");
        }
        printf("mask %s, blend %d, %s: %s\n", maskName, blend, fmtName, failures ? "FAILED" : "PASS");
        return failures != 0;
    }
}
