// Command buffer order on one Metal queue: explicit enqueue reserves a place, commit order doesn't change it.
// ./mtlorder [iterations [threads]]   (VGMTL_ENABLE=1 in the VM; runs on a Mac too, as the reference)
//
// Each case prints PASS, FAIL or INFO (behavior recorded, not judged) and the exit status counts the failures:
//   control      A then B committed in order: B's 0x22 is last
//   reverse      enqueue A, enqueue B, commit B, commit A: B still runs after A
//   implicit     enqueue A, commit B (enqueued at commit, after A), commit A
//   held         B committed behind an uncommitted A waits for A; another queue's work goes on meanwhile
//   empty        an earlier reservation with no work in it releases the one after it
//   handler      A's completed handler waits for B, later on the same queue (INFO: Apple's driver never returns)
//   order        16 enqueued in order, committed shuffled: they complete, and their handlers run, in enqueue order
//   dropped      an enqueued command buffer released without a commit (INFO: what happens to the one after it)
//   parallel     threads encode and commit one queue's reserved command buffers at once, each also uploading a new
//                texture through replaceRegion and copying it out: the last reservation's fill wins, every upload lands
//   queues       the same uploads, each thread on its own queue: no submit overtakes another's deferred upload
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdatomic.h>

static int gFailures;
static const NSUInteger kLen = 4096;

static void report(const char *name, BOOL ok, NSString *detail) {
    printf("%-9s %s  %s\n", ok ? "PASS" : "FAIL", name, detail.UTF8String);
    if (!ok) {
        gFailures++;
    }
}
static void info(const char *name, NSString *detail) { printf("%-9s %s  %s\n", "INFO", name, detail.UTF8String); }

// A semaphore signaled by the completed handler: added before commit, waited for with a timeout.
static dispatch_semaphore_t watch(id<MTLCommandBuffer> cb) {
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        dispatch_semaphore_signal(s);
    }];
    return s;
}
static BOOL waitFor(dispatch_semaphore_t s, double seconds) {
    return dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
}

static id<MTLCommandBuffer> filler(id<MTLCommandQueue> q, id<MTLBuffer> b, uint8_t value) {
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e fillBuffer:b range:NSMakeRange(0, b.length) value:value];
    [e endEncoding];
    return cb;
}

// How many bytes of b aren't value (and the first one that isn't).
static NSUInteger mismatches(id<MTLBuffer> b, uint8_t value, int *first) {
    const uint8_t *p = b.contents;
    NSUInteger bad = 0;
    *first = -1;
    for (NSUInteger i = 0; i < b.length; i++) {
        if (p[i] != value) {
            if (*first < 0) {
                *first = p[i];
            }
            bad++;
        }
    }
    return bad;
}
static NSString *contents(id<MTLBuffer> b, uint8_t want) {
    int first;
    NSUInteger bad = mismatches(b, want, &first);
    return bad ? [NSString stringWithFormat:@"%lu of %lu bytes not 0x%02x (first 0x%02x)", (unsigned long)bad,
                                            (unsigned long)b.length, want, first]
               : [NSString stringWithFormat:@"all %lu bytes 0x%02x", (unsigned long)b.length, want];
}
static void clear(id<MTLBuffer> b) { memset(b.contents, 0, b.length); }

static const char *statusName(MTLCommandBufferStatus s) {
    switch (s) {
    case MTLCommandBufferStatusNotEnqueued: return "NotEnqueued";
    case MTLCommandBufferStatusEnqueued: return "Enqueued";
    case MTLCommandBufferStatusCommitted: return "Committed";
    case MTLCommandBufferStatusScheduled: return "Scheduled";
    case MTLCommandBufferStatusCompleted: return "Completed";
    case MTLCommandBufferStatusError: return "Error";
    }
    return "?";
}

