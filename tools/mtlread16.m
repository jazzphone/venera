// mtlread16: texture reads with 16-bit integer coordinates (tex.read(ushort2(...)), RenderBox's coverage reads) against
// 32-bit ones, from a 64x8 R16Float texture whose texel (x, y) holds x + 100 y.
//   mtlread16            (needs the process allow-listed, e.g. VGMTL_ENABLE=1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint vid [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; V o; o.p = float4(p[vid],0,1); return o; }\n"
    "fragment float4 r16(V in [[stage_in]], texture2d<half, access::read> t [[texture(5)]]) { return float4(float(t.read(ushort2(in.p.xy)).r), 0, 0, 1); }\n"
    "fragment float4 r32(V in [[stage_in]], texture2d<half, access::read> t [[texture(5)]]) { return float4(float(t.read(uint2(in.p.xy)).r), 0, 0, 1); }\n";

static uint16_t f2h(float f) {
    uint32_t x;
    memcpy(&x, &f, 4);
    uint32_t e = (x >> 23) & 0xff, m = x & 0x7fffff;
    return e < 113 ? 0 : (uint16_t)(((e - 112) << 10) | (m >> 13));
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
        if (!lib) {
            printf("%s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float width:64 height:8 mipmapped:NO];
        sd.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> src = [dev newTextureWithDescriptor:sd];
        uint16_t in[64 * 8];
        for (int y = 0; y < 8; y++) {
            for (int x = 0; x < 64; x++) {
                in[y * 64 + x] = f2h((float)(x + 100 * y));
            }
        }
        [src replaceRegion:MTLRegionMake2D(0, 0, 64, 8) mipmapLevel:0 withBytes:in bytesPerRow:128];
        int failures = 0;
        for (NSString *fn in @[ @"r16", @"r32" ]) {
            MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
            rd.vertexFunction = [lib newFunctionWithName:@"vs"];
            rd.fragmentFunction = [lib newFunctionWithName:fn];
            rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:64 height:8 mipmapped:NO];
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
            [e setFragmentTexture:src atIndex:5];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            float px[64 * 8 * 4];
            [t getBytes:px bytesPerRow:64 * 16 fromRegion:MTLRegionMake2D(0, 0, 64, 8) mipmapLevel:0];
            int bad = 0;
            for (int y = 0; y < 8; y++) {
                for (int x = 0; x < 64; x++) {
                    bad += px[(y * 64 + x) * 4] != (float)(x + 100 * y);
                }
            }
            failures += bad > 0;
            printf("%s: %d of 512 wrong; row 2:", fn.UTF8String, bad);
            for (int x = 0; x < 10; x++) {
                printf(" %g", px[(2 * 64 + x) * 4]);
            }
            printf("\n");
        }
        printf("%s\n", failures ? "FAILED" : "PASS");
        return failures != 0;
    }
}
