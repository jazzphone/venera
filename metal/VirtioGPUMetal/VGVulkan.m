// The plugin's Vulkan device: Mesa's Venus ICD (Contents/Resources/libvulkan_virtio.dylib, loaded directly, no
// Vulkan loader) on the host's GPU, one VkDevice + queue + command pool per process, and host-visible buffers.
#import "vg.h"
#import <dlfcn.h>

struct vg_vulkan gVk = {.lock = PTHREAD_MUTEX_INITIALIZER};

typedef PFN_vkVoidFunction(VKAPI_PTR *PFN_icdGetInstanceProcAddr)(VkInstance, const char *);
typedef VkResult(VKAPI_PTR *PFN_negotiate)(uint32_t *version);

NSString *vg_resource_path(const char *name) {
    Dl_info info;
    if (!dladdr((const void *)vg_resource_path, &info) || !info.dli_fname) {
        return nil;
    }
    // .../VirtioGPUMetal.bundle/Contents/MacOS/VirtioGPUMetal -> .../Contents/Resources/<name>
    NSString *contents = [[@(info.dli_fname) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    return [[contents stringByAppendingPathComponent:@"Resources"] stringByAppendingPathComponent:@(name)];
}

static int vg_vulkan_init_locked(void) {
    NSString *path = vg_resource_path("libvulkan_virtio.dylib");
    void *lib = path ? dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL) : NULL;
    if (!lib) {
        vglog("vulkan: dlopen %s: %s", path.UTF8String, dlerror());
        return -1;
    }
    PFN_negotiate negotiate = (PFN_negotiate)dlsym(lib, "vk_icdNegotiateLoaderICDInterfaceVersion");
    PFN_icdGetInstanceProcAddr gipa = (PFN_icdGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");
    if (!negotiate || !gipa) {
        vglog("vulkan: the ICD has no loader entry points");
        return -1;
    }
    uint32_t icdVersion = 5;
    negotiate(&icdVersion);
    PFN_vkCreateInstance createInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "VirtioGPUMetal", 1, "VirtioGPUMetal", 1,
                             VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app, 0, NULL, 0, NULL};
    VkResult r = createInstance(&ici, NULL, &gVk.instance);
    if (r != VK_SUCCESS) {
        vglog("vulkan: vkCreateInstance %d", r);
        return -1;
    }
    // Instance-level lookups first; device-level ones are refreshed through vkGetDeviceProcAddr below.
#define VG_LOAD(name) gVk.name = (PFN_##name)gipa(gVk.instance, #name);
    VG_VK_FUNCS(VG_LOAD)
#undef VG_LOAD
    VkPhysicalDevice devs[8];
    uint32_t n = 8;
    r = gVk.vkEnumeratePhysicalDevices(gVk.instance, &n, devs);
    if (r < 0 || !n) {
        vglog("vulkan: vkEnumeratePhysicalDevices %d, %u devices", r, n);
        return -1;
    }
    for (uint32_t i = 0; i < n && !gVk.physical; i++) {   // the host's GPU, not llvmpipe (Venus lists both)
        VkPhysicalDeviceProperties p;
        gVk.vkGetPhysicalDeviceProperties(devs[i], &p);
        if (p.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU) {
            gVk.physical = devs[i];
            gVk.props = p;
        }
    }
    if (!gVk.physical) {
        vglog("vulkan: only CPU devices");
        return -1;
    }
    VkQueueFamilyProperties qf[8];
    uint32_t qn = 8;
    gVk.vkGetPhysicalDeviceQueueFamilyProperties(gVk.physical, &qn, qf);
    gVk.queueFamily = UINT32_MAX;
    for (uint32_t q = 0; q < qn && gVk.queueFamily == UINT32_MAX; q++) {
        const VkQueueFlags want = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
        if ((qf[q].queueFlags & want) == want) {
            gVk.queueFamily = q;
        }
    }
    if (gVk.queueFamily == UINT32_MAX) {
        vglog("vulkan: no graphics+compute queue family");
        return -1;
    }
    VkPhysicalDeviceMemoryProperties mp;
    gVk.vkGetPhysicalDeviceMemoryProperties(gVk.physical, &mp);
    gVk.hostMemoryType = UINT32_MAX;
    const VkMemoryPropertyFlags hv = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    for (int pass = 0; pass < 2 && gVk.hostMemoryType == UINT32_MAX; pass++) {
        for (uint32_t t = 0; t < mp.memoryTypeCount; t++) {
            VkMemoryPropertyFlags f = mp.memoryTypes[t].propertyFlags;
            if ((f & hv) == hv && (pass || (f & VK_MEMORY_PROPERTY_HOST_CACHED_BIT))) {
                gVk.hostMemoryType = t;
                break;
            }
        }
    }
    if (gVk.hostMemoryType == UINT32_MAX) {
        vglog("vulkan: no host-visible coherent memory type");
        return -1;
    }
    gVk.memory = mp;
    // Translated shaders declare what they use (descriptor indexing, formatless storage images, 8/16-bit types,
    // the memory model...), and Vulkan needs each feature enabled: turn on everything the device has, except
    // robustBufferAccess (bounds checks on every access, which Metal doesn't promise).
    VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &f13};
    VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12};
    VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f11};
    gVk.vkGetPhysicalDeviceFeatures2(gVk.physical, &f2);
    f2.features.robustBufferAccess = VK_FALSE;
    f13.robustImageAccess = VK_FALSE;
    gVk.formatlessStorage = f2.features.shaderStorageImageReadWithoutFormat && f2.features.shaderStorageImageWriteWithoutFormat;
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, gVk.queueFamily, 1, &prio};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, 0, 1, &qci, 0, NULL, 0, NULL, NULL};
    r = gVk.vkCreateDevice(gVk.physical, &dci, NULL, &gVk.device);
    if (r != VK_SUCCESS) {
        vglog("vulkan: vkCreateDevice %d", r);
        return -1;
    }
