// mtlcube: Metal cube textures, plain Metal API (the Memoji's lighting, AvatarKit/VFX, uses them). Compiles its shaders at
// run time (newLibraryWithSource). Runs the same on a real Mac (the reference) and in the VM:
//   VGMTL_ENABLE=1 ./mtlcube        (the environment allows a plain process the VM's device)
// Checks, one line each, then "mtlcube: PASS" or "mtlcube: FAIL (n)" last:
//   A) a 4x4 RGBA8 cube: arrayLength 1; each face filled by replaceRegion:...slice: with its own color, read back
//   B) a kernel samples the cube along +X -X +Y -Y +Z -Z: each direction must see its face's color
//   C) a kernel writes face 4 (texturecube<float, access::write>), read back with getBytes:...slice:
//   D) a render pass clears face 2 (a cube's slice as the color attachment), read back
//   E) a 2D-array view of the cube's six faces reads face 5 at slice 5
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void sample_cube(texturecube<float> cube [[texture(0)]], sampler s [[sampler(0)]],\n"
     "                        device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
     "    float3 d[6] = { float3(1,0,0), float3(-1,0,0), float3(0,1,0), float3(0,-1,0), float3(0,0,1), float3(0,0,-1) };\n"
     "    if (i < 6) out[i] = cube.sample(s, d[i]);\n"
     "}\n"
     "kernel void write_face(texturecube<float, access::write> cube [[texture(0)]], uint2 p [[thread_position_in_grid]]) {\n"
     "    if (p.x < 4 && p.y < 4) cube.write(float4(0.25, 0.5, 0.75, 1.0), p, 4);\n"
     "}\n";

static int fails;
static void check(BOOL ok, NSString *what) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
    fails += !ok;
}
static BOOL near(uint32_t px, uint32_t want) {   // RGBA8 little-endian words, each channel within 2
    for (int c = 0; c < 4; c++) {
        int a = (px >> (8 * c)) & 0xff, b = (want >> (8 * c)) & 0xff;
        if (abs(a - b) > 2) {
            return NO;
        }
    }
    return YES;
}
static uint32_t faceColor(int f) {   // R, G, B, A bytes: face f is (40f+20, 200-30f, f odd ? 255 : 0, 255)
    return (uint32_t)(40 * f + 20) | (uint32_t)(200 - 30 * f) << 8 | (uint32_t)(f & 1 ? 255 : 0) << 16 | 0xffu << 24;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("mtlcube: no Metal device\nmtlcube: FAIL (1)\n");
            return 1;
        }
        printf("device: %s\n", dev.name.UTF8String);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:nil error:&err];
        if (!lib) {
            printf("library: %s\nmtlcube: FAIL (1)\n", err.localizedDescription.UTF8String);
            return 1;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                         size:4
                                                                                    mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget |
                   MTLTextureUsagePixelFormatView;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> cube = [dev newTextureWithDescriptor:td];
        check(cube != nil, @"A: newTextureWithDescriptor: a 4x4 RGBA8 cube");
        if (!cube) {
            printf("mtlcube: FAIL (%d)\n", fails);
            return 1;
        }
        check(cube.textureType == MTLTextureTypeCube && cube.arrayLength == 1,
              [NSString stringWithFormat:@"A: textureType %lu (5), arrayLength %lu (1)", (unsigned long)cube.textureType,
                                         (unsigned long)cube.arrayLength]);
        uint32_t px[16];
        for (int f = 0; f < 6; f++) {
            for (int i = 0; i < 16; i++) {
                px[i] = faceColor(f);
            }
            [cube replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:f withBytes:px bytesPerRow:16 bytesPerImage:64];
        }
        BOOL same = YES;
        for (int f = 0; f < 6; f++) {
            memset(px, 0, sizeof(px));
            [cube getBytes:px bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:f];
            same = same && near(px[0], faceColor(f)) && near(px[15], faceColor(f));
        }
        check(same, @"A: each face reads back its own color");

        // B: sampling
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"sample_cube"]
                                                                            error:&err];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
        id<MTLBuffer> out = [dev newBufferWithLength:6 * 16 options:MTLResourceStorageModeShared];
        memset(out.contents, 0, 96);
        check(ps != nil, [NSString stringWithFormat:@"B: sample_cube pipeline %s", ps ? "" : err.localizedDescription.UTF8String]);
        if (ps) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setTexture:cube atIndex:0];
            [ce setSamplerState:smp atIndex:0];
            [ce setBuffer:out offset:0 atIndex:0];
            [ce dispatchThreads:MTLSizeMake(6, 1, 1) threadsPerThreadgroup:MTLSizeMake(6, 1, 1)];
            [ce endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            const float *o = out.contents;
            int good = 0;
            for (int f = 0; f < 6; f++) {
                uint32_t want = faceColor(f);
                BOOL ok = YES;
                for (int c = 0; c < 4; c++) {
                    ok = ok && fabsf(o[4 * f + c] - ((want >> (8 * c)) & 0xff) / 255.0f) < 0.02f;
                }
                good += ok;
                if (!ok) {
                    printf("     direction %d: %.3f %.3f %.3f %.3f\n", f, o[4 * f], o[4 * f + 1], o[4 * f + 2], o[4 * f + 3]);
                }
            }
            check(good == 6, [NSString stringWithFormat:@"B: %d of 6 directions sample their face", good]);
        }

        // C: a kernel writes face 4
        id<MTLComputePipelineState> pw = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"write_face"]
                                                                            error:&err];
        check(pw != nil, [NSString stringWithFormat:@"C: write_face pipeline %s", pw ? "" : err.localizedDescription.UTF8String]);
        if (pw) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:pw];
            [ce setTexture:cube atIndex:0];
            [ce dispatchThreads:MTLSizeMake(4, 4, 1) threadsPerThreadgroup:MTLSizeMake(4, 4, 1)];
            [ce endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            memset(px, 0, sizeof(px));
            [cube getBytes:px bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:4];
            uint32_t want = 64 | 128 << 8 | 191 << 16 | 0xffu << 24;
            uint32_t f3[16];
            [cube getBytes:f3 bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:3];
            check(near(px[0], want) && near(px[15], want) && near(f3[0], faceColor(3)),
                  [NSString stringWithFormat:@"C: face 4 written (0x%08x, want 0x%08x), face 3 untouched (0x%08x)", px[0],
                                             want, f3[0]]);
        }

        // D: render into face 2
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = cube;
        rp.colorAttachments[0].slice = 2;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1);
        {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            memset(px, 0, sizeof(px));
            [cube getBytes:px bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:2];
            uint32_t f1[16];
            [cube getBytes:f1 bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:1];
            check(cb.status == MTLCommandBufferStatusCompleted && near(px[5], 0xffff00ff) && near(f1[5], faceColor(1)),
                  [NSString stringWithFormat:@"D: render pass on slice 2 (status %lu, 0x%08x), face 1 untouched (0x%08x)",
                                             (unsigned long)cb.status, px[5], f1[5]]);
        }

        // E: a 2D-array view of the six faces
        id<MTLTexture> arr = [cube newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                     textureType:MTLTextureType2DArray
                                                          levels:NSMakeRange(0, 1)
                                                          slices:NSMakeRange(0, 6)];
        if (arr) {
            memset(px, 0, sizeof(px));
            [arr getBytes:px bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:5];
        }
        check(arr && arr.arrayLength == 6 && near(px[0], faceColor(5)),
              [NSString stringWithFormat:@"E: 2D-array view: arrayLength %lu (6), slice 5 0x%08x", (unsigned long)arr.arrayLength,
                                         px[0]]);
        printf(fails ? "mtlcube: FAIL (%d)\n" : "mtlcube: PASS\n", fails);
        return fails != 0;
    }
}