// One thread's work in the parallel cases: a new texture filled by replaceRegion (a deferred upload in Venera), copied
// into out; plus, when shared is set, a fill of the shared buffer with value.
static void encodeUpload(id<MTLDevice> dev, id<MTLCommandBuffer> cb, id<MTLBuffer> out, uint32_t pattern,
                         id<MTLBuffer> shared, uint8_t value) {
    const NSUInteger w = 64, h = 16;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w height:h mipmapped:NO];
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint32_t px[64 * 16];
    for (NSUInteger i = 0; i < w * h; i++) {
        px[i] = pattern ^ (uint32_t)i;
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4];
    id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    if (shared) {
        [e fillBuffer:shared range:NSMakeRange(0, shared.length) value:value];
    }
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:out destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
    [e endEncoding];
}
static BOOL uploadLanded(id<MTLBuffer> out, uint32_t pattern) {
    const uint32_t *p = out.contents;
    for (NSUInteger i = 0; i < 64 * 16; i++) {
        if (p[i] != (pattern ^ (uint32_t)i)) {
            return NO;
        }
    }
    return YES;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const int iterations = argc > 1 ? atoi(argv[1]) : 100;
        const int threads = argc > 2 ? atoi(argv[2]) : 8;
        if (iterations < 1 || threads < 2 || threads > 64) {
            fprintf(stderr, "usage: mtlorder [iterations>0 [threads 2-64]]\n");
            return 2;
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            fprintf(stderr, "no Metal device\n");
            return 2;
        }
        printf("device: %s\n", dev.name.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> b = [dev newBufferWithLength:kLen options:MTLResourceStorageModeShared];

        {   // control
            clear(b);
            id<MTLCommandBuffer> A = filler(q, b, 0x11), B = filler(q, b, 0x22);
            dispatch_semaphore_t sb = watch(B);
            [A commit];
            [B commit];
            BOOL done = waitFor(sb, 5);
            int first;
            report("control", done && !mismatches(b, 0x22, &first), done ? contents(b, 0x22) : @"B never completed");
        }
        {   // reverse
            clear(b);
            id<MTLCommandBuffer> A = filler(q, b, 0x11), B = filler(q, b, 0x22);
            dispatch_semaphore_t sa = watch(A), sb = watch(B);
            [A enqueue];
            [B enqueue];
            [B commit];
            [A commit];
            BOOL done = waitFor(sa, 5) && waitFor(sb, 5);
            int first;
            report("reverse", done && !mismatches(b, 0x22, &first), done ? contents(b, 0x22) : @"never completed");
        }
        {   // implicit
            clear(b);
            id<MTLCommandBuffer> A = filler(q, b, 0x11), B = filler(q, b, 0x22);
            dispatch_semaphore_t sa = watch(A), sb = watch(B);
            [A enqueue];
            [B commit];
            [A commit];
            BOOL done = waitFor(sa, 5) && waitFor(sb, 5);
            int first;
            report("implicit", done && !mismatches(b, 0x22, &first), done ? contents(b, 0x22) : @"never completed");
        }
        {   // held: B waits for A; another queue isn't held up
            clear(b);
            id<MTLCommandQueue> q2 = [dev newCommandQueue];
            id<MTLBuffer> other = [dev newBufferWithLength:kLen options:MTLResourceStorageModeShared];
            clear(other);
            id<MTLCommandBuffer> A = filler(q, b, 0x11), B = filler(q, b, 0x22);
            dispatch_semaphore_t sa = watch(A), sb = watch(B);
            [A enqueue];
            [B enqueue];
            [B commit];
            id<MTLCommandBuffer> C = filler(q2, other, 0x33);
            dispatch_semaphore_t sc = watch(C);
            [C commit];
            BOOL otherDone = waitFor(sc, 3);
            BOOL bEarly = waitFor(sb, 0.3);
            MTLCommandBufferStatus held = B.status;
            [A commit];
            BOOL done = waitFor(sa, 5) && (bEarly || waitFor(sb, 5));
            int first;
            BOOL ok = otherDone && !bEarly && done && !mismatches(b, 0x22, &first) && !mismatches(other, 0x33, &first);
            report("held", ok,
                   [NSString stringWithFormat:@"other queue %s; B before A's commit: %s (%s); after: %@",
                                              otherDone ? "completed" : "STALLED", bEarly ? "COMPLETED" : "waiting",
                                              statusName(held), done ? contents(b, 0x22) : @"never completed"]);
        }
        {   // empty: a reservation with nothing in it
            clear(b);
            id<MTLCommandBuffer> A = [q commandBuffer], B = filler(q, b, 0x22);
            dispatch_semaphore_t sa = watch(A), sb = watch(B);
            [A enqueue];
            [B enqueue];
            [B commit];
            [A commit];
            BOOL done = waitFor(sa, 5) && waitFor(sb, 5);
            int first;
            report("empty", done && !mismatches(b, 0x22, &first) && A.status == MTLCommandBufferStatusCompleted,
                   done ? [NSString stringWithFormat:@"A %s, %@", statusName(A.status), contents(b, 0x22)]
                        : @"never completed");
        }
        {   // handler: A's completed handler waits for B (on its own queue: on Apple's driver it never returns, and
            // the queue's handlers stay blocked behind it)
            clear(b);
            id<MTLCommandQueue> qh = [dev newCommandQueue];
            id<MTLCommandBuffer> A = filler(qh, b, 0x11), B = filler(qh, b, 0x22);
            dispatch_semaphore_t handled = dispatch_semaphore_create(0);
            __block MTLCommandBufferStatus seen = 0;
            [A addCompletedHandler:^(id<MTLCommandBuffer> c) {
                [B waitUntilCompleted];
                seen = B.status;
                dispatch_semaphore_signal(handled);
            }];
            [A enqueue];
            [B enqueue];
            [A commit];
            [B commit];
            BOOL done = waitFor(handled, 3);
            info("handler", done ? [NSString stringWithFormat:@"B %s inside A's handler", statusName(seen)]
                                 : @"A's handler still waiting for B after 3 s (handlers run one at a time per queue)");
        }
        {   // order: 16 reserved in order, committed shuffled
            clear(b);
            enum { N = 16 };
            NSMutableArray<id<MTLCommandBuffer>> *cbs = [NSMutableArray array];
            int *completedOrder = calloc(N, sizeof(int));
            __block int nCompleted = 0;
            __block BOOL earlierDone = YES;
            NSLock *lock = [NSLock new];
            dispatch_group_t g = dispatch_group_create();
            for (int i = 0; i < N; i++) {
                id<MTLCommandBuffer> cb = filler(q, b, (uint8_t)(0x40 + i));
                dispatch_group_enter(g);
                [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
                    [lock lock];
                    completedOrder[nCompleted++] = i;
                    for (int j = 0; j < i; j++) {
                        MTLCommandBufferStatus s = cbs[j].status;
                        if (s != MTLCommandBufferStatusCompleted && s != MTLCommandBufferStatusError) {
                            earlierDone = NO;
                        }
                    }
                    [lock unlock];
                    dispatch_group_leave(g);
                }];
                [cbs addObject:cb];
            }
            for (id<MTLCommandBuffer> cb in cbs) {
                [cb enqueue];
            }
            int perm[N];
            for (int i = 0; i < N; i++) {
                perm[i] = i;
            }
            srandom(42);
            for (int i = N - 1; i > 0; i--) {
                int j = (int)(random() % (i + 1)), t = perm[i];
                perm[i] = perm[j], perm[j] = t;
            }
            for (int i = 0; i < N; i++) {
                [cbs[perm[i]] commit];
            }
            BOOL done = dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
            BOOL inOrder = done;
            NSMutableString *seq = [NSMutableString string];
            for (int i = 0; i < nCompleted; i++) {
                [seq appendFormat:@"%d%s", completedOrder[i], i + 1 < nCompleted ? "," : ""];
                inOrder = inOrder && completedOrder[i] == i;
            }
            int first;
            report("order", inOrder && earlierDone && !mismatches(b, 0x40 + N - 1, &first),
                   [NSString stringWithFormat:@"handlers %@%s; %@", seq, earlierDone ? "" : " (an earlier one not done)",
                                              contents(b, 0x40 + N - 1)]);
            if (done) {
                free(completedOrder);   // a handler still to run would write it: kept when they timed out
            }
        }
        {   // dropped: an enqueued command buffer released without a commit (recorded, not judged)
            clear(b);
            id<MTLCommandQueue> q3 = [dev newCommandQueue];
            @autoreleasepool {
                id<MTLCommandBuffer> A = filler(q3, b, 0x11);
                [A enqueue];
                A = nil;
            }
            id<MTLCommandBuffer> B = filler(q3, b, 0x22);
            dispatch_semaphore_t sb = watch(B);
            [B commit];
            BOOL done = waitFor(sb, 2);
            info("dropped", done ? [NSString stringWithFormat:@"B completed: %@", contents(b, 0x22)]
                                 : @"B still waiting after 2 s (the queue holds the dropped reservation's place)");
        }
        {   // parallel: one queue, reserved in order, encoded and committed from threads at once
            int bad = 0, timeouts = 0, lost = 0;
            for (int it = 0; it < iterations; it++) {
                clear(b);
                NSMutableArray<id<MTLCommandBuffer>> *cbs = [NSMutableArray array];
                NSMutableArray<id<MTLBuffer>> *outs = [NSMutableArray array];
                for (int i = 0; i < threads; i++) {
                    [cbs addObject:[q commandBuffer]];
                    [outs addObject:[dev newBufferWithLength:64 * 16 * 4 options:MTLResourceStorageModeShared]];
                    [cbs[i] enqueue];
                }
                dispatch_group_t g = dispatch_group_create();
                for (int i = 0; i < threads; i++) {
                    dispatch_group_enter(g);
                    [cbs[i] addCompletedHandler:^(id<MTLCommandBuffer> c) {
                        dispatch_group_leave(g);
                    }];
                }
                const int iteration = it;
                dispatch_apply(threads, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
                    @autoreleasepool {
                        encodeUpload(dev, cbs[i], outs[i], 0x01000000u * (uint32_t)(i + 1) + (uint32_t)iteration, b,
                                     (uint8_t)(i + 1));
                        usleep((useconds_t)(random() % 200));
                        [cbs[i] commit];
                    }
                });
                if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
                    timeouts++;
                    break;
                }
                int first;
                bad += mismatches(b, (uint8_t)threads, &first) != 0;
                for (int i = 0; i < threads; i++) {
                    lost += !uploadLanded(outs[i], 0x01000000u * (uint32_t)(i + 1) + (uint32_t)it);
                }
            }
            report("parallel", !bad && !timeouts && !lost,
                   [NSString stringWithFormat:@"%d iterations x %d threads: %d with the wrong last fill, %d uploads "
                                              @"missing, %d timeouts",
                                              iterations, threads, bad, lost, timeouts]);
        }
        {   // queues: each thread on its own queue, uploads and submits racing
            NSMutableArray<id<MTLCommandQueue>> *qs = [NSMutableArray array];
            for (int i = 0; i < threads; i++) {
                [qs addObject:[dev newCommandQueue]];
            }
            __block atomic_int lost = 0, timeouts = 0;
            dispatch_apply(threads, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
                id<MTLBuffer> out = [dev newBufferWithLength:64 * 16 * 4 options:MTLResourceStorageModeShared];
                for (int it = 0; it < iterations; it++) {
                    @autoreleasepool {
                        memset(out.contents, 0, out.length);
                        id<MTLCommandBuffer> cb = [qs[i] commandBuffer];
                        uint32_t pattern = 0x01000000u * (uint32_t)(i + 1) + (uint32_t)it;
                        encodeUpload(dev, cb, out, pattern, nil, 0);
                        dispatch_semaphore_t s = watch(cb);
                        [cb commit];
                        if (!waitFor(s, 10)) {
                            atomic_fetch_add(&timeouts, 1);
                            return;
                        }
                        if (!uploadLanded(out, pattern)) {
                            atomic_fetch_add(&lost, 1);
                        }
                    }
                }
            });
            report("queues", !lost && !timeouts,
                   [NSString stringWithFormat:@"%d threads x %d iterations: %d uploads missing, %d timeouts", threads,
                                              iterations, (int)lost, (int)timeouts]);
        }
        printf("%d failure(s)\n", gFailures);
        return gFailures ? 1 : 0;
    }
}