#define VG_LOAD_DEV(name)                                                                                           \
    {                                                                                                               \
        PFN_vkVoidFunction f = gVk.vkGetDeviceProcAddr(gVk.device, #name);                                          \
        if (f) {                                                                                                    \
            gVk.name = (PFN_##name)f;                                                                               \
        }                                                                                                           \
    }
    VG_VK_FUNCS(VG_LOAD_DEV)
#undef VG_LOAD_DEV
    gVk.vkGetDeviceQueue(gVk.device, gVk.queueFamily, 0, &gVk.queue);
    VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
                                   VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, gVk.queueFamily};
    r = gVk.vkCreateCommandPool(gVk.device, &pci, NULL, &gVk.pool);
    if (r != VK_SUCCESS) {
        vglog("vulkan: vkCreateCommandPool %d", r);
        return -1;
    }
    vglog("vulkan: %s (vendor %04x device %04x, API %u.%u.%u), queue family %u, host memory type %u", gVk.props.deviceName,
          gVk.props.vendorID, gVk.props.deviceID, VK_VERSION_MAJOR(gVk.props.apiVersion),
          VK_VERSION_MINOR(gVk.props.apiVersion), VK_VERSION_PATCH(gVk.props.apiVersion), gVk.queueFamily,
          gVk.hostMemoryType);
    return 0;
}

int vg_vulkan_init(void) {
    pthread_mutex_lock(&gVk.lock);
    if (!gVk.state) {
        gVk.state = vg_vulkan_init_locked() ? -1 : 1;
    }
    int up = gVk.state > 0;
    pthread_mutex_unlock(&gVk.lock);
    return up ? 0 : -1;
}

uint32_t vg_memory_type(uint32_t bits, VkMemoryPropertyFlags want) {
    for (uint32_t t = 0; t < gVk.memory.memoryTypeCount; t++) {
        if ((bits & (1u << t)) && (gVk.memory.memoryTypes[t].propertyFlags & want) == want) {
            return t;
        }
    }
    for (uint32_t t = 0; t < gVk.memory.memoryTypeCount; t++) {
        if (bits & (1u << t)) {
            return t;
        }
    }
    return UINT32_MAX;
}

int vg_buffer_create(VkDeviceSize size, vg_buffer *out) {
    memset(out, 0, sizeof(*out));
    if (!size) {
        size = 4;
    }
    VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bci.size = size;
    bci.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT |
                VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
                VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkResult r = gVk.vkCreateBuffer(gVk.device, &bci, NULL, &out->buffer);
    if (r != VK_SUCCESS) {
        vglog("buffer: vkCreateBuffer(%llu) %d", (unsigned long long)size, r);
        return -1;
    }
    VkMemoryRequirements req;
    gVk.vkGetBufferMemoryRequirements(gVk.device, out->buffer, &req);
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size, gVk.hostMemoryType};
    r = gVk.vkAllocateMemory(gVk.device, &mai, NULL, &out->memory);
    if (r == VK_SUCCESS) {
        r = gVk.vkBindBufferMemory(gVk.device, out->buffer, out->memory, 0);
    }
    if (r == VK_SUCCESS) {
        r = gVk.vkMapMemory(gVk.device, out->memory, 0, VK_WHOLE_SIZE, 0, &out->map);
    }
    if (r != VK_SUCCESS) {
        vglog("buffer: %llu bytes: memory %d", (unsigned long long)size, r);
        vg_buffer_destroy(out);
        return -1;
    }
    out->size = size;
    return 0;
}

void vg_buffer_destroy(vg_buffer *b) {
    if (b->map) {
        gVk.vkUnmapMemory(gVk.device, b->memory);
    }
    if (b->buffer) {
        gVk.vkDestroyBuffer(gVk.device, b->buffer, NULL);
    }
    if (b->memory) {
        gVk.vkFreeMemory(gVk.device, b->memory, NULL);
    }
    memset(b, 0, sizeof(*b));
}

void vg_trace_sync(const char *after) {
    if (vg_tracing() && gVk.device) {
        vglog("sync after %s ...", after);
        VkResult r = gVk.vkDeviceWaitIdle(gVk.device);
        vglog("sync after %s: %d", after, r);
    }
}
