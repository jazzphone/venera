// citest (stage 5d): Core Image on the Metal device, the way Preview, QuickTime and Photos use it. Each case renders a
// small image through a CIContext made on MTLCreateSystemDefaultDevice() and checks a pixel against what the CPU
// renderer (kCIContextUseSoftwareRenderer) gives for the same filter.
//   citest [CASE]        (needs the process allow-listed, e.g. VGMTL_ENABLE=1; VGMTL_LENIENT=0 to stop at a gap)
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static int failures, ran;

static BOOL pixel(CIContext *ctx, CIImage *img, CGPoint at, uint8_t out[4]) {
    CGRect r = CGRectMake(at.x, at.y, 1, 1);
    [ctx render:img toBitmap:out rowBytes:4 bounds:r format:kCIFormatRGBA8 colorSpace:nil];
    return YES;
}

static void check(const char *name, CIImage *(^make)(void), CGPoint at, const char *only) {
    if (only && strcmp(only, name)) {
        return;
    }
    ran++;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    CIContext *gpu = [CIContext contextWithMTLDevice:dev options:@{kCIContextWorkingColorSpace : [NSNull null]}];
    CIContext *cpu = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @YES,
                                                     kCIContextWorkingColorSpace : [NSNull null]}];
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    CIImage *img = make();
    uint8_t g[4] = {0}, c[4] = {0};
    pixel(gpu, img, at, g);
    double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
    pixel(cpu, img, at, c);
    int d = 0;
    for (int i = 0; i < 4; i++) {
        d = MAX(d, abs(g[i] - c[i]));
    }
    BOOL ok = d <= 3;
    failures += !ok;
    printf("%-22s %s  gpu %3u %3u %3u %3u  cpu %3u %3u %3u %3u  (%.0f ms)\n", name, ok ? "ok  " : "FAIL", g[0], g[1], g[2],
           g[3], c[0], c[1], c[2], c[3], ms);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *only = argc > 1 ? argv[1] : NULL;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("device: %s\n", dev ? dev.name.UTF8String : "(none)");
        if (!dev) {
            return 2;
        }
        CIImage *red = [[CIImage imageWithColor:[CIColor colorWithRed:0.8 green:0.2 blue:0.1]] imageByCroppingToRect:CGRectMake(0, 0, 64, 64)];
        CIImage *grad = [[CIFilter filterWithName:@"CILinearGradient"
                                     withInputParameters:@{@"inputPoint0" : [CIVector vectorWithX:0 Y:0],
                                                           @"inputPoint1" : [CIVector vectorWithX:64 Y:0],
                                                           @"inputColor0" : [CIColor colorWithRed:0 green:0 blue:0],
                                                           @"inputColor1" : [CIColor colorWithRed:1 green:1 blue:1]}]
                             .outputImage imageByCroppingToRect:CGRectMake(0, 0, 64, 64)];
        check("constant color", ^{ return red; }, CGPointMake(10, 10), only);
        check("linear gradient", ^{ return grad; }, CGPointMake(32, 10), only);
        check("color controls", ^{
            return [red imageByApplyingFilter:@"CIColorControls"
                          withInputParameters:@{@"inputSaturation" : @0.3, @"inputBrightness" : @0.1, @"inputContrast" : @1.2}];
        }, CGPointMake(10, 10), only);
        check("gaussian blur", ^{
            return [[grad imageByApplyingGaussianBlurWithSigma:4] imageByCroppingToRect:CGRectMake(0, 0, 64, 64)];
        }, CGPointMake(32, 32), only);
        check("sepia", ^{ return [red imageByApplyingFilter:@"CISepiaTone" withInputParameters:@{@"inputIntensity" : @0.8}]; },
              CGPointMake(10, 10), only);
        check("lanczos scale", ^{
            return [grad imageByApplyingFilter:@"CILanczosScaleTransform" withInputParameters:@{@"inputScale" : @0.5}];
        }, CGPointMake(10, 10), only);
        check("kernel from string", ^{
            CIColorKernel *k = [CIColorKernel kernelWithString:@"kernel vec4 swap(__sample s) { return s.bgra; }"];
            return k ? [k applyWithExtent:red.extent arguments:@[ red ]] : [CIImage emptyImage];
        }, CGPointMake(10, 10), only);
        printf("%d of %d %s\n", ran - failures, ran, failures ? "FAILED" : "PASS");
        return failures ? 1 : 0;
    }
}
