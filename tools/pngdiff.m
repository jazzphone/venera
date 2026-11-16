// pngdiff: compare two images pixel by pixel (runs on the build Mac): how many pixels differ (by more than TOL in
// any channel), the largest difference and the bounding box of the differences.
//   pngdiff A.png B.png [TOL [MASK.png]]   (MASK: B dimmed, the differing pixels red)
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

static uint8_t *load(const char *path, size_t *w, size_t *h) {
    CGImageSourceRef src = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]], NULL);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (!img) {
        fprintf(stderr, "can't read %s\n", path);
        exit(2);
    }
    *w = CGImageGetWidth(img), *h = CGImageGetHeight(img);
    uint8_t *px = calloc(*w * *h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, *w, *h, 8, *w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, *w, *h), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CGImageRelease(img);
    CFRelease(src);
    return px;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "pngdiff A.png B.png [TOL]\n");
        return 2;
    }
    int tol = argc > 3 ? atoi(argv[3]) : 0;
    size_t wa, ha, wb, hb;
    uint8_t *a = load(argv[1], &wa, &ha), *b = load(argv[2], &wb, &hb);
    if (wa != wb || ha != hb) {
        printf("sizes differ: %zux%zu vs %zux%zu\n", wa, ha, wb, hb);
        return 1;
    }
    size_t n = 0, x0 = wa, y0 = ha, x1 = 0, y1 = 0;
    int maxd = 0;
    for (size_t y = 0; y < ha; y++) {
        for (size_t x = 0; x < wa; x++) {
            int d = 0;
            for (int c = 0; c < 4; c++) {
                int v = abs((int)a[(y * wa + x) * 4 + c] - (int)b[(y * wa + x) * 4 + c]);
                d = v > d ? v : d;
            }
            if (d > tol) {
                n++;
                x0 = x < x0 ? x : x0, y0 = y < y0 ? y : y0, x1 = x > x1 ? x : x1, y1 = y > y1 ? y : y1;
            }
            maxd = d > maxd ? d : maxd;
        }
    }
    if (argc > 4) {
        for (size_t i = 0; i < wa * ha; i++) {
            int d = 0;
            for (int c = 0; c < 4; c++) {
                int v = abs((int)a[i * 4 + c] - (int)b[i * 4 + c]);
                d = v > d ? v : d;
            }
            uint8_t *p = &b[i * 4];
            if (d > tol) {
                p[0] = 255, p[1] = 0, p[2] = 0;
            } else {
                p[0] /= 3, p[1] /= 3, p[2] /= 3;
            }
            p[3] = 255;
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(b, wa, ha, 8, wa * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[4]]], CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(dst, img, NULL);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
        CGImageRelease(img);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
    }
    if (n) {
        printf("%zu of %zu pixels differ (> %d), max %d, in (%zu,%zu)-(%zu,%zu)\n", n, wa * ha, tol, maxd, x0, y0, x1, y1);
    } else {
        printf("identical (max difference %d)\n", maxd);
    }
    return n ? 1 : 0;
}
