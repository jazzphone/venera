// mtlsurface: stage 4d, IOSurface-backed textures through the plain Metal API (no window):
//   1. the GPU clears a surface texture: the IOSurface's own memory must hold the pixels afterwards (copy-out);
//   2. the CPU writes the surface, the GPU samples it into another texture (pull by seed);
//   3. getBytes on the surface texture sees the CPU's write;
//   4. 1280x800 surface frames: clear + copy-out, timed.
//   mtlsurface [render.metallib [--la-blend]]
//   --la-blend checks the luminance-alpha model used by Venera against a synthetic LA08 surface.
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

static void check_la_blend(id<MTLDevice> dev, id<MTLCommandQueue> queue, id<MTLLibrary> lib) {
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (id)kIOSurfaceWidth : @32, (id)kIOSurfaceHeight : @32,
        (id)kIOSurfaceBytesPerElement : @2, (id)kIOSurfacePixelFormat : @((uint32_t)'LA08')
    });
    if (!s || IOSurfaceLock(s, 0, NULL) != KERN_SUCCESS) {
        check("allocate LA08 test surface", NO, nil);
        if (s) CFRelease(s);
        return;
    }
    for (size_t y = 0; y < 32; y++) {
        uint8_t *row = (uint8_t *)IOSurfaceGetBaseAddress(s) + y * IOSurfaceGetBytesPerRow(s);
        for (size_t x = 0; x < 32; x++) {
            row[2 * x] = 192;
            row[2 * x + 1] = 160;
        }
    }
    IOSurfaceUnlock(s, 0, NULL);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
                                                                                   width:32 height:32 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td iosurface:s plane:0];
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"tri_vertex"];
    rd.fragmentFunction = [lib newFunctionWithName:@"color_fragment"];
    MTLRenderPipelineColorAttachmentDescriptor *color = rd.colorAttachments[0];
    color.pixelFormat = td.pixelFormat;
    color.blendingEnabled = YES;
    color.sourceRGBBlendFactor = MTLBlendFactorOne;
    color.destinationRGBBlendFactor = MTLBlendFactorZero;
    color.sourceAlphaBlendFactor = MTLBlendFactorZero;
    color.destinationAlphaBlendFactor = MTLBlendFactorOne;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [dev newRenderPipelineStateWithDescriptor:rd error:&error];
    if (!target || !pipeline) {
        check("create LA08 texture and blended pipeline", NO, error.localizedDescription);
        CFRelease(s);
        return;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    const float vertices[][8] = {{-1, -1, 0, 0, .25, 0, 0, .5}, {3, -1, 0, 0, .25, 0, 0, .5}, {-1, 3, 0, 0, .25, 0, 0, .5}};
    const float offset[2] = {0, 0};
    [e setRenderPipelineState:pipeline];
    [e setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [e setVertexBytes:offset length:sizeof(offset) atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) == KERN_SUCCESS) {
        const uint8_t *px = (const uint8_t *)IOSurfaceGetBaseAddress(s) + 16 * IOSurfaceGetBytesPerRow(s) + 2 * 16;
        check("LA08 blend replaces luminance and preserves destination alpha",
              cb.status == MTLCommandBufferStatusCompleted && abs((int)px[0] - 64) <= 1 && px[1] == 160,
              [NSString stringWithFormat:@"LA %u,%u, want 64,160", px[0], px[1]]);
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    } else {
        check("read LA08 test surface", NO, nil);
    }
    CFRelease(s);
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
        if (argc > 2 && !strcmp(argv[2], "--la-blend")) {
            check_la_blend(dev, q, lib);
            return failures ? 1 : 0;
        }

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
