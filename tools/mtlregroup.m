// mtlregroup: one IOSurface plane read through a wrapper of other texels (round 23), right after a GPU write through
// another, as VideoToolbox's Metal transfer does (a 512-wide BGRA plane as a 128-wide RGBA32Uint texture): each image
// must see the other's write at once, before any write-back to the surface's CPU memory.
//   VGMTL_ENABLE=1 ./mtlregroup
// Checks, one line each, then "mtlregroup: PASS" or "mtlregroup: FAIL (n)":
//   A) BGRA 512x64 cleared to a color on the GPU, read at once through RGBA32Uint 128x64 by a kernel: every word
//   B) a kernel writes RGBA32Uint 128x64, read at once through BGRA 512x64 by a blit to a buffer: every pixel
//   C) ten rounds of A and B in a row, alternating, each with its own color, no waits between commits
//   D) the CPU's copy after all that: the last round's color everywhere
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void read_words(texture2d<uint, access::read> t [[texture(0)]], device uint4 *out [[buffer(0)]],\n"
     "                       uint2 p [[thread_position_in_grid]]) {\n"
     "    if (p.x < t.get_width() && p.y < t.get_height()) out[p.y * t.get_width() + p.x] = t.read(p);\n"
     "}\n"
     "kernel void write_words(texture2d<uint, access::write> t [[texture(0)]], constant uint &w [[buffer(0)]],\n"
     "                        uint2 p [[thread_position_in_grid]]) {\n"
     "    if (p.x < t.get_width() && p.y < t.get_height()) t.write(uint4(w), p);\n"
     "}\n";

enum { W = 512, H = 64 };
static int fails;
static void check(BOOL ok, NSString *what) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
    fails += !ok;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("mtlregroup: device %s\n", dev.name.UTF8String);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:nil error:&err];
        id<MTLComputePipelineState> rd = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"read_words"] error:&err] : nil;
        id<MTLComputePipelineState> wr = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"write_words"] error:&err] : nil;
        if (!rd || !wr) {
            printf("mtlregroup: FAIL pipelines: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef) @{
            (id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfaceBytesPerElement : @4,
            (id)kIOSurfaceBytesPerRow : @(W * 4), (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA')
        });
        MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:W height:H mipmapped:NO];
        bd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        MTLTextureDescriptor *ud = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint
                                                                                      width:W / 4 height:H mipmapped:NO];
        ud.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> bgra = [dev newTextureWithDescriptor:bd iosurface:s plane:0];
        id<MTLTexture> words = [dev newTextureWithDescriptor:ud iosurface:s plane:0];
        check(bgra && words, @"both wrappers made (the regrouping taken)");
        if (!bgra || !words) {
            printf("mtlregroup: FAIL (%d)\n", fails);
            return 1;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> out = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];

        // the BGRA bytes of a clear color, as one little-endian word: B, G, R, A
        uint32_t (^clearBGRA)(int) = ^uint32_t(int round) {
            double r = (round * 37 % 255) / 255.0, g = (round * 91 % 255) / 255.0, b = (round * 53 % 255) / 255.0;
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = bgra;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            [cb commit];
            return (uint32_t)lround(b * 255) | (uint32_t)lround(g * 255) << 8 | (uint32_t)lround(r * 255) << 16 | 0xffu << 24;
        };
        // a kernel reads the words; YES when every word is want
        BOOL (^readWords)(uint32_t) = ^BOOL(uint32_t want) {
            memset(out.contents, 0, out.length);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:rd];
            [ce setTexture:words atIndex:0];
            [ce setBuffer:out offset:0 atIndex:0];
            [ce dispatchThreads:MTLSizeMake(W / 4, H, 1) threadsPerThreadgroup:MTLSizeMake(16, 4, 1)];
            [ce endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            const uint32_t *w = out.contents;
            for (int i = 0; i < W * H; i++) {
                if (w[i] != want) {
                    printf("     word %d is %08x, not %08x\n", i, w[i], want);
                    return NO;
                }
            }
            return YES;
        };
        // a kernel writes the words
        void (^writeWords)(uint32_t) = ^(uint32_t v) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:wr];
            [ce setTexture:words atIndex:0];
            [ce setBytes:&v length:4 atIndex:0];
            [ce dispatchThreads:MTLSizeMake(W / 4, H, 1) threadsPerThreadgroup:MTLSizeMake(16, 4, 1)];
            [ce endEncoding];
            [cb commit];
        };
        // a blit reads the BGRA pixels; YES when every pixel is want
        BOOL (^readPixels)(uint32_t) = ^BOOL(uint32_t want) {
            memset(out.contents, 0, out.length);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromTexture:bgra sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(W, H, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:W * 4
                destinationBytesPerImage:W * H * 4];
            [be endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            const uint32_t *p = out.contents;
            for (int i = 0; i < W * H; i++) {
                if (p[i] != want) {
                    printf("     pixel %d is %08x, not %08x\n", i, p[i], want);
                    return NO;
                }
            }
            return YES;
        };

        uint32_t c = clearBGRA(1);
        check(readWords(c), [NSString stringWithFormat:@"A: a BGRA clear (%08x) read at once as RGBA32Uint words", c]);
        writeWords(0x80402010u);
        check(readPixels(0x80402010u), @"B: RGBA32Uint words (80402010) read at once as BGRA pixels");
        BOOL all = YES;
        uint32_t last = 0;
        for (int round = 2; round < 12; round++) {
            if (round & 1) {
                last = clearBGRA(round);
                all &= readWords(last);
            } else {
                last = 0x01010101u * (uint32_t)(round * 17) | 0xff000000u;
                writeWords(last);
                all &= readPixels(last);
            }
        }
        check(all, @"C: ten rounds, alternating, no waits between the writes and the reads");
        IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
        const uint32_t *cpu = IOSurfaceGetBaseAddress(s);
        BOOL same = YES;
        for (int y = 0; y < H && same; y++) {
            for (int x = 0; x < W; x++) {
                if (cpu[y * W + x] != last) {
                    printf("     CPU pixel %d,%d is %08x, not %08x\n", x, y, cpu[y * W + x], last);
                    same = NO;
                    break;
                }
            }
        }
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
        check(same, [NSString stringWithFormat:@"D: the surface's CPU copy holds the last round (%08x)", last]);
        printf(fails ? "mtlregroup: FAIL (%d)\n" : "mtlregroup: PASS\n", fails);
        CFRelease(s);
        return fails != 0;
    }
}
