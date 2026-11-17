// mtlmrt: a fragment output of two halves to a 2-channel target, in the shapes RenderBox's path shaders use, read back
// against the CPU: (a) one target, half2 at color(0); (b) two targets, only color(1) written (half2), color(0)
// R16Float with nothing written; (c) as (b) with float2. Each writes (0.25, -1) everywhere.
// (d) as (b) with a [[front_facing]] input; (e) as (b) with a second output, color(0), after it in the struct.
//   mtlmrt            (needs the process allow-listed, e.g. VGMTL_ENABLE=1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint vid [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; V o; o.p = float4(p[vid],0,1); return o; }\n"
    "struct A { half2 c [[color(0)]]; };\n"
    "fragment A fa(V in [[stage_in]]) { A o; o.c = half2(0.25h, -1.0h); return o; }\n"
    "struct B { half2 c [[color(1)]]; };\n"
    "fragment B fb(V in [[stage_in]]) { B o; o.c = half2(0.25h, -1.0h); return o; }\n"
    "struct C { float2 c [[color(1)]]; };\n"
    "fragment C fc(V in [[stage_in]]) { C o; o.c = float2(0.25, -1.0); return o; }\n"
    "fragment B fd(bool ff [[front_facing]]) { B o; o.c = half2(0.25h, ff ? 1.0h : -1.0h); return o; }\n"
    "fragment B ff(V in [[stage_in]]) { B o; o.c = half2(0.25h, in.p.x > 1e9 ? 1.0h : -1.0h); return o; }\n"
    "fragment B fg(bool ff [[front_facing]]) { B o; o.c = half2(0.25h, half(ff ? 1.0f : -1.0f)); return o; }\n"
    "fragment C fh(bool ff [[front_facing]]) { C o; o.c = float2(0.25, ff ? 1.0 : -1.0); return o; }\n"
    "fragment B fi(bool ff [[front_facing]]) { B o; int s = ff ? 1 : -1; o.c = half2(0.25h, half(s)); return o; }\n"
    "struct E { half2 c [[color(1)]]; half4 d [[color(0)]]; };\n"
    "fragment E fe(V in [[stage_in]]) { E o; o.c = half2(0.25h, -1.0h); o.d = half4(0); return o; }\n";

static float h2f(uint16_t h) {
    uint32_t e = (h >> 10) & 31, m = h & 1023;
    float v = e == 0 ? ldexpf((float)m, -24) : ldexpf((float)(m | 1024), (int)e - 25);
    return (h & 0x8000) ? -v : v;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        int failures = 0;
        for (NSString *fn in @[ @"fa", @"fb", @"fc", @"fd", @"fe", @"ff", @"fg", @"fh", @"fi" ]) {
            BOOL two = ![fn isEqual:@"fa"];
            MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
            rd.vertexFunction = [lib newFunctionWithName:@"vs"];
            rd.fragmentFunction = [lib newFunctionWithName:fn];
            if (two) {
                rd.colorAttachments[0].pixelFormat = MTLPixelFormatR16Float;
                rd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
                rd.colorAttachments[1].pixelFormat = MTLPixelFormatRG16Float;
            } else {
                rd.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
            }
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
            if (!ps) {
                printf("%s: pipeline: %s\n", fn.UTF8String, err.localizedDescription.UTF8String);
                failures++;
                continue;
            }
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:32 height:8 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> acc = [dev newTextureWithDescriptor:td];
            td.pixelFormat = MTLPixelFormatR16Float;
            id<MTLTexture> c0 = [dev newTextureWithDescriptor:td];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
            rp.colorAttachments[0].texture = two ? c0 : acc;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            if (two) {
                rp.colorAttachments[1].texture = acc;
                rp.colorAttachments[1].loadAction = MTLLoadActionClear;
                rp.colorAttachments[1].storeAction = MTLStoreActionStore;
            }
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:ps];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            uint16_t px[32 * 8 * 2];
            [acc getBytes:px bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(0, 0, 32, 8) mipmapLevel:0];
            int bad = 0;
            for (int i = 0; i < 32 * 8; i++) {
                float want = ([fn isEqual:@"fd"] || [fn isEqual:@"fg"] || [fn isEqual:@"fh"] || [fn isEqual:@"fi"]) ? h2f(px[1]) : -1.0f;   // front_facing: either sign, the same everywhere
                bad += h2f(px[i * 2]) != 0.25f || h2f(px[i * 2 + 1]) != want || fabsf(want) != 1.0f;
            }
            failures += bad > 0;
            printf("%s (%s): %d of 256 wrong; first pixels:", fn.UTF8String,
                   [fn isEqual:@"fa"] ? "half2 at color(0)" : [fn isEqual:@"fb"] ? "half2 at color(1)" : [fn isEqual:@"fc"] ? "float2 at color(1)" : [fn isEqual:@"fd"] ? "front_facing input" : [fn isEqual:@"fe"] ? "color(1) then color(0)" : [fn isEqual:@"ff"] ? "half select on position" : [fn isEqual:@"fg"] ? "front_facing, float select" : [fn isEqual:@"fh"] ? "front_facing, all float" : "front_facing via int", bad);
            for (int i = 0; i < 4; i++) {
                printf(" (%g, %g)", h2f(px[i * 2]), h2f(px[i * 2 + 1]));
            }
            printf("\n");
        }
        printf("%s\n", failures ? "FAILED" : "PASS");
        return failures != 0;
    }
}
