// vtstill: a still from a movie through AVAssetImageGenerator (VideoToolbox's decode and Metal transfer: a 10-bit
// HEVC movie's 'x420' planes converted to RGB), with its size, brightest pixel and mean (R+G+B, of 765), saved as PNG.
// Run it with the VM's device and without it to compare the GPU's conversion with the CPU's:
//   VGMTL_ENABLE=1 ./vtstill MOVIE SECONDS OUT.png      (a plain process without VGMTL_ENABLE gets no Venera device)
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: vtstill MOVIE SECONDS OUT.png\n");
            return 2;
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("vtstill: device %s\n", dev ? dev.name.UTF8String : "(none)");
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
        AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        gen.requestedTimeToleranceBefore = kCMTimeZero;
        gen.requestedTimeToleranceAfter = kCMTimeZero;
        NSError *err = nil;
        CMTime actual;
        CGImageRef img = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(atof(argv[2]), 600) actualTime:&actual error:&err];
        if (!img) {
            printf("vtstill: FAIL %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
        uint8_t *px = calloc(w * h, 4);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef cg = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(cg, CGRectMake(0, 0, w, h), img);
        uint64_t sum = 0;
        unsigned best = 0;
        for (size_t i = 0; i < w * h; i++) {
            unsigned v = px[4 * i] + px[4 * i + 1] + px[4 * i + 2];
            sum += v;
            best = v > best ? v : best;
        }
        printf("vtstill: %zux%zu at %.3f s, brightest %u/765, mean %llu\n", w, h, CMTimeGetSeconds(actual), best,
               (unsigned long long)(sum / (w * h)));
        CGImageDestinationRef d = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[3])], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
        if (d) {
            CGImageDestinationAddImage(d, img, NULL);
            CGImageDestinationFinalize(d);
            CFRelease(d);
        } else {
            printf("vtstill: can't write %s\n", argv[3]);
        }
        CGContextRelease(cg);
        CGColorSpaceRelease(cs);
        CGImageRelease(img);
        free(px);
        return 0;
    }
}
