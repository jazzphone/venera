// Shared by the plugin's files: the log, the Venus device and its function table, the translator.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <pthread.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

// Call trace (5b): VGMTL_CALLS=1, or the file /Library/GPUBundles/VirtioGPUMetal-calls (WindowServer reads it; its
// environment can't be set). VGCALL lines go to the log with the object they're about.
BOOL vg_calltrace(void);
void vg_callstack(const char *what);   // with the call trace on: the caller's frames, compacted
#define VGCALL(fmt, ...)                                                                                           \
    do {                                                                                                           \
        if (vg_calltrace()) {                                                                                      \
            vglog("CALL " fmt, ##__VA_ARGS__);                                                                     \
        }                                                                                                          \
    } while (0)
void vglog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
// 5c timing (VGMTLPerf.m): what each kind of work cost, summed and logged every 5 s in WindowServer (or with
// VGMTL_PERF=1) while anything happened.
enum { VG_PERF_PULL_COPY, VG_PERF_PULL_GPU, VG_PERF_WB_COPY, VG_PERF_CB, VG_PERF_ONESHOT, VG_PERF_UPLOAD, VG_PERF_DEFERRED, VG_PERF_FETCH, VG_PERF_CB_QUEUE, VG_PERF_CB_WAIT, VG_PERF_GPU, VG_PERF_POOL_HIT, VG_PERF_POOL_MISS, VG_PERF_SUBMIT_WAIT, VG_PERF_TRANSLATE, VG_PERF_DISK_HIT, VG_PERF_N };
BOOL vg_perf_on(void);
// GPU timestamps around a command buffer (5c, only while timing is on): begin returns a pair index or -1.
int vg_gpu_time_begin(VkCommandBuffer cb);
void vg_gpu_time_end(VkCommandBuffer cb, int pair);
void vg_gpu_time_collect(int pair);
void vg_perf(int kind, uint64_t bytes, uint64_t ns);
static inline uint64_t vg_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
// VGMTL_TRACE=1: step-by-step lines for bisecting a host-side failure (the log is written before each step).
BOOL vg_tracing(void);
#define vgtrace(...)                                                                                                \
    do {                                                                                                            \
        if (vg_tracing()) {                                                                                         \
            vglog(__VA_ARGS__);                                                                                     \
        }                                                                                                           \
    } while (0)
// In trace mode, waits for the host to finish everything queued so far (Venus runs most calls asynchronously, so a
// host crash otherwise surfaces at some later call).
void vg_trace_sync(const char *after);

// Every Vulkan entry point the plugin calls, loaded from the Venus ICD (instance- or device-level).
#define VG_VK_FUNCS(X)                                                                                              \
    X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceProperties) X(vkGetPhysicalDeviceQueueFamilyProperties)      \
    X(vkGetPhysicalDeviceMemoryProperties) X(vkCreateDevice) X(vkGetDeviceProcAddr) X(vkGetDeviceQueue)            \
    X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkFreeMemory)       \
    X(vkBindBufferMemory) X(vkMapMemory) X(vkUnmapMemory) X(vkCreateCommandPool) X(vkAllocateCommandBuffers)       \
    X(vkFreeCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkQueueSubmit) X(vkCreateFence)        \
    X(vkWaitForFences) X(vkDestroyFence) X(vkCmdPipelineBarrier) X(vkCmdCopyBuffer) X(vkCmdFillBuffer)             \
    X(vkCreateShaderModule) X(vkDestroyShaderModule) X(vkCreateDescriptorSetLayout) X(vkCreatePipelineLayout)      \
    X(vkCreateComputePipelines) X(vkCreateDescriptorPool) X(vkDestroyDescriptorPool) X(vkAllocateDescriptorSets)   \
    X(vkUpdateDescriptorSets) X(vkCmdBindPipeline) X(vkCmdBindDescriptorSets) X(vkCmdPushConstants)                \
    X(vkCmdDispatch) X(vkGetPhysicalDeviceFeatures2) X(vkGetPhysicalDeviceFormatProperties) X(vkCreateImage)       \
    X(vkDestroyImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) X(vkCreateImageView)                     \
    X(vkDestroyImageView) X(vkCreateSampler) X(vkDestroySampler) X(vkCmdCopyBufferToImage)                         \
    X(vkCmdCopyImageToBuffer) X(vkCmdCopyImage) X(vkCmdBeginRendering) X(vkCmdEndRendering) X(vkCreateGraphicsPipelines)              \
    X(vkDestroyPipeline) X(vkCmdSetViewport) X(vkCmdSetScissor) X(vkCmdSetPrimitiveTopology) X(vkCmdSetCullMode)    \
    X(vkCmdSetFrontFace) X(vkCmdSetDepthTestEnable) X(vkCmdSetDepthWriteEnable) X(vkCmdSetDepthCompareOp)           \
    X(vkCmdSetBlendConstants) X(vkCmdBindVertexBuffers) X(vkCmdBindIndexBuffer) X(vkCmdDraw) X(vkCmdDrawIndexed)   \
    X(vkCmdSetStencilTestEnable) X(vkCmdSetDepthBiasEnable) X(vkCmdSetRasterizerDiscardEnable)                     \
    X(vkCmdSetPrimitiveRestartEnable) X(vkCmdSetDepthBoundsTestEnable) X(vkDeviceWaitIdle)                         \
    X(vkCreateQueryPool) X(vkCmdResetQueryPool) X(vkCmdWriteTimestamp) X(vkGetQueryPoolResults)

