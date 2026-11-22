// Repeatedly create, use, and release render and compute pipeline states in one process.
// VGMTL_ENABLE=1 ./mtllifetime [render.metallib [iterations]]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static BOOL render(id<MTLDevice> device, id<MTLCommandBuffer> cb, id<MTLTexture> target,
                   MTLRenderPipelineDescriptor *desc) {
    NSError *error = nil;
    id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!state) {
        fprintf(stderr, "render state: %s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass];
    const float vertices[][8] = {{-1, -1, 0, 0, 1, 0, 0, 1}, {3, -1, 0, 0, 1, 0, 0, 1}, {-1, 3, 0, 0, 1, 0, 0, 1}};
    const float offset[2] = {0, 0};
    [encoder setRenderPipelineState:state];
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [encoder setVertexBytes:offset length:sizeof(offset) atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return encoder != nil;
}

static BOOL compute(id<MTLDevice> device, id<MTLCommandBuffer> cb, id<MTLTexture> target, id<MTLFunction> fn) {
    NSError *error = nil;
    id<MTLComputePipelineState> state = [device newComputePipelineStateWithFunction:fn error:&error];
    if (!state) {
        fprintf(stderr, "compute state: %s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    id<MTLComputeCommandEncoder> encoder = [cb computeCommandEncoder];
    [encoder setComputePipelineState:state];
    [encoder setTexture:target atIndex:0];
    // Two local sizes force two Vulkan pipeline variants on this compute state.
    [encoder dispatchThreads:MTLSizeMake(32, 32, 1) threadsPerThreadgroup:MTLSizeMake(8, 4, 1)];
    [encoder dispatchThreads:MTLSizeMake(32, 32, 1) threadsPerThreadgroup:MTLSizeMake(4, 8, 1)];
    [encoder endEncoding];
    return encoder != nil;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const int iterations = argc > 2 ? atoi(argv[2]) : 200;
        if (iterations < 1) {
            fprintf(stderr, "usage: mtllifetime [render.metallib [iterations>0]]\n");
            return 2;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:argc > 1 ? @(argv[1]) : @"render.metallib"];
        id<MTLLibrary> lib = [device newLibraryWithURL:url error:&error];
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [lib newFunctionWithName:@"tri_vertex"];
        desc.fragmentFunction = [lib newFunctionWithName:@"color_fragment"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLFunction> fn = [lib newFunctionWithName:@"pattern"];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:32 height:32 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite;
        id<MTLTexture> color = [device newTextureWithDescriptor:td];
        id<MTLTexture> pattern = [device newTextureWithDescriptor:td];
        if (!queue || !color || !pattern || !desc.vertexFunction || !desc.fragmentFunction || !fn) {
            fprintf(stderr, "device or shaders unavailable: %s\n", error.localizedDescription.UTF8String ?: "-");
            return 1;
        }
        printf("%s: %d iterations\n", device.name.UTF8String, iterations);
        for (int i = 0; i < iterations; i++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                // The app's references, including autoreleased encoder objects, are gone before commit.
                @autoreleasepool {
                    if (!render(device, cb, color, desc) || !compute(device, cb, pattern, fn)) {
                        return 1;
                    }
                }
                [cb commit];
                [cb waitUntilCompleted];
                if (cb.status != MTLCommandBufferStatusCompleted) {
                    fprintf(stderr, "iteration %d: %s\n", i + 1, cb.error.localizedDescription.UTF8String ?: "GPU error");
                    return 1;
                }
            }
            if ((i + 1) % 50 == 0 || i + 1 == iterations) {
                printf("completed %d\n", i + 1);
            }
        }
        uint8_t red[4] = {0}, result[4] = {0};
        [color getBytes:red bytesPerRow:4 fromRegion:MTLRegionMake2D(1, 2, 1, 1) mipmapLevel:0];
        [pattern getBytes:result bytesPerRow:4 fromRegion:MTLRegionMake2D(1, 2, 1, 1) mipmapLevel:0];
        BOOL ok = red[0] == 255 && red[1] == 0 && red[2] == 0 && red[3] == 255 &&
                  result[0] == 1 && result[1] == 2 && result[2] == 3 && result[3] == 255;
        printf("%s: render %u,%u,%u,%u; compute %u,%u,%u,%u\n", ok ? "PASS" : "FAIL",
               red[0], red[1], red[2], red[3], result[0], result[1], result[2], result[3]);
        return !ok;
    }
}
