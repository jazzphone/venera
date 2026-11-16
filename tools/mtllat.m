// mtllat: Metal command buffer round trips on our device (stage 5c), to tell Venus' latency from real work.
//   VGMTL_ENABLE=1 mtllat [COUNT]
// Runs COUNT times each: an empty command buffer, a 16-byte buffer fill, and a 1280x800 BGRA texture -> buffer copy
// (what a WindowServer frame's write-back does), each committed and waited for; prints min / median / max in ms.
#import <Metal/Metal.h>
#include <stdlib.h>

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void run(const char *name, int n, id<MTLCommandQueue> q, void (^encode)(id<MTLCommandBuffer>)) {
    double *ms = calloc(n, sizeof(double));
    for (int i = 0; i < n; i++) {
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        encode(cb);
        [cb commit];
        [cb waitUntilCompleted];
        ms[i] = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
    }
    qsort(ms, n, sizeof(double), cmp);
    printf("%-34s min %6.2f  median %6.2f  max %6.2f ms\n", name, ms[0], ms[n / 2], ms[n - 1]);
    free(ms);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int n = argc > 1 ? atoi(argv[1]) : 50;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("no Metal device\n");
            return 1;
        }
        printf("device: %s, %d runs each\n", dev.name.UTF8String, n);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> small = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> big = [dev newBufferWithLength:1280 * 800 * 4 options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:1280
                                                                                     height:800
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        run("empty", n, q, ^(id<MTLCommandBuffer> cb) {});
        run("fill 16 bytes", n, q, ^(id<MTLCommandBuffer> cb) {
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b fillBuffer:small range:NSMakeRange(0, 16) value:7];
            [b endEncoding];
        });
        run("clear 1280x800 (render pass)", n, q, ^(id<MTLCommandBuffer> cb) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        });
        run("1280x800 texture -> buffer", n, q, ^(id<MTLCommandBuffer> cb) {
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(1280, 800, 1) toBuffer:big destinationOffset:0
                    destinationBytesPerRow:1280 * 4 destinationBytesPerImage:1280 * 800 * 4];
            [b endEncoding];
        });
        void *dst = malloc(1280 * 800 * 4);
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (int i = 0; i < n; i++) {
            memcpy(dst, big.contents, 1280 * 800 * 4);   // reading host-visible memory on the CPU
        }
        printf("%-34s avg %6.2f ms\n", "CPU read of the 4 MB buffer", (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6 / n);
        free(dst);
    }
    return 0;
}
