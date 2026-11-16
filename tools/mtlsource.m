// mtlsource (stage 5d): compile Metal shading language source at run time (as ANGLE does for WebGL) and run it: a
// compute kernel checked on the CPU, then a render pass whose pixels are read back.
//   mtlsource            (needs the process allow-listed, e.g. VGMTL_ENABLE=1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSource = @"#include <metal_stdlib>\n"
                                  "using namespace metal;\n"
                                  "kernel void scale_add(device const float *a [[buffer(0)]], device float *b [[buffer(1)]],\n"
                                  "                      constant float &k [[buffer(2)]], uint i [[thread_position_in_grid]]) {\n"
                                  "    b[i] = a[i] * k + float(i);\n"
                                  "}\n"
                                  "struct V { float4 p [[position]]; float4 c; };\n"
                                  "vertex V vs(uint vid [[vertex_id]]) {\n"
                                  "    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};\n"
                                  "    V o; o.p = float4(p[vid], 0, 1); o.c = float4(0.25, 0.5, 1.0, 1.0); return o;\n"
                                  "}\n"
                                  "fragment float4 fs(V in [[stage_in]]) { return in.c; }\n"
                                  "vertex V vs_half(uint vid [[vertex_id]]) {\n"
                                  "    float2 p[3] = {float2(-1, -1), float2(1, -1), float2(-1, 1)};\n"
                                  "    V o; o.p = float4(p[vid], 0, 1); o.c = float4(1, 1, 1, 1); return o;\n"
                                  "}\n";

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("device: %s\n", dev ? dev.name.UTF8String : "(none)");
        if (!dev) {
            return 2;
        }
        NSError *err = nil;
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:[MTLCompileOptions new] error:&err];
        printf("newLibraryWithSource: %s (%.1f ms)%s%s\n", lib ? "ok" : "FAILED",
               (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, err ? " error: " : "",
               err ? err.localizedDescription.UTF8String : "");
        if (!lib) {
            return 1;
        }
        printf("functions: %s\n", [[lib functionNames] componentsJoinedByString:@", "].UTF8String);
        int failures = 0;
        // compute
        id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"scale_add"] error:&err];
        const int n = 4096;
        id<MTLBuffer> a = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> b = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
        float *pa = a.contents, k = 3.0f;
        for (int i = 0; i < n; i++) {
            pa[i] = i * 0.5f;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:cps];
        [ce setBuffer:a offset:0 atIndex:0];
        [ce setBuffer:b offset:0 atIndex:1];
        [ce setBytes:&k length:4 atIndex:2];
        [ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        float *pb = b.contents;
        int bad = 0;
        for (int i = 0; i < n; i++) {
            bad += pb[i] != pa[i] * k + i;
        }
        printf("compute from source: %s (%d of %d wrong)\n", bad ? "FAIL" : "ok", bad, n);
        failures += bad != 0;
        // render
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"vs"];
        rd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
        printf("render pipeline from source: %s%s\n", rps ? "ok" : "FAILED ", rps ? "" : err.localizedDescription.UTF8String);
        if (rps) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                         width:64 height:64 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModeManaged;
            id<MTLTexture> t = [dev newTextureWithDescriptor:td];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
            rp.colorAttachments[0].texture = t;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:rps];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [re endEncoding];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be synchronizeResource:t];
            [be endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            uint8_t px[4];
            [t getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(32, 32, 1, 1) mipmapLevel:0];
            BOOL ok = abs(px[0] - 64) <= 1 && abs(px[1] - 128) <= 1 && px[2] == 255 && px[3] == 255;
            printf("render from source: %s (pixel %u %u %u %u)\n", ok ? "ok" : "FAIL", px[0], px[1], px[2], px[3]);
            failures += !ok;
        } else {
            failures++;
        }
        // 4x multisampling (5d): a triangle over half the target, resolved; its diagonal edge gets partial coverage
        if ([dev supportsTextureSampleCount:4]) {
            MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                         width:64 height:64 mipmapped:NO];
            md.textureType = MTLTextureType2DMultisample;
            md.sampleCount = 4;
            md.usage = MTLTextureUsageRenderTarget;
            md.storageMode = MTLStorageModePrivate;
            id<MTLTexture> ms = [dev newTextureWithDescriptor:md];
            MTLTextureDescriptor *rdsc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:64 height:64 mipmapped:NO];
            rdsc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            rdsc.storageMode = MTLStorageModeManaged;
            id<MTLTexture> res = [dev newTextureWithDescriptor:rdsc];
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"vs_half"];
            pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            pd.rasterSampleCount = 4;
            id<MTLRenderPipelineState> mps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
            if (!ms || !res || !mps) {
                printf("msaa: FAILED to make %s\n", !ms ? "the 4x texture" : !res ? "the resolve texture" : "the pipeline");
                failures++;
            } else {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
                rp.colorAttachments[0].texture = ms;
                rp.colorAttachments[0].resolveTexture = res;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
                cb = [q commandBuffer];
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:mps];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                [be synchronizeResource:res];
                [be endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                uint8_t px[64 * 64 * 4];
                [res getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
                int inside = px[(56 * 64 + 8) * 4], outside = px[(8 * 64 + 56) * 4], partial = 0;
                for (int y = 0; y < 64; y++) {
                    int v = px[(y * 64 + y) * 4];   // the edge: pixel centers on it are half covered
                    partial += v > 20 && v < 235;
                }
                BOOL ok = inside == 255 && outside == 0 && partial > 0;
                printf("msaa 4x resolve: %s (inside %d, outside %d, %d partially covered edge pixels)\n", ok ? "ok" : "FAIL",
                       inside, outside, partial);
                failures += !ok;
            }
        } else {
            printf("msaa: the device says it doesn't do 4 samples\n");
        }
        // stencil (5d): a mask written by one draw, tested by the next, on a Stencil8 attachment
        {
            MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8
                                                                                        width:64 height:64 mipmapped:NO];
            sd.usage = MTLTextureUsageRenderTarget;
            sd.storageMode = MTLStorageModePrivate;
            id<MTLTexture> stex = [dev newTextureWithDescriptor:sd];
            MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                         width:64 height:64 mipmapped:NO];
            cd.usage = MTLTextureUsageRenderTarget;
            cd.storageMode = MTLStorageModeManaged;
            id<MTLTexture> ctex = [dev newTextureWithDescriptor:cd];
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            pd.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
            pd.vertexFunction = [lib newFunctionWithName:@"vs_half"];
            pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
            pd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
            id<MTLRenderPipelineState> maskp = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
            pd.vertexFunction = [lib newFunctionWithName:@"vs"];
            pd.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
            id<MTLRenderPipelineState> fillp = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
            MTLDepthStencilDescriptor *wd = [MTLDepthStencilDescriptor new];
            MTLStencilDescriptor *w = [MTLStencilDescriptor new];
            w.stencilCompareFunction = MTLCompareFunctionAlways;
            w.depthStencilPassOperation = MTLStencilOperationReplace;
            wd.frontFaceStencil = w;
            wd.backFaceStencil = w;
            MTLDepthStencilDescriptor *td = [MTLDepthStencilDescriptor new];
            MTLStencilDescriptor *t = [MTLStencilDescriptor new];
            t.stencilCompareFunction = MTLCompareFunctionEqual;
            td.frontFaceStencil = t;
            td.backFaceStencil = t;
            if (!stex || !ctex || !maskp || !fillp) {
                printf("stencil: FAILED to make %s\n", !stex ? "the Stencil8 texture" : !ctex ? "the color texture" : "a pipeline");
                failures++;
            } else {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
                rp.colorAttachments[0].texture = ctex;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.stencilAttachment.texture = stex;
                rp.stencilAttachment.loadAction = MTLLoadActionClear;
                rp.stencilAttachment.clearStencil = 0;
                cb = [q commandBuffer];
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:maskp];
                [re setDepthStencilState:[dev newDepthStencilStateWithDescriptor:wd]];
                [re setStencilReferenceValue:1];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re setRenderPipelineState:fillp];
                [re setDepthStencilState:[dev newDepthStencilStateWithDescriptor:td]];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                [be synchronizeResource:ctex];
                [be endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                uint8_t in[4], outp[4];
                [ctex getBytes:in bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(8, 56, 1, 1) mipmapLevel:0];
                [ctex getBytes:outp bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(56, 8, 1, 1) mipmapLevel:0];
                BOOL ok = in[2] == 255 && in[1] >= 127 && outp[0] == 0 && outp[1] == 0 && outp[2] == 0;
                printf("stencil mask: %s (inside %u %u %u, outside %u %u %u)\n", ok ? "ok" : "FAIL", in[0], in[1], in[2],
                       outp[0], outp[1], outp[2]);
                failures += !ok;
            }
        }
        printf("%s\n", failures ? "FAILED" : "PASS");
        return failures ? 1 : 0;
    }
}
