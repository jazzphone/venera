// Core Animation surface probe (5b bring-up, off unless /Library/GPUBundles/VirtioGPUMetal-cahook exists).
//
// WindowServer aborts in CA::OGL::Context::push_surface ("transient surface %p not found", ogl-context.cpp:1186): a
// surface isn't in the context's list (ctx+0x58 / +0x60, chosen by bit 10 of the surface's word at +0x5c) when it is
// pushed. To see the surface's life, this replaces slots of CA::OGL::MetalContext's vtable with wrappers that log the
// call (context, first argument, result, the surface's words at +0x5c and +0x90) and call the original. The slot
// offsets are macOS 26.7.3 (25G342) QuartzCore's, found with `codepeek QuartzCore vtable 0x23ee1c`; every slot is
// checked to hold the expected function before it is touched, so another build is left alone.
#import "objects.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <errno.h>

typedef uint64_t (*vg_fn6)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

typedef struct {
    const char *name;
    unsigned long slot;   // image offset of the vtable slot
    unsigned long fn;     // image offset of the function it must hold
    int argSurface;       // which argument (1-based after this) is a Surface *, 0 = none
    int retSurface;       // the result is a Surface *
} vg_hook;

static const vg_hook kHooks[] = {
    {"collect", 0x33ca0a10, 0x062b96, 0, 0},
    {"purge", 0x33ca0a18, 0x23d4e6, 0, 0},
    {"create_surface", 0x33ca0bc0, 0x16cefc, 0, 1},
    {"create_surface_with_properties", 0x33ca0bc8, 0x23ee1c, 0, 1},
    {"create_surface_from_texture", 0x33ca0bd8, 0x240654, 0, 1},
    {"create_surface_from_iosurface", 0x33ca0be0, 0x24080c, 0, 1},
    {"create_reinterpreted_surface", 0x33ca0be8, 0x240d38, 1, 1},
    {"reuse_surface", 0x33ca0bf8, 0x0b71da, 1, 1},
    {"extend_surface", 0x33ca0c00, 0x2410e0, 1, 1},
    {"create_null_surface", 0x33ca0c20, 0x241a50, 0, 1},
    {"finalize_surface", 0x33ca0c28, 0x0649e6, 1, 0},
    {"set_surface", 0x33ca0c60, 0x05c498, 1, 0},
    {"set_surface_volatile", 0x33ca0c70, 0x07b48a, 1, 0},
    {"get_surface", 0x33ca0d00, 0x244de2, 0, 1},
};
enum { kNHooks = sizeof(kHooks) / sizeof(kHooks[0]) };
static vg_fn6 gOrig[kNHooks];
static volatile int32_t gEvents;

static void vg_hook_log(int i, uint64_t self, uint64_t a1, uint64_t a2, uint64_t r) {
    if (__atomic_add_fetch(&gEvents, 1, __ATOMIC_RELAXED) > 4000) {
        return;
    }
    const vg_hook *h = &kHooks[i];
    uint64_t s = h->retSurface ? r : (h->argSurface == 1 ? a1 : h->argSurface == 2 ? a2 : 0);
    uint32_t w5c = 0, w90 = 0;
    if (s > 0x100000000ULL) {
        w5c = *(const volatile uint32_t *)(s + 0x5c);
        w90 = *(const volatile uint32_t *)(s + 0x90);
    }
    vglog("CA %s ctx %llx a1 %llx a2 %llx -> %llx | surface %llx +5c %08x (list %u) +90 %08x", h->name,
          (unsigned long long)self, (unsigned long long)a1, (unsigned long long)a2, (unsigned long long)r,
          (unsigned long long)s, w5c, (w5c >> 10) & 1, w90);
}

#define VG_HOOK(n)                                                                                                 \
    static uint64_t vg_hook_##n(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f) {          \
        uint64_t r = gOrig[n](a, b, c, d, e, f);                                                                   \
        vg_hook_log(n, a, b, c, r);                                                                                \
        return r;                                                                                                  \
    }
