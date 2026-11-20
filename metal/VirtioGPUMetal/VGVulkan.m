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

static uint32_t (*gResIdOf)(VkDevice, VkDeviceMemory);
static int (*gImportSurface)(VkDevice, uint32_t, uint64_t *);
BOOL gVgSharing;

int vg_import_surface(uint32_t surface, uint64_t out[7]) {
    return gImportSurface && gVgSharing ? gImportSurface(gVk.device, surface, out) : -1;
}

uint32_t vg_memory_res_id(VkDeviceMemory memory) {
    return gResIdOf && memory ? gResIdOf(gVk.device, memory) : 0;
}

static int vg_vulkan_init_locked(void) {
    // Fence waits through the kernel's interrupt instead of Venus' shared-memory fence feedback (5c): feedback is polled
    // with short usleeps that macOS stretches under load (median small submit under WindowServer load: 8.3 ms with
    // feedback, 5.8 ms without, tools/mtllat). A VN_PERF the process set itself wins.
    if (access("/Library/GPUBundles/VirtioGPUMetal-fencefeedback", F_OK) != 0) {   // the flag file keeps feedback
        setenv("VN_PERF", "no_fence_feedback", 0);
    }
    NSString *path = vg_resource_path("libvulkan_virtio.dylib");
    void *lib = path ? dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL) : NULL;
    if (!lib) {
        vglog("vulkan: dlopen %s: %s", path.UTF8String, dlerror());
        return -1;
    }
    gResIdOf = (uint32_t(*)(VkDevice, VkDeviceMemory))dlsym(lib, "vn_macos_device_memory_res_id");   // Mesa patch 0006
    gImportSurface = (int (*)(VkDevice, uint32_t, uint64_t *))dlsym(lib, "vn_macos_import_surface");    // Mesa patch 0007
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
    // Sampling a color attachment inside its own pass needs VK_EXT_attachment_feedback_loop_layout: framebuffer fetch
    // in place (5c round 6, mode 4), and an attachment the app binds as a texture (5d, RenderBox) in every mode.
    VkPhysicalDeviceAttachmentFeedbackLoopLayoutFeaturesEXT ffl = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ATTACHMENT_FEEDBACK_LOOP_LAYOUT_FEATURES_EXT};
    const BOOL wantFeedback = YES;
    VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
                                            wantFeedback ? &ffl : NULL};
    VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &f13};
    VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12};
    VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f11};
    gVk.vkGetPhysicalDeviceFeatures2(gVk.physical, &f2);
    f2.features.robustBufferAccess = VK_FALSE;
    f13.robustImageAccess = VK_FALSE;
    gVk.formatlessStorage = f2.features.shaderStorageImageReadWithoutFormat && f2.features.shaderStorageImageWriteWithoutFormat;
    gVk.tessellation = f2.features.tessellationShader;
    gVk.int64 = f2.features.shaderInt64;
    gVk.deviceAddress = f12.bufferDeviceAddress;
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, gVk.queueFamily, 1, &prio};
    // VK_EXT_calibrated_timestamps (5c round 4): GPU timestamps on the guest's clock, to split completion latency.
    // Each optional extension the device lacks is dropped and the device created again.
    const char *exts[4] = {"VK_EXT_calibrated_timestamps", "VK_EXT_attachment_feedback_loop_layout"};
    uint32_t next = wantFeedback && ffl.attachmentFeedbackLoopLayout ? 2 : 1;
    // Surface sharing between processes (5d): dma-buf external memory, when the device has it and Mesa can import.
    uint32_t nde = 0;
    gVk.vkEnumerateDeviceExtensionProperties(gVk.physical, NULL, &nde, NULL);
    VkExtensionProperties *de = calloc(nde ? nde : 1, sizeof(*de));
    gVk.vkEnumerateDeviceExtensionProperties(gVk.physical, NULL, &nde, de);
    int haveExt = 0;
    for (uint32_t i = 0; i < nde; i++) {
        haveExt |= !strcmp(de[i].extensionName, "VK_KHR_external_memory_fd") ? 1
                   : !strcmp(de[i].extensionName, "VK_EXT_external_memory_dma_buf") ? 2 : 0;
    }
    free(de);
    // Opt-in (the flag file VirtioGPUMetal-share): measured on VM 108 it saves WindowServer's pull copies, under 1% of a
    // core for a 640x480 window drawing every frame, against the risk of a surface's frames getting lost between
    // processes (the first version lost Safari's page background).
    BOOL share = haveExt == 3 && gImportSurface && access("/Library/GPUBundles/VirtioGPUMetal-share", F_OK) == 0;
    const char *const *base = exts;
    const char *withShare[4];
    if (share) {   // ahead of the optional ones the loop below drops from the end
        withShare[0] = "VK_KHR_external_memory_fd";
        withShare[1] = "VK_EXT_external_memory_dma_buf";
        withShare[2] = exts[0];
        withShare[3] = exts[1];
        base = withShare;
        next += 2;
    }
    if (wantFeedback && !ffl.attachmentFeedbackLoopLayout) {
        vglog("vulkan: no attachmentFeedbackLoopLayout: framebuffer fetch stays with copies");
    }
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, 0, 1, &qci, 0, NULL, next, base, NULL};
    for (;;) {
        r = gVk.vkCreateDevice(gVk.physical, &dci, NULL, &gVk.device);
        if (r != VK_ERROR_EXTENSION_NOT_PRESENT || !dci.enabledExtensionCount) {
            break;
        }
        dci.enabledExtensionCount--;   // the feedback loop first, then the timestamps
    }
    if (r == VK_SUCCESS) {
        uint32_t k = share ? (dci.enabledExtensionCount > 2 ? dci.enabledExtensionCount - 2 : 0) : dci.enabledExtensionCount;
        gVgSharing = share && dci.enabledExtensionCount >= 2;
        gVk.calibrated = k >= 1;
        gVk.feedbackLoop = k >= 2;
        if (wantFeedback) {
            vglog("vulkan: framebuffer fetch %s", gVk.feedbackLoop ? "in place (attachment feedback loop)" : "by copies");
        }
    }
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
    // Buffers are made with device addresses when the device has them (Metal tessellation's control stage reads the
    // factor and vertex buffers through them); the flag file VirtioGPUMetal-nobda makes them as before.
    gVk.bufferAddresses = gVk.deviceAddress && gVk.vkGetBufferDeviceAddress &&
                          access("/Library/GPUBundles/VirtioGPUMetal-nobda", F_OK) != 0;
    vglog("vulkan: tessellationShader %s, shaderInt64 %s, bufferDeviceAddress %s (buffers %s device addresses): "
          "Metal tessellation %s",
          gVk.tessellation ? "on" : "ABSENT", gVk.int64 ? "on" : "ABSENT", gVk.deviceAddress ? "on" : "ABSENT",
          gVk.bufferAddresses ? "carry" : "have no", gVk.tessellation && gVk.int64 && gVk.bufferAddresses ? "available" : "UNAVAILABLE");
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

