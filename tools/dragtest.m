// dragtest (stage 5c): a normal AppKit window at a known place, with a long scrollable text, for measuring drags,
// scrolls and resizes driven from the host (tools/qmpinput.py) without anyone at the screen.
//   launchctl asuser <uid> sudo -u <user> ./dragtest [SECONDS [scroll|minimize]]
// The window's content is 640x420 points with its bottom-left corner at (200, 150) on a 1280x800 screen: its title bar
// is around (520, 216), its text around (520, 420) and its bottom-right corner at (840, 650), in top-left screen
// coordinates. "scroll" scrolls the text 8 points per frame at 60 Hz from the third second on (the host's wheel events
// don't reach it); "minimize" minimizes and restores the window every 2 s.
#import <Cocoa/Cocoa.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        int secs = argc > 1 ? atoi(argv[1]) : 60;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 150, 640, 420)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.title = @"VGDragTest";
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:w.contentView.bounds];
        sv.hasVerticalScroller = YES;
        sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
        tv.autoresizingMask = NSViewWidthSizable;
        NSMutableString *text = [NSMutableString string];
        for (int i = 1; i <= 3000; i++) {
            [text appendFormat:@"Line %4d  The quick brown fox jumps over the lazy dog. 0123456789 ABCDEFGHIJ\n", i];
        }
        tv.string = text;
        tv.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
        sv.documentView = tv;
        [w.contentView addSubview:sv];
        [w makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        const char *mode = argc > 2 ? argv[2] : "";
        if (!strcmp(mode, "scroll")) {
            __block CGFloat y = 0, dir = 8;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) {
                    CGFloat max = tv.frame.size.height - sv.contentView.bounds.size.height;
                    y += dir;
                    if (y > max || y < 0) {
                        dir = -dir;
                        y += 2 * dir;
                    }
                    [sv.contentView scrollToPoint:NSMakePoint(0, y)];
                    [sv reflectScrolledClipView:sv.contentView];
                }];
            });
        } else if (!strcmp(mode, "minimize")) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
                    if (w.isMiniaturized) {
                        [w deminiaturize:nil];
                    } else {
                        [w miniaturize:nil];
                    }
                }];
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)secs * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
        [NSApp run];
    }
    return 0;
}
