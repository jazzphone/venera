// wininfo (stage 5d): the on-screen windows, front to back: owner, pid, layer, bounds, alpha (CGWindowList; no Screen
// Recording permission needed for these fields).   launchctl asuser UID sudo -u USER ./wininfo
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
int main(void) {
    @autoreleasepool {
        NSArray *list = CFBridgingRelease(
            CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
        for (NSDictionary *w in list) {
            NSDictionary *b = w[(id)kCGWindowBounds];
            printf("%-28s pid %-6d layer %-4d %4.0f,%4.0f %4.0fx%-4.0f alpha %.2f id %d\n",
                   [w[(id)kCGWindowOwnerName] UTF8String] ?: "?", [w[(id)kCGWindowOwnerPID] intValue],
                   [w[(id)kCGWindowLayer] intValue], [b[@"X"] doubleValue], [b[@"Y"] doubleValue], [b[@"Width"] doubleValue],
                   [b[@"Height"] doubleValue], [w[(id)kCGWindowAlpha] doubleValue], [w[(id)kCGWindowNumber] intValue]);
        }
    }
    return 0;
}
