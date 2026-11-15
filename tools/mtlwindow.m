// mtlwindow: stage 4d's checkpoint. A plain Cocoa app with a CAMetalLayer: every frame takes a drawable, clears it to a
// cycling color, draws a spinning triangle on the GPU (render.metallib's tri_vertex + color_fragment), presents and
// commits. WindowServer still composites in software and reads the drawables' IOSurfaces, which the plugin fills
// at completion. Runs for SECONDS, then prints frames presented, the frame time, and checks one drawable's IOSurface.
//   mtlwindow [SECONDS] [render.metallib]
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdatomic.h>

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLRenderPipelineState> gPipe;
static CAMetalLayer *layer;
static _Atomic int completed, presented;
static int frames;
static uint64_t started;
static double seconds = 8;
static int checked = -1;

static void frame(void) {
    @autoreleasepool {
        id<CAMetalDrawable> d = [layer nextDrawable];
        if (!d) {
            return;
        }
        double t = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e9;
        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture = d.texture;
        p.colorAttachments[0].loadAction = MTLLoadActionClear;
        p.colorAttachments[0].storeAction = MTLStoreActionStore;
        p.colorAttachments[0].clearColor = MTLClearColorMake(0.5 + 0.5 * sin(t), 0.2, 0.5 + 0.5 * cos(t * 0.7), 1);
        float v[3][8];
        for (int i = 0; i < 3; i++) {
            double a = t * 2 + i * 2 * M_PI / 3;
            float c[3][4] = {{1, 0.9f, 0.2f, 1}, {0.2f, 1, 0.4f, 1}, {0.3f, 0.5f, 1, 1}};
            float row[8] = {(float)(0.7 * cos(a)), (float)(0.7 * sin(a)), 0, 0, c[i][0], c[i][1], c[i][2], c[i][3]};
            memcpy(v[i], row, sizeof(row));
        }
        float offset[2] = {0, 0};
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:p];
        [e setRenderPipelineState:gPipe];
        [e setVertexBytes:v length:sizeof(v) atIndex:0];
        [e setVertexBytes:offset length:sizeof(offset) atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        [cb presentDrawable:d];
        int n = frames++;
        MTLClearColor want = p.colorAttachments[0].clearColor;
        id<MTLTexture> tex = d.texture;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            atomic_fetch_add(&completed, 1);
            if (n == 30) {   // the drawable's own IOSurface must hold this frame's clear color in a corner
                IOSurfaceRef s = tex.iosurface;
                if (!s) {
                    printf("  frame 30: the drawable's texture has no IOSurface (texture class %s)\n",
                           class_getName([(NSObject *)tex class]));
                    checked = 0;
                    return;
                }
                IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
                const uint8_t *px = IOSurfaceGetBaseAddress(s);   // top-left pixel, BGRA
                int r = px[2], g = px[1], b = px[0];
                // The frame as handed to WindowServer, saved as /var/tmp/vgframe.png
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                CGContextRef ctx = CGBitmapContextCreate((void *)px, IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), 8,
                                                         IOSurfaceGetBytesPerRow(s), cs,
                                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
                CGImageDestinationRef dst = img ? CGImageDestinationCreateWithURL(
                    (__bridge CFURLRef)[NSURL fileURLWithPath:@"/var/tmp/vgframe.png"],
                    (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL) : NULL;
                if (dst) {
                    CGImageDestinationAddImage(dst, img, NULL);
                    CGImageDestinationFinalize(dst);
                    CFRelease(dst);
                }
                if (img) {
                    CGImageRelease(img);
                }
                if (ctx) {
                    CGContextRelease(ctx);
                }
                CGColorSpaceRelease(cs);
                IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
                int wr = (int)lround(want.red * 255), wg = (int)lround(want.green * 255), wb = (int)lround(want.blue * 255);
                checked = abs(r - wr) <= 2 && abs(g - wg) <= 2 && abs(b - wb) <= 2;
                printf("  frame 30: IOSurface %u top-left RGB %d %d %d, cleared to %d %d %d: %s\n", IOSurfaceGetID(s), r,
                       g, b, wr, wg, wb, checked ? "ok" : "MISMATCH");
            }
        }];
        [d addPresentedHandler:^(id<MTLDrawable> drawable) { atomic_fetch_add(&presented, 1); }];
        [cb commit];
    }
}

@interface App : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@end

@implementation App
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 640, 480)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = [NSString stringWithFormat:@"VirtioGPUMetal: %@", dev.name];
    NSView *view = self.window.contentView;
    layer = [CAMetalLayer layer];
    layer.device = dev;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    CGFloat scale = self.window.backingScaleFactor;
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(view.bounds.size.width * scale, view.bounds.size.height * scale);
    view.wantsLayer = YES;
    view.layer = layer;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    printf("window up: drawable %.0fx%.0f, layer device %s\n", layer.drawableSize.width, layer.drawableSize.height,
           layer.device.name.UTF8String);
    started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) { frame(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        double s = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e9;
        printf("%d frames encoded, %d completed, %d presented in %.1f s: %.1f fps\n", frames, atomic_load(&completed),
               atomic_load(&presented), s, atomic_load(&completed) / s);
        BOOL ok = atomic_load(&completed) > 30 && checked == 1;
        printf("%s\n", ok ? "PASS" : "FAIL");
        exit(ok ? 0 : 1);
    });
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc > 1) {
            seconds = atof(argv[1]);
        }
        dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("no Metal device (is the accelerator armed?)\n");
            return 1;
        }
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:argc > 2 ? @(argv[2]) : @"render.metallib"]
                                              error:&err];
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"tri_vertex"];
        rd.fragmentFunction = [lib newFunctionWithName:@"color_fragment"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        gPipe = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
        if (!gPipe) {
            printf("pipeline: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        queue = [dev newCommandQueue];
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        App *delegate = [App new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