VG_HOOK(0) VG_HOOK(1) VG_HOOK(2) VG_HOOK(3) VG_HOOK(4) VG_HOOK(5) VG_HOOK(6) VG_HOOK(7) VG_HOOK(8) VG_HOOK(9)
VG_HOOK(10) VG_HOOK(11) VG_HOOK(12) VG_HOOK(13)
// (no functions with float or stack arguments: the wrappers pass six integer registers through)
static const vg_fn6 kWrappers[kNHooks] = {vg_hook_0, vg_hook_1, vg_hook_2,  vg_hook_3,  vg_hook_4,  vg_hook_5,  vg_hook_6,
                                          vg_hook_7, vg_hook_8, vg_hook_9, vg_hook_10, vg_hook_11, vg_hook_12, vg_hook_13};

void vg_cahook_install(void) {
    if (access("/Library/GPUBundles/VirtioGPUMetal-cahook", R_OK) != 0) {
        return;
    }
    const char *qc = "/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore";
    const uint8_t *base = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (!strcmp(_dyld_get_image_name(i), qc)) {
            base = (const uint8_t *)_dyld_get_image_header(i);
        }
    }
    if (!base) {
        vglog("cahook: QuartzCore isn't loaded");
        return;
    }
    int installed = 0;
    for (int i = 0; i < kNHooks; i++) {
        void **slot = (void **)(base + kHooks[i].slot);
        if (*slot != (void *)(base + kHooks[i].fn)) {
            vglog("cahook: slot %s holds %p, not +0x%lx: another QuartzCore build, not hooking", kHooks[i].name, *slot,
                  kHooks[i].fn);
            continue;
        }
        vm_address_t page = (vm_address_t)slot & ~(vm_address_t)(vm_page_size - 1);
        kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            vglog("cahook: vm_protect %s: 0x%x", kHooks[i].name, kr);
            continue;
        }
        gOrig[i] = (vg_fn6)*slot;
        *slot = (void *)kWrappers[i];
        vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ);
        installed++;
    }
    vglog("cahook: %d of %d CA::OGL::MetalContext slots wrapped", installed, (int)kNHooks);
    void vg_cahook_inline(const uint8_t *base);
    vg_cahook_inline(base);
}

// ---- inline hooks on non-virtual CA::OGL functions (same flag) -------------------------------------------------
// The function's first instructions (only the plain prologue forms below are accepted) are copied into a trampoline
// that jumps back past them; the function's start becomes "jmp [rip+0]; .quad wrapper". The wrappers log and call the
// trampoline. Six integer arguments, as above.

static size_t vg_insn_len(const uint8_t *p) {
    if (p[0] >= 0x50 && p[0] <= 0x57) return 1;                                          // push reg
    if (p[0] == 0x41 && p[1] >= 0x50 && p[1] <= 0x57) return 2;                          // push r8-r15
    if ((p[0] & 0xf0) == 0x40 && p[1] == 0x89 && (p[2] & 0xc0) == 0xc0) return 3;        // mov reg, reg
    if (p[0] == 0x48 && p[1] == 0x83 && p[2] == 0xec) return 4;                          // sub rsp, imm8
    if (p[0] == 0x48 && p[1] == 0x81 && p[2] == 0xec) return 7;                          // sub rsp, imm32
    return 0;
}

typedef struct {
    const char *name;
    unsigned long fn;   // image offset
    int surfaceArg;     // 1-based argument after this that is a Surface *, 0 none
    int onlyTransient;  // log only when that surface is on the transient list (bit 10 of +0x5c)
} vg_ihook;
static const vg_ihook kIHooks[] = {
    {"Context::release_surface", 0x64648, 1, 0},
    {"Context::release_surface_async", 0xc8f88, 1, 0},
    {"Context::add_transient_render_texture", 0x1717a4, 0, 0},
    {"Context::push_surface", 0x16e188, 1, 1},
    {"FlattenNode::retain_surface", 0x27b402, 0, 0},
};
enum { kNIHooks = sizeof(kIHooks) / sizeof(kIHooks[0]) };
static vg_fn6 gTramp[kNIHooks];
static const uint8_t *gQC;

