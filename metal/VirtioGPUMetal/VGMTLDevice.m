// VirtioGPUMetal.bundle: the Metal driver plugin for VirtioGPUAccel (stage 4a: the device appears, nothing runs yet).
//
// Metal finds it through the accelerator's MetalPluginName / MetalPluginClassName (published at run time by the
// late arm, `acceltest arm`), allocates VGMTLDevice and calls -initWithAcceleratorPort:. MTLIOAccelDevice (Metal's
// private base class) opens the family's user clients itself. We add the Vulkan side: Mesa's Venus ICD
// (Contents/Resources/libvulkan_virtio.dylib, loaded directly, no Vulkan loader) on the host's GPU.
//
// Allow-list: only listed processes get a device; everyone else gets none, as before the arm. WindowServer is always
// refused until stage 5a. /Library/GPUBundles/VirtioGPUMetal-allow.txt: one process name per line, `*` = all;
// mtlprobe is always allowed; VGMTL_ENABLE=1 in the environment allows the process.
//
// Shape after nullmoth/nvidia-macos-driver's NVMTLDevice (plugin/NVMTLDevice.m): the refusal before super's init and
// the initLimits call are theirs.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdio.h>
#import <string.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

@interface MTLIOAccelDevice : NSObject
- (instancetype)initWithAcceleratorPort:(mach_port_t)port;
@end

// MTLAddDevice asserts the conformance. Most of the protocol is answered by MTLIOAccelDevice / _MTLDevice; what isn't
// yet lands in -doesNotRecognizeSelector: below (and its log line says which).
@interface VGMTLDevice : MTLIOAccelDevice <MTLDevice>
@end

// ---- log: os_log (subsystem local.homelab.VirtioGPUMetal), stderr when VGMTL_LOG=1, /var/tmp/VirtioGPUMetal.log
// when the process can write it -------------------------------------------------------------------------------------

static os_log_t vglog_handle(void) {
    static os_log_t h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = os_log_create("local.homelab.VirtioGPUMetal", "plugin"); });
    return h;
}

static void vglog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void vglog(const char *fmt, ...) {
    char line[600];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    os_log(vglog_handle(), "%{public}s", line);
    const char *e = getenv("VGMTL_LOG");
    if (e && e[0] == '1') {
        fprintf(stderr, "VirtioGPUMetal[%d %s]: %s\n", getpid(), getprogname(), line);
    }
    FILE *f = fopen("/var/tmp/VirtioGPUMetal.log", "a");
    if (f) {
        fprintf(f, "[%d %s] %s\n", getpid(), getprogname(), line);
        fclose(f);
    }
}

// ---- allow-list ------------------------------------------------------------------------------------------------

static BOOL vg_process_allowed(void) {
    const char *me = getprogname();
    if (!strcmp(me, "WindowServer")) {
        return NO;   // until stage 5a: a refused WindowServer composites in software, as today
    }
    if (!strcmp(me, "mtlprobe")) {
        return YES;
    }
    const char *e = getenv("VGMTL_ENABLE");
    if (e && e[0] == '1') {
        return YES;
    }
    FILE *f = fopen("/Library/GPUBundles/VirtioGPUMetal-allow.txt", "r");
    if (!f) {
        return NO;
    }
    char line[256];
    BOOL ok = NO;
    while (!ok && fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = 0;
        ok = !strcmp(line, "*") || !strcmp(line, me);
    }
    fclose(f);
    return ok;
}

// A refusal before [super initWithAcceleratorPort:] must not free the object: under ARC returning nil releases self,
// and -[_MTLDevice dealloc] then releases dispatch objects only super's init creates (NV measured the crash inside
// MTLCopyAllDevices). Keep the uninitialized object instead; after super's init a plain nil is safe.
static id vg_refuse_before_init(id obj) {
    (void)CFBridgingRetain(obj);
    return nil;
}

// ---- Venus ---------------------------------------------------------------------------------------------------------

