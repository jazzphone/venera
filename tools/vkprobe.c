// vkprobe: load Mesa's Venus ICD directly (no Vulkan loader) and list what it sees.
//   vkprobe [path/to/libvulkan_virtio.dylib] [--features]   (VN_DEBUG=init,result for Venus logs)
//   --features: also every device extension, the 17 the Metal plugin looks for, and the core features it reads
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

typedef VkResult(VKAPI_PTR *PFN_negotiate)(uint32_t *version);
typedef PFN_vkVoidFunction(VKAPI_PTR *PFN_icdGetInstanceProcAddr)(VkInstance, const char *);

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/Volumes/vgpu/libvulkan_virtio.dylib";
    void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        printf("dlopen %s: %s\n", path, dlerror());
        return 1;
    }
    PFN_negotiate negotiate = (PFN_negotiate)dlsym(lib, "vk_icdNegotiateLoaderICDInterfaceVersion");
    PFN_icdGetInstanceProcAddr gipa = (PFN_icdGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");
    if (!negotiate || !gipa) {
        printf("missing ICD entry points\n");
        return 1;
    }
    uint32_t icdVersion = 5;
    printf("negotiate ICD interface: %d (version %u)\n", negotiate(&icdVersion), icdVersion);

    PFN_vkCreateInstance createInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    PFN_vkEnumerateInstanceVersion enumVersion =
        (PFN_vkEnumerateInstanceVersion)gipa(NULL, "vkEnumerateInstanceVersion");
    uint32_t apiVersion = 0;
    if (enumVersion) {
        enumVersion(&apiVersion);
    }
    printf("instance API %u.%u.%u\n", VK_VERSION_MAJOR(apiVersion), VK_VERSION_MINOR(apiVersion),
           VK_VERSION_PATCH(apiVersion));

    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vkprobe", 1, NULL, 0, VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app, 0, NULL, 0, NULL};
    VkInstance instance = VK_NULL_HANDLE;
    VkResult r = createInstance(&ici, NULL, &instance);
    printf("vkCreateInstance: %d\n", r);
    if (r != VK_SUCCESS) {
        return 1;
    }

#define GET(name) PFN_##name name = (PFN_##name)gipa(instance, #name)
    GET(vkEnumeratePhysicalDevices);
    GET(vkGetPhysicalDeviceProperties);
    GET(vkGetPhysicalDeviceMemoryProperties);
    GET(vkGetPhysicalDeviceQueueFamilyProperties);
    GET(vkDestroyInstance);
    GET(vkEnumerateDeviceExtensionProperties);
    GET(vkGetPhysicalDeviceFeatures2);
    int features = argc > 2 && !strcmp(argv[2], "--features");

    uint32_t count = 0;
    r = vkEnumeratePhysicalDevices(instance, &count, NULL);
    printf("vkEnumeratePhysicalDevices: %d, %u device(s)\n", r, count);
    VkPhysicalDevice devices[8];
    if (count > 8) {
        count = 8;
    }
    vkEnumeratePhysicalDevices(instance, &count, devices);
    for (uint32_t i = 0; i < count; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(devices[i], &p);
        static const char *types[] = {"other", "integrated GPU", "discrete GPU", "virtual GPU", "CPU"};
        printf("\n[%u] %s\n    type %s, API %u.%u.%u, driver 0x%x, vendor 0x%04x device 0x%04x\n", i, p.deviceName,
               p.deviceType <= 4 ? types[p.deviceType] : "?", VK_VERSION_MAJOR(p.apiVersion),
               VK_VERSION_MINOR(p.apiVersion), VK_VERSION_PATCH(p.apiVersion), p.driverVersion, p.vendorID,
               p.deviceID);
        printf("    maxImageDimension2D %u, maxComputeWorkGroupInvocations %u\n", p.limits.maxImageDimension2D,
               p.limits.maxComputeWorkGroupInvocations);
        VkPhysicalDeviceMemoryProperties m;
        vkGetPhysicalDeviceMemoryProperties(devices[i], &m);
        for (uint32_t h = 0; h < m.memoryHeapCount; h++) {
            printf("    heap %u: %llu MB%s\n", h, (unsigned long long)(m.memoryHeaps[h].size >> 20),
                   (m.memoryHeaps[h].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) ? " device-local" : "");
        }
        for (uint32_t t = 0; t < m.memoryTypeCount; t++) {
            VkMemoryPropertyFlags f = m.memoryTypes[t].propertyFlags;
            printf("    type %u: heap %u%s%s%s%s\n", t, m.memoryTypes[t].heapIndex,
                   (f & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) ? " device-local" : "",
                   (f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) ? " host-visible" : "",
                   (f & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) ? " coherent" : "",
                   (f & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) ? " cached" : "");
        }
        uint32_t qfCount = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &qfCount, NULL);
        VkQueueFamilyProperties qf[8];
        if (qfCount > 8) {
            qfCount = 8;
        }
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &qfCount, qf);
        for (uint32_t q = 0; q < qfCount; q++) {
            printf("    queue family %u: %u queue(s)%s%s%s\n", q, qf[q].queueCount,
                   (qf[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) ? " graphics" : "",
                   (qf[q].queueFlags & VK_QUEUE_COMPUTE_BIT) ? " compute" : "",
                   (qf[q].queueFlags & VK_QUEUE_TRANSFER_BIT) ? " transfer" : "");
        }
        if (features && p.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU) {
            uint32_t en = 0;
            vkEnumerateDeviceExtensionProperties(devices[i], NULL, &en, NULL);
            VkExtensionProperties *ext = calloc(en, sizeof(*ext));
            vkEnumerateDeviceExtensionProperties(devices[i], NULL, &en, ext);
            printf("    %u device extensions:", en);
            for (uint32_t e = 0; e < en; e++) {
                printf("%s%s", (e % 3) ? "  " : "\n      ", ext[e].extensionName);
            }
            // nvidia-macos-driver plugin/nvmtl_vk.c kWant: optional, each turns a feature on
            static const char *want[] = {"VK_EXT_extended_dynamic_state3", "VK_EXT_depth_clip_enable",
                "VK_EXT_memory_budget", "VK_KHR_acceleration_structure", "VK_KHR_ray_query",
                "VK_KHR_deferred_host_operations", "VK_EXT_external_memory_host", "VK_EXT_image_drm_format_modifier",
                "VK_KHR_external_memory_fd", "VK_EXT_mutable_descriptor_type", "VK_KHR_cooperative_matrix",
                "VK_EXT_calibrated_timestamps", "VK_EXT_sample_locations", "VK_KHR_pipeline_executable_properties",
                "VK_EXT_provoking_vertex", "VK_KHR_vertex_attribute_divisor", "VK_EXT_pipeline_robustness"};
            printf("\n    the Metal plugin's 17 optional extensions:\n");
            for (unsigned w = 0; w < sizeof(want) / sizeof(*want); w++) {
                int have = 0;
                for (uint32_t e = 0; e < en; e++) {
                    have |= !strcmp(ext[e].extensionName, want[w]);
                }
                printf("      %-40s %s\n", want[w], have ? "yes" : "no");
            }
            free(ext);
            VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
            VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &f13};
            VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12};
            VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f11};
            vkGetPhysicalDeviceFeatures2(devices[i], &f2);
