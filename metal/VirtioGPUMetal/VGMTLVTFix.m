// VideoToolbox's reply wait, corrected in this process (0.1.10): a synchronous decode's frame in its own call.
//
// Intel VideoToolbox (26.x) waits for the host's answer to a paravirtualized call in
// VTParavirtualizationReplyClerkWaitForReply: CMTimeGetSeconds(timeout) * 1e9 goes into a 32-bit register (cvttsd2si
// r14d) and on to dispatch_time as movsxd rsi, r14d. A 10 s timeout overflows to a deadline in the past, so the wait
// succeeds only if the answer is already there. VeneraVideo worked around it by holding a synchronous send (inside
// VideoToolbox's send lock) until the answer came; but that lock also keeps VideoToolbox's queue from answering the
// host's frame (Demt), so a synchronous decode's frame always came after its call: the moving wallpaper's still-frame
// loop never had a frame, decoded the whole movie looking for one, and the screen stayed black.
//
// Two same-length edits make the wait 64-bit: cvttsd2si r14, xmm0 (f2 4c 0f 2c f0) and mov rsi, r14 (4c 89 f6). They
// are made only where both instructions are found exactly once, in their context, in this process's VideoToolbox
// (the page becomes this process's own copy; the file on disk is untouched, and Venera boots with AMFI's enforcement
// off). Then this process tells VeneraVideo, by holding a connection of its own type open, that its synchronous
// decodes wait properly: VeneraVideo stops holding them and marks them for venera-videod, which answers them as Apple's
// host does (the frame, its answer from the guest, then the call's answer). The flag file VirtioGPUMetal-novtfix
// leaves VideoToolbox as it is.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <string.h>
#include "vg.h"

BOOL vg_debug_flag(const char *name);

#define kVVTypeWaitsProperly 0x76776678u   // 'vwfx': VeneraVideo's marker client (VeneraVideo.cpp)

static int gFixed;   // 1 once VideoToolbox is corrected in this process
static io_connect_t gMarker;

// the only place of `pat` (with 0x100 as "any byte") in [p, p+n), or NULL when there is none or more than one
static const uint8_t *vg_find_once(const uint8_t *p, size_t n, const uint16_t *pat, size_t pn) {
    const uint8_t *hit = NULL;
    for (size_t i = 0; i + pn <= n; i++) {
        if (p[i] != pat[0]) {
            continue;
        }
        size_t k = 1;
        while (k < pn && (pat[k] == 0x100 || p[i + k] == pat[k])) {
            k++;
        }
        if (k == pn) {
            if (hit) {
                return NULL;
            }
            hit = p + i;
        }
    }
    return hit;
}

static BOOL vg_write_code(uint8_t *at, const uint8_t *bytes, size_t n) {
    vm_address_t page = (vm_address_t)at & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t len = ((vm_address_t)at + n - page + vm_page_size - 1) & ~(vm_size_t)(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, len, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        vglog("vtfix: VideoToolbox's page can't be made writable (%d)", kr);
        return NO;
    }
    memcpy(at, bytes, n);
    kr = vm_protect(mach_task_self(), page, len, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        vglog("vtfix: VideoToolbox's page can't be made executable again (%d)", kr);
    }
    return kr == KERN_SUCCESS;
}

static void vg_vt_fix(const struct mach_header *mh) {
    if (gFixed) {
        return;
    }
    unsigned long size = 0;
    const uint8_t *text = getsectiondata((const struct mach_header_64 *)mh, "__TEXT", "__text", &size);
    if (!text || !size) {
        return;
    }
    // mulsd xmm0, [rip+X]; cvttsd2si r14d, xmm0; lea r13, [rbx+24]
    static const uint16_t conv[] = {0xf2, 0x0f, 0x59, 0x05, 0x100, 0x100, 0x100, 0x100, 0xf2, 0x44, 0x0f, 0x2c, 0xf0,
                                    0x4c, 0x8d, 0x6b, 0x18};
    // mov r13, [rbx]; movsxd rsi, r14d; xor edi, edi; call dispatch_time
    static const uint16_t ext[] = {0x4c, 0x8b, 0x2b, 0x49, 0x63, 0xf6, 0x31, 0xff, 0xe8};
    const uint8_t *a = vg_find_once(text, size, conv, sizeof(conv) / sizeof(*conv));
    if (!a) {
        vglog("vtfix: VideoToolbox's reply wait not found (another macOS build?): left as it is");
        gFixed = -1;
        return;
    }
    const uint8_t *b = vg_find_once(a, 0x100, ext, sizeof(ext) / sizeof(*ext));
    if (!b) {
        vglog("vtfix: VideoToolbox's reply wait didn't match all through: left as it is");
        gFixed = -1;
        return;
    }
    static const uint8_t conv64[] = {0xf2, 0x4c, 0x0f, 0x2c, 0xf0}, mov64[] = {0x4c, 0x89, 0xf6};
    if (!vg_write_code((uint8_t *)a + 8, conv64, sizeof(conv64)) || !vg_write_code((uint8_t *)b + 3, mov64, sizeof(mov64))) {
        gFixed = -1;
        return;
    }
    gFixed = 1;
    // VeneraVideo: this process's synchronous decodes wait properly now (held open for the process's life)
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleVideoToolboxParavirtualizationDriver"));
    if (svc) {
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), kVVTypeWaitsProperly, &gMarker);
        IOObjectRelease(svc);
        vglog("vtfix: VideoToolbox's reply wait corrected; VeneraVideo %s", kr == KERN_SUCCESS ? "told" : "not told (an older one?)");
    } else {
        vglog("vtfix: VideoToolbox's reply wait corrected; no VeneraVideo");
    }
}

static void vg_image_added(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (gFixed || !dladdr(mh, &info) || !info.dli_fname || !strstr(info.dli_fname, "/VideoToolbox.framework/")) {
        return;
    }
    vg_vt_fix(mh);
}

__attribute__((constructor)) static void vg_vt_fix_install(void) {
    if (vg_debug_flag("novtfix")) {
        return;
    }
    // now if VideoToolbox is loaded, else when it is
    _dyld_register_func_for_add_image(vg_image_added);
}
