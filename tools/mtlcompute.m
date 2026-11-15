// mtlcompute: stage 4b's checkpoint. Plain Metal API, nothing VirtioGPU-specific: load compute.metallib (built on the
// Mac from tools/shaders/compute.metal), run kernels and blits, check every result on the CPU, time each step.
//   mtlcompute [compute.metallib]          (run after `acceltest arm`; VGMTL_LOG=1 echoes the plugin's log)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <stdatomic.h>

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static int failures;

#define CHECK(cond, ...)                                                                                            \
    do {                                                                                                            \
        if (!(cond)) {                                                                                              \
            printf("  FAIL: " __VA_ARGS__);                                                                         \
            printf("\n");                                                                                           \
            failures++;                                                                                             \
        }                                                                                                           \
    } while (0)

static BOOL run(id<MTLCommandBuffer> cb, const char *what, uint64_t t0) {
    [cb commit];
    [cb waitUntilCompleted];
    printf("  %-44s %8.2f ms  status %lu%s%s\n", what, (now_ns() - t0) / 1e6, (unsigned long)cb.status,
           cb.error ? "  error: " : "", cb.error ? cb.error.localizedDescription.UTF8String : "");
    return cb.status == MTLCommandBufferStatusCompleted;
}

static void vadd(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLComputePipelineState> p, NSUInteger n, NSUInteger tg) {
    id<MTLBuffer> a = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> b = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> c = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    float *pa = a.contents, *pb = b.contents, *pc = c.contents;
    for (NSUInteger i = 0; i < n; i++) {
        pa[i] = (float)i;
        pb[i] = 0.5f * (float)(i % 1000);
        pc[i] = -1.0f;
    }
    uint64_t t0 = now_ns();
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:p];
    [e setBuffer:a offset:0 atIndex:0];
    [e setBuffer:b offset:0 atIndex:1];
    [e setBuffer:c offset:0 atIndex:2];
    [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
    [e endEncoding];
    char what[96];
    snprintf(what, sizeof(what), "vadd %lu floats, threadgroup %lu", (unsigned long)n, (unsigned long)tg);
    if (!run(cb, what, t0)) {
        failures++;
        return;
    }
    NSUInteger bad = 0, first = NSNotFound;
    for (NSUInteger i = 0; i < n; i++) {
        if (pc[i] != pa[i] + pb[i]) {
            if (first == NSNotFound) {
                first = i;
            }
            bad++;
        }
    }
    CHECK(!bad, "%lu of %lu wrong, first at %lu: %f + %f != %f", (unsigned long)bad, (unsigned long)n,
          (unsigned long)first, first < n ? pa[first] : 0, first < n ? pb[first] : 0, first < n ? pc[first] : 0);
    if (!bad) {
        printf("    all %lu results right\n", (unsigned long)n);
    }
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
        NSString *path = argc > 1 ? @(argv[1]) : @"compute.metallib";
        NSError *err = nil;
        uint64_t t0 = now_ns();
        id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
        printf("library %s: %s (%.1f ms) functions: %s\n", path.UTF8String, lib ? "loaded" : "FAILED",
               (now_ns() - t0) / 1e6, [[lib.functionNames componentsJoinedByString:@", "] UTF8String]);
        if (!lib) {
            printf("  %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];

        // 1. Pipelines.
        t0 = now_ns();
        id<MTLComputePipelineState> pAdd = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"vadd"]
                                                                              error:&err];
        id<MTLComputePipelineState> pSum =
            [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"reduce_sum"] error:&err];
        printf("pipelines: vadd %s, reduce_sum %s (%.1f ms)%s%s\n", pAdd ? "ok" : "FAILED", pSum ? "ok" : "FAILED",
               (now_ns() - t0) / 1e6, err ? "  " : "", err ? err.localizedDescription.UTF8String : "");
        if (!pAdd || !pSum) {
            return 1;
        }
        printf("  maxTotalThreadsPerThreadgroup %lu, threadExecutionWidth %lu\n",
               (unsigned long)pAdd.maxTotalThreadsPerThreadgroup, (unsigned long)pAdd.threadExecutionWidth);

        // 2. Vector add: whole threadgroups (16M), then a grid with a partial last threadgroup.
        printf("compute:\n");
        vadd(dev, q, pAdd, 1u << 24, 256);
        vadd(dev, q, pAdd, 1u << 24, 256);   // again, pipeline cached
        vadd(dev, q, pAdd, 1000003, 64);

        // 3. Reduction with threadgroup memory and an atomic, dispatched as threadgroups; count from setBytes.
        {
            const uint32_t n = 1u << 24, tg = 256;
            id<MTLBuffer> in = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> out = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
            uint32_t *pi = in.contents;
            uint64_t want = 0;
            for (uint32_t i = 0; i < n; i++) {
                pi[i] = i % 7;
                want += i % 7;
            }
            *(uint32_t *)out.contents = 0;
            t0 = now_ns();
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:pSum];
            [e setBuffer:in offset:0 atIndex:0];
            [e setBuffer:out offset:0 atIndex:1];
            [e setBytes:&n length:4 atIndex:2];
            [e setThreadgroupMemoryLength:tg * 4 atIndex:0];
            [e dispatchThreadgroups:MTLSizeMake(n / tg, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
            [e endEncoding];
            if (run(cb, "reduce_sum 16M uints (threadgroup memory)", t0)) {
                uint32_t got = *(uint32_t *)out.contents;
                CHECK(got == (uint32_t)want, "sum %u, want %llu", got, (unsigned long long)want);
                if (got == (uint32_t)want) {
                    printf("    sum %u right\n", got);
                }
            } else {
                failures++;
            }
        }

        // 4. Blits: fill 64 MB, copy it, check both; and a completion handler.
        printf("blit:\n");
        {
            const NSUInteger n = 64u << 20;
            id<MTLBuffer> a = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
            id<MTLBuffer> b = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
            memset(b.contents, 0, n);
            __block _Atomic int handled = 0;
            t0 = now_ns();
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
            [e fillBuffer:a range:NSMakeRange(0, n) value:0xa5];
            [e copyFromBuffer:a sourceOffset:4096 toBuffer:b destinationOffset:0 size:n - 4096];
            [e endEncoding];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { atomic_store(&handled, 1); }];
            if (run(cb, "fill 64 MB + copy 64 MB", t0)) {
                const uint8_t *pa = a.contents, *pb = b.contents;
                NSUInteger bad = 0;
                for (NSUInteger i = 0; i < n; i++) {
                    bad += pa[i] != 0xa5;
                    bad += pb[i] != (i < n - 4096 ? 0xa5 : 0);
                }
                CHECK(!bad, "%lu bytes wrong", (unsigned long)bad);
                CHECK(atomic_load(&handled), "completion handler didn't run");
                if (!bad) {
                    printf("    all %lu MB right, completion handler %s\n", (unsigned long)(n >> 20),
                           atomic_load(&handled) ? "ran" : "MISSING");
                }
            } else {
                failures++;
            }
        }
        printf("%s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
        return failures ? 1 : 0;
    }
}
