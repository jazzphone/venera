// vtenc (video encoding, runs in the guest): encode N generated frames with VideoToolbox and say what did it -- the
// encoder VideoToolbox picked (hardware or software), the frames per second, the bytes out, the first frame's parameter
// sets. The before/after measurement for hardware encoding through the host (0.1.2).
//   vtenc [avc1|hvc1] [WIDTH HEIGHT] [FRAMES] [require]     (require: kVTVideoEncoderSpecification_RequireHardware...)
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <IOSurface/IOSurface.h>
#import <AVFoundation/AVFoundation.h>
#include <mach/mach_time.h>

static double now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static double now(void);
static _Atomic int gOut, gErr;
static _Atomic long gBytes;
static _Atomic int gKey;
static NSMutableArray *gSamples;   // VTENC_VERIFY: every sample, decoded afterwards
static IOSurfaceRef gFirst;
static double gT0;

static void done(void *ref, void *frameRef, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    if (status || !sb) {
        if (gErr++ < 3) printf("  frame error %d\n", (int)status);
        return;
    }
    gOut++;
    if (getenv("VTENC_TIMES")) printf("  %.3f ms: frame %lld out\n", (now() - gT0) * 1e3, CMSampleBufferGetPresentationTimeStamp(sb).value);
    if (gSamples) @synchronized(gSamples) { [gSamples addObject:(__bridge id)sb]; }
    gBytes += (long)CMSampleBufferGetTotalSampleSize(sb);
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    BOOL key = !(att && CFArrayGetCount(att) &&
                 CFDictionaryContainsKey(CFArrayGetValueAtIndex(att, 0), kCMSampleAttachmentKey_NotSync));
    if (key && gKey++ == 0) {
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
        CFDictionaryRef ext = CMFormatDescriptionGetExtensions(fd);
        CFDictionaryRef atoms = ext ? CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) : NULL;
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(fd);
        if (getenv("VTENC_SHOW")) printf("  sample's format description: %s\n", [(__bridge id)fd description].UTF8String);
        printf("  first key frame: %d x %d, %zu B, parameter sets: %s\n", d.width, d.height,
               CMSampleBufferGetTotalSampleSize(sb), atoms ? [[(__bridge NSDictionary *)atoms allKeys] componentsJoinedByString:@","].UTF8String : "none");
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *c = argc > 1 ? argv[1] : "avc1";
        int w = argc > 3 ? atoi(argv[2]) : 1280, h = argc > 3 ? atoi(argv[3]) : 720;
        int n = argc > 4 ? atoi(argv[4]) : 120;
        if (getenv("VTENC_VERIFY")) gSamples = [NSMutableArray array];
        BOOL require = argc > 5 && !strcmp(argv[5], "require");
        CMVideoCodecType codec = !strcmp(c, "hvc1") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
        NSMutableDictionary *spec = [(require ? @{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @YES}
                                              : @{(id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @YES}) mutableCopy];
        if (getenv("VTENC_ENCODER")) spec[(id)kVTVideoEncoderSpecification_EncoderID] = @(getenv("VTENC_ENCODER"));   // one encoder by its ID
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
        if (!getenv("VTENC_NORT")) VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef) @(w * h * 4));
        VTCompressionSessionPrepareToEncodeFrames(s);
        CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(s);
        double t0 = now();
        gT0 = t0;
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
            if (getenv("VTENC_PACE")) usleep(1000 * atoi(getenv("VTENC_PACE")));   // a camera's or a screen's pace
            CVPixelBufferRelease(pb);
        }
        if (getenv("VTENC_PAUSE")) usleep(1000 * atoi(getenv("VTENC_PAUSE")));   // time to attach a sampler
        if (getenv("VTENC_TIMES")) printf("  %.3f ms: CompleteFrames\n", (now() - gT0) * 1e3);
        VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
        if (getenv("VTENC_TIMES")) printf("  %.3f ms: CompleteFrames returned\n", (now() - gT0) * 1e3);
        int atComplete = gOut + gErr;   // VideoToolbox promises every frame is out by now
        for (int w = 0; w < 50 && gOut + gErr < n; w++) usleep(10000);   // a straggler's callback, up to 0.5 s
        if (getenv("VTENC_SHOW") && gFirst && CFGetTypeID(gFirst) == IOSurfaceGetTypeID()) {   // what the encoder added
            CFDictionaryRef v = IOSurfaceCopyAllValues(gFirst);
            NSMutableDictionary *m = [(__bridge NSDictionary *)v mutableCopy];
            [m removeObjectForKey:@"CreationProperties"];
            printf("  after encoding, IOSurface %u values: %s\n", IOSurfaceGetID(gFirst), m.description.UTF8String);
        }
        double dt = now() - t0;
        if (gSamples && gSamples.count && getenv("VTENC_MOV")) {   // the stream as a movie, to decode elsewhere
            NSArray *all = [gSamples sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
                return CMTimeCompare(CMSampleBufferGetDecodeTimeStamp((__bridge CMSampleBufferRef)a),
                                     CMSampleBufferGetDecodeTimeStamp((__bridge CMSampleBufferRef)b));
            }];
            NSURL *u = [NSURL fileURLWithPath:@(getenv("VTENC_MOV"))];
            [[NSFileManager defaultManager] removeItemAtURL:u error:nil];
            AVAssetWriter *aw = [AVAssetWriter assetWriterWithURL:u fileType:AVFileTypeQuickTimeMovie error:nil];
            AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil
                sourceFormatHint:CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)all[0])];
            [aw addInput:in];
            [aw startWriting];
            [aw startSessionAtSourceTime:kCMTimeZero];
            for (id o in all) {
                while (!in.readyForMoreMediaData) usleep(1000);
                [in appendSampleBuffer:(__bridge CMSampleBufferRef)o];
            }
            [in markAsFinished];
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [aw finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            printf("  wrote %s: %s\n", getenv("VTENC_MOV"), aw.status == AVAssetWriterStatusCompleted ? "ok" : aw.error.description.UTF8String);
        }
        if (gSamples && gSamples.count) {   // decode them back; the luma at (16, 100) should be (100 + 3 * frame) & 255
            NSArray *all = [gSamples sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
                return CMTimeCompare(CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)a),
                                     CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)b));
            }];
            VTDecompressionSessionRef ds = NULL;
            __block int good = 0, bad = 0, worst = 0, firstErr = 0;
            NSDictionary *dspec = getenv("VTENC_SWDEC") ? @{@"AllowParavirtualizedDecoder" : @NO, (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder : @NO} : nil;
            OSStatus st = VTDecompressionSessionCreate(NULL, CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)all[0]), (__bridge CFDictionaryRef)dspec, NULL, NULL, &ds);
            for (id o in all) {
                CMSampleBufferRef sb = (__bridge CMSampleBufferRef)o;
                int i = (int)CMSampleBufferGetPresentationTimeStamp(sb).value;
                VTDecompressionSessionDecodeFrameWithOutputHandler(ds, sb, getenv("VTENC_ASYNC") ? kVTDecodeFrame_EnableAsynchronousDecompression : 0, NULL, ^(OSStatus e, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {
                    if (e || !img) { bad++; if (!firstErr) firstErr = e ? e : -1; return; }
                    CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
                    const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(img, 0);
                    int got = y[100 * CVPixelBufferGetBytesPerRowOfPlane(img, 0) + 16], want = (100 + i * 3) & 0xff;
                    int diff = abs(got - want); if (diff > 128) diff = 256 - diff;
                    if (diff > worst) worst = diff;
                    diff <= 8 ? good++ : bad++;
                    if (diff > 8) printf("  frame %d decoded off: luma %d, want %d (pts %lld, flags 0x%x)\n", i, got, want, pts.value, (unsigned)f);
                    CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
                });
            }
            VTDecompressionSessionWaitForAsynchronousFrames(ds);
            printf("decoded back: %d match, %d off or failed (decoder %d, first error %d), worst difference %d\n", good, bad, (int)st, firstErr, worst);
            if (getenv("VTENC_SHOW")) printf("  format: %s\n", [(__bridge id)CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)all[0]) description].UTF8String);
        }
        printf("%d frames in %.2f s: %.1f fps, %d out (%d when CompleteFrames returned), %ld KB, %d errors\n", n, dt, n / dt, gOut,
               atComplete, gBytes / 1024, gErr);
        VTCompressionSessionInvalidate(s);
        return gOut ? 0 : 1;
    }
}
