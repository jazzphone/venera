// Timing counters (stage 5c): where a WindowServer frame's time goes. Each kind sums its count, bytes and time; a
// timer logs the last 5 s whenever anything happened. Off unless asked for (0.1.2: on by default in WindowServer it
// wrote 12 lines every 5 s, ~20 MB a day): VGMTL_PERF=1, or the flag file /Library/GPUBundles/VirtioGPUMetal-perf,
// which WindowServer checks at each tick, so it turns on and off without a restart. VGMTL_PERF=2 (or the flag file
// /Library/GPUBundles/VirtioGPUMetal-gputime) adds GPU timestamps around every command buffer.
#import "objects.h"
#include <stdatomic.h>

static dispatch_source_t gTimer;   // kept for the process's life
static _Atomic uint64_t gCount[VG_PERF_N], gBytes[VG_PERF_N], gNs[VG_PERF_N];
static const char *const kNames[VG_PERF_N] = {"pull copy", "pull GPU", "write-back copy",
                                              "command buffer commit->done (includes the write-back GPU copy)", "one-shot",
                                              "replaceRegion upload (deferred)", "deferred ops recorded (bytes = ops)",
                                              "framebuffer fetch copy (bytes ~ pixels x 4)", "completion: commit -> first fence check",
                                              "completion: fence wait", "GPU time (timestamps)", "staging pool hit", "staging pool miss (new buffer)",
                                              "commitAndWaitUntilSubmitted: waited (GPU, or the write-back)",
                                              "shader translated", "shader from the disk cache",
                                              "waitUntilCompleted: blocked",
                                              "latency: commit -> GPU starts it", "latency: GPU done -> guest sees it",
                                              "descriptor set written", "descriptor set reused",
                                              "draw state commands skipped",
                                              "commit: prepare through submit lock",
                                              "commit: vkQueueSubmit",
                                              "completion: dispatch delay",
                                              "completion: predecessor status wait",
                                              "fence: status probe",
                                              "fence: polling backoff and other overhead",
                                              "GPU clock calibration: maximum deviation"};

void vg_perf_count(int kind, uint64_t count, uint64_t bytes, uint64_t ns) {
    atomic_fetch_add_explicit(&gCount[kind], count, memory_order_relaxed);
    atomic_fetch_add_explicit(&gBytes[kind], bytes, memory_order_relaxed);
    atomic_fetch_add_explicit(&gNs[kind], ns, memory_order_relaxed);
}

void vg_perf(int kind, uint64_t bytes, uint64_t ns) {
    vg_perf_count(kind, 1, bytes, ns);
}

static void vg_perf_report(void) {
    if (!vg_perf_on()) {   // WindowServer's timer runs while the flag file is away: drop what was counted
        for (int k = 0; k < VG_PERF_N; k++) {
            atomic_store(&gCount[k], 0), atomic_store(&gBytes[k], 0), atomic_store(&gNs[k], 0);
        }
        return;
    }
    // one line per kind: the unified log cuts long messages
    for (int k = 0; k < VG_PERF_N; k++) {
        uint64_t c = atomic_exchange(&gCount[k], 0), b = atomic_exchange(&gBytes[k], 0), t = atomic_exchange(&gNs[k], 0);
        if (c) {
            vglog("perf 5 s: %s %llu x, %.1f MB, %.1f ms total, %.2f ms each", kNames[k], c, b / 1048576.0, t / 1e6,
                  t / 1e6 / c);
        }
    }
}

static BOOL gPerfOn;        // VGMTL_PERF, or the flag file when the process started
static BOOL gPerfWatch;     // WindowServer: the flag file is read again at every tick
static _Atomic BOOL gPerfFlag;
BOOL vg_perf_on(void) { return gPerfOn || atomic_load_explicit(&gPerfFlag, memory_order_relaxed); }

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

// GPU timestamps on the guest's clock: guest ns = device ticks x period + offset, the offset measured around a
// vkGetCalibratedTimestampsEXT (a Venus round trip; its midpoint) and renewed every second.
static double vg_gpu_offset(void) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static double offset;
    static uint64_t at;
    static PFN_vkGetCalibratedTimestampsEXT get;
    if (!gVk.calibrated) {
        return 0;
    }
    pthread_mutex_lock(&lock);
    if (!get) {
        get = (PFN_vkGetCalibratedTimestampsEXT)gVk.vkGetDeviceProcAddr(gVk.device, "vkGetCalibratedTimestampsEXT");
    }
    uint64_t now = vg_now();
    if (get && (!at || now - at > 1000000000ull)) {
        VkCalibratedTimestampInfoEXT info = {VK_STRUCTURE_TYPE_CALIBRATED_TIMESTAMP_INFO_EXT, NULL, VK_TIME_DOMAIN_DEVICE_EXT};
        uint64_t dev = 0, dev_max = 0;
        uint64_t t0 = vg_now();
        if (get(gVk.device, 1, &info, &dev, &dev_max) == VK_SUCCESS) {
            uint64_t t1 = vg_now();
            offset = (double)(t0 + t1) / 2 - dev * (double)gVk.props.limits.timestampPeriod;
            at = t1;
            vg_perf(VG_PERF_CALIBRATION, 0, MAX(dev_max, (t1 - t0) / 2));
        }
    }
    double o = offset;
    pthread_mutex_unlock(&lock);
    return o;
}

void vg_gpu_time_collect(int pair, uint64_t submittedNs, uint64_t observedNs) {
    uint64_t ts[2];
    if (pair < 0 || gVk.vkGetQueryPoolResults(gVk.device, gQueries, 2 * pair, 2, sizeof(ts), ts, sizeof(uint64_t),
                                              VK_QUERY_RESULT_64_BIT) != VK_SUCCESS) {
        return;
    }
    const double period = gVk.props.limits.timestampPeriod;
    if (ts[1] > ts[0]) {
        vg_perf(VG_PERF_GPU, 0, (uint64_t)((ts[1] - ts[0]) * period));
    }
    double off = vg_gpu_offset();
    if (off != 0 && submittedNs && observedNs) {
        double start = ts[0] * period + off, end = ts[1] * period + off;
        double pre = start - (double)submittedNs, post = (double)observedNs - end;
        vg_perf(VG_PERF_LAT_PRE, 0, pre > 0 ? (uint64_t)pre : 0);
        vg_perf(VG_PERF_LAT_POST, 0, post > 0 ? (uint64_t)post : 0);
    }
}

__attribute__((constructor)) static void vg_perf_start(void) {
    const char *e = getenv("VGMTL_PERF");
    // 5d: /Library/GPUBundles/VirtioGPUMetal-perf turns it on in every process (an app's XPC service has no environment
    // of ours)
    gPerfOn = (e && (e[0] == '1' || e[0] == '2')) || access("/Library/GPUBundles/VirtioGPUMetal-perf", F_OK) == 0;
    gPerfWatch = !strcmp(getprogname(), "WindowServer");
    if (!gPerfOn && !gPerfWatch) {
        return;
    }
    gGpuTimeOn = (e && e[0] == '2') || access("/Library/GPUBundles/VirtioGPUMetal-gputime", F_OK) == 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        if (gPerfWatch) {
            atomic_store(&gPerfFlag, access("/Library/GPUBundles/VirtioGPUMetal-perf", F_OK) == 0);
        }
        vg_perf_report();
    });
    dispatch_resume(timer);
    gTimer = timer;
}
