// modetest (stage 5c): list the main display's modes, or switch to one and back, as the console user.
//   modetest                 list modes (the current one marked), each with its IOKit flags and whether macOS calls it
//                            usable for the desktop; "dup" marks a mode macOS lists only when asked for its duplicate
//                            low-resolution modes (kCGDisplayShowDuplicateLowResolutionModes)
//   modetest W H [SECONDS] [2x]   switch to WxH (2x: the Retina one, twice the pixels), stay SECONDS (default 5; 0
//                            stays: saved as the user's display setting), switch back; prints what CoreGraphics
//                            reports
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

static void show(CGDisplayModeRef m, const char *tag) {
    printf("%s%zux%zu (%zux%zu pixels) %.0f Hz\n", tag, CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
           CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m), CGDisplayModeGetRefreshRate(m));
}

static void showFull(CGDisplayModeRef m, const char *tag, BOOL dup) {
    printf("%s%zux%zu (%zux%zu pixels) %.0f Hz  io 0x%08x%s%s\n", tag, CGDisplayModeGetWidth(m),
           CGDisplayModeGetHeight(m), CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
           CGDisplayModeGetRefreshRate(m), CGDisplayModeGetIOFlags(m),
           CGDisplayModeIsUsableForDesktopGUI(m) ? " desktop" : "", dup ? " dup" : "");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        CGDirectDisplayID d = CGMainDisplayID();
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
        NSDictionary *opts = @{(id)kCGDisplayShowDuplicateLowResolutionModes : @YES};
        NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(d, (__bridge CFDictionaryRef)opts));
        if (argc < 3) {
            showFull(cur, "current: ", NO);
            NSArray *plain = CFBridgingRelease(CGDisplayCopyAllDisplayModes(d, NULL));
            for (id o in modes) {
                CGDisplayModeRef m = (__bridge CGDisplayModeRef)o;
                BOOL listed = NO;
                for (id p in plain) {
                    CGDisplayModeRef q = (__bridge CGDisplayModeRef)p;
                    listed |= CGDisplayModeGetIODisplayModeID(q) == CGDisplayModeGetIODisplayModeID(m) &&
                              CGDisplayModeGetPixelWidth(q) == CGDisplayModeGetPixelWidth(m) &&
                              CGDisplayModeGetWidth(q) == CGDisplayModeGetWidth(m);
                }
                showFull(m, CGDisplayModeGetIODisplayModeID(m) == CGDisplayModeGetIODisplayModeID(cur) &&
                                    CGDisplayModeGetPixelWidth(m) == CGDisplayModeGetPixelWidth(cur) &&
                                    CGDisplayModeGetWidth(m) == CGDisplayModeGetWidth(cur) ? "* " : "  ", !listed);
            }
            return 0;
        }
        size_t w = strtoul(argv[1], NULL, 10), h = strtoul(argv[2], NULL, 10);
        int secs = argc > 3 ? atoi(argv[3]) : 5;
        const int retina = argc > 4 && !strcmp(argv[4], "2x");
        CGDisplayModeRef want = NULL;
        for (id o in modes) {
            CGDisplayModeRef m = (__bridge CGDisplayModeRef)o;
            if (CGDisplayModeGetWidth(m) == w && CGDisplayModeGetHeight(m) == h &&
                (CGDisplayModeGetPixelWidth(m) == 2 * w) == retina) {
                want = m;
                break;
            }
        }
        if (!want) {
            printf("no %zux%zu mode\n", w, h);
            return 1;
        }
        show(cur, "from ");
        CGError e;
        if (secs == 0) {   // stays: committed as the user's setting (CGDisplaySetDisplayMode's lasts as long as this process)
            CGDisplayConfigRef cfg = NULL;
            e = CGBeginDisplayConfiguration(&cfg);
            if (e == kCGErrorSuccess) {
                e = CGConfigureDisplayWithDisplayMode(cfg, d, want, NULL);
            }
            e = e == kCGErrorSuccess ? CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently) : e;
        } else {
            e = CGDisplaySetDisplayMode(d, want, NULL);
        }
        printf("set %zux%zu -> %d\n", w, h, e);
        CGDisplayModeRef now = CGDisplayCopyDisplayMode(d);
        show(now, "now ");
        CGDisplayModeRelease(now);
        if (secs == 0) {   // stays (for the login session)
            CGDisplayModeRelease(cur);
            return e == kCGErrorSuccess ? 0 : 1;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        e = CGDisplaySetDisplayMode(d, cur, NULL);
        printf("back -> %d\n", e);
        now = CGDisplayCopyDisplayMode(d);
        show(now, "now ");
        CGDisplayModeRelease(now);
        CGDisplayModeRelease(cur);
        return e == kCGErrorSuccess ? 0 : 1;
    }
}
