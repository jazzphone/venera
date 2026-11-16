// mtlpath (5d): RenderBox's path_exterior_vertex, from RenderBox's own metallib, run on recorded inputs (the PathGlobals,
// the CubicSegment array, the strip indices and the _shader_state constant a Dock icon draw used) with a fragment
// shader of ours that paints whatever it covers. Says whether the vertex stage makes any geometry on this device.
//   mtlpath DIR [INSTANCES INDICES W H]   (DIR holds globals.bin, segments.bin, indices.bin, shader_state.bin;
//                                          needs the process allow-listed, e.g. VGMTL_ENABLE=1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// The vertex shader's segment search, written out: a binary search over the CubicSegment array by its running counts,
// moving a device pointer, then the previous segment's end point (index -1).
static NSString *const kSearch =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct Seg { int count; float recip_n; packed_float2 p1, p2, p3; };\n"
     "kernel void search(device const Seg *segs [[buffer(0)]], device float4 *out [[buffer(1)]],\n"
     "                   uint i [[thread_position_in_grid]]) {\n"
     "    int total = as_type<int>(segs[0].recip_n), idx = int(i);\n"
     "    if (total <= idx) { out[i] = float4(-1); return; }\n"
     "    device const Seg *s = segs + 1;\n"
     "    int n = segs[0].count;\n"
     "    while (n > 1) { int h = n >> 1; device const Seg *m = s + h;\n"
     "        bool after = m->count > idx; n = after ? h : n - h; s = after ? s : m; }\n"
     "    float2 prev = float2((s - 1)->p3);\n"
     "    out[i] = float4(float(s->count), prev.x, prev.y, s->p1[0]);\n"
     "}\n";

