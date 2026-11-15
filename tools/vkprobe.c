// vkprobe: load Mesa's Venus ICD directly (no Vulkan loader) and list what it sees.
//   vkprobe [path/to/libvulkan_virtio.dylib]      (VN_DEBUG=init,result for Venus logs)
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
    }
    vkDestroyInstance(instance, NULL);
    printf("\n%s\n", count ? "PASS" : "FAIL: no devices");
    return count ? 0 : 1;
}
