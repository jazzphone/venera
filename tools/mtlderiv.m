// mtlderiv: screen-space derivatives in half and float precision. Core Animation's glass anti-aliases the edges of
// its shapes with fwidth() of a half: each pixel of a 64x16 target gets fwidth/dfdx/dfdy of a smooth ramp, which
// should be the same everywhere.
//   mtlderiv            (needs the process allow-listed, e.g. VGMTL_ENABLE=1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint vid [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; V o; o.p = float4(p[vid],0,1); return o; }\n"
    "fragment float4 fh(V in [[stage_in]]) { half r = half(in.p.x * 0.01h + in.p.y * 0.02h);\n"
    "  return float4(fwidth(r), dfdx(r), dfdy(r), 1); }\n"
    "fragment float4 ff(V in [[stage_in]]) { float r = in.p.x * 0.01 + in.p.y * 0.02;\n"
    "  return float4(fwidth(r), dfdx(r), dfdy(r), 1); }\n";

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        int failures = 0;
        for (NSString *fn in @[ @"fh", @"ff" ]) {
            MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
            rd.vertexFunction = [lib newFunctionWithName:@"vs"];
            rd.fragmentFunction = [lib newFunctionWithName:fn];
            rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                         width:64 height:16 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> t = [dev newTextureWithDescriptor:td];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
            rp.colorAttachments[0].texture = t;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:ps];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            float px[64 * 16 * 4];
            [t getBytes:px bytesPerRow:64 * 16 fromRegion:MTLRegionMake2D(0, 0, 64, 16) mipmapLevel:0];
            int bad = 0;
            for (int i = 0; i < 64 * 16; i++) {
                bad += fabsf(px[i * 4] - 0.03f) > 0.005f || fabsf(px[i * 4 + 1] - 0.01f) > 0.003f || fabsf(px[i * 4 + 2] - 0.02f) > 0.004f;
            }
            failures += bad > 0;
            printf("%s: %d of %d pixels wrong; first pixels fwidth/dfdx/dfdy:", fn.UTF8String, bad, 64 * 16);
            for (int i = 0; i < 6; i++) {
                printf("  %.4f/%.4f/%.4f", px[i * 4], px[i * 4 + 1], px[i * 4 + 2]);
            }
            printf("\n");
        }
        printf("%s\n", failures ? "FAILED" : "PASS");
        return failures != 0;
    }
}
