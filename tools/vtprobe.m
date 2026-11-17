// vtprobe (video): what VideoToolbox in this macOS offers for paravirtualized decoding -- the private entry points,
// whether it thinks it runs in a guest, the decoder list, and whether a session can be had for a file's first video
// track with the paravirtualized decoder required, allowed, or hardware required.
//   vtprobe FILE.mp4
//   vtprobe -decode N FILE.mp4      decode the first N frames with the default decoder; each frame's result
//                                   (status, flags, pixel format, size, the first pixels) and the time it took
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <IOSurface/IOSurface.h>
#include <dlfcn.h>

static void cb(void *a, void *b, OSStatus s, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {}
static int gFrames;
static void decoded(void *a, void *b, OSStatus s, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {
    gFrames++;
    if (gFrames > 8 && gFrames % 30) {
        return;
    }
    char fmt[5] = "----";
    size_t w = 0, h = 0;
    unsigned px[4] = {0};
    IOSurfaceRef surf = NULL;
    OSType t = 0;
    if (img) {
        t = CVPixelBufferGetPixelFormatType(img);
        for (int i = 0; i < 4; i++) {
            fmt[i] = (char)(t >> (24 - 8 * i));
        }
        w = CVPixelBufferGetWidth(img), h = CVPixelBufferGetHeight(img);
        surf = CVPixelBufferGetIOSurface(img);
        CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
        const uint8_t *y = CVPixelBufferIsPlanar(img) ? CVPixelBufferGetBaseAddressOfPlane(img, 0) : CVPixelBufferGetBaseAddress(img);
        size_t bpr = CVPixelBufferIsPlanar(img) ? CVPixelBufferGetBytesPerRowOfPlane(img, 0) : CVPixelBufferGetBytesPerRow(img);
        if (y && (t == 'x420' || t == 'xf20' || t == 'x422')) {   // 10 bits in the top of 16
            const uint16_t *y16 = (const uint16_t *)y;
            size_t s16 = bpr / 2;
            px[0] = y16[0] >> 6, px[1] = y16[w / 2] >> 6, px[2] = y16[(h / 2) * s16 + w / 2] >> 6,
            px[3] = y16[(h - 1) * s16 + w - 1] >> 6;
        } else if (y) {
            px[0] = y[0], px[1] = y[w / 2], px[2] = y[(h / 2) * bpr + w / 2], px[3] = y[(h - 1) * bpr + w - 1];
        }
        CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    }
    printf("frame %d: status %d flags 0x%x %s %zux%zu surface %u seed %u pts %.3f, luma %u %u %u %u\n", gFrames, (int)s,
           (unsigned)f, fmt, w, h, surf ? IOSurfaceGetID(surf) : 0, surf ? IOSurfaceGetSeed(surf) : 0, CMTimeGetSeconds(pts),
           px[0], px[1], px[2], px[3]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/VideoToolboxParavirtualizationSupport.framework/"
               "VideoToolboxParavirtualizationSupport", RTLD_NOW);
        const char *syms[] = {"VTParavirtualizationIsRunningInGuest", "VTParavirtualizationHostSessionCreate",
                              "VTParavirtualizationGuestSupportSetUpWithHandlers",
                              "VTParavirtualizationGuestSupportSendRawMessageToHost",
                              "kVTVideoDecoderSpecification_RequireParavirtualizedDecoder",
                              "kVTVideoDecoderSpecification_AllowParavirtualizedDecoder", "kVTVideoDecoder_IsParavirtualized",
                              "VTVPParavirtualizedH264VideoEncoder_CreateInstance"};
        for (unsigned i = 0; i < sizeof(syms) / sizeof(*syms); i++) {
            printf("%-58s %s\n", syms[i], dlsym(RTLD_DEFAULT, syms[i]) ? "present" : "-");
        }
        Boolean (*inGuest)(void) = dlsym(RTLD_DEFAULT, "VTParavirtualizationIsRunningInGuest");
        if (inGuest) {
            printf("VTParavirtualizationIsRunningInGuest() = %d\n", inGuest());
        }
        const char *codecs[] = {"avc1", "hvc1", "av01", "vp09"};
        for (int i = 0; i < 4; i++) {
            CMVideoCodecType c = (CMVideoCodecType)((uint32_t)codecs[i][0] << 24 | (uint32_t)codecs[i][1] << 16 |
                                                    (uint32_t)codecs[i][2] << 8 | (uint32_t)codecs[i][3]);
            printf("VTIsHardwareDecodeSupported(%s) = %d\n", codecs[i], VTIsHardwareDecodeSupported(c));
        }
        CFDictionaryRef (*hevcCaps)(void) = dlsym(RTLD_DEFAULT, "VTCopyHEVCDecoderCapabilitiesDictionary");
        if (hevcCaps) {
            CFDictionaryRef d = hevcCaps();
            printf("VTCopyHEVCDecoderCapabilitiesDictionary: %s\n",
                   d ? [[(__bridge NSDictionary *)d description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String : "(null)");
        }
        CFArrayRef list = NULL;
        OSStatus (*copyList)(CFDictionaryRef, CFArrayRef *) = dlsym(RTLD_DEFAULT, "VTCopyVideoDecoderList");   // private
        if (copyList) {
            copyList(NULL, &list);
        }
        for (NSDictionary *d in (__bridge NSArray *)list) {
            NSString *desc = [[d description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if ([desc containsString:@"264"] || [desc containsString:@"HEVC"] || [desc containsString:@"aravirt"]) {
                printf("decoder: %s\n", desc.UTF8String);
            }
        }
        if (argc < 2) {
            return 0;
        }
        if (!strcmp(argv[1], "-decode") && argc > 3) {
            int n = atoi(argv[2]);
            AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[3])] options:nil];
            AVAssetTrack *t = [[a tracksWithMediaType:AVMediaTypeVideo] firstObject];
            AVAssetReader *r = [AVAssetReader assetReaderWithAsset:a error:nil];
            AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:t outputSettings:nil];
            [r addOutput:o];
            [r startReading];
            CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)t.formatDescriptions.firstObject;
            VTDecompressionSessionRef s = NULL;
            VTDecompressionOutputCallbackRecord rec = {decoded, NULL};
            NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
            OSStatus st = VTDecompressionSessionCreate(NULL, fd, NULL, (__bridge CFDictionaryRef)attrs, &rec, &s);
            CFBooleanRef hw = NULL;
            if (s) {
                VTSessionCopyProperty(s, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &hw);
            }
            printf("session: status %d, %s\n", (int)st, hw == kCFBooleanTrue ? "hardware" : "software");
            if (!s) {
                return 1;
            }
            NSDate *t0 = [NSDate date];
            int sent = 0;
            for (; sent < n; sent++) {
                CMSampleBufferRef sb = [o copyNextSampleBuffer];
                if (!sb) {
                    break;
                }
                VTDecodeInfoFlags info = 0;
                st = VTDecompressionSessionDecodeFrame(s, sb, kVTDecodeFrame_EnableAsynchronousDecompression, NULL, &info);
                if (st) {
                    printf("decode %d: status %d\n", sent, (int)st);
                }
                CFRelease(sb);
            }
            VTDecompressionSessionWaitForAsynchronousFrames(s);
            double secs = -[t0 timeIntervalSinceNow];
            printf("%d frames sent, %d came back in %.2f s (%.1f fps)\n", sent, gFrames, secs, gFrames / secs);
            VTDecompressionSessionInvalidate(s);
            return 0;
        }
        AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
        AVAssetTrack *t = [[a tracksWithMediaType:AVMediaTypeVideo] firstObject];
        CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)t.formatDescriptions.firstObject;
        if (!fd) {
            printf("no video track\n");
            return 1;
        }
        CFStringRef *req = dlsym(RTLD_DEFAULT, "kVTVideoDecoderSpecification_RequireParavirtualizedDecoder");
        CFStringRef *allow = dlsym(RTLD_DEFAULT, "kVTVideoDecoderSpecification_AllowParavirtualizedDecoder");
        struct { const char *what; NSDictionary *spec; } tries[] = {
            {"default", @{}},
            {"require paravirtualized", req ? @{(__bridge NSString *)*req : @YES} : nil},
            {"allow paravirtualized", allow ? @{(__bridge NSString *)*allow : @YES} : nil},
            {"require hardware", @{(__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder : @YES}},
        };
        for (unsigned i = 0; i < 4; i++) {
            if (!tries[i].spec) {
                continue;
            }
            VTDecompressionSessionRef s = NULL;
            VTDecompressionOutputCallbackRecord r = {cb, NULL};
            OSStatus st = VTDecompressionSessionCreate(NULL, fd, (__bridge CFDictionaryRef)tries[i].spec, NULL, &r, &s);
            CFBooleanRef hw = NULL;
            if (s) {
                VTSessionCopyProperty(s, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &hw);
            }
            printf("session (%s): status %d%s\n", tries[i].what, (int)st,
                   s ? (hw == kCFBooleanTrue ? ", hardware" : ", software") : "");
            if (s) {
                VTDecompressionSessionInvalidate(s);
                CFRelease(s);
            }
        }
        return 0;
    }
}
