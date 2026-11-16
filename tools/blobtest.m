// blobtest (stage 5c): can the display scan out a Venus allocation? Fills a host-visible Metal buffer on our device
// with a test pattern, shows it on scanout 0 with SET_SCANOUT_BLOB through the kext (root only), waits, then puts the
// framebuffer back.
//   sudo VGMTL_ENABLE=1 blobtest [SECONDS]
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#include "../kext/VirtioGPUUserAPI.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        int secs = argc > 1 ? atoi(argv[1]) : 8;
        const uint32_t W = 1280, H = 800, stride = W * 4;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("no Metal device\n");
            return 1;
        }
        id<MTLBuffer> buf = [dev newBufferWithLength:(NSUInteger)stride * H options:MTLResourceStorageModeShared];
        uint32_t *px = buf.contents;
        for (uint32_t y = 0; y < H; y++) {   // BGRX: color bars, a white frame, a diagonal
            for (uint32_t x = 0; x < W; x++) {
                static const uint32_t bars[8] = {0xffffff, 0xffff00, 0x00ffff, 0x00ff00, 0xff00ff, 0xff0000, 0x0000ff, 0x000000};
                uint32_t c = bars[x * 8 / W];
                if (x < 8 || y < 8 || x >= W - 8 || y >= H - 8 || (x * H / W > y - 4 && x * H / W < y + 4)) {
                    c = 0xffffff;
                }
                px[y * W + x] = c;
            }
        }
        uint32_t res = ((uint32_t(*)(id, SEL))objc_msgSend)(buf, sel_registerName("vgResId"));
        printf("buffer %u bytes, blob resource %u\n", stride * H, res);
        if (!res) {
            return 1;
        }
        io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kVGUCAccelClass));
        io_connect_t c = 0;
        kern_return_t kr = s ? IOServiceOpen(s, mach_task_self(), kVGUCAccelType, &c) : KERN_FAILURE;
        if (kr != KERN_SUCCESS) {
            printf("open: 0x%x\n", kr);
            return 1;
        }
        uint64_t in[5] = {res, W, H, stride, 0};
        kr = IOConnectCallScalarMethod(c, kVGUCScanoutBlob, in, 5, NULL, NULL);
        printf("SET_SCANOUT_BLOB -> 0x%x; showing it for %d s\n", kr, secs);
        fflush(stdout);
        sleep(secs);
        uint64_t back[5] = {0, 0, 0, 0, 0};
        kr = IOConnectCallScalarMethod(c, kVGUCScanoutBlob, back, 5, NULL, NULL);
        printf("framebuffer back -> 0x%x\n", kr);
        IOServiceClose(c);
    }
    return 0;
}