// Small buffers are cut from 4 MB mapped chunks (5d): every Venus allocation that is mapped takes one of the core's
// 2048 host-memory ranges for the whole machine, one per MTLBuffer, and with WindowServer, Safari and a few apps open
// they ran out -- Grapher's 4 KB vertex buffers failed to map (VK_ERROR_MEMORY_MAP_FAILED) and its 3D surface never
// drew. Power-of-two classes from 256 bytes to 256 KB, a free list each; chunks are kept for the process's life.
enum { kVgSubMin = 8, kVgSubMax = 18, kVgSubChunk = 4 << 20 };
typedef struct {
    VkDeviceMemory memory;
    uint8_t *map;
} vg_chunk;
typedef struct {
    uint32_t chunk, off;
} vg_slot;
static pthread_mutex_t gSubLock = PTHREAD_MUTEX_INITIALIZER;
static vg_chunk *gChunks;
static uint32_t gNChunks, gCapChunks;
static vg_slot *gFree[kVgSubMax - kVgSubMin + 1];
static uint32_t gNFree[kVgSubMax - kVgSubMin + 1], gCapFree[kVgSubMax - kVgSubMin + 1];

static void vg_sub_push(uint32_t cls, vg_slot s) {
    if (gNFree[cls] == gCapFree[cls]) {
        gCapFree[cls] = gCapFree[cls] ? gCapFree[cls] * 2 : 256;
        gFree[cls] = realloc(gFree[cls], gCapFree[cls] * sizeof(vg_slot));
    }
    gFree[cls][gNFree[cls]++] = s;
}

