// Timing counters (stage 5c): where a WindowServer frame's time goes. Each kind sums its count, bytes and time; a
// timer logs the last 5 s whenever anything happened. On in WindowServer and with VGMTL_PERF=1; VGMTL_PERF=2 (or the
// flag file /Library/GPUBundles/VirtioGPUMetal-gputime) adds GPU timestamps around every command buffer.
#import "objects.h"
#include <stdatomic.h>

static dispatch_source_t gTimer;   // kept for the process's life
static _Atomic uint64_t gCount[VG_PERF_N], gBytes[VG_PERF_N], gNs[VG_PERF_N];
static const char *const kNames[VG_PERF_N] = {"pull copy", "pull GPU", "write-back copy",
                                              "command buffer commit->done (includes the write-back GPU copy)", "one-shot",
                                              "replaceRegion upload (deferred)", "deferred ops recorded (bytes = ops)",
                                              "framebuffer fetch copy (bytes ~ pixels x 4)", "completion: in line after commit",
                                              "completion: fence wait", "GPU time (timestamps)", "staging pool hit", "staging pool miss (new buffer)",
                                              "commitAndWaitUntilSubmitted: waited (GPU, or the write-back)",
                                              "shader translated", "shader from the disk cache",
                                              "waitUntilCompleted: blocked"};

void vg_perf(int kind, uint64_t bytes, uint64_t ns) {
    atomic_fetch_add_explicit(&gCount[kind], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&gBytes[kind], bytes, memory_order_relaxed);
    atomic_fetch_add_explicit(&gNs[kind], ns, memory_order_relaxed);
}

static void vg_perf_report(void) {
    // one line per kind: the unified log cuts long messages
    for (int k = 0; k < VG_PERF_N; k++) {
        uint64_t c = atomic_exchange(&gCount[k], 0), b = atomic_exchange(&gBytes[k], 0), t = atomic_exchange(&gNs[k], 0);
        if (c) {
            vglog("perf 5 s: %s %llu x, %.1f MB, %.1f ms total, %.2f ms each", kNames[k], c, b / 1048576.0, t / 1e6,
                  t / 1e6 / c);
        }
    }
}

static BOOL gPerfOn;
BOOL vg_perf_on(void) { return gPerfOn; }

// ---- GPU timestamps ----
static VkQueryPool gQueries;
static _Atomic uint32_t gNextPair;
enum { kPairs = 256 };

static BOOL gGpuTimeOn;   // VGMTL_PERF=2 or /Library/GPUBundles/VirtioGPUMetal-gputime: a Venus round trip per buffer

int vg_gpu_time_begin(VkCommandBuffer cb) {
    if (!gGpuTimeOn || gVk.props.limits.timestampPeriod == 0) {
        return -1;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VkQueryPoolCreateInfo qi = {VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, NULL, 0, VK_QUERY_TYPE_TIMESTAMP, 2 * kPairs};
        if (gVk.vkCreateQueryPool(gVk.device, &qi, NULL, &gQueries) != VK_SUCCESS) {
            gQueries = VK_NULL_HANDLE;
        }
    });
    if (!gQueries) {
        return -1;
    }
    int pair = (int)(atomic_fetch_add(&gNextPair, 1) % kPairs);
    gVk.vkCmdResetQueryPool(cb, gQueries, 2 * pair, 2);
    gVk.vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, gQueries, 2 * pair);
    return pair;
}

void vg_gpu_time_end(VkCommandBuffer cb, int pair) {
    if (pair >= 0) {
        gVk.vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, gQueries, 2 * pair + 1);
    }
}

void vg_gpu_time_collect(int pair) {
    uint64_t ts[2];
    if (pair < 0 || gVk.vkGetQueryPoolResults(gVk.device, gQueries, 2 * pair, 2, sizeof(ts), ts, sizeof(uint64_t),
                                              VK_QUERY_RESULT_64_BIT) != VK_SUCCESS) {
        return;
    }
    if (ts[1] > ts[0]) {
        vg_perf(VG_PERF_GPU, 0, (uint64_t)((ts[1] - ts[0]) * (double)gVk.props.limits.timestampPeriod));
    }
}

__attribute__((constructor)) static void vg_perf_start(void) {
    const char *e = getenv("VGMTL_PERF");
    if (!((e && (e[0] == '1' || e[0] == '2')) || !strcmp(getprogname(), "WindowServer"))) {
        return;
    }
    gPerfOn = YES;
    gGpuTimeOn = (e && e[0] == '2') || access("/Library/GPUBundles/VirtioGPUMetal-gputime", F_OK) == 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{ vg_perf_report(); });
    dispatch_resume(timer);
    gTimer = timer;
}
