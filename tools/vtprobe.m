// vtprobe (video): what VideoToolbox in this macOS offers for paravirtualized decoding -- the private entry points,
// whether it thinks it runs in a guest, the decoder list, and whether a session can be had for a file's first video
// track with the paravirtualized decoder required, allowed, or hardware required.
//   vtprobe FILE.mp4
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <dlfcn.h>

static void cb(void *a, void *b, OSStatus s, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {}

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
