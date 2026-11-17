// makeicon: draws Venera's app icon (a display on a blue-to-violet tile, macOS's icon grid) into an .iconset folder,
// for iconutil. Runs on the build Mac: helper/makeicon OUT.iconset
#import <Cocoa/Cocoa.h>
static void draw(NSString *dir, int px, NSString *name) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGFloat s = px / 1024.0;
    NSRect tile = NSMakeRect(100 * s, 100 * s, 824 * s, 824 * s);   // the grid's 824 pt tile
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:185 * s yRadius:185 * s];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.20 green:0.47 blue:0.98 alpha:1]
                                                  endingColor:[NSColor colorWithSRGBRed:0.47 green:0.25 blue:0.86 alpha:1]];
    [g drawInBezierPath:p angle:-90];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:430 * s weight:NSFontWeightMedium];
    cfg = [cfg configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.whiteColor]];
    NSImage *sym = [[NSImage imageWithSystemSymbolName:@"play.display" accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    NSSize z = sym.size;
    [sym drawInRect:NSMakeRect((1024 * s - z.width) / 2, (1024 * s - z.height) / 2, z.width, z.height)];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *dir = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        for (int b = 16; b <= 512; b *= 2) {
            draw(dir, b, [NSString stringWithFormat:@"icon_%dx%d.png", b, b]);
            draw(dir, b * 2, [NSString stringWithFormat:@"icon_%dx%d@2x.png", b, b]);
        }
    }
}