static NSString *const kFrag =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct PathExteriorVertex { float4 position [[position]]; float2 path_y; float path_slope; float path_intercept;\n"
     "                            half path_value; };\n"
     "fragment float4 paint(PathExteriorVertex in [[stage_in]]) {\n"
     "    return float4(1.0, float(in.path_value), in.path_slope, in.path_intercept);\n"
     "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "mtlpath DIR [INSTANCES INDICES W H]\n");
            return 2;
        }
        NSString *dir = @(argv[1]);
        NSUInteger instances = argc > 2 ? strtoul(argv[2], NULL, 0) : 5, nidx = argc > 3 ? strtoul(argv[3], NULL, 0) : 64;
        NSUInteger W = argc > 4 ? strtoul(argv[4], NULL, 0) : 224, H = argc > 5 ? strtoul(argv[5], NULL, 0) : 128;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("device: %s\n", dev.name.UTF8String);
        NSError *err = nil;
        NSURL *url = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/RenderBox.framework/Versions/A/Resources/default.metallib"];
        id<MTLLibrary> rb = [dev newLibraryWithURL:url error:&err];
        id<MTLLibrary> mine = [dev newLibraryWithSource:kFrag options:[MTLCompileOptions new] error:&err];
        if (!rb || !mine) {
            printf("library: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        {   // the search alone, as a compute kernel, against the CPU
            NSData *sg = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"segments.bin"]];
            id<MTLLibrary> sl = [dev newLibraryWithSource:kSearch options:[MTLCompileOptions new] error:&err];
            id<MTLComputePipelineState> cps = sl ? [dev newComputePipelineStateWithFunction:[sl newFunctionWithName:@"search"] error:&err] : nil;
            if (!cps) {
                printf("search kernel: %s\n", err.localizedDescription.UTF8String);
            } else {
                id<MTLBuffer> sb = [dev newBufferWithBytes:sg.bytes length:sg.length options:MTLResourceStorageModeShared];
                id<MTLBuffer> ob = [dev newBufferWithLength:64 * 16 options:MTLResourceStorageModeShared];
                id<MTLCommandQueue> cq = [dev newCommandQueue];
                id<MTLCommandBuffer> cb = [cq commandBuffer];
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:cps];
                [ce setBuffer:sb offset:0 atIndex:0];
                [ce setBuffer:ob offset:0 atIndex:1];
                [ce dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
                [ce endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                typedef struct { int count; float recip_n, p[6]; } Seg;
                const Seg *segs = sg.bytes;
                const float *o = ob.contents;
                int total, bad = 0;
                memcpy(&total, &segs[0].recip_n, 4);
                for (int i = 0; i < 64; i++) {
                    float e[4] = {-1, -1, -1, -1};
                    if (i < total) {
                        const Seg *sp = segs + 1;
                        int n = segs[0].count;
                        while (n > 1) { int h = n >> 1; const Seg *m = sp + h; int after = m->count > i; n = after ? h : n - h; sp = after ? sp : m; }
                        e[0] = sp->count, e[1] = (sp - 1)->p[4], e[2] = (sp - 1)->p[5], e[3] = sp->p[0];
                    }
                    int ok = 1;
                    for (int k = 0; k < 4; k++) ok &= fabsf(o[i * 4 + k] - e[k]) < 1e-3f || (isinf(e[k]) && isinf(o[i * 4 + k]));
                    if (!ok && bad++ < 4) {
                        printf("  search %d: gpu %g %g %g %g, cpu %g %g %g %g\n", i, o[i * 4], o[i * 4 + 1], o[i * 4 + 2], o[i * 4 + 3],
                               e[0], e[1], e[2], e[3]);
                    }
                }
                printf("segment search: %s (%d of 64 wrong, total %d)\n", bad ? "FAIL" : "ok", bad, total);
            }
        }
        NSData *state = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"shader_state.bin"]];
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
        [cv setConstantValue:state.bytes type:MTLDataTypeUInt4 atIndex:0];
        id<MTLFunction> vf = [rb newFunctionWithName:@"path_exterior_vertex" constantValues:cv error:&err];
        if (!vf) {
            printf("vertex function: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = vf;
        rd.fragmentFunction = [mine newFunctionWithName:@"paint"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
        if (!ps) {
            printf("pipeline: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        NSData *g = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"globals.bin"]];
        NSData *seg = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"segments.bin"]];
        NSData *idx = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"indices.bin"]];
        id<MTLBuffer> segb = [dev newBufferWithBytes:seg.bytes length:seg.length options:MTLResourceStorageModeShared];
        id<MTLBuffer> ib = [dev newBufferWithBytes:idx.bytes length:idx.length options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                     width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        for (int clamp = 0; clamp < 2; clamp++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
            rp.colorAttachments[0].texture = t;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:ps];
            [re setDepthClipMode:clamp ? MTLDepthClipModeClamp : MTLDepthClipModeClip];
            [re setVertexBytes:g.bytes length:g.length atIndex:0];
            [re setVertexBuffer:segb offset:0 atIndex:1];
            [re drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip indexCount:nidx indexType:MTLIndexTypeUInt16
                          indexBuffer:ib indexBufferOffset:0 instanceCount:instances];
            [re endEncoding];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be synchronizeResource:t];
            [be endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            float *px = malloc(W * H * 16);
            [t getBytes:px bytesPerRow:W * 16 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            NSUInteger n = 0, x0 = W, y0 = H, x1 = 0, y1 = 0;
            double vsum = 0;
            for (NSUInteger y = 0; y < H; y++) {
                for (NSUInteger x = 0; x < W; x++) {
                    float *p = px + (y * W + x) * 4;
                    if (p[0] > 0) {
                        n++, vsum += p[1];
                        x0 = MIN(x0, x), y0 = MIN(y0, y), x1 = MAX(x1, x), y1 = MAX(y1, y);
                    }
                }
            }
            printf("depth %s: %lu pixels covered", clamp ? "clamped" : "clipped", (unsigned long)n);
            if (n) {
                printf(", box (%lu,%lu)-(%lu,%lu), mean path_value %.3f", (unsigned long)x0, (unsigned long)y0, (unsigned long)x1,
                       (unsigned long)y1, vsum / n);
            }
            printf("\n");
            free(px);
        }
        return 0;
    }
}
