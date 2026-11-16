// Lenient mode (stage 5a bring-up; every process since 5d, VGMTL_LENIENT=0 turns it off): a message none of our objects answers is
// logged once (class and selector) and answered by a sink that returns nil / 0, instead of the unrecognized-selector
// abort. One WindowServer start then lists everything the compositor sends that we don't implement yet, rather than one
// crash per selector. respondsToSelector: stays truthful: only -forwardingTargetForSelector: changes, and it is used
// only for a message actually sent. A struct- or float-returning method answered by the sink returns garbage: the log
// line is the to-do list, not a fix.
#import "objects.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface VGNullSink : NSObject
@end

static id vg_nop(id self, SEL _cmd, ...) { return nil; }

@implementation VGNullSink
+ (BOOL)resolveInstanceMethod:(SEL)sel {
    class_addMethod(self, sel, (IMP)vg_nop, "@@:");
    return YES;
}
@end

static VGNullSink *gSink;
static NSMutableSet<NSString *> *gIgnored;

static id vg_forwarding_target(id self, SEL _cmd, SEL sel) {
    // the class's own (or an ancestor's) answer first: MTLIOAccelDevice may forward somewhere real
    Class sup = class_getSuperclass(object_getClass(self));
    IMP superImp = sup ? class_getMethodImplementation(sup, _cmd) : NULL;
    if (superImp && superImp != (IMP)vg_forwarding_target) {
        id t = ((id(*)(id, SEL, SEL))superImp)(self, _cmd, sel);
        if (t) {
            return t;
        }
    }
    NSString *key = [NSString stringWithFormat:@"-[%s %s]", class_getName(object_getClass(self)), sel_getName(sel)];
    BOOL first = NO;
    @synchronized(gIgnored) {
        if (![gIgnored containsObject:key]) {
            [gIgnored addObject:key];
            first = YES;
        }
    }
    if (first) {
        vglog("LENIENT: %s not implemented, answered with nil/0", key.UTF8String);
    }
    return gSink;
}

BOOL vg_lenient(void) {
    static int on = -1;
    if (on < 0) {
        // 5d (app Metal): on in every process, so an app that sends something we don't implement yet logs it and goes
        // on instead of aborting on the unrecognized selector; VGMTL_LENIENT=0 restores the abort (to find the caller).
        const char *e = getenv("VGMTL_LENIENT");
        on = !(e && e[0] == '0');
    }
    return on;
}

// Every class of this bundle whose name starts with VG (the sink excepted) gets the forwarding hook.
void vg_cahook_install(void);

__attribute__((constructor)) static void vg_lenient_install(void) {
    if (!strcmp(getprogname(), "WindowServer")) {
        BOOL vg_windowserver_refused(void);
        void vg_coredisplay_off(const char *why);
        if (vg_windowserver_refused()) {
            vg_coredisplay_off("the accelerator doesn't give this WindowServer Metal");
        }
        vg_cahook_install();   // only with /Library/GPUBundles/VirtioGPUMetal-cahook present
        void vg_coredisplay_report(void);
        vg_coredisplay_report();   // now, and again once the displays are up
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
            vg_coredisplay_report();
        });
    }
    if (!vg_lenient()) {
        return;
    }
    gSink = [VGNullSink new];
    gIgnored = [NSMutableSet set];
    Dl_info di;
    if (!dladdr((const void *)vg_lenient_install, &di)) {
        return;
    }
    unsigned n = 0;
    const char **names = objc_copyClassNamesForImage(di.dli_fname, &n);
    unsigned hooked = 0;
    for (unsigned i = 0; i < n; i++) {
        if (strncmp(names[i], "VG", 2) || !strcmp(names[i], "VGNullSink")) {
            continue;
        }
        Class c = objc_getClass(names[i]);
        if (c && class_addMethod(c, @selector(forwardingTargetForSelector:), (IMP)vg_forwarding_target, "@@::")) {
            hooked++;
        }
    }
    free(names);
    vglog("lenient mode on (%s): %u classes answer unknown messages with nil/0 and log them", getprogname(), hooked);
}