typedef PFN_vkVoidFunction(VKAPI_PTR *PFN_icdGetInstanceProcAddr)(VkInstance, const char *);
typedef VkResult(VKAPI_PTR *PFN_negotiate)(uint32_t *version);

static struct {
    int state;   // 0 not tried, 1 up, -1 failed
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkPhysicalDeviceProperties props;
    uint32_t queueFamily;
} gVk;

static int vg_vulkan_init(void) {
    if (gVk.state) {
        return gVk.state > 0 ? 0 : -1;
    }
    gVk.state = -1;
    Dl_info info;
    if (!dladdr((const void *)vg_vulkan_init, &info) || !info.dli_fname) {
        vglog("vulkan: can't find my own image");
        return -1;
    }
    // .../VirtioGPUMetal.bundle/Contents/MacOS/VirtioGPUMetal -> .../Contents/Resources/libvulkan_virtio.dylib
    char path[1024];
    snprintf(path, sizeof(path), "%s", info.dli_fname);
    char *slash = strrchr(path, '/');
    if (slash) {
        *slash = 0;
    }
    slash = strrchr(path, '/');
    if (slash) {
        *slash = 0;
    }
    strlcat(path, "/Resources/libvulkan_virtio.dylib", sizeof(path));
    void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        vglog("vulkan: dlopen %s: %s", path, dlerror());
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
#define GET(name) PFN_##name name = (PFN_##name)gipa(gVk.instance, #name)
    GET(vkEnumeratePhysicalDevices);
    GET(vkGetPhysicalDeviceProperties);
    GET(vkGetPhysicalDeviceQueueFamilyProperties);
    GET(vkCreateDevice);
#undef GET
    VkPhysicalDevice devs[8];
    uint32_t n = 8;
    r = vkEnumeratePhysicalDevices(gVk.instance, &n, devs);
    if (r < 0 || !n) {
        vglog("vulkan: vkEnumeratePhysicalDevices %d, %u devices", r, n);
        return -1;
    }
    // The host's GPU, not llvmpipe (Venus lists both).
    for (uint32_t i = 0; i < n && !gVk.physical; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(devs[i], &p);
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
    vkGetPhysicalDeviceQueueFamilyProperties(gVk.physical, &qn, qf);
    gVk.queueFamily = UINT32_MAX;
    for (uint32_t q = 0; q < qn; q++) {
        if ((qf[q].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) == (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) {
            gVk.queueFamily = q;
            break;
        }
    }
    if (gVk.queueFamily == UINT32_MAX) {
        vglog("vulkan: no graphics+compute queue family");
        return -1;
    }
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, gVk.queueFamily, 1, &prio};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &qci, 0, NULL, 0, NULL, NULL};
    r = vkCreateDevice(gVk.physical, &dci, NULL, &gVk.device);
    if (r != VK_SUCCESS) {
        vglog("vulkan: vkCreateDevice %d", r);
        return -1;
    }
    vglog("vulkan: %s (vendor %04x device %04x, API %u.%u.%u), queue family %u, VkDevice up", gVk.props.deviceName,
          gVk.props.vendorID, gVk.props.deviceID, VK_VERSION_MAJOR(gVk.props.apiVersion),
          VK_VERSION_MINOR(gVk.props.apiVersion), VK_VERSION_PATCH(gVk.props.apiVersion), gVk.queueFamily);
    gVk.state = 1;
    return 0;
}

// ---- the device ----------------------------------------------------------------------------------------------------

@implementation VGMTLDevice
// Properties the base class implements (NV's list, NVMTLDevice.m): no ivars or accessors of ours.
@dynamic depth24Stencil8PixelFormatSupported, headless, location, locationNumber, lowPower,
    maxArgumentBufferSamplerCount, maxTransferRate, peerCount, peerGroupID, peerIndex, registryID, removable,
    sparseTileSizeInBytes, supportsPlacementSparse;

