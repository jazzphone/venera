// mtlmip: rendering into mip levels and sampling them back at an explicit level -- Core Animation's variable blur
// (Liquid Glass) does both. Each level of a 192x192 texture is cleared to its own color, (a) through the render pass's
// level and (b) through a texture view of that level; a fragment shader then samples each level with level(n).
//   mtlmip            (needs the process allow-listed, e.g. VGMTL_ENABLE=1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint vid [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; V o; o.p = float4(p[vid],0,1); return o; }\n"
    "fragment half4 lvl(V in [[stage_in]], texture2d<half> t [[texture(0)]], constant float &lod [[buffer(0)]]) {\n"
    "  constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);\n"
    "  return t.sample(s, float2(0.5, 0.5), level(lod)); }\n"
    "fragment half4 fill(V in [[stage_in]], constant float4 &c [[buffer(0)]]) { return half4(c); }\n";

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("device: %s\n", dev.name.UTF8String);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"vs"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        rd.fragmentFunction = [lib newFunctionWithName:@"fill"];
        id<MTLRenderPipelineState> fillPS = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
        rd.fragmentFunction = [lib newFunctionWithName:@"lvl"];
        id<MTLRenderPipelineState> lvlPS = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        float colors[4][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {1, 1, 0, 1}};
        const char *names[4] = {"red", "green", "blue", "yellow"};
        int failures = 0;
        for (int how = 0; how < 2; how++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                         width:192 height:192 mipmapped:YES];
            td.mipmapLevelCount = 4;
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> t = [dev newTextureWithDescriptor:td];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            for (int l = 0; l < 4; l++) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
                if (how == 0) {
                    rp.colorAttachments[0].texture = t;
                    rp.colorAttachments[0].level = (NSUInteger)l;
                } else {
                    rp.colorAttachments[0].texture = [t newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                         textureType:MTLTextureType2D levels:NSMakeRange(l, 1)
                                                                              slices:NSMakeRange(0, 1)];
                }
                rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
                [e setRenderPipelineState:fillPS];
                [e setFragmentBytes:colors[l] length:16 atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [e endEncoding];
            }
            MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                         width:4 height:1 mipmapped:NO];
            od.usage = MTLTextureUsageRenderTarget;
            od.storageMode = MTLStorageModeManaged;
            id<MTLTexture> out = [dev newTextureWithDescriptor:od];
            for (int l = 0; l < 4; l++) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
                rp.colorAttachments[0].texture = out;
                rp.colorAttachments[0].loadAction = l ? MTLLoadActionLoad : MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
                [e setRenderPipelineState:lvlPS];
                [e setScissorRect:(MTLScissorRect){(NSUInteger)l, 0, 1, 1}];
                float lod = (float)l;
                [e setFragmentBytes:&lod length:4 atIndex:0];
                [e setFragmentTexture:t atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [e endEncoding];
            }
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be synchronizeResource:out];
            [be endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            uint8_t px[16];
            [out getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 1) mipmapLevel:0];
            printf("%s:", how ? "views of each level" : "render pass level");
            for (int l = 0; l < 4; l++) {
                uint8_t *p = px + l * 4;   // BGRA
                int ok = abs(p[2] - (int)(colors[l][0] * 255)) < 8 && abs(p[1] - (int)(colors[l][1] * 255)) < 8 &&
                         abs(p[0] - (int)(colors[l][2] * 255)) < 8;
                failures += !ok;
                printf("  level %d %s (%u %u %u)%s", l, names[l], p[2], p[1], p[0], ok ? "" : " WRONG");
            }
            printf("\n");
        }
        printf("%s\n", failures ? "FAILED" : "PASS");
        return failures != 0;
    }
}
