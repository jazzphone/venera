// mtlrender: stage 4c's checkpoint. Plain Metal API: render into offscreen textures with render.metallib (built on the
// Mac from tools/shaders/render.metal), read the pixels back with getBytes and compare them with what Metal promises.
//   mtlrender [render.metallib]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static int failures;
enum { W = 64, H = 64 };

typedef struct {
    float pos[2], uv[2], color[4];
} Vtx;

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> lib;

static id<MTLTexture> target(MTLTextureUsage extra) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | extra;
    d.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:d];
}

static MTLRenderPassDescriptor *pass(id<MTLTexture> t, MTLLoadAction load, MTLClearColor clear) {
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = t;
    p.colorAttachments[0].loadAction = load;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = clear;
    return p;
}

static id<MTLRenderPipelineState> pipeline(NSString *vs, NSString *fs, MTLVertexDescriptor *vd, BOOL blend) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:vs];
    d.fragmentFunction = [lib newFunctionWithName:fs];
    d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    if (blend) {
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
    }
    NSError *err = nil;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    printf("  pipeline %s + %s%s: %s (%.1f ms)%s%s\n", vs.UTF8String, fs.UTF8String, blend ? " (blend)" : "",
           p ? "ok" : "FAILED", (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, err ? "  " : "",
           err ? err.localizedDescription.UTF8String : "");
    if (!p) {
        failures++;
    }
    return p;
}

static BOOL finish(id<MTLCommandBuffer> cb) {
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        printf("  command buffer status %lu: %s\n", (unsigned long)cb.status, cb.error.localizedDescription.UTF8String);
        failures++;
        return NO;
    }
    return YES;
}