static void vg_ihook_log(int i, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t r, void *ret) {
    const vg_ihook *h = &kIHooks[i];
    uint64_t s = h->surfaceArg == 1 ? b : h->surfaceArg == 2 ? c : 0;
    uint32_t w5c = s > 0x100000000ULL ? *(const volatile uint32_t *)(s + 0x5c) : 0;
    if (h->onlyTransient && !(w5c & 0x400)) {
        return;
    }
    if (__atomic_add_fetch(&gEvents, 1, __ATOMIC_RELAXED) > 6000) {
        return;
    }
    vglog("CA %s this %llx args %llx %llx %llx -> %llx | surface %llx +5c %08x | from +0x%lx", h->name,
          (unsigned long long)a, (unsigned long long)b, (unsigned long long)c, (unsigned long long)d,
          (unsigned long long)r, (unsigned long long)s, w5c, (unsigned long)((const uint8_t *)ret - gQC));
}

// push_surface's own lookup (QuartzCore 25G342, CA::OGL::Context::push_surface): list head at ctx+0x58 or +0x60
// (bit 10 of the surface's +0x5c word), next pointer at +0x10. A miss is what aborts: say so first, with the stack.
static void vg_push_check(uint64_t ctx, uint64_t s) {
    if (s < 0x100000000ULL || ctx < 0x100000000ULL) {
        return;
    }
    uint32_t w5c = *(const volatile uint32_t *)(s + 0x5c);
    uint64_t idx = (w5c >> 7) & 8;
    uint64_t p = *(const volatile uint64_t *)(ctx + 0x58 + idx);
    int hops = 0;
    while (p && p != s && hops++ < 100000) {
        p = *(const volatile uint64_t *)(p + 0x10);
    }
    if (p == s) {
        return;
    }
    vglog("CA push_surface MISS ctx %llx surface %llx +5c %08x +90 %08x list %llu head %llx other-list head %llx",
          (unsigned long long)ctx, (unsigned long long)s, w5c, *(const volatile uint32_t *)(s + 0x90),
          (unsigned long long)idx / 8, (unsigned long long)*(const volatile uint64_t *)(ctx + 0x58 + idx),
          (unsigned long long)*(const volatile uint64_t *)(ctx + 0x58 + (8 - idx)));
    NSArray<NSString *> *frames = [NSThread callStackSymbols];
    for (NSUInteger i = 1; i < frames.count && i < 24; i++) {
        vglog("CA   %s", frames[i].UTF8String);
    }
}

#define VG_IHOOK(n)                                                                                                \
    static uint64_t vg_ihook_##n(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f) {         \
        void *ret = __builtin_return_address(0);                                                                   \
        if (kIHooks[n].onlyTransient) {                                                                            \
            vg_push_check(a, b);                                                                                   \
        }                                                                                                          \
        if (kIHooks[n].onlyTransient || kIHooks[n].surfaceArg) {                                                   \
            vg_ihook_log(n, a, b, c, d, 0, ret);   /* before: the surface may be gone after */                      \
        }                                                                                                          \
        uint64_t r = gTramp[n](a, b, c, d, e, f);                                                                  \
        if (!kIHooks[n].onlyTransient && !kIHooks[n].surfaceArg) {                                                 \
            vg_ihook_log(n, a, b, c, d, r, ret);                                                                   \
        }                                                                                                          \
        return r;                                                                                                  \
    }
VG_IHOOK(0) VG_IHOOK(1) VG_IHOOK(2) VG_IHOOK(3) VG_IHOOK(4)
static const vg_fn6 kIWrappers[kNIHooks] = {vg_ihook_0, vg_ihook_1, vg_ihook_2, vg_ihook_3, vg_ihook_4};

