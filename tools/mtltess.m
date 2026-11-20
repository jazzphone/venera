// mtltess (5d): Metal tessellation, plain Metal API. Compiles its shaders at run time (newLibraryWithSource), draws quad
// patches with a post-tessellation vertex function into a 256x256 offscreen texture, reads it back and checks the
// pixels against what the patches must cover. Runs the same on a real Mac (the reference) and in the VM:
//   VGMTL_ENABLE=1 ./mtltess        (the environment allows a plain process the VM's device)
// Prints one line per check, a coverage count and checksum per draw, and "mtltess: PASS" or "mtltess: FAIL (n)" last.
//
// The scene: three quad patches of 4 control points each (PerPatchControlPoint vertex buffer, float2 positions) and one
// float4 per patch (PerPatch vertex buffer). Patch 0 covers the left of the middle band, patch 1 the right; patch 2 sits
// in the top band with edge factors 0, so it must be culled. The fragment color is
//   r = 0.5 * perPatch.r + 0.25 * patch_id   (patch 0: 0.125, patch 1: 0.625 -- wrong patch_id or per-patch data shows)
//   g = u, b = v                              (position_in_patch, interpolated: checks the control-point order)
// Draws: A) factors written by the CPU, drawPatches; B) factors written by a compute kernel (PerPatch factor step);
// C) the same patches through drawIndexedPatches with a uint16 control-point index buffer and shuffled control points.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void tess_factors(device MTLQuadTessellationFactorsHalf *f [[buffer(0)]], constant uint &n [[buffer(1)]],\n"
     "                         uint pid [[thread_position_in_grid]]) {\n"
     "    if (pid >= n) return;\n"
     "    half k = pid < 2 ? 4.0h : 0.0h;\n"
     "    for (int i = 0; i < 4; i++) f[pid].edgeTessellationFactor[i] = k;\n"
     "    f[pid].insideTessellationFactor[0] = k;\n"
     "    f[pid].insideTessellationFactor[1] = k;\n"
     "}\n"
     "struct CP { float2 position [[attribute(0)]]; };\n"
     "struct PatchIn {\n"
     "    patch_control_point<CP> cp;\n"
     "    float4 tint [[attribute(1)]];\n"
     "};\n"
     "struct VOut { float4 position [[position]]; float4 color; };\n"
     "[[patch(quad, 4)]]\n"
     "vertex VOut tess_vertex(PatchIn patch [[stage_in]], float2 uv [[position_in_patch]], uint pid [[patch_id]]) {\n"
     "    float2 a = mix(patch.cp[0].position, patch.cp[1].position, uv.x);\n"
     "    float2 b = mix(patch.cp[3].position, patch.cp[2].position, uv.x);\n"
     "    VOut o;\n"
     "    o.position = float4(mix(a, b, uv.y), 0.0, 1.0);\n"
     "    o.color = float4(0.5 * patch.tint.r + 0.25 * float(pid), uv.x, uv.y, 1.0);\n"
     "    return o;\n"
     "}\n"
     "fragment float4 tess_fragment(VOut in [[stage_in]]) { return in.color; }\n";

enum { W = 256, H = 256, kPatches = 3 };
static int failures;

// patch k's rectangle in NDC: x0, y0, x1, y1
static const float kRect[kPatches][4] = {{-0.75f, -0.5f, -0.05f, 0.5f}, {0.05f, -0.5f, 0.75f, 0.5f}, {-0.5f, 0.6f, 0.5f, 0.9f}};
static const float kTint[kPatches] = {0.25f, 0.75f, 1.0f};

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;

static BOOL finish(id<MTLCommandBuffer> cb, const char *what) {
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        printf("  %s: command buffer status %lu: %s\n", what, (unsigned long)cb.status,
               cb.error.localizedDescription.UTF8String ?: "-");
        failures++;
        return NO;
    }
    return YES;
}

static id<MTLRenderPipelineState> pipeline(id<MTLLibrary> lib, MTLTessellationControlPointIndexType cpidx,
                                           MTLTessellationFactorStepFunction step) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"tess_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"tess_fragment"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[0].offset = 0;
    vd.layouts[0].stride = 8;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerPatchControlPoint;
    vd.attributes[1].format = MTLVertexFormatFloat4;
    vd.attributes[1].bufferIndex = 1;
    vd.attributes[1].offset = 0;
    vd.layouts[1].stride = 16;
    vd.layouts[1].stepFunction = MTLVertexStepFunctionPerPatch;
    d.vertexDescriptor = vd;
    d.maxTessellationFactor = 16;
    d.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
    d.tessellationPartitionMode = MTLTessellationPartitionModeInteger;
    d.tessellationFactorStepFunction = step;
    d.tessellationOutputWindingOrder = MTLWindingClockwise;
    d.tessellationControlPointIndexType = cpidx;
    NSError *err = nil;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    printf("  pipeline (control-point index type %lu, factor step %lu): %s (%.1f ms)%s%s\n", (unsigned long)cpidx,
           (unsigned long)step, p ? "ok" : "FAILED", (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, err ? "  " : "",
           err ? err.localizedDescription.UTF8String : "");
    if (!p) {
        failures++;
    }
    return p;
}