// Reads the texture back and compares pixels (x, y) with an expected RGBA, +-2 per channel.
static void expect(id<MTLTexture> t, const char *what, int n, const int (*pts)[2], const uint8_t (*want)[4]) {
    uint8_t px[W * H * 4];
    [t getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    int bad = 0;
    for (int i = 0; i < n; i++) {
        const uint8_t *p = px + (pts[i][1] * W + pts[i][0]) * 4;
        for (int c = 0; c < 4; c++) {
            if (abs((int)p[c] - (int)want[i][c]) > 2) {
                printf("    %s: pixel (%d,%d) = %u %u %u %u, want %u %u %u %u\n", what, pts[i][0], pts[i][1], p[0], p[1],
                       p[2], p[3], want[i][0], want[i][1], want[i][2], want[i][3]);
                bad++;
                break;
            }
        }
    }
    printf("  %-48s %s\n", what, bad ? "FAIL" : "ok");
    failures += bad != 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("no Metal device (is the accelerator armed?)\n");
            return 1;
        }
        printf("device: %s\n", dev.name.UTF8String);
        NSError *err = nil;
        lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:argc > 1 ? @(argv[1]) : @"render.metallib"] error:&err];
        if (!lib) {
            printf("library: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        printf("library functions: %s\n", [[lib.functionNames componentsJoinedByString:@", "] UTF8String]);
        queue = [dev newCommandQueue];
        const MTLClearColor gray = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);

        // 1. Clear only.
        id<MTLTexture> t = target(0);
        {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            [[cb renderCommandEncoderWithDescriptor:pass(t, MTLLoadActionClear, gray)] endEncoding];
            if (finish(cb)) {
                const int p[][2] = {{0, 0}, {63, 63}, {31, 17}};
                const uint8_t w[][4] = {{64, 128, 191, 255}, {64, 128, 191, 255}, {64, 128, 191, 255}};
                expect(t, "clear", 3, p, w);
            }
        }

        // 2. A red triangle in the top half from a vertex buffer + setVertexBytes, back faces culled: left -> top ->
        //    right is clockwise on screen, Metal's default front face, so it must be drawn, and at the top.
        id<MTLRenderPipelineState> pColor = pipeline(@"tri_vertex", @"color_fragment", nil, NO);
        if (pColor) {
            Vtx v[3] = {{{-1, 0}, {0, 0}, {1, 0, 0, 1}}, {{0, 1}, {0, 0}, {1, 0, 0, 1}}, {{1, 0}, {0, 0}, {1, 0, 0, 1}}};
            id<MTLBuffer> vb = [dev newBufferWithBytes:v length:sizeof(v) options:MTLResourceStorageModeShared];
            float offset[2] = {0, 0};
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(t, MTLLoadActionClear, gray)];
            [e setRenderPipelineState:pColor];
            [e setCullMode:MTLCullModeBack];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setVertexBytes:offset length:sizeof(offset) atIndex:1];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            if (finish(cb)) {
                const int p[][2] = {{32, 28}, {32, 4}, {32, 40}, {2, 2}};
                const uint8_t w[][4] = {{255, 0, 0, 255}, {255, 0, 0, 255}, {64, 128, 191, 255}, {64, 128, 191, 255}};
                expect(t, "triangle: top half, clockwise front face kept", 4, p, w);
            }
            // The same triangle with front faces culled must disappear.
            cb = [queue commandBuffer];
            e = [cb renderCommandEncoderWithDescriptor:pass(t, MTLLoadActionClear, gray)];
            [e setRenderPipelineState:pColor];
            [e setCullMode:MTLCullModeFront];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setVertexBytes:offset length:sizeof(offset) atIndex:1];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            if (finish(cb)) {
                const int p[][2] = {{32, 28}};
                const uint8_t w[][4] = {{64, 128, 191, 255}};
                expect(t, "triangle: culled as a front face", 1, p, w);
            }

            // 3. An indexed quad (4 vertices, 6 uint16 indices) in the bottom-right quarter, offset by setVertexBytes.
            Vtx q[4] = {{{0, 0}, {0, 0}, {0, 1, 0, 1}}, {{1, 0}, {0, 0}, {0, 1, 0, 1}},
                        {{1, 1}, {0, 0}, {0, 1, 0, 1}}, {{0, 1}, {0, 0}, {0, 1, 0, 1}}};
            uint16_t idx[6] = {0, 1, 2, 0, 2, 3};
            id<MTLBuffer> qb = [dev newBufferWithBytes:q length:sizeof(q) options:MTLResourceStorageModeShared];
            id<MTLBuffer> ib = [dev newBufferWithBytes:idx length:sizeof(idx) options:MTLResourceStorageModeShared];
            float down[2] = {0, -1};
            cb = [queue commandBuffer];
            e = [cb renderCommandEncoderWithDescriptor:pass(t, MTLLoadActionClear, gray)];
            [e setRenderPipelineState:pColor];
            [e setVertexBuffer:qb offset:0 atIndex:0];
            [e setVertexBytes:down length:sizeof(down) atIndex:1];
            [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib
                   indexBufferOffset:0];
            [e endEncoding];
            if (finish(cb)) {
                const int p[][2] = {{48, 48}, {16, 48}, {48, 16}};
                const uint8_t w[][4] = {{0, 255, 0, 255}, {64, 128, 191, 255}, {64, 128, 191, 255}};
                expect(t, "indexed quad: bottom-right quarter", 3, p, w);
            }
        }

        // 4. A 2x2 texture (red green / blue white) on a full-screen quad, nearest filtering: each quarter one texel.
        id<MTLRenderPipelineState> pTex = pipeline(@"tri_vertex", @"texture_fragment", nil, NO);
        if (pTex) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:2 height:2 mipmapped:NO];
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            const uint8_t texels[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
            [tex replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:texels bytesPerRow:8];
            uint8_t back[16] = {0};
            [tex getBytes:back bytesPerRow:8 fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0];
            int same = !memcmp(back, texels, 16);
            printf("  %-48s %s\n", "replaceRegion + getBytes round trip", same ? "ok" : "FAIL");
            failures += !same;
            MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
            sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
            id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
            Vtx v[6] = {{{-1, 1}, {0, 0}, {1, 1, 1, 1}}, {{1, 1}, {1, 0}, {1, 1, 1, 1}}, {{1, -1}, {1, 1}, {1, 1, 1, 1}},
                        {{-1, 1}, {0, 0}, {1, 1, 1, 1}}, {{1, -1}, {1, 1}, {1, 1, 1, 1}}, {{-1, -1}, {0, 1}, {1, 1, 1, 1}}};
            float zero[2] = {0, 0};
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(t, MTLLoadActionDontCare, gray)];
            [e setRenderPipelineState:pTex];
            [e setVertexBytes:v length:sizeof(v) atIndex:0];
            [e setVertexBytes:zero length:sizeof(zero) atIndex:1];
            [e setFragmentTexture:tex atIndex:0];
            [e setFragmentSamplerState:smp atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            if (finish(cb)) {
                const int p[][2] = {{16, 16}, {48, 16}, {16, 48}, {48, 48}};
                const uint8_t w[][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 255}};
                expect(t, "textured quad: texel (0,0) at the top left", 4, p, w);
            }
        }

        // 5. Alpha blending: half-transparent red over the gray clear.
        id<MTLRenderPipelineState> pBlend = pipeline(@"tri_vertex", @"color_fragment", nil, YES);
        if (pBlend) {
            Vtx v[3] = {{{-3, -1}, {0, 0}, {1, 0, 0, 0.5}}, {{1, 3}, {0, 0}, {1, 0, 0, 0.5}}, {{1, -1}, {0, 0}, {1, 0, 0, 0.5}}};
            float zero[2] = {0, 0};
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(t, MTLLoadActionClear, gray)];
            [e setRenderPipelineState:pBlend];
            [e setVertexBytes:v length:sizeof(v) atIndex:0];
            [e setVertexBytes:zero length:sizeof(zero) atIndex:1];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            if (finish(cb)) {
                const int p[][2] = {{32, 32}};
                const uint8_t w[][4] = {{160, 64, 96, 128}};   // 0.5*red + 0.5*gray; alpha = src alpha
                expect(t, "blending: 50% red over gray", 1, p, w);
            }
        }

        // 5b. Framebuffer fetch: two draws in one pass, each reading what the pass holds ([[color(0)]]).
        id<MTLRenderPipelineState> pSwap = pipeline(@"tri_vertex", @"fetch_swap_fragment", nil, NO);
        id<MTLRenderPipelineState> pHalf = pipeline(@"tri_vertex", @"fetch_half_fragment", nil, NO);
        if (pSwap && pHalf) {
            Vtx v[3] = {{{-3, -1}, {0, 0}, {1, 1, 1, 1}}, {{1, 3}, {0, 0}, {1, 1, 1, 1}}, {{1, -1}, {0, 0}, {1, 1, 1, 1}}};
            float zero[2] = {0, 0};
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(t, MTLLoadActionClear, gray)];
            [e setVertexBytes:v length:sizeof(v) atIndex:0];
            [e setVertexBytes:zero length:sizeof(zero) atIndex:1];
            [e setRenderPipelineState:pSwap];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e setRenderPipelineState:pHalf];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            if (finish(cb)) {
                const int p[][2] = {{32, 32}};
                const uint8_t w[][4] = {{96, 64, 32, 128}};   // gray (64,128,192) swapped, then halved
                expect(t, "framebuffer fetch: swap, then halve", 1, p, w);
            }
        } else {
            failures++;
        }

        // 6. Vertex attributes through a vertex descriptor: an interleaved float2 + float4 triangle in the bottom half.
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat2;
        vd.attributes[0].offset = 0;
        vd.attributes[0].bufferIndex = 0;
        vd.attributes[1].format = MTLVertexFormatFloat4;
        vd.attributes[1].offset = 8;
        vd.attributes[1].bufferIndex = 0;
        vd.layouts[0].stride = 24;
        id<MTLRenderPipelineState> pAttr = pipeline(@"attr_vertex", @"color_fragment", vd, NO);
        if (pAttr) {
            float v[3][6] = {{-1, 0, 0, 0, 1, 1}, {1, 0, 0, 0, 1, 1}, {0, -1, 0, 0, 1, 1}};
            id<MTLBuffer> vb = [dev newBufferWithBytes:v length:sizeof(v) options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(t, MTLLoadActionClear, gray)];
            [e setRenderPipelineState:pAttr];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            if (finish(cb)) {
                const int p[][2] = {{32, 36}, {32, 20}};
                const uint8_t w[][4] = {{0, 0, 255, 255}, {64, 128, 191, 255}};
                expect(t, "vertex descriptor: blue triangle, bottom half", 2, p, w);
            }
        }

        // 7. A compute kernel writing a texture (storage image), read back.
        id<MTLComputePipelineState> pPat = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"pattern"]
                                                                             error:&err];
        printf("  pipeline pattern (compute, texture write): %s%s%s\n", pPat ? "ok" : "FAILED", err ? "  " : "",
               err ? err.localizedDescription.UTF8String : "");
        if (pPat) {
            id<MTLTexture> st = target(MTLTextureUsageShaderWrite);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:pPat];
            [e setTexture:st atIndex:0];
            [e dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [e endEncoding];
            if (finish(cb)) {
                const int p[][2] = {{0, 0}, {5, 9}, {63, 1}, {40, 63}};
                uint8_t w[4][4];
                for (int i = 0; i < 4; i++) {
                    w[i][0] = (uint8_t)p[i][0], w[i][1] = (uint8_t)p[i][1], w[i][2] = (uint8_t)(p[i][0] ^ p[i][1]), w[i][3] = 255;
                }
                expect(st, "compute: texture write pattern", 4, p, (const uint8_t(*)[4])w);
            }
        } else {
            failures++;
        }
        printf("%s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
        return failures ? 1 : 0;
    }
}
