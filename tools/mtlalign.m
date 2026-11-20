// mtlalign: compute buffers bound at offsets Metal allows and the host's Vulkan doesn't (a multiple of the data's size,
// not of minStorageBufferOffsetAlignment: the Memoji's blend-shape kernels read 16-bit indices at offsets of 2 mod 4).
//   VGMTL_ENABLE=1 ./mtlalign
// A kernel reads ushorts from buffer(0) bound at offset 6 and writes them, plus 1000, as ushorts to buffer(1) bound at
// offset 10; buffer(1) is read-write, so its bytes before offset 10 must be left as they were. "mtlalign: PASS" last.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void add(device const ushort *in [[buffer(0)]], device ushort *out [[buffer(1)]],\n"
     "                uint i [[thread_position_in_grid]]) {\n"
     "    if (i < 64) out[i] = in[i] + 1000;\n"
     "}\n";

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = dev ? [dev newLibraryWithSource:kSource options:nil error:&err] : nil;
        id<MTLComputePipelineState> ps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"add"]
                                                                                 error:&err] : nil;
        if (!ps) {
            printf("setup: %s\nmtlalign: FAIL (1)\n", dev ? err.localizedDescription.UTF8String : "no Metal device");
            return 1;
        }
        printf("device: %s\n", dev.name.UTF8String);
        id<MTLBuffer> in = [dev newBufferWithLength:512 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:512 options:MTLResourceStorageModeShared];
        uint16_t *pi = in.contents, *po = out.contents;
        for (int i = 0; i < 256; i++) {
            pi[i] = (uint16_t)i;
            po[i] = 0xbeef;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:6 atIndex:0];
        [ce setBuffer:out offset:10 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        int bad = 0;
        for (int i = 0; i < 64; i++) {
            if (po[5 + i] != 3 + i + 1000) {   // out[i] is ushort 5 + i of the buffer, in[i] ushort 3 + i
                if (bad++ < 4) {
                    printf("     out[%d] = %u, want %d\n", i, po[5 + i], 3 + i + 1000);
                }
            }
        }
        BOOL before = po[0] == 0xbeef && po[4] == 0xbeef, after = po[69] == 0xbeef;
        printf("%s 64 ushorts read at offset 6 and written at offset 10 (%d wrong)\n", bad ? "FAIL" : "ok  ", bad);
        printf("%s the bytes around them untouched\n", before && after ? "ok  " : "FAIL");
        int fails = (bad != 0) + !(before && after);
        printf(fails ? "mtlalign: FAIL (%d)\n" : "mtlalign: PASS\n", fails);
        return fails != 0;
    }
}
