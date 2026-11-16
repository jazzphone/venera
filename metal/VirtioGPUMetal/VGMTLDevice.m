// VirtioGPUMetal.bundle: the Metal driver plugin for VirtioGPUAccel (stage 4a: the device appears, nothing runs yet).
//
// Metal finds it through the accelerator's MetalPluginName / MetalPluginClassName (published at run time by the
// late arm, `acceltest arm`), allocates VGMTLDevice and calls -initWithAcceleratorPort:. MTLIOAccelDevice (Metal's
// private base class) opens the family's user clients itself. We add the Vulkan side: Mesa's Venus ICD
// (Contents/Resources/libvulkan_virtio.dylib, loaded directly, no Vulkan loader) on the host's GPU.
//
// Allow-list: only listed processes get a device; everyone else gets none, as before the arm. WindowServer gets it only
// when the accelerator says so (VirtioGPUWindowServer = true, published by the kext's own arm at vgpuaccel=4, never by
// the late arm) and the list has no "-WindowServer" line. /Library/GPUBundles/VirtioGPUMetal-allow.txt: one process
// name per line, `*` = all, `-name` = never; mtlprobe is always allowed; VGMTL_ENABLE=1 in the environment allows the
// process.
//
// Shape after nullmoth/nvidia-macos-driver's NVMTLDevice (plugin/NVMTLDevice.m): the refusal before super's init and
// the initLimits call are theirs.
#import "objects.h"
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
    // The file only while it can be had (5d): a sandboxed process (Safari's GPU process) is refused it, and each refusal
    // is a sandbox report of its own.
    static _Atomic int noFile;
    if (noFile) {
        return;
    }
    FILE *f = fopen("/var/tmp/VirtioGPUMetal.log", "a");
    if (f) {
        fprintf(f, "[%d %s] %s\n", getpid(), getprogname(), line);
        fclose(f);
    } else {
        noFile = 1;
    }
}

BOOL vg_calltrace(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("VGMTL_CALLS");
        on = (e && e[0] == '1') || access("/Library/GPUBundles/VirtioGPUMetal-calls", R_OK) == 0;
    }
    return on;
}

void vg_callstack(const char *what) {
    if (!vg_calltrace()) {
        return;
    }
    NSArray<NSString *> *frames = [NSThread callStackSymbols];
    NSMutableString *line = [NSMutableString stringWithFormat:@"STACK %s:", what];
    for (NSUInteger i = 2; i < frames.count && i < 10; i++) {
        // "N  Image  0xaddr  symbol + off" -> "symbol+off"
        NSArray *parts = [frames[i] componentsSeparatedByString:@" "];
        NSMutableArray *words = [NSMutableArray array];
        for (NSString *p in parts) {
            if (p.length) {
                [words addObject:p];
            }
        }
        if (words.count >= 6) {
            [line appendFormat:@" | %@+%@", words[3], words[5]];
        }
    }
    vglog("%s", line.UTF8String);
}

BOOL vg_tracing(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("VGMTL_TRACE");
        on = e && e[0] == '1';
    }
    return on;
}

// ---- allow-list ------------------------------------------------------------------------------------------------

// One line of the allow-list file is exactly `line` (or `*` when star is YES).
static BOOL vg_allow_file_has(const char *name, BOOL star) {
    FILE *f = fopen("/Library/GPUBundles/VirtioGPUMetal-allow.txt", "r");
    if (!f) {
        return NO;
    }
    char line[256];
    BOOL ok = NO;
    while (!ok && fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = 0;
        ok = (star && !strcmp(line, "*")) || !strcmp(line, name);
    }
    fclose(f);
    return ok;
}

static BOOL vg_accel_allows_windowserver(mach_port_t port) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(port, CFSTR("VirtioGPUWindowServer"), kCFAllocatorDefault, 0);
    BOOL yes = v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v);
    if (v) {
        CFRelease(v);
    }
    return yes;
}

// For the guard's fallback (VGMTLCAHook.m): would WindowServer be refused? Asked before any device exists, so it finds
// the accelerator itself.
BOOL vg_windowserver_refused(void) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("VirtioGPUAccel"));
    if (!s) {
        return NO;   // no accelerator: Metal won't load us anyway
    }
    BOOL allowed = vg_accel_allows_windowserver(s) && !vg_allow_file_has("-WindowServer", NO);
    IOObjectRelease(s);
    return !allowed;
}