+ (void)load {
    // MTLAddDevice asserts MTLDeviceSPI too, Metal's private protocol (no header): adopt the runtime's own object.
    Protocol *spi = objc_getProtocol("MTLDeviceSPI");
    BOOL added = spi && class_addProtocol(self, spi);
    vglog("VGMTLDevice +load (MTLDeviceSPI %s)", spi ? (added ? "adopted" : "already adopted") : "NOT FOUND");
}

- (instancetype)initWithAcceleratorPort:(mach_port_t)port {
    vglog("initWithAcceleratorPort:%u", port);
    if (!port || !IOObjectConformsTo(port, "VirtioGPUAccel")) {
        vglog("  not a VirtioGPUAccel: no device");
        return vg_refuse_before_init(self);
    }
    if (!vg_process_allowed()) {
        vglog("  not allow-listed: no device for %s", getprogname());
        return vg_refuse_before_init(self);
    }
    self = [super initWithAcceleratorPort:port];
    if (!self) {
        vglog("  -[MTLIOAccelDevice initWithAcceleratorPort:] returned nil");
        return nil;
    }
    vglog("  MTLIOAccelDevice init -> %p", (__bridge void *)self);
    if (vg_vulkan_init()) {
        vglog("  Venus didn't come up: no device");
        return nil;
    }
    SEL il = sel_registerName("initLimits");
    if ([self respondsToSelector:il]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(self, il);
            vglog("  initLimits done");
        } @catch (NSException *e) {
            vglog("  initLimits threw %s: %s", e.name.UTF8String, e.reason.UTF8String);
            return nil;
        }
    } else {
        vglog("  no -initLimits: table-served limits stay 0");
    }
    return self;
}

- (NSString *)name {
    if (gVk.state > 0) {
        return [NSString stringWithFormat:@"%s (VirtioGPUMetal)", gVk.props.deviceName];
    }
    return @"Virtio-GPU (VirtioGPUMetal)";
}

- (NSString *)vendorName {
    return @"Virtio";
}

// Metal's compute limit, from Vulkan's (Metal's own ceiling is 1024 threads per threadgroup).
- (MTLSize)maxThreadsPerThreadgroup {
    if (gVk.state <= 0) {
        return MTLSizeMake(1, 1, 1);
    }
    const VkPhysicalDeviceLimits *l = &gVk.props.limits;
    return MTLSizeMake(MIN(l->maxComputeWorkGroupSize[0], 1024u), MIN(l->maxComputeWorkGroupSize[1], 1024u),
                       MIN(l->maxComputeWorkGroupSize[2], 1024u));
}

// What -[_MTLDevice initLimits] and the base class ask a vendor device (the values NV's NVMTLDevice_contract.m gives).
- (NSUInteger)featureProfile { return 10002; }
- (NSUInteger)doubleFPConfig { return 0; }
- (NSUInteger)halfFPConfig { return 0; }
- (NSUInteger)singleFPConfig { return 0; }
- (NSUInteger)getTimestampFrequency { return 1000000000ULL; }
- (BOOL)isDepth24Stencil8PixelFormatSupported { return YES; }
- (BOOL)metalAssertionsEnabled { return NO; }
- (void)setMetalAssertionsEnabled:(BOOL)on { }
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(MTLPixelFormat)format { return 256; }
- (NSUInteger)resourcePatchingTypeForResourceType:(NSUInteger)type { return 0; }
- (void)receive:(id)what { }
- (void)reserveResourceIndicesForResourceType:(NSUInteger)type indices:(NSUInteger *)indices indexCount:(NSUInteger)count { }

// Anything else the base class or a caller sends that we don't answer yet: logged once per selector, then the normal
// unrecognized-selector exception.
- (void)doesNotRecognizeSelector:(SEL)sel {
    vglog("  unanswered selector: %s", sel_getName(sel));
    [super doesNotRecognizeSelector:sel];
}

@end
