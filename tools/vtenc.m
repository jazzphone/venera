// vtenc (video encoding, runs in the guest): encode N generated frames with VideoToolbox and say what did it -- the
// encoder VideoToolbox picked (hardware or software), the frames per second, the bytes out, the first frame's parameter
// sets. The before/after measurement for hardware encoding through the host (0.1.2).
//   vtenc [avc1|hvc1] [WIDTH HEIGHT] [FRAMES] [require]     (require: kVTVideoEncoderSpecification_RequireHardware...)
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <IOSurface/IOSurface.h>
#include <mach/mach_time.h>

static double now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static _Atomic int gOut, gErr;
static _Atomic long gBytes;
static _Atomic int gKey;
static IOSurfaceRef gFirst;

static void done(void *ref, void *frameRef, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    if (status || !sb) {
        if (gErr++ < 3) printf("  frame error %d\n", (int)status);
        return;
    }
    gOut++;
    gBytes += (long)CMSampleBufferGetTotalSampleSize(sb);
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    BOOL key = !(att && CFArrayGetCount(att) &&
                 CFDictionaryContainsKey(CFArrayGetValueAtIndex(att, 0), kCMSampleAttachmentKey_NotSync));
    if (key && gKey++ == 0) {
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
        CFDictionaryRef ext = CMFormatDescriptionGetExtensions(fd);
        CFDictionaryRef atoms = ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) : NULL;
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(fd);
        printf("  first key frame: %d x %d, %zu B, parameter sets: %s\n", d.width, d.height,
               CMSampleBufferGetTotalSampleSize(sb), atoms ? [[(__bridge NSDictionary *)atoms allKeys] componentsJoinedByString:@","].UTF8String : "none");
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *c = argc > 1 ? argv[1] : "avc1";
        int w = argc > 3 ? atoi(argv[2]) : 1280, h = argc > 3 ? atoi(argv[3]) : 720;
        int n = argc > 4 ? atoi(argv[4]) : 120;
        BOOL require = argc > 5 && !strcmp(argv[5], "require");
        CMVideoCodecType codec = !strcmp(c, "hvc1") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
        NSDictionary *spec = require ? @{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @YES}
                                     : @{(id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @YES};
        CFArrayRef list = NULL;
        VTCopyVideoEncoderList(NULL, &list);
        int hw = 0;
        for (NSDictionary *e in (__bridge NSArray *)list) {
            if ([e[(id)kVTVideoEncoderList_CodecType] unsignedIntValue] == codec && [e[@"IsHardwareAccelerated"] boolValue]) {
                printf("  hardware encoder listed: %s (%s)\n", [e[(id)kVTVideoEncoderList_EncoderID] UTF8String],
                       [e[(id)kVTVideoEncoderList_DisplayName] UTF8String]);
                hw++;
            }
        }
        if (!hw) printf("  no hardware encoder listed for %s\n", c);
        VTCompressionSessionRef s = NULL;
        OSStatus st = VTCompressionSessionCreate(NULL, w, h, codec, (__bridge CFDictionaryRef)spec, NULL, NULL, done, NULL, &s);
        if (st) {
            printf("VTCompressionSessionCreate %s %dx%d: %d\n", c, w, h, (int)st);
            return 1;
        }
        CFBooleanRef usingHW = NULL;
        VTSessionCopyProperty(s, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &usingHW);
        CFStringRef eid = NULL;
        VTSessionCopyProperty(s, CFSTR("EncoderID"), NULL, &eid);
        printf("session: %s %dx%d, hardware %s, encoder %s\n", c, w, h,
               usingHW ? (CFBooleanGetValue(usingHW) ? "yes" : "no") : "unknown", eid ? [(__bridge NSString *)eid UTF8String] : "?");
        VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef) @(w * h * 4));
        VTCompressionSessionPrepareToEncodeFrames(s);
        CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(s);
        double t0 = now();
        for (int i = 0; i < n; i++) {
            CVPixelBufferRef pb = NULL;
            if (pool) CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb);
            if (!pb) CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         (__bridge CFDictionaryRef) @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}}, &pb);
            CVPixelBufferLockBaseAddress(pb, 0);
            for (size_t p = 0; p < CVPixelBufferGetPlaneCount(pb); p++) {   // a moving gradient, so frames differ
                uint8_t *b = CVPixelBufferGetBaseAddressOfPlane(pb, p);
                size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p), ph = CVPixelBufferGetHeightOfPlane(pb, p);
                for (size_t y = 0; y < ph; y++) memset(b + y * bpr, (int)((y + i * 3) & 0xff), bpr);
            }
            CVPixelBufferUnlockBaseAddress(pb, 0);
            if (i == 0 && getenv("VTENC_SHOW")) {   // what names this buffer: its IOSurface's values and attachments
                IOSurfaceRef sf = CVPixelBufferGetIOSurface(pb);
                CFDictionaryRef v = sf ? IOSurfaceCopyAllValues(sf) : NULL;
                printf("  buffer: IOSurface %u, values %s\n", sf ? IOSurfaceGetID(sf) : 0,
                       v ? [(__bridge NSDictionary *)v description].UTF8String : "none");
                CFDictionaryRef at = CVBufferCopyAttachments(pb, kCVAttachmentMode_ShouldPropagate);
                printf("  attachments %s\n", at ? [(__bridge NSDictionary *)at description].UTF8String : "none");
            }
            if (i == 0) gFirst = (IOSurfaceRef)CFRetain(CVPixelBufferGetIOSurface(pb) ?: (IOSurfaceRef)kCFNull);
            VTCompressionSessionEncodeFrame(s, pb, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
            CVPixelBufferRelease(pb);
        }
        VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
        if (getenv("VTENC_SHOW") && gFirst && CFGetTypeID(gFirst) == IOSurfaceGetTypeID()) {   // what the encoder added
            CFDictionaryRef v = IOSurfaceCopyAllValues(gFirst);
            NSMutableDictionary *m = [(__bridge NSDictionary *)v mutableCopy];
            [m removeObjectForKey:@"CreationProperties"];
            printf("  after encoding, IOSurface %u values: %s\n", IOSurfaceGetID(gFirst), m.description.UTF8String);
        }
        double dt = now() - t0;
        printf("%d frames in %.2f s: %.1f fps, %d out, %ld KB, %d errors\n", n, dt, n / dt, gOut, gBytes / 1024, gErr);
        VTCompressionSessionInvalidate(s);
        return gOut ? 0 : 1;
    }
}
