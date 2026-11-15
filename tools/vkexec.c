// vkexec: make the GPU do real work through Venus and check it from macOS.
// Fill a buffer on the GPU (vkCmdFillBuffer), copy it to a second one (vkCmdCopyBuffer), wait on a
// fence, then read every word back on the CPU. No shaders, so no shader compiler needed.
//   vkexec [libvulkan_virtio.dylib] [MB]
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

typedef PFN_vkVoidFunction(VKAPI_PTR *PFN_icdGetInstanceProcAddr)(VkInstance, const char *);

static uint64_t now_us(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000; }

#define CHECK(call)                                                                                \
    do {                                                                                           \
        VkResult r_ = (call);                                                                      \
        if (r_ != VK_SUCCESS) {                                                                    \
            printf("%s failed: %d\n", #call, r_);                                                  \
            return 1;                                                                              \
        }                                                                                          \
    } while (0)

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "./libvulkan_virtio.dylib";
    VkDeviceSize size = (VkDeviceSize)(argc > 2 ? atoi(argv[2]) : 64) << 20;
    void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        printf("dlopen: %s\n", dlerror());
        return 1;
    }
    uint32_t icdVersion = 5;
    ((VkResult(*)(uint32_t *))dlsym(lib, "vk_icdNegotiateLoaderICDInterfaceVersion"))(&icdVersion);
    PFN_icdGetInstanceProcAddr gipa = (PFN_icdGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");

    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vkexec", 1, NULL, 0, VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app, 0, NULL, 0, NULL};
    VkInstance instance;
    CHECK(((PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance"))(&ici, NULL, &instance));
#define IGET(name) PFN_##name name = (PFN_##name)gipa(instance, #name)
    IGET(vkEnumeratePhysicalDevices);
    IGET(vkGetPhysicalDeviceProperties);
    IGET(vkGetPhysicalDeviceMemoryProperties);
    IGET(vkCreateDevice);
    IGET(vkGetDeviceProcAddr);
    IGET(vkDestroyInstance);

    VkPhysicalDevice pd[4];
    uint32_t count = 4;
    CHECK(vkEnumeratePhysicalDevices(instance, &count, pd));
    VkPhysicalDevice gpu = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties props;
    for (uint32_t i = 0; i < count && !gpu; i++) {
        vkGetPhysicalDeviceProperties(pd[i], &props);
        if (props.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU) {
            gpu = pd[i];
        }
    }
    if (!gpu) {
        printf("no GPU device\n");
        return 1;
    }
    printf("device: %s\n", props.deviceName);

    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &priority};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &qci, 0, NULL, 0, NULL, NULL};
    VkDevice dev;
    uint64_t t0 = now_us();
    CHECK(vkCreateDevice(gpu, &dci, NULL, &dev));
    printf("vkCreateDevice: %llu us\n", (unsigned long long)(now_us() - t0));
#define DGET(name) PFN_##name name = (PFN_##name)vkGetDeviceProcAddr(dev, #name)
    DGET(vkGetDeviceQueue);
    DGET(vkCreateBuffer);
    DGET(vkGetBufferMemoryRequirements);
    DGET(vkAllocateMemory);
    DGET(vkBindBufferMemory);
    DGET(vkMapMemory);
    DGET(vkCreateCommandPool);
    DGET(vkAllocateCommandBuffers);
    DGET(vkBeginCommandBuffer);
    DGET(vkCmdFillBuffer);
    DGET(vkCmdPipelineBarrier);
    DGET(vkCmdCopyBuffer);
    DGET(vkEndCommandBuffer);
    DGET(vkCreateFence);
    DGET(vkQueueSubmit);
    DGET(vkWaitForFences);
    DGET(vkDestroyDevice);

    VkQueue queue;
    vkGetDeviceQueue(dev, 0, 0, &queue);

    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(gpu, &mp);
    VkBuffer buf[2];
    VkDeviceMemory mem[2];
    void *ptr[2];
    for (int b = 0; b < 2; b++) {
        VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, size,
                                  VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                  VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
        CHECK(vkCreateBuffer(dev, &bci, NULL, &buf[b]));
        VkMemoryRequirements req;
        vkGetBufferMemoryRequirements(dev, buf[b], &req);
        // host-visible + coherent, cached if offered: the CPU reads the result back
        VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        uint32_t type = UINT32_MAX;
        for (uint32_t t = 0; t < mp.memoryTypeCount; t++) {
            if ((req.memoryTypeBits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & want) == want) {
                if (type == UINT32_MAX || (mp.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT)) {
                    type = t;
                }
            }
        }
        VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size, type};
        t0 = now_us();
        CHECK(vkAllocateMemory(dev, &mai, NULL, &mem[b]));
        CHECK(vkBindBufferMemory(dev, buf[b], mem[b], 0));
        CHECK(vkMapMemory(dev, mem[b], 0, size, 0, &ptr[b]));
        printf("buffer %d: %llu MB, memory type %u, allocate+map %llu us\n", b, (unsigned long long)(size >> 20),
               type, (unsigned long long)(now_us() - t0));
    }
    memset(ptr[0], 0, size);
    memset(ptr[1], 0, size);

    VkCommandPoolCreateInfo cpci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, 0};
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
    VkCommandBufferAllocateInfo cbai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool,
                                        VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(dev, &cbai, &cb));
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                      VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    CHECK(vkBeginCommandBuffer(cb, &begin));
    const uint32_t pattern = 0xC0FFEE42;
    vkCmdFillBuffer(cb, buf[0], 0, VK_WHOLE_SIZE, pattern);
    VkMemoryBarrier barrier = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT,
                               VK_ACCESS_TRANSFER_READ_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &barrier, 0,
                         NULL, 0, NULL);
    VkBufferCopy region = {0, 0, size};
    vkCmdCopyBuffer(cb, buf[0], buf[1], 1, &region);
    VkMemoryBarrier toHost = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT,
                              VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &toHost, 0, NULL, 0,
                         NULL);
    CHECK(vkEndCommandBuffer(cb));

    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, 0};
    VkFence fence;
    CHECK(vkCreateFence(dev, &fci, NULL, &fence));
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cb, 0, NULL};
    t0 = now_us();
    CHECK(vkQueueSubmit(queue, 1, &si, fence));
    VkResult wr = vkWaitForFences(dev, 1, &fence, VK_TRUE, 10ull * 1000 * 1000 * 1000);
    uint64_t gpuUs = now_us() - t0;
    printf("submit fill %llu MB + copy + wait: %s in %llu us (%.1f GB/s copied)\n", (unsigned long long)(size >> 20),
           wr == VK_SUCCESS ? "done" : "NOT DONE", (unsigned long long)gpuUs,
           gpuUs ? (double)size / 1e3 / gpuUs : 0.0);
    if (wr != VK_SUCCESS) {
        printf("vkWaitForFences: %d\nFAIL\n", wr);
        return 1;
    }

    const uint32_t *a = ptr[0], *b = ptr[1];
    uint64_t badA = 0, badB = 0, words = size / 4;
    t0 = now_us();
    for (uint64_t i = 0; i < words; i++) {
        badA += a[i] != pattern;
        badB += b[i] != pattern;
    }
    printf("CPU check of %llu words in each buffer: %llu / %llu wrong (%llu us)\n", (unsigned long long)words,
           (unsigned long long)badA, (unsigned long long)badB, (unsigned long long)(now_us() - t0));
    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(instance, NULL);
    printf("%s\n", (badA || badB) ? "FAIL" : "PASS: the GPU did the work");
    return (badA || badB) ? 1 : 0;
}
