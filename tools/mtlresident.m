// mtlresident: does a command buffer's round trip grow with the large images its process holds? (round 23: at Retina
// sizes WindowServer's queue idles 7.3 ms before each command buffer, 3.2 ms at 1280x800.) Allocates N private
// 2880x1800 BGRA textures in steps, clears each once (so it is resident), and after each step times 40 tiny
// command buffers (a 16-byte buffer fill), committed and waited for.
//   VGMTL_ENABLE=1 ./mtlresident [MAXN]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int maxn = argc > 1 ? atoi(argv[1]) : 32;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("mtlresident: device %s\n", dev.name.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> small = [dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
        NSMutableArray *held = [NSMutableArray array];
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:2880 height:1800 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        const int steps[] = {0, 4, 8, 16, 24, 32, 48};
        for (int si = 0; si < 7 && steps[si] <= maxn; si++) {
            while ((int)held.count < steps[si]) {
                id<MTLTexture> t = [dev newTextureWithDescriptor:d];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = t;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLCommandBuffer> cb = [q commandBuffer];
                [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                [held addObject:t];
            }
            double ms[40];
            for (int r = 0; r < 40; r++) {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                [be fillBuffer:small range:NSMakeRange(0, 16) value:(uint8_t)r];
                [be endEncoding];
                uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                [cb commit];
                [cb waitUntilCompleted];
                ms[r] = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
            }
            qsort(ms, 40, sizeof(double), cmp);
            printf("%3d images held (%4.0f MB): a tiny command buffer's round trip median %6.2f ms, p90 %6.2f ms\n",
                   (int)held.count, held.count * 2880.0 * 1800 * 4 / 1048576, ms[20], ms[36]);
        }
        return 0;
    }
}