#define F(s, name) printf("      %-44s %s\n", #name, s.name ? "yes" : "no")
            printf("    features the plugin reads:\n");
            F(f2.features, geometryShader); F(f2.features, tessellationShader); F(f2.features, shaderFloat64);
            F(f2.features, textureCompressionBC); F(f2.features, independentBlend); F(f2.features, depthClamp);
            F(f2.features, fillModeNonSolid); F(f2.features, samplerAnisotropy); F(f2.features, shaderInt64);
            F(f2.features, shaderInt16); F(f2.features, fragmentStoresAndAtomics); F(f2.features, multiViewport);
            F(f11, storageBuffer16BitAccess); F(f11, multiview); F(f11, shaderDrawParameters);
            F(f11, samplerYcbcrConversion); F(f11, variablePointers);
            F(f12, bufferDeviceAddress); F(f12, descriptorIndexing); F(f12, runtimeDescriptorArray);
            F(f12, descriptorBindingPartiallyBound); F(f12, descriptorBindingVariableDescriptorCount);
            F(f12, shaderSampledImageArrayNonUniformIndexing); F(f12, descriptorBindingSampledImageUpdateAfterBind);
            F(f12, shaderFloat16); F(f12, shaderInt8); F(f12, storageBuffer8BitAccess); F(f12, timelineSemaphore);
            F(f12, scalarBlockLayout); F(f12, vulkanMemoryModel); F(f12, hostQueryReset); F(f12, samplerMirrorClampToEdge);
            F(f12, separateDepthStencilLayouts); F(f12, imagelessFramebuffer);
            F(f13, dynamicRendering); F(f13, synchronization2); F(f13, maintenance4); F(f13, shaderDemoteToHelperInvocation);
            F(f13, robustImageAccess); F(f13, inlineUniformBlock); F(f13, subgroupSizeControl);
#undef F
        }
    }
    vkDestroyInstance(instance, NULL);
    printf("\n%s\n", count ? "PASS" : "FAIL: no devices");
    return count ? 0 : 1;
}
