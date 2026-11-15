// carender: Core Animation's Metal renderer (CA::OGL::MetalContext, the one WindowServer composites with) in an
// ordinary process, on our Metal device, so a WindowServer abort can be reproduced in seconds instead of a boot.
// Renders a layer tree into an offscreen texture with CARenderer: a gradient image, a CABackdropLayer that tracks the
// luma under it (what the menu bar does; it runs CA::OGL::MetalContext::calculate_average_luma), a rounded,
// translucent layer on top. Prints a few pixels per frame.
//   VGMTL_ENABLE=1 carender [FRAMES] [notrack|fx]
// fx adds what makes Core Animation render through transient (offscreen) surfaces: a Gaussian blur filter on a layer,
// a blurring backdrop (a "material"), a shadow, a mask and a group-opacity subtree.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static CGImageRef gradient(size_t w, size_t h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    for (size_t y = 0; y < h; y++) {
        CGContextSetRGBFillColor(c, (CGFloat)y / h, 0.3, 1.0 - (CGFloat)y / h, 1.0);
        CGContextFillRect(c, CGRectMake(0, y, w, 1));
    }
    CGImageRef img = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    CGColorSpaceRelease(cs);
    return img;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int frames = argc > 1 ? atoi(argv[1]) : 5;
        BOOL track = !(argc > 2 && !strcmp(argv[2], "notrack"));
        BOOL fx = argc > 2 && !strcmp(argv[2], "fx");
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("no Metal device (VGMTL_ENABLE=1? accelerator armed?)\n");
            return 1;
        }
        printf("device: %s\n", dev.name.UTF8String);
        const NSUInteger W = 256, H = 256;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:W
                                                                                     height:H
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandQueue> queue = [dev newCommandQueue];

        CALayer *root = [CALayer layer];
        root.frame = CGRectMake(0, 0, W, H);
        root.backgroundColor = CGColorCreateGenericRGB(0.1, 0.1, 0.1, 1);
        CALayer *image = [CALayer layer];
        image.frame = root.bounds;
        CGImageRef img = gradient(W, H);
        image.contents = (__bridge id)img;
        [root addSublayer:image];

        Class backdropClass = NSClassFromString(@"CABackdropLayer");
        CALayer *backdrop = backdropClass ? [backdropClass layer] : nil;
        if (backdrop) {
            backdrop.frame = CGRectMake(0, H - 40, W, 40);   // a menu bar's strip
            if (track && [backdrop respondsToSelector:@selector(setTracksLuma:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(backdrop, @selector(setTracksLuma:), YES);
                if ([backdrop respondsToSelector:@selector(setTracksLumaWhileHidden:)]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(backdrop, @selector(setTracksLumaWhileHidden:), YES);
                }
                if ([backdrop respondsToSelector:@selector(setLumaUpdateRate:)]) {
                    ((void (*)(id, SEL, double))objc_msgSend)(backdrop, @selector(setLumaUpdateRate:), 60.0);
                }
            }
            [root addSublayer:backdrop];
        }
        printf("backdrop layer: %s, tracksLuma %s\n", backdrop ? "yes" : "no (no CABackdropLayer)", track ? "on" : "off");

        CALayer *panel = [CALayer layer];
        panel.frame = CGRectMake(48, 48, 160, 100);
        panel.cornerRadius = 16;
        panel.backgroundColor = CGColorCreateGenericRGB(1, 1, 1, 0.6);
        [root addSublayer:panel];

        if (fx) {
            Class filterClass = NSClassFromString(@"CAFilter");
            id (*mk)(id, SEL, id) = (id(*)(id, SEL, id))objc_msgSend;
            id blur = filterClass ? mk(filterClass, @selector(filterWithType:), @"gaussianBlur") : nil;
            [blur setValue:@8 forKey:@"inputRadius"];
            id bblur = filterClass ? mk(filterClass, @selector(filterWithType:), @"gaussianBlur") : nil;
            [bblur setValue:@20 forKey:@"inputRadius"];
            printf("fx: CAFilter %s\n", blur ? "yes" : "NO");
            panel.shadowOpacity = 0.8;
            panel.shadowRadius = 10;
            panel.shadowOffset = CGSizeMake(0, -6);
            if (backdrop && bblur) {
                backdrop.filters = @[ bblur ];   // a material: blur what's behind
            }
            CALayer *blurred = [CALayer layer];
            blurred.frame = CGRectMake(20, 160, 90, 60);
            blurred.backgroundColor = CGColorCreateGenericRGB(0, 1, 0, 1);
            if (blur) {
                blurred.filters = @[ blur ];
            }
            [root addSublayer:blurred];
            CALayer *masked = [CALayer layer];
            masked.frame = CGRectMake(150, 160, 90, 60);
            masked.backgroundColor = CGColorCreateGenericRGB(1, 1, 0, 1);
            CALayer *mask = [CALayer layer];
            mask.frame = CGRectMake(0, 0, 90, 60);
            mask.cornerRadius = 30;
            mask.backgroundColor = CGColorCreateGenericRGB(0, 0, 0, 1);
            masked.mask = mask;
            [root addSublayer:masked];
            CALayer *group = [CALayer layer];
            group.frame = CGRectMake(100, 10, 80, 40);
            group.opacity = 0.5;
            group.allowsGroupOpacity = YES;
            for (int k = 0; k < 2; k++) {
                CALayer *c = [CALayer layer];
                c.frame = CGRectMake(k * 30, 0, 50, 40);
                c.backgroundColor = CGColorCreateGenericRGB(k, 0, 1 - k, 1);
                [group addSublayer:c];
            }
            [root addSublayer:group];
        }

        // A local CAContext (private) gives the tree a render context ID; update_backdrop_luma looks it up.
        id ctx = nil;
        Class ctxClass = NSClassFromString(@"CAContext");
        if (ctxClass && [ctxClass respondsToSelector:@selector(localContext)]) {
            ctx = ((id(*)(id, SEL))objc_msgSend)(ctxClass, @selector(localContext));
            ((void (*)(id, SEL, id))objc_msgSend)(ctx, @selector(setLayer:), root);
            printf("local CAContext id %u\n", ((unsigned (*)(id, SEL))objc_msgSend)(ctx, @selector(contextId)));
        }
        CARenderer *r = [CARenderer rendererWithMTLTexture:target options:@{kCARendererMetalCommandQueue : queue}];
        r.layer = root;
        r.bounds = root.bounds;
        [CATransaction flush];
        for (int f = 0; f < frames; f++) {
            panel.position = CGPointMake(128 + 30 * sin(f), 98);
            [CATransaction flush];
            [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
            [r addUpdateRect:root.bounds];
            [r render];
            [r endFrame];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            [cb commit];
            [cb waitUntilCompleted];   // the renderer's own buffers were committed before ours on the same queue
            uint8_t px[4][4];
            const int pts[4][2] = {{10, 10}, {128, 100}, {128, 240}, {250, 250}};
            for (int i = 0; i < 4; i++) {
                [target getBytes:px[i] bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(pts[i][0], pts[i][1], 1, 1) mipmapLevel:0];
            }
            printf("frame %d: (10,10) %02x%02x%02x%02x  (128,100) %02x%02x%02x%02x  (128,240) %02x%02x%02x%02x  "
                   "(250,250) %02x%02x%02x%02x\n",
                   f, px[0][2], px[0][1], px[0][0], px[0][3], px[1][2], px[1][1], px[1][0], px[1][3], px[2][2], px[2][1],
                   px[2][0], px[2][3], px[3][2], px[3][1], px[3][0], px[3][3]);
            fflush(stdout);
        }
        {   // the last frame as /var/tmp/carender.png (BGRA)
            NSMutableData *pix = [NSMutableData dataWithLength:W * H * 4];
            [target getBytes:pix.mutableBytes bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef c = CGBitmapContextCreate(pix.mutableBytes, W, H, 8, W * 4, cs,
                                                   kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGImageRef out = CGBitmapContextCreateImage(c);
            CGImageDestinationRef d = CGImageDestinationCreateWithURL(
                (__bridge CFURLRef)[NSURL fileURLWithPath:@"/var/tmp/carender.png"], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
            CGImageDestinationAddImage(d, out, NULL);
            CGImageDestinationFinalize(d);
            CFRelease(d);
            CGImageRelease(out);
            CGContextRelease(c);
            CGColorSpaceRelease(cs);
            printf("frame saved: /var/tmp/carender.png\n");
        }
        CGImageRelease(img);
        printf("done\n");
    }
    return 0;
}
