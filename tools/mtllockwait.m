// mtllockwait: a display stream's handover, in one process (round 23). A surface named like one ("... DisplayStream
// ..."), cleared on the GPU with commitAndWaitUntilSubmitted (as WindowServer hands frames to Screen Sharing), then at
// once locked and read on the CPU, as ScreensharingAgent does. Every read must see its frame's color: either the
// commit waited for the write-back, or (with this process on the lockwait list) the lock waits for it.
//   printf 'mtllockwait\n' > /Library/GPUBundles/VirtioGPUMetal-lockwait     (the reader's hook in this process)
//   VGMTL_ENABLE=1 ./mtllockwait [ROUNDS]
// Prints each phase's time (commit to return, lock) and "mtllockwait: PASS" or "FAIL (n stale reads)".
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

@protocol VGSubmit
- (void)commitAndWaitUntilSubmitted;   // Metal SPI (what WindowServer calls)
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        int rounds = argc > 1 ? atoi(argv[1]) : 60;
        enum { W = 1280, H = 800 };
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("mtllockwait: device %s\n", dev.name.UTF8String);
        IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef) @{
            (id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfaceBytesPerElement : @4,
            (id)kIOSurfaceBytesPerRow : @(W * 4), (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
            (id)kIOSurfaceName : @"mtllockwait DisplayStream surface 0/2"
        });
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:W height:H mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:d iosurface:s plane:0];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) {
            fprintf(stderr, "mtllockwait: initial surface lock failed\n");
            CFRelease(s);
            return 1;
        }
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);   // the first read tags the surface
        int stale = 0, lockErrors = 0;
        double commitMs = 0, lockMs = 0;
        for (int r = 0; r < rounds; r++) {
            uint8_t b = (uint8_t)(r * 37 + 11), g = (uint8_t)(r * 91 + 7), rr = (uint8_t)(r * 53 + 3);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(rr / 255.0, g / 255.0, b / 255.0, 1);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            [(id<VGSubmit>)cb commitAndWaitUntilSubmitted];
            uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            kern_return_t locked = IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
            uint64_t t2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            commitMs += (t1 - t0) / 1e6, lockMs += (t2 - t1) / 1e6;
            if (locked != KERN_SUCCESS) {
                lockErrors++;
                continue;
            }
            const uint32_t *px = IOSurfaceGetBaseAddress(s);
            uint32_t want = b | (uint32_t)g << 8 | (uint32_t)rr << 16 | 0xffu << 24;
            if (px[0] != want || px[(H - 1) * W + W - 1] != want) {
                stale++;
            }
            IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
            usleep(16000);
        }
        printf("mtllockwait: %d rounds: commit to return %.2f ms, lock %.2f ms on average; %d stale reads\n", rounds,
               commitMs / rounds, lockMs / rounds, stale);
        printf(stale ? "mtllockwait: FAIL (%d stale reads)\n" : "mtllockwait: PASS\n", stale);
        CFRelease(s);
        return stale || lockErrors;
    }
}
