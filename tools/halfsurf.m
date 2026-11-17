// halfsurf: a window whose layer shows CPU-drawn IOSurfaces -- a gradient with stripes of known width -- in
// 64RGBAHalf (as the Dock draws its menus) beside 32BGRA, for WindowServer to composite.
//   halfsurf [SECONDS]
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>

static uint16_t f2h(float f) {
    uint32_t x;
    memcpy(&x, &f, 4);
    uint32_t sign = (x >> 16) & 0x8000, e = ((x >> 23) & 0xff), m = x & 0x7fffff;
    if (e < 113) return (uint16_t)sign;
    return (uint16_t)(sign | ((e - 112) << 10) | (m >> 13));
}

static IOSurfaceRef make(OSType fmt, int w, int h) {
    int bpe = fmt == 'RGhA' ? 8 : 4;
    NSDictionary *p = @{(id)kIOSurfaceWidth : @(w), (id)kIOSurfaceHeight : @(h), (id)kIOSurfaceBytesPerElement : @(bpe),
                        (id)kIOSurfacePixelFormat : @(fmt)};
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)p);
    IOSurfaceLock(s, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(s);
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            float r = (float)x / w, g = (float)y / h, b = (x / 20) % 2 ? 0.9f : 0.2f;   // 20-pixel bands in blue
            if (fmt == 'RGhA') {
                uint16_t *px = (uint16_t *)(base + y * bpr) + x * 4;
                px[0] = f2h(r), px[1] = f2h(g), px[2] = f2h(b), px[3] = f2h(1);
            } else {
                uint8_t *px = base + y * bpr + x * 4;
                px[0] = (uint8_t)(b * 255), px[1] = (uint8_t)(g * 255), px[2] = (uint8_t)(r * 255), px[3] = 255;
            }
        }
    }
    IOSurfaceUnlock(s, 0, NULL);
    printf("%.4s: %dx%d, %zu bytes per row\n", (char *)&(OSType){CFSwapInt32HostToBig(fmt)}, w, h, bpr);
    return s;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 300, 520, 240) styleMask:NSWindowStyleMaskTitled
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @"halfsurf: 64RGBAHalf (left), 32BGRA (right)";
        NSView *v = win.contentView;
        v.wantsLayer = YES;
        CALayer *a = [CALayer layer], *b = [CALayer layer];
        a.frame = CGRectMake(10, 10, 245, 220);
        b.frame = CGRectMake(265, 10, 245, 220);
        a.contents = (__bridge id)make('RGhA', 225, 179);
        b.contents = (__bridge id)make('BGRA', 225, 179);
        [v.layer addSublayer:a];
        [v.layer addSublayer:b];
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        double secs = argc > 1 ? atof(argv[1]) : 20;
        [NSTimer scheduledTimerWithTimeInterval:secs repeats:NO block:^(NSTimer *t) { [NSApp terminate:nil]; }];
        [NSApp run];
    }
    return 0;
}