static id<MTLTexture> target(void) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeManaged;
    return [dev newTextureWithDescriptor:d];
}

static MTLRenderPassDescriptor *pass(id<MTLTexture> t) {
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = t;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
    return p;
}

// What pixel (x, y) must be: inside (1) with its color, outside a patch (0, the clear color), or near an edge (-1, not
// checked: the two GPUs may round the edge differently).
static int expected(int x, int y, uint8_t want[4]) {
    float nx = (x + 0.5f) / W * 2 - 1, ny = 1 - (y + 0.5f) / H * 2, edge = 2.5f * 2 / W;
    for (int k = 0; k < 2; k++) {
        const float *r = kRect[k];
        if (nx > r[0] - edge && nx < r[2] + edge && ny > r[1] - edge && ny < r[3] + edge) {
            if (nx < r[0] + edge || nx > r[2] - edge || ny < r[1] + edge || ny > r[3] - edge) {
                return -1;
            }
            float u = (nx - r[0]) / (r[2] - r[0]), v = (ny - r[1]) / (r[3] - r[1]);
            float c[3] = {0.5f * kTint[k] + 0.25f * k, u, v};
            for (int i = 0; i < 3; i++) {
                want[i] = (uint8_t)(c[i] * 255 + 0.5f);
            }
            want[3] = 255;
            return 1;
        }
    }
    want[0] = 64, want[1] = 128, want[2] = 191, want[3] = 255;
    return 0;
}