// A slot of class cls (2^(cls+kVgSubMin) bytes); NO when no chunk could be had.
static BOOL vg_sub_get(uint32_t cls, vg_slot *out) {
    pthread_mutex_lock(&gSubLock);
    if (!gNFree[cls]) {
        // a chunk's buffers all have addresses or none do (gVk.bufferAddresses is decided once, at init)
        VkMemoryAllocateFlagsInfo fi = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, NULL, VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT, 0};
        VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, gVk.bufferAddresses ? &fi : NULL, kVgSubChunk,
                                    gVk.hostMemoryType};
        VkDeviceMemory m = VK_NULL_HANDLE;
        void *map = NULL;
        if (gVk.vkAllocateMemory(gVk.device, &mai, NULL, &m) != VK_SUCCESS) {
            pthread_mutex_unlock(&gSubLock);
            return NO;
        }
        if (gVk.vkMapMemory(gVk.device, m, 0, VK_WHOLE_SIZE, 0, &map) != VK_SUCCESS) {
            gVk.vkFreeMemory(gVk.device, m, NULL);
            pthread_mutex_unlock(&gSubLock);
            return NO;
        }
        if (gNChunks == gCapChunks) {
            gCapChunks = gCapChunks ? gCapChunks * 2 : 16;
            gChunks = realloc(gChunks, gCapChunks * sizeof(vg_chunk));
        }
        uint32_t idx = gNChunks++;
        gChunks[idx] = (vg_chunk){m, map};
        uint32_t slot = 1u << (cls + kVgSubMin);
        for (uint32_t off = kVgSubChunk; off >= slot; off -= slot) {
            vg_sub_push(cls, (vg_slot){idx, off - slot});
        }
    }
    *out = gFree[cls][--gNFree[cls]];
    pthread_mutex_unlock(&gSubLock);
    return YES;
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
    if (gVk.bufferAddresses) {
        bci.usage |= VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    }
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkResult r = gVk.vkCreateBuffer(gVk.device, &bci, NULL, &out->buffer);
    if (r != VK_SUCCESS) {
        vglog("buffer: vkCreateBuffer(%llu) %d", (unsigned long long)size, r);
        return -1;
    }
    VkMemoryRequirements req;
    gVk.vkGetBufferMemoryRequirements(gVk.device, out->buffer, &req);
    VkDeviceSize need = MAX(req.size, req.alignment);
    if (need <= (1u << kVgSubMax) && (req.memoryTypeBits & (1u << gVk.hostMemoryType)) &&
        access("/Library/GPUBundles/VirtioGPUMetal-nosuballoc", F_OK) != 0) {
        uint32_t cls = 0;
        while ((1ull << (cls + kVgSubMin)) < need) {
            cls++;
        }
        vg_slot s;
        if (vg_sub_get(cls, &s)) {
            r = gVk.vkBindBufferMemory(gVk.device, out->buffer, gChunks[s.chunk].memory, s.off);
            if (r == VK_SUCCESS) {
                out->memory = gChunks[s.chunk].memory;
                out->map = gChunks[s.chunk].map + s.off;
                out->size = size;
                out->subChunk = s.chunk + 1;
                out->subClass = cls;
                out->subOffset = s.off;
                out->addressable = gVk.bufferAddresses;
                return 0;
            }
            pthread_mutex_lock(&gSubLock);
            vg_sub_push(cls, s);
            pthread_mutex_unlock(&gSubLock);
        }
    }
    VkMemoryAllocateFlagsInfo fi = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, NULL, VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT, 0};
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, gVk.bufferAddresses ? &fi : NULL, req.size,
                                gVk.hostMemoryType};
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
    out->addressable = gVk.bufferAddresses;
    return 0;
}

VkDeviceAddress vg_buffer_address(vg_buffer *b) {
    if (!b->buffer || !b->addressable || !gVk.vkGetBufferDeviceAddress) {
        return 0;
    }
    if (!b->address) {
        VkBufferDeviceAddressInfo ai = {VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, b->buffer};
        b->address = gVk.vkGetBufferDeviceAddress(gVk.device, &ai);
    }
    return b->address;
}

void vg_buffer_destroy(vg_buffer *b) {
    if (b->subChunk && b->memory) {   // cut from a chunk: the slot goes back, the chunk stays
        if (b->buffer) {
            gVk.vkDestroyBuffer(gVk.device, b->buffer, NULL);
        }
        pthread_mutex_lock(&gSubLock);
        vg_sub_push(b->subClass, (vg_slot){b->subChunk - 1, b->subOffset});
        pthread_mutex_unlock(&gSubLock);
        memset(b, 0, sizeof(*b));
        return;
    }
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
