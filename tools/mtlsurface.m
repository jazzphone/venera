// mtlsurface: stage 4d, IOSurface-backed textures through the plain Metal API (no window):
//   1. the GPU clears a surface texture: the IOSurface's own memory must hold the pixels afterwards (copy-out);
//   2. the CPU writes the surface, the GPU samples it into another texture (pull by seed);
//   3. getBytes on the surface texture sees the CPU's write;
//   4. 1280x800 surface frames: clear + copy-out, timed.
//   mtlsurface [render.metallib]
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>

static int failures;

static IOSurfaceRef surface(int w, int h) {
    NSDictionary *p = @{
        (id)kIOSurfaceWidth : @(w), (id)kIOSurfaceHeight : @(h), (id)kIOSurfaceBytesPerElement : @4,
        (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA')
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)p);
}

static void check(const char *what, BOOL ok, NSString *detail) {
    printf("  %-52s %s%s%s\n", what, ok ? "ok" : "FAIL", detail ? "  " : "", detail ? detail.UTF8String : "");
    failures += !ok;
}

static uint32_t pixel(IOSurfaceRef s, int x, int y) {   // BGRA bytes as 0xAARRGGBB
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    uint32_t v = *(uint32_t *)((uint8_t *)IOSurfaceGetBaseAddress(s) + y * IOSurfaceGetBytesPerRow(s) + x * 4);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    return v;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("no Metal device (is the accelerator armed?)\n");
            return 1;
        }
        printf("device: %s\n", dev.name.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:argc > 1 ? @(argv[1]) : @"render.metallib"]
                                              error:&err];

        // 1. GPU writes, the surface holds it.
        IOSurfaceRef s = surface(64, 64);
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:64 height:64 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> st = [dev newTextureWithDescriptor:d iosurface:s plane:0];
        check("newTextureWithDescriptor:iosurface:plane:", st && st.iosurface == s, nil);
        if (!st) {
            return 1;
        }
        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture = st;
        p.colorAttachments[0].loadAction = MTLLoadActionClear;
        p.colorAttachments[0].storeAction = MTLStoreActionStore;
        p.colorAttachments[0].clearColor = MTLClearColorMake(1, 0.5, 0, 1);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        [[cb renderCommandEncoderWithDescriptor:p] endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        uint32_t v = pixel(s, 10, 20);
        check("GPU clear lands in the IOSurface's memory", (v & 0xffffff00) == 0xffff8000 || (v & 0xffffff00) == 0xffff7f00,
              [NSString stringWithFormat:@"pixel 0x%08x, want 0xffff8000", v]);

        // 2. CPU writes the surface (green), the GPU samples it into a private texture.
        IOSurfaceLock(s, 0, NULL);
        for (int y = 0; y < 64; y++) {
            uint32_t *row = (uint32_t *)((uint8_t *)IOSurfaceGetBaseAddress(s) + y * IOSurfaceGetBytesPerRow(s));
            for (int x = 0; x < 64; x++) {
                row[x] = 0xff00ff00;
            }
        }
        IOSurfaceUnlock(s, 0, NULL);
        uint8_t px[4] = {0};
        [st getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(5, 5, 1, 1) mipmapLevel:0];
        check("getBytes sees the CPU's write to the surface", px[0] == 0 && px[1] == 255 && px[2] == 0,
              [NSString stringWithFormat:@"BGRA %u %u %u %u", px[0], px[1], px[2], px[3]]);
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"tri_vertex"];
        rd.fragmentFunction = [lib newFunctionWithName:@"texture_fragment"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pipe = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:64 height:64 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> out = [dev newTextureWithDescriptor:td];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
        float v6[6][8] = {{-1, 1, 0, 0, 1, 1, 1, 1}, {1, 1, 1, 0, 1, 1, 1, 1}, {1, -1, 1, 1, 1, 1, 1, 1},
                          {-1, 1, 0, 0, 1, 1, 1, 1}, {1, -1, 1, 1, 1, 1, 1, 1}, {-1, -1, 0, 1, 1, 1, 1, 1}};
        float zero[2] = {0, 0};
        MTLRenderPassDescriptor *p2 = [MTLRenderPassDescriptor renderPassDescriptor];
        p2.colorAttachments[0].texture = out;
        p2.colorAttachments[0].loadAction = MTLLoadActionClear;
        p2.colorAttachments[0].storeAction = MTLStoreActionStore;
        cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:p2];
        [e setRenderPipelineState:pipe];
        [e setVertexBytes:v6 length:sizeof(v6) atIndex:0];
        [e setVertexBytes:zero length:sizeof(zero) atIndex:1];
        [e setFragmentTexture:st atIndex:0];
        [e setFragmentSamplerState:smp atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [e endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        [out getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(32, 32, 1, 1) mipmapLevel:0];
        check("GPU samples the CPU-written surface (RGBA out)", pipe && px[0] == 0 && px[1] == 255 && px[2] == 0,
              [NSString stringWithFormat:@"RGBA %u %u %u %u%s", px[0], px[1], px[2], px[3], pipe ? "" : " (no pipeline)"]);
        CFRelease(s);

        // 4. Full-size frames: 1280x800 surface, clear + copy-out, 30 times.
        IOSurfaceRef big = surface(1280, 800);
        MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:1280 height:800 mipmapped:NO];
        bd.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> bt = [dev newTextureWithDescriptor:bd iosurface:big plane:0];
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (int i = 0; i < 30; i++) {
            MTLRenderPassDescriptor *bp = [MTLRenderPassDescriptor renderPassDescriptor];
            bp.colorAttachments[0].texture = bt;
            bp.colorAttachments[0].loadAction = MTLLoadActionClear;
            bp.colorAttachments[0].storeAction = MTLStoreActionStore;
            bp.colorAttachments[0].clearColor = MTLClearColorMake(i / 30.0, 0, 1, 1);
            cb = [q commandBuffer];
            [[cb renderCommandEncoderWithDescriptor:bp] endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
        }
        double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6 / 30;
        uint32_t last = pixel(big, 640, 400);
        check("1280x800 surface frame (clear + copy-out), each", (last & 0xff) == 0xff,
              [NSString stringWithFormat:@"%.2f ms, last pixel 0x%08x", ms, last]);
        CFRelease(big);
        printf("%s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
        return failures ? 1 : 0;
    }
}
