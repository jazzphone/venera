// codepeek: read a function's bytes out of a loaded system library (dyld shared cache, no file on disk) and resolve
// what it references, so a crash inside Apple code can be read without developer tools in the guest.
//   codepeek LIBPATH OFFSET LENGTH OUTFILE
// OFFSET is the image offset a crash report gives (imageOffset - symbolLocation = the function's start). Writes the raw
// bytes to OUTFILE (disassemble on the Mac: llvm-objdump -D -b binary -m i386:x86-64 --adjust-vma=OFFSET) and prints
// every RIP-relative load whose target holds a selector (mov reg, [rip+d] of a selref) and every call's target name.
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *name_at(const void *p) {
    Dl_info di;
    static char buf[512];
    if (dladdr(p, &di) && di.dli_sname) {
        snprintf(buf, sizeof(buf), "%s+%ld (%s)", di.dli_sname, (long)((const char *)p - (const char *)di.dli_saddr),
                 strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname);
        return buf;
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: codepeek LIBPATH OFFSET LENGTH OUTFILE\n");
        return 2;
    }
    if (!dlopen(argv[1], RTLD_LAZY)) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    const struct mach_header *mh = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (!strcmp(_dyld_get_image_name(i), argv[1])) {
            mh = _dyld_get_image_header(i);
        }
    }
    if (!mh) {
        fprintf(stderr, "image not found\n");
        return 1;
    }
    unsigned long off = strtoul(argv[2], NULL, 0), len = strtoul(argv[3], NULL, 0);
    const uint8_t *p = (const uint8_t *)mh + off;
    FILE *f = fopen(argv[4], "wb");
    fwrite(p, 1, len, f);
    fclose(f);
    printf("image %p, function at %p (+0x%lx), %lu bytes -> %s\n", (void *)mh, (void *)p, off, len, argv[4]);
    for (unsigned long i = 0; i + 7 <= len; i++) {
        const uint8_t *q = p + i;
        // mov r64, [rip+disp32]: REX.W (48/4c) 8b modrm(00 reg 101)
        if ((q[0] == 0x48 || q[0] == 0x4c) && q[1] == 0x8b && (q[2] & 0xc7) == 0x05) {
            int32_t d;
            memcpy(&d, q + 3, 4);
            const void *target = q + 7 + d;
            const char *n = name_at(target);
            SEL sel = *(SEL const *)target;
            const char *sn = NULL;
            if (sel && (uintptr_t)sel > 0x100000000ULL) {
                // a selref holds a pointer to the selector's C string
                const char *s = (const char *)sel;
                int ok = 1;
                for (int k = 0; k < 3 && ok; k++) {
                    ok = s[k] >= 0x20 && s[k] < 0x7f;
                }
                if (ok) {
                    sn = sel_getName(sel);
                }
            }
            printf("  +0x%lx load [%p]%s%s%s%s\n", off + i, target, n ? " " : "", n ? n : "", sn ? "  sel " : "",
                   sn ? sn : "");
        }
        // call rel32
        if (q[0] == 0xe8 && i + 5 <= len) {
            int32_t d;
            memcpy(&d, q + 1, 4);
            const void *target = q + 5 + d;
            const char *n = name_at(target);
            printf("  +0x%lx call %p %s\n", off + i, target, n ? n : "");
        }
        // call [rip+disp32]
        if (q[0] == 0xff && q[1] == 0x15) {
            int32_t d;
            memcpy(&d, q + 2, 4);
            const void *slot = q + 6 + d;
            const void *target = *(void *const *)slot;
            const char *n = name_at(target);
            printf("  +0x%lx call *%p -> %p %s\n", off + i, slot, target, n ? n : "");
        }
    }
    return 0;
}
