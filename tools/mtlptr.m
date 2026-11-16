// mtlptr (5d): device-pointer patterns a translator can get wrong, each a kernel checked against the CPU. RenderBox's
// path coverage (a binary search moving a device pointer, then the element before it) read zeros on this device.
//   mtlptr            (needs the process allow-listed, e.g. VGMTL_ENABLE=1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct Seg { int count; float v; };\n"
     // a: an index below the pointer's base (the element before)
     "kernel void a(device const Seg *s [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
     "    device const Seg *p = s + 1 + (i & 7); o[i] = (p - 1)->v; }\n"
     // b: a select between two device pointers
     "kernel void b(device const Seg *s [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
     "    device const Seg *p = (i & 1) ? s + 3 : s + 5; o[i] = p->v; }\n"
     // c: the binary search with an integer index
     "kernel void c(device const Seg *s [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
     "    int base = 1, n = 16, idx = int(i);\n"
     "    while (n > 1) { int h = n >> 1; bool after = s[base + h].count > idx; n = after ? h : n - h; base = after ? base : base + h; }\n"
     "    o[i] = s[base].v; }\n"
     // d: the binary search moving a pointer (a loop phi of a device pointer)
     "kernel void d(device const Seg *s [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
     "    device const Seg *p = s + 1; int n = 16, idx = int(i);\n"
     "    while (n > 1) { int h = n >> 1; device const Seg *m = p + h; bool after = m->count > idx; n = after ? h : n - h;\n"
     "                    p = after ? p : m; }\n"
     "    o[i] = p->v; }\n"
     // e: d, then the element before
     "kernel void e(device const Seg *s [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
     "    device const Seg *p = s + 1; int n = 16, idx = int(i);\n"
     "    while (n > 1) { int h = n >> 1; device const Seg *m = p + h; bool after = m->count > idx; n = after ? h : n - h;\n"
     "                    p = after ? p : m; }\n"
     "    o[i] = (p - 1)->v; }\n"
     // f: a pointer plus a computed offset, no loop
     "kernel void f(device const Seg *s [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
     "    device const Seg *p = s + 1; p += (i % 9); o[i] = p->v; }\n";

typedef struct {
    int count;
    float v;
} Seg;

static float cpu(char k, const Seg *s, int i) {
    const Seg *p;
    int n = 16, h, after, base = 1;
    switch (k) {
    case 'a': p = s + 1 + (i & 7); return (p - 1)->v;
    case 'b': p = (i & 1) ? s + 3 : s + 5; return p->v;
    case 'c':
        while (n > 1) { h = n >> 1; after = s[base + h].count > i; n = after ? h : n - h; base = after ? base : base + h; }
        return s[base].v;
    case 'd':
    case 'e':
        p = s + 1;
        while (n > 1) { h = n >> 1; const Seg *m = p + h; after = m->count > i; n = after ? h : n - h; p = after ? p : m; }
        return k == 'd' ? p->v : (p - 1)->v;
    default: p = s + 1 + (i % 9); return p->v;
    }
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("device: %s\n", dev.name.UTF8String);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:[MTLCompileOptions new] error:&err];
        if (!lib) {
            printf("library: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        Seg segs[40];
        for (int k = 0; k < 40; k++) {
            segs[k].count = k * 4;        // running counts: element k starts at 4k
            segs[k].v = 100.0f + k;
        }
        id<MTLBuffer> sb = [dev newBufferWithBytes:segs length:sizeof(segs) options:MTLResourceStorageModeShared];
        id<MTLBuffer> ob = [dev newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        int failures = 0;
        for (const char *k = "abcdef"; *k; k++) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(((char[]){*k, 0}))]
                                                                                error:&err];
            if (!ps) {
                printf("%c: pipeline FAILED: %s\n", *k, err.localizedDescription.UTF8String);
                failures++;
                continue;
            }
            memset(ob.contents, 0, 64 * 4);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setBuffer:sb offset:0 atIndex:0];
            [ce setBuffer:ob offset:0 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(60, 1, 1) threadsPerThreadgroup:MTLSizeMake(60, 1, 1)];
            [ce endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            const float *o = ob.contents;
            int bad = 0, first = -1;
            for (int i = 0; i < 60; i++) {
                if (o[i] != cpu(*k, segs, i)) {
                    bad++;
                    if (first < 0) {
                        first = i;
                    }
                }
            }
            failures += bad != 0;
            printf("%c: %s", *k, bad ? "FAIL" : "ok  ");
            if (bad) {
                printf(" (%d of 60 wrong; [%d] gpu %g cpu %g)", bad, first, o[first], cpu(*k, segs, first));
            }
            printf("\n");
        }
        printf("%s\n", failures ? "FAILED" : "PASS");
        return failures ? 1 : 0;
    }
}