void vg_cahook_inline(const uint8_t *base) {
    gQC = base;
    uint8_t *tramps = mmap(NULL, vm_page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (tramps == MAP_FAILED) {
        vglog("cahook: no trampoline page");
        return;
    }
    // 1. trampolines, made executable before any function jumps to them
    size_t len[kNIHooks] = {0};
    for (int i = 0; i < kNIHooks; i++) {
        uint8_t *fn = (uint8_t *)base + kIHooks[i].fn;
        size_t n = 0;
        while (n < 14) {
            size_t l = vg_insn_len(fn + n);
            if (!l) {
                break;
            }
            n += l;
        }
        if (n < 14) {
            vglog("cahook: %s starts with an instruction we don't relocate (+%zu): not hooked", kIHooks[i].name, n);
            continue;
        }
        uint8_t *t = tramps + 64 * i;
        memcpy(t, fn, n);
        t[n] = 0xff, t[n + 1] = 0x25, memset(t + n + 2, 0, 4);   // jmp [rip+0]
        uint64_t back = (uint64_t)(fn + n);
        memcpy(t + n + 6, &back, 8);
        gTramp[i] = (vg_fn6)t;
        len[i] = n;
    }
    if (mprotect(tramps, vm_page_size, PROT_READ | PROT_EXEC) != 0) {
        vglog("cahook: trampolines not executable (errno %d): no inline hooks", errno);
        return;
    }
    // 2. the jumps
    int installed = 0;
    for (int i = 0; i < kNIHooks; i++) {
        size_t n = len[i];
        if (!n) {
            continue;
        }
        uint8_t *fn = (uint8_t *)base + kIHooks[i].fn;
        uint8_t patch[32];
        memset(patch, 0x90, sizeof(patch));
        patch[0] = 0xff, patch[1] = 0x25, memset(patch + 2, 0, 4);
        uint64_t to = (uint64_t)kIWrappers[i];
        memcpy(patch + 6, &to, 8);
        vm_address_t page = (vm_address_t)fn & ~(vm_address_t)(vm_page_size - 1);
        vm_size_t span = ((vm_address_t)fn + n - page + vm_page_size - 1) & ~(vm_address_t)(vm_page_size - 1);
        kern_return_t kr = vm_protect(mach_task_self(), page, span, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            vglog("cahook: vm_protect text for %s: 0x%x", kIHooks[i].name, kr);
            continue;
        }
        memcpy(fn, patch, n);
        kr = vm_protect(mach_task_self(), page, span, false, VM_PROT_READ | VM_PROT_EXECUTE);
        if (kr != KERN_SUCCESS) {
            vglog("cahook: making %s executable again: 0x%x", kIHooks[i].name, kr);
        }
        installed++;
    }
    vglog("cahook: %d of %d inline hooks", installed, (int)kNIHooks);
}

// ---- CoreDisplay's IOPresentment switch (5b) ----------------------------------------------------------------
// CoreDisplay::UseIOPresentment() (25G342, CoreDisplay+0xb6f0): a global bool at +0x3e78b94d, then once a required
// mask (+0x3e790c84) that four flags must cover: +0x3e78b94e (x2), +0x3e78c261 (x8), +0x3e78c262 (x4), +0x3e78c263
// (x16). If either fails, displays take the legacy display-surface path and WindowServer composites them with
// CompositorSW. Logged from WindowServer a few seconds after the plugin loads. Only read: calling
// CoreDisplay_UseIOPresentment() here would compute the mask early and clear the global for good when it fails.
// The mask is the GPU vendors of the IOFramebuffer services, from their class names (GetGPUVendorForFramebufferService,
// +0xdf3f9: "Intel" 2, "AMD" 4, "NVDA" 8, "AppleParavirt" 0x10, anything else 1, and bit 1 is dropped).
void vg_coredisplay_report(void) {
    const char *cd = "/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay";
    const uint8_t *base = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (!strcmp(_dyld_get_image_name(i), cd)) {
            base = (const uint8_t *)_dyld_get_image_header(i);
        }
    }
    if (!base || base[0xb6f0] != 0x80 || base[0xb6f1] != 0x3d) {
        vglog("coredisplay: not the 25G342 layout (or not loaded): no report");
        return;
    }
    vglog("coredisplay: UseIOPresentment global %u, vendor mask 0x%x (once %s), flags b94e %u c261 %u c262 %u c263 %u",
          base[0x3e78b94d], *(const uint32_t *)(base + 0x3e790c84),
          *(const int64_t *)(base + 0x3e790c88) == -1 ? "done" : "not yet", base[0x3e78b94e], base[0x3e78c261],
          base[0x3e78c262], base[0x3e78c263]);
}
