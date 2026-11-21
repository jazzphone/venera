// mtldraws: what a draw costs on the way to the host GPU (round 23). One render pass of N small draws, each with its
// own vertex bytes (Core Animation's pattern: setVertexBytes, then a draw), committed and waited for; the median of
// 15 round trips for N = 1, 50, 200, 800 and 2000. A cost that grows with N, while the GPU's work stays tiny, is the
// commands' encoding in the guest and decoding in the host.
//   VGMTL_ENABLE=1 ./mtldraws
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSource = @"#include <metal_stdlib>\n"
                                  "using namespace metal;\n"
                                  "vertex float4 v(uint i [[vertex_id]], constant float2 *p [[buffer(0)]]) {\n"
                                  "    return float4(p[i], 0, 1);\n"
                                  "}\n"
                                  "fragment half4 f() { return half4(1, 0, 0, 1); }\n";

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("mtldraws: device %s\n", dev.name.UTF8String);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) {
            printf("mtldraws: FAIL %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:256 height:256 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        const int counts[] = {1, 50, 200, 800, 2000};
        for (int c = 0; c < 5; c++) {
            int n = counts[c];
            double ms[15], enc[15];
            for (int r = 0; r < 15; r++) {
                uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = rt;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
                [e setRenderPipelineState:ps];
                for (int i = 0; i < n; i++) {
                    float x = (i % 64) / 32.0f - 1, y = (i / 64 % 64) / 32.0f - 1;
                    float tri[6] = {x, y, x + 0.03f, y, x, y + 0.03f};
                    [e setVertexBytes:tri length:sizeof(tri) atIndex:0];
                    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }
                [e endEncoding];
                uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                [cb commit];
                [cb waitUntilCompleted];
                uint64_t t2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                enc[r] = (t1 - t0) / 1e6;
                ms[r] = (t2 - t1) / 1e6;
            }
            qsort(ms, 15, sizeof(double), cmp);
            qsort(enc, 15, sizeof(double), cmp);
            printf("%5d draws: encode %7.2f ms, commit -> done median %7.2f ms (min %.2f, max %.2f), %.1f us a draw\n",
                   n, enc[7], ms[7], ms[0], ms[14], n > 1 ? (ms[7] - 0) * 1000 / n : 0);
        }
        return 0;
    }
}
