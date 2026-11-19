// vbltest (round 21): do the display's VBLs reach apps? Over SECONDS each: CVDisplayLink callbacks; an NSView display
// link's (macOS 14+); and a CAMetalLayer drawn every display link tick: drawables presented, presented handlers that
// fired, and the spacing of their presentedTime. RX4Darwin found Metal's display-link and present paths need the display
// pipe's own VBL; without it, presented handlers or the display link can stall.
//   VGMTL_ENABLE=1 vbltest [SECONDS]      (as the console user)
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // CVDisplayLink is what older apps use
#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>

static double secs = 3;
static atomic_int cvTicks;
static int viewTicks, drawn, presented, presentedZero;
static double lastPresented, gapMin = 1e9, gapMax, gapSum;
static int gapN;
static id<MTLCommandQueue> queue;
static CAMetalLayer *layer;

static CVReturn cvTick(CVDisplayLinkRef l, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags fi,
                       CVOptionFlags *fo, void *ctx) {
    atomic_fetch_add(&cvTicks, 1);
    return kCVReturnSuccess;
}

@interface V : NSView
@end
@implementation V
- (void)tick:(CADisplayLink *)l {
    viewTicks++;
    id<CAMetalDrawable> d = [layer nextDrawable];
    if (!d) {
        return;
    }
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = d.texture;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake((viewTicks % 60) / 60.0, 0.3, 0.6, 1);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:p] endEncoding];
    [d addPresentedHandler:^(id<MTLDrawable> dd) {
        dispatch_async(dispatch_get_main_queue(), ^{
            presented++;
            double t = dd.presentedTime;
            if (t == 0) {
                presentedZero++;
                return;
            }
            if (lastPresented > 0) {
                double g = (t - lastPresented) * 1000;
                gapMin = MIN(gapMin, g), gapMax = MAX(gapMax, g), gapSum += g, gapN++;
            }
            lastPresented = t;
        });
    }];
    [cb presentDrawable:d];
    [cb commit];
    drawn++;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1) {
            secs = atof(argv[1]);
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        // 1. CVDisplayLink
        CVDisplayLinkRef cv = NULL;
        CVDisplayLinkCreateWithActiveCGDisplays(&cv);
        CVDisplayLinkSetOutputCallback(cv, cvTick, NULL);
        CVDisplayLinkStart(cv);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        CVDisplayLinkStop(cv);
        printf("CVDisplayLink: %d callbacks in %.0f s (%.1f/s), nominal %.2f Hz\n", atomic_load(&cvTicks), secs,
               atomic_load(&cvTicks) / secs, 1.0 / CVDisplayLinkGetActualOutputVideoRefreshPeriod(cv));
        // 2. a window's view display link, drawing Metal each tick
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("no Metal device (VGMTL_ENABLE=1?)\n");
            return 1;
        }
        queue = [dev newCommandQueue];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 400, 300)
                                                  styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered
                                                      defer:NO];
        V *v = [[V alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        v.wantsLayer = YES;
        layer = [CAMetalLayer layer];
        layer.device = dev;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(400, 300);
        v.layer = layer;
        w.contentView = v;
        [w makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        CADisplayLink *dl = [v displayLinkWithTarget:v selector:@selector(tick:)];
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        [dl invalidate];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        printf("view display link: %d ticks in %.0f s (%.1f/s); drawn %d, presented handlers %d (%d with presentedTime 0)",
               viewTicks, secs, viewTicks / secs, drawn, presented, presentedZero);
        if (gapN) {
            printf("; presentedTime gaps %.1f-%.1f ms, mean %.1f", gapMin, gapMax, gapSum / gapN);
        }
        printf("\n");
    }
    return 0;
}