#define VG_DECLARE(name) PFN_##name name;
struct vg_vulkan {
    int state;   // 0 not tried, 1 up, -1 failed
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    VkPhysicalDeviceProperties props;
    uint32_t queueFamily;
    uint32_t hostMemoryType;   // host-visible + coherent (cached when there is one): every buffer for now
    VkPhysicalDeviceMemoryProperties memory;
    BOOL formatlessStorage;    // shaderStorageImageRead/WriteWithoutFormat: typeless storage textures
    VkCommandPool pool;
    pthread_mutex_t lock;      // the queue and the command pool
    VG_VK_FUNCS(VG_DECLARE)
};
#undef VG_DECLARE
extern struct vg_vulkan gVk;

int vg_vulkan_init(void);   // 0 = up
uint32_t vg_memory_type(uint32_t bits, VkMemoryPropertyFlags want);   // first allowed type with `want`, else any

// A Vulkan buffer in host-visible memory, mapped for its life.
typedef struct {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *map;
    VkDeviceSize size;
} vg_buffer;
int vg_buffer_create(VkDeviceSize size, vg_buffer *out);
void vg_buffer_destroy(vg_buffer *b);
// The virtio-gpu blob resource behind a mapped allocation (Mesa's vn_macos_device_memory_res_id), 0 if none (5c).
uint32_t vg_memory_res_id(VkDeviceMemory memory);
// Staging buffers recycled (5c): creating one through Venus is several round trips. get returns one at least size
// bytes (out->size is its whole size); put takes it back, or destroys it when the pool is full.
int vg_staging_get(VkDeviceSize size, vg_buffer *out);
void vg_staging_put(vg_buffer *b);

// Deferred GPU work (5c): new images' first layout transition, replaceRegion uploads and buffer-backed texture
// refreshes used to be one-shot command buffers, each submitted and waited for (~5 ms each through Venus, hundreds a
// second in WindowServer). Now they wait in a queue and are recorded ahead of the next submit: a commit submits them
// in their own command buffer just before its own (same vkQueueSubmit), a one-shot records them first.
void vg_pending_init_image(VkImage image, VkImageAspectFlags aspect, uint32_t mips, uint32_t layers);
// staging (may be NULL) belongs to the queue from here on and is destroyed once the copy has run.
void vg_pending_copy(VkBuffer src, VkImage dst, const VkBufferImageCopy *c, const vg_buffer *staging);
void vg_pending_forget(VkImage image);   // an image going away: drop what waits for it
// Records everything waiting into cb (barriers around it); the stagings to destroy after cb completes go to *owned
// (an array of vg_buffer the caller frees with vg_pending_release). NO when nothing was waiting.
BOOL vg_pending_record(VkCommandBuffer cb, NSMutableData **owned);
void vg_pending_release(NSMutableData *owned);

// The translator (NV's metal2vulkan wrapper, Contents/Resources/libnvmtl_translate.dylib) and Apple's LLVM.
NSString *vg_air_to_text(NSData *air);   // AIR bitcode -> LLVM IR text, nil on failure
// fc: function-constant values (index -> bytes) the module is specialized with first; nil or empty for none.
NSData *vg_translate(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc, const uint32_t *tgLengths,
                     uint32_t tgCount, NSString **error);
NSDictionary *vg_reflect(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc, NSString **error);
NSString *vg_resource_path(const char *name);   // .../VirtioGPUMetal.bundle/Contents/Resources/<name>

// Objects the device hands out (VGMTLCompute.m).
id<MTLBuffer> vg_new_buffer(id<MTLDevice> device, NSUInteger length, MTLResourceOptions options, const void *bytes);
id<MTLCommandQueue> vg_new_queue(id<MTLDevice> device);
id<MTLLibrary> vg_new_library(id<MTLDevice> device, NSData *metallib, NSError **error);
id<MTLComputePipelineState> vg_new_compute_pipeline(id<MTLDevice> device, id<MTLFunction> function, NSError **error);

// What VGMTLLibrary.m's functions carry for the pipeline code.
@interface NSObject (VGFunction)
- (NSString *)vgLL;      // the entry's LLVM IR text
- (NSString *)vgStage;   // "kernel" | "vertex" | "fragment"
- (NSDictionary<NSNumber *, NSData *> *)vgFC;   // function-constant values, nil if none were given
@end
