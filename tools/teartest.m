// teartest (round 17): a borderless window over the whole screen that turns black and white on alternate frames, for
// catching torn frames from outside the VM (tools/vncgrab.py on the host; a frame that is part black and part white
// held two frames at once). Draws with Core Animation, so its frames go the way any app's do.
//   launchctl asuser <uid> sudo -u <user> ./teartest [SECONDS [bg]]
// "bg": a still magenta window over the screen at the normal level instead, a plain backdrop for dragging another
// window over (anything not magenta outside that window is left behind).
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        double secs = argc > 1 ? atof(argv[1]) : 10;
        BOOL bg = argc > 2 && !strcmp(argv[2], "bg");
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect f = NSScreen.mainScreen.frame;
        NSWindow *w = [[NSWindow alloc] initWithContentRect:f
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.level = bg ? NSNormalWindowLevel : CGShieldingWindowLevel();
        w.opaque = YES;
        w.contentView.wantsLayer = YES;
        CALayer *l = w.contentView.layer;
        [w makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        __block BOOL white = NO;
        __block long frames = 0;
        if (bg) {
            l.backgroundColor = [NSColor colorWithSRGBRed:1 green:0 blue:1 alpha:1].CGColor;
        }
        NSTimer *t = [NSTimer timerWithTimeInterval:bg ? 3600 : 1.0 / 60 repeats:YES block:^(NSTimer *timer) {
            white = !white;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            l.backgroundColor = white ? NSColor.whiteColor.CGColor : NSColor.blackColor.CGColor;
            [CATransaction commit];
            frames++;
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            printf("%ld frames asked for\n", frames);
            [NSApp terminate:nil];
        });
        [NSApp run];
    }
    return 0;
}
