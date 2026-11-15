// codepeek: read a function's bytes out of a loaded system library (dyld shared cache, no file on disk) and resolve
// what it references, so a crash inside Apple code can be read without developer tools in the guest.
//   codepeek LIBPATH OFFSET LENGTH OUTFILE
//   codepeek LIBPATH find SUBSTRING          functions of the library whose (mangled) name contains SUBSTRING
//   codepeek LIBPATH sels SUBSTRING          every selector those functions load (unique), with the function
//   codepeek LIBPATH callers OFFSET          the functions of the library that call (call rel32) the one at OFFSET
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
#include <mach-o/getsect.h>

// An objc_msgSend$selector stub (__objc_stubs): "mov rsi, [rip+selref]" (48 8b 35 d32) first, then the jump.
static const uint8_t *gStubs;
static unsigned long gStubsSize;
static const char *stub_selector(const uint8_t *t) {
    if (!gStubs || t < gStubs || t + 7 > gStubs + gStubsSize) {
        return NULL;   // only real stubs: a stray e8 byte would point anywhere
    }
    if (t[0] == 0x48 && t[1] == 0x8b && t[2] == 0x35) {
        int32_t d;
        memcpy(&d, t + 3, 4);
        const char *sn = *(const char *const *)(t + 7 + d);
        if ((uintptr_t)sn > 0x100000000ULL && sel_isMapped((SEL)sn)) {
            return sn;
        }
    }
    return NULL;
}

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
    if (argc < 4 || (argc < 5 && strcmp(argv[2], "find") && strcmp(argv[2], "sels") && strcmp(argv[2], "callers"))) {
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
    gStubs = getsectiondata((const struct mach_header_64 *)mh, "__TEXT", "__objc_stubs", &gStubsSize);
    if (!strcmp(argv[2], "callers")) {
        unsigned long tsize = 0;
        const uint8_t *text = getsectiondata((const struct mach_header_64 *)mh, "__TEXT", "__text", &tsize);
        const uint8_t *want = (const uint8_t *)mh + strtoul(argv[3], NULL, 0);
        for (unsigned long i = 0; text && i + 5 <= tsize; i++) {
            const uint8_t *q = text + i;
            if (q[0] != 0xe8) {
                continue;
            }
            int32_t d;
            memcpy(&d, q + 1, 4);
            if (q + 5 + d == want) {
                const char *n = name_at(q);
                printf("+0x%lx %s\n", (unsigned long)(q - (const uint8_t *)mh), n ? n : "?");
            }
        }
        return 0;
    }
    if (!strcmp(argv[2], "find") || !strcmp(argv[2], "sels")) {
        unsigned long tsize = 0;
        const uint8_t *text = getsectiondata((const struct mach_header_64 *)mh, "__TEXT", "__text", &tsize);
        if (!text) {
            fprintf(stderr, "no __text\n");
            return 1;
        }
        const int sels = !strcmp(argv[2], "sels");
        const void *cur = NULL;
        const char *curname = NULL;
        int match = 0;
        // dladdr each 4 bytes: a new nearest symbol is a new function
        static char seen[1 << 16][96];
        unsigned nseen = 0;
        for (unsigned long i = 0; i + 8 < tsize; i += (sels && match) ? 1 : 4) {
            const uint8_t *q = text + i;
            Dl_info di;
            if ((i & 3) == 0 && dladdr(q, &di) && di.dli_saddr != cur) {
                cur = di.dli_saddr;
                curname = di.dli_sname;
                match = curname && strstr(curname, argv[3]);
                if (match && !sels) {
                    printf("+0x%lx %s\n", (unsigned long)((const uint8_t *)cur - (const uint8_t *)mh), curname);
                }
            }
            if (!sels || !match) {
                continue;
            }
            if (q[0] == 0xe8) {
                int32_t d;
                memcpy(&d, q + 1, 4);
                const char *sn = stub_selector(q + 5 + d);
                if (sn) {
                    int dup = 0;
                    for (unsigned k = 0; k < nseen && !dup; k++) {
                        dup = !strncmp(seen[k], sn, 95);
                    }
                    if (!dup && nseen < (1 << 16)) {
                        strncpy(seen[nseen++], sn, 95);
                        printf("%s\t%s\n", sn, curname);
                    }
                }
            }
            if ((q[0] == 0x48 || q[0] == 0x4c) && q[1] == 0x8b && (q[2] & 0xc7) == 0x05) {
                int32_t d;
                memcpy(&d, q + 3, 4);
                const char *const *target = (const char *const *)(q + 7 + d);
                Dl_info ti;
                // selector references live in __objc_selrefs: a pointer to the selector's name
                if (dladdr(target, &ti) && (uintptr_t)*target > 0x100000000ULL) {
                    const char *sn = *target;
                    int ok = 1;
                    for (int k = 0; k < 2 && ok; k++) {
                        ok = sn[k] >= 0x21 && sn[k] < 0x7f;
                    }
                    if (ok && sel_isMapped((SEL)sn)) {
                        int dup = 0;
                        for (unsigned k = 0; k < nseen && !dup; k++) {
                            dup = !strncmp(seen[k], sn, 95);
                        }
                        if (!dup && nseen < (1 << 16)) {
                            strncpy(seen[nseen++], sn, 95);
                            printf("%s\t%s\n", sn, curname);
                        }
                    }
                }
            }
        }
        return 0;
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
            const char *sn = stub_selector((const uint8_t *)target);
            const uint8_t *tb = (const uint8_t *)target;
            Dl_info tdi;
            // a __stubs entry, "jmp [rip+d]": name what the pointer it jumps through holds
            if (!sn && dladdr(target, &tdi) && tdi.dli_fbase == (void *)mh && tb[0] == 0xff && tb[1] == 0x25) {
                int32_t jd;
                memcpy(&jd, tb + 2, 4);
                target = *(void *const *)(tb + 6 + jd);
            }
            const char *n = name_at(target);
            if (sn) {
                printf("  +0x%lx send [%s]\n", off + i, sn);
            } else {
                printf("  +0x%lx call %p %s\n", off + i, target, n ? n : "");
            }
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