static void check(id<MTLTexture> t, const char *what) {
    static uint8_t px[W * H * 4];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b synchronizeResource:t];
    [b endEncoding];
    if (!finish(cb, what)) {
        return;
    }
    [t getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    int covered = 0, wantCovered = 0, bad = 0, shown = 0;
    uint32_t sum = 0;
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            const uint8_t *p = px + (y * W + x) * 4;
            BOOL clear = abs(p[0] - 64) <= 2 && abs(p[1] - 128) <= 2 && abs(p[2] - 191) <= 2;
            covered += !clear;
            sum = sum * 31 + (uint32_t)(p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24);
            uint8_t want[4];
            int e = expected(x, y, want);
            wantCovered += e == 1;
            if (e < 0) {
                continue;
            }
            int off = 0;
            for (int c = 0; c < 4; c++) {
                off |= abs((int)p[c] - (int)want[c]) > 3;
            }
            if (off) {
                if (shown++ < 6) {
                    printf("    %s: pixel (%d,%d) = %u %u %u %u, want %u %u %u %u\n", what, x, y, p[0], p[1], p[2], p[3],
                           want[0], want[1], want[2], want[3]);
                }
                bad++;
            }
        }
    }
    // a few named points too, so a failure says where
    const struct {
        int x, y;
        const char *name;
    } pts[] = {{77, 128, "patch 0 middle"}, {178, 128, "patch 1 middle"}, {40, 72, "patch 0 top-left"},
               {216, 184, "patch 1 bottom-right"}, {128, 32, "culled patch 2"}, {128, 128, "gap between patches"},
               {8, 8, "corner"}};
    for (size_t i = 0; i < sizeof(pts) / sizeof(pts[0]); i++) {
        const uint8_t *p = px + (pts[i].y * W + pts[i].x) * 4;
        printf("    %-22s (%3d,%3d) = %3u %3u %3u %3u\n", pts[i].name, pts[i].x, pts[i].y, p[0], p[1], p[2], p[3]);
    }
    printf("  %-40s %s  (%d pixels covered, %d expected away from edges; %d wrong; checksum %08x)\n", what,
           bad ? "FAIL" : "ok", covered, wantCovered, bad, sum);
    failures += bad != 0;
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("no Metal device (VGMTL_ENABLE=1 in the VM?)\n");
            return 2;
        }
        printf("device: %s\n", dev.name.UTF8String);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:[MTLCompileOptions new] error:&err];
        if (!lib) {
            printf("newLibraryWithSource: FAILED: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        id<MTLFunction> tv = [lib newFunctionWithName:@"tess_vertex"];
        printf("tess_vertex: patchType %lu (2 = quad), patchControlPointCount %ld (4)\n", (unsigned long)tv.patchType,
               (long)tv.patchControlPointCount);
        if (tv.patchType != MTLPatchTypeQuad || tv.patchControlPointCount != 4) {
            printf("  function queries FAIL\n");
            failures++;
        }
        queue = [dev newCommandQueue];

        // control points: (x0,y0) (x1,y0) (x1,y1) (x0,y1) per patch -- u along x, v along y
        float cps[kPatches * 4 * 2], tint[kPatches * 4];
        for (int k = 0; k < kPatches; k++) {
            const float *r = kRect[k];
            const float q[8] = {r[0], r[1], r[2], r[1], r[2], r[3], r[0], r[3]};
            memcpy(cps + k * 8, q, sizeof(q));
            tint[k * 4 + 0] = kTint[k], tint[k * 4 + 1] = tint[k * 4 + 2] = 0, tint[k * 4 + 3] = 1;
        }
        id<MTLBuffer> cpBuf = [dev newBufferWithBytes:cps length:sizeof(cps) options:MTLResourceStorageModeShared];
        id<MTLBuffer> tintBuf = [dev newBufferWithBytes:tint length:sizeof(tint) options:MTLResourceStorageModeShared];
        // MTLQuadTessellationFactorsHalf: edge[4], inside[2]; 4.0 is 0x4400 as a half
        uint16_t fac[kPatches * 6];
        for (int k = 0; k < kPatches; k++) {
            for (int i = 0; i < 6; i++) {
                fac[k * 6 + i] = k < 2 ? 0x4400 : 0;
            }
        }
        id<MTLBuffer> facCpu = [dev newBufferWithBytes:fac length:sizeof(fac) options:MTLResourceStorageModeShared];

        id<MTLRenderPipelineState> p = pipeline(lib, MTLTessellationControlPointIndexTypeNone,
                                                MTLTessellationFactorStepFunctionPerPatch);
        id<MTLTexture> t = target();
        if (p) {
            // A. CPU-written factors
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(t)];
            [e setRenderPipelineState:p];
            [e setVertexBuffer:cpBuf offset:0 atIndex:0];
            [e setVertexBuffer:tintBuf offset:0 atIndex:1];
            [e setTessellationFactorBuffer:facCpu offset:0 instanceStride:0];
            [e drawPatches:4 patchStart:0 patchCount:kPatches patchIndexBuffer:nil patchIndexBufferOffset:0 instanceCount:1
                baseInstance:0];
            [e endEncoding];
            if (finish(cb, "A")) {
                check(t, "A: drawPatches, CPU factors");
            }

            // B. factors from a compute kernel in the same command buffer
            id<MTLComputePipelineState> kp = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"tess_factors"]
                                                                                error:&err];
            if (!kp) {
                printf("  factor kernel pipeline FAILED: %s\n", err.localizedDescription.UTF8String);
                failures++;
            } else {
                id<MTLBuffer> facGpu = [dev newBufferWithLength:sizeof(fac) options:MTLResourceStorageModePrivate];
                uint32_t n = kPatches;
                cb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:kp];
                [ce setBuffer:facGpu offset:0 atIndex:0];
                [ce setBytes:&n length:sizeof(n) atIndex:1];
                [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(4, 1, 1)];
                [ce endEncoding];
                e = [cb renderCommandEncoderWithDescriptor:pass(t)];
                [e setRenderPipelineState:p];
                [e setVertexBuffer:cpBuf offset:0 atIndex:0];
                [e setVertexBuffer:tintBuf offset:0 atIndex:1];
                [e setTessellationFactorBuffer:facGpu offset:0 instanceStride:0];
                [e drawPatches:4 patchStart:0 patchCount:kPatches patchIndexBuffer:nil patchIndexBufferOffset:0 instanceCount:1
                    baseInstance:0];
                [e endEncoding];
                if (finish(cb, "B")) {
                    check(t, "B: drawPatches, kernel factors");
                }
            }
        }

        // C. drawIndexedPatches: the control points stored in reverse, a uint16 index buffer puts them back
        id<MTLRenderPipelineState> pi = pipeline(lib, MTLTessellationControlPointIndexTypeUInt16,
                                                 MTLTessellationFactorStepFunctionPerPatch);
        if (pi) {
            float rev[kPatches * 4 * 2];
            uint16_t idx[kPatches * 4];
            for (int i = 0; i < kPatches * 4; i++) {
                int j = kPatches * 4 - 1 - i;   // control point i lives at j
                rev[j * 2] = cps[i * 2], rev[j * 2 + 1] = cps[i * 2 + 1];
                idx[i] = (uint16_t)j;
            }
            id<MTLBuffer> revBuf = [dev newBufferWithBytes:rev length:sizeof(rev) options:MTLResourceStorageModeShared];
            id<MTLBuffer> idxBuf = [dev newBufferWithBytes:idx length:sizeof(idx) options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(t)];
            [e setRenderPipelineState:pi];
            [e setVertexBuffer:revBuf offset:0 atIndex:0];
            [e setVertexBuffer:tintBuf offset:0 atIndex:1];
            [e setTessellationFactorBuffer:facCpu offset:0 instanceStride:0];
            [e drawIndexedPatches:4 patchStart:0 patchCount:kPatches patchIndexBuffer:nil patchIndexBufferOffset:0
                controlPointIndexBuffer:idxBuf controlPointIndexBufferOffset:0 instanceCount:1 baseInstance:0];
            [e endEncoding];
            if (finish(cb, "C")) {
                check(t, "C: drawIndexedPatches, uint16 indices");
            }
        }
        printf(failures ? "mtltess: FAIL (%d)\n" : "mtltess: PASS\n", failures);
        return failures ? 1 : 0;
    }
}
