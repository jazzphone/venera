// Protection options and the responsible process (5b): Core Animation sets -setProtectionOptions: on its command buffers
// (CA::OGL::MetalContext::start_command_buffer) and reads -protectionOptions back from command buffers and textures
// before it encodes; a value that doesn't come back as set reads as a change, and CA flushes its command buffer in the
// middle of a pass (calculate_average_luma then takes its fallback and aborts on a transient surface). The values are
// kept per object (associated objects) and mean nothing to the GPU here.
#import "objects.h"
#import <objc/runtime.h>

static char kProtectionKey, kResponsibleKey, kPurgeKey;

MTLPurgeableState vg_purgeable(id r, MTLPurgeableState state) {
    @synchronized(r) {
        NSNumber *prev = objc_getAssociatedObject(r, &kPurgeKey);
        MTLPurgeableState was = prev ? (MTLPurgeableState)prev.unsignedIntegerValue : MTLPurgeableStateNonVolatile;
        if (state != MTLPurgeableStateKeepCurrent) {
            // Empty (discard the contents) leaves a resource that is volatile and empty; we keep the contents anyway
            objc_setAssociatedObject(r, &kPurgeKey, @(state == MTLPurgeableStateEmpty ? MTLPurgeableStateVolatile : state),
                                     OBJC_ASSOCIATION_RETAIN);
        }
        return was;
    }
}

static uint64_t vg_protection(id self, SEL _cmd) { return [objc_getAssociatedObject(self, &kProtectionKey) unsignedLongLongValue]; }
static void vg_set_protection(id self, SEL _cmd, uint64_t v) {
    objc_setAssociatedObject(self, &kProtectionKey, @(v), OBJC_ASSOCIATION_RETAIN);
}
static int vg_responsible(id self, SEL _cmd) { return [objc_getAssociatedObject(self, &kResponsibleKey) intValue]; }
static void vg_set_responsible(id self, SEL _cmd, int pid) {
    objc_setAssociatedObject(self, &kResponsibleKey, @(pid), OBJC_ASSOCIATION_RETAIN);
}

__attribute__((constructor)) static void vg_protection_install(void) {
    const char *classes[] = {"VGMTLTexture", "VGMTLBuffer", "VGMTLCommandBuffer", "VGMTLHeap"};
    for (size_t i = 0; i < sizeof(classes) / sizeof(*classes); i++) {
        Class c = objc_getClass(classes[i]);
        if (!c) {
            continue;
        }
        class_addMethod(c, @selector(protectionOptions), (IMP)vg_protection, "Q@:");
        class_addMethod(c, @selector(setProtectionOptions:), (IMP)vg_set_protection, "v@:Q");
        class_addMethod(c, sel_registerName("responsibleProcess"), (IMP)vg_responsible, "i@:");
        class_addMethod(c, sel_registerName("setResponsibleProcess:"), (IMP)vg_set_responsible, "v@:i");
    }
}