static BOOL vg_process_allowed(mach_port_t port) {
    const char *me = getprogname();
    if (!strcmp(me, "WindowServer")) {
        BOOL accel = vg_accel_allows_windowserver(port), denied = vg_allow_file_has("-WindowServer", NO);
        vglog("WindowServer asks: accelerator %s, allow-list %s", accel ? "allows it (vgpuaccel=4)" : "does not allow it",
              denied ? "says -WindowServer" : "has no -WindowServer");
        return accel && !denied;
    }
    if (!strcmp(me, "mtlprobe")) {
        return YES;
    }
    const char *e = getenv("VGMTL_ENABLE");
    if (e && e[0] == '1') {
        return YES;
    }
    char deny[260];
    snprintf(deny, sizeof(deny), "-%s", me);
    return !vg_allow_file_has(deny, NO) && vg_allow_file_has(me, YES);
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
    if (!vg_process_allowed(port)) {
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
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options
                               deallocator:(void (^)(void *, NSUInteger))deallocator {
    return vg_new_buffer_nocopy(self, pointer, length, options, deallocator);
}
- (id<MTLCommandQueue>)newCommandQueue { return vg_new_queue(self); }
- (BOOL)supportsSampleCount:(NSUInteger)count {   // 5d: what the host renders color and depth with
    return count == 1 || (gVk.props.limits.framebufferColorSampleCounts & gVk.props.limits.framebufferDepthSampleCounts & count);
}
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n { return vg_new_queue(self); }
- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(MTLCommandQueueDescriptor *)d { return vg_new_queue(self); }
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    return vg_new_library(self, (NSData *)data, error);   // dispatch_data_t is an NSData on macOS
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error {
    NSData *d = [NSData dataWithContentsOfURL:url options:0 error:error];
    return d ? vg_new_library(self, d, error) : nil;
}
// Metal shading language source (5d: ANGLE, i.e. WebGL in Safari and Chrome, writes its shaders as source at run time).
// Apple's base class compiles it (MTLCompilerService) into an Apple library; its container (libraryDataContents, the
// same metallib a file holds) goes through our own loader. After nullmoth/nvidia-macos-driver's
// nvmtlBridgeAppleLibrary (NVMTLDevice.m).
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options error:(NSError **)error {
    if (error) {
        *error = nil;
    }
    struct objc_super sup = {self, class_getSuperclass(object_getClass(self))};
    uint64_t t0 = vg_now();
    id apple = ((id(*)(struct objc_super *, SEL, id, id, NSError **))objc_msgSendSuper)(
        &sup, @selector(newLibraryWithSource:options:error:), source, options, error);
    if (!apple) {
        vglog("newLibraryWithSource: Apple's compiler failed: %s",
              error && *error ? (*error).localizedDescription.UTF8String : "(no reason)");
        return nil;
    }
    SEL contents = sel_registerName("libraryDataContents");
    NSData *container = [apple respondsToSelector:contents] ? ((id(*)(id, SEL))objc_msgSend)(apple, contents) : nil;
    if (![container isKindOfClass:[NSData class]] || container.length < 4) {
        vglog("newLibraryWithSource: Apple's %s has no metallib container", object_getClassName(apple));
        if (error) {
            *error = [NSError errorWithDomain:@"VirtioGPUMetal" code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"newLibraryWithSource: no metallib container"}];
        }
        return nil;
    }
    if (error) {
        *error = nil;   // a warning from Apple's compiler isn't a failure of ours
    }
    id<MTLLibrary> mine = vg_new_library(self, container, error);
    vg_library_set_dylibs(mine, options.libraries);   // its externs link against these (5d: Core Image)
    vglog("newLibraryWithSource: %lu chars -> %lu B container in %.1f ms -> %s", (unsigned long)source.length,
          (unsigned long)container.length, (vg_now() - t0) / 1e6, mine ? "ours" : "FAILED");
    return mine;
}
// Dynamic libraries (5d: Core Image's ci_stdlib).
- (BOOL)supportsDynamicLibraries { return YES; }
- (BOOL)supportsRenderDynamicLibraries { return YES; }
- (id<MTLDynamicLibrary>)newDynamicLibrary:(id<MTLLibrary>)library error:(NSError **)error {
    return vg_new_dynamic_library(library, error);
}
- (id<MTLDynamicLibrary>)newDynamicLibraryWithURL:(NSURL *)url error:(NSError **)error {
    id<MTLLibrary> l = [self newLibraryWithURL:url error:error];
    return l ? vg_new_dynamic_library(l, error) : nil;
}
- (void)newLibraryWithSource:(NSString *)source
                     options:(MTLCompileOptions *)options
           completionHandler:(MTLNewLibraryCompletionHandler)handler {
    NSError *e = nil;
    id<MTLLibrary> lib = [self newLibraryWithSource:source options:options error:&e];
    if (handler) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          handler(lib, lib ? nil : e);
        });
    }
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
// The two-argument form Core Animation's luma pass uses (5c: with transparency on, WindowServer aborted on
// "function=compute_average_luma": MTLIOAccelDevice's own version returned nil without an error).
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d
                                                               error:(NSError **)error {
    return vg_new_compute_pipeline(self, d.computeFunction, error);
}
// Completion-handler forms, answered synchronously (the base class's would not reach our pipelines either).
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)f
                          completionHandler:(MTLNewComputePipelineStateCompletionHandler)handler {
    NSError *e = nil;
    id<MTLComputePipelineState> p = vg_new_compute_pipeline(self, f, &e);
    handler(p, e);
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)f
                                    options:(MTLPipelineOption)o
                          completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)handler {
    NSError *e = nil;
    id<MTLComputePipelineState> p = vg_new_compute_pipeline(self, f, &e);
    handler(p, nil, e);
}
- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d
                                      options:(MTLPipelineOption)o
                            completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)handler {
    NSError *e = nil;
    id<MTLComputePipelineState> p = vg_new_compute_pipeline(self, d.computeFunction, &e);
    handler(p, nil, e);
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
                           completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler {
    NSError *e = nil;
    id<MTLRenderPipelineState> p = [self newRenderPipelineStateWithDescriptor:d error:&e];
    handler(p, e);
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
                                     options:(MTLPipelineOption)o
                           completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler {
    NSError *e = nil;
    id<MTLRenderPipelineState> p = [self newRenderPipelineStateWithDescriptor:d error:&e];
    handler(p, nil, e);
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

// ---- stage 4c: textures and rendering (VGMTLTexture.m, VGMTLRender.m) ----

- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d { return vg_new_texture(self, d); }
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)s plane:(NSUInteger)p {
    return vg_new_surface_texture(self, d, s, p);
}
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d { return vg_new_sampler(self, d); }
- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)d {
    return vg_new_depth_stencil(self, d);
}
- (id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)d { return vg_new_heap(self, d); }
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)d { return vg_heap_texture_size(d); }
- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)o {
    return vg_heap_buffer_size(length);
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error {
    return vg_new_render_pipeline(self, d, error);
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
                                                           options:(MTLPipelineOption)o
                                                        reflection:(MTLAutoreleasedRenderPipelineReflection *)r
                                                             error:(NSError **)error {
    if (r) {
        *r = nil;
    }
    return vg_new_render_pipeline(self, d, error);
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
// Core Animation's capability questions (CA::OGL::new_metal_context), answered here rather than by the base class:
// in WindowServer the base class claimed tile shaders, and CA's calculate_average_luma took its Apple-GPU tile path and
// aborted (5b). We are a Mac2 / Metal3 GPU without tile shading, memoryless targets, framebuffer reads (fetch is
// emulated by copies, slowly) or raster order groups.
static void vg_cap_asked(const char *what, BOOL answer) {
    static NSMutableSet *asked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ asked = [NSMutableSet set]; });
    @synchronized(asked) {
        NSString *k = @(what);
        if ([asked containsObject:k]) {
            return;
        }
        [asked addObject:k];
    }
    vglog("capability %s asked: %s", what, answer ? "YES" : "NO");
}
- (BOOL)supportsTileShaders { vg_cap_asked("supportsTileShaders", NO); return NO; }
- (BOOL)supportsMemorylessRenderTargets { vg_cap_asked("supportsMemorylessRenderTargets", NO); return NO; }
- (BOOL)isFramebufferReadSupported { vg_cap_asked("isFramebufferReadSupported", NO); return NO; }
- (BOOL)supportsRasterOrderGroups { vg_cap_asked("supportsRasterOrderGroups", NO); return NO; }
- (BOOL)areRasterOrderGroupsSupported { return NO; }
- (BOOL)supportsSIMDShuffleAndFill { return NO; }
- (BOOL)supportsYCBCRFormats12 { return NO; }
- (BOOL)supportsYCBCRPackedFormats12 { return NO; }
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
