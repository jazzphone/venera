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
#import "vg.h"
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdio.h>
#import <string.h>


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

void vglog(const char *fmt, ...) {
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

// ---- stage 4b: the objects compute needs (VGMTLCompute.m, VGMTLLibrary.m) ----

- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    return vg_new_buffer(self, length, options, NULL);
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options {
    return vg_new_buffer(self, length, options, bytes);
}
- (id<MTLCommandQueue>)newCommandQueue { return vg_new_queue(self); }
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n { return vg_new_queue(self); }
- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(MTLCommandQueueDescriptor *)d { return vg_new_queue(self); }
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    return vg_new_library(self, (NSData *)data, error);   // dispatch_data_t is an NSData on macOS
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error {
    NSData *d = [NSData dataWithContentsOfURL:url options:0 error:error];
    return d ? vg_new_library(self, d, error) : nil;
}
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)path error:(NSError **)error {
    return [self newLibraryWithURL:[NSURL fileURLWithPath:path] error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f error:(NSError **)error {
    return vg_new_compute_pipeline(self, f, error);
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f
                                                           options:(MTLPipelineOption)o
                                                        reflection:(MTLAutoreleasedComputePipelineReflection *)r
                                                             error:(NSError **)error {
    if (r) {
        *r = nil;
    }
    return vg_new_compute_pipeline(self, f, error);
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d
                                                             options:(MTLPipelineOption)o
                                                          reflection:(MTLAutoreleasedComputePipelineReflection *)r
                                                               error:(NSError **)error {
    if (r) {
        *r = nil;
    }
    return vg_new_compute_pipeline(self, d.computeFunction, error);
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
