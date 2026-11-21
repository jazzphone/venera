// xlfc: run the translator on a function's text with function constants, as the Metal driver does, to bring back a
// refusal on the Mac (the text from the faildump or shaderdump flag files). XLFC_LIB names the library: the VM's
// x86_64 build (build/translator/, under Rosetta), or one built for this Mac from the patched copy:
//   (cd build/translator-src/translator/wrapper && CARGO_TARGET_DIR=$PWD/../../../translator-target-arm64 cargo build --release)
//   xlfc FILE.ll vertex|fragment|kernel [INDEX:HEXBYTES ...]
// e.g. xlfc acc.ll fragment 0:01000000020000000000000000000000 (a uint4 at index 0, little-endian words).
// Prints "xlfc: N bytes of SPIR-V" or "xlfc: FAIL <the translator's error>".
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*xl_fn)(const char *, const char *, uint8_t **, size_t *, char *, size_t);
typedef int (*xl_fc_fn)(const char *, const char *, const uint32_t *, const uint32_t *, const uint8_t *const *, size_t,
                        uint8_t **, size_t *, char *, size_t);

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: xlfc FILE.ll STAGE [INDEX:HEXBYTES ...]\n");
        return 2;
    }
    const char *lib = getenv("XLFC_LIB") ? getenv("XLFC_LIB") : "build/translator/libnvmtl_translate.dylib";
    void *h = dlopen(lib, RTLD_NOW);
    if (!h) {
        fprintf(stderr, "xlfc: %s\n", dlerror());
        return 2;
    }
    xl_fn tr = (xl_fn)dlsym(h, "nvmtl_translate");
    xl_fc_fn trfc = (xl_fc_fn)dlsym(h, "nvmtl_translate_fc");
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror(argv[1]);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *ll = malloc(n + 1);
    if (fread(ll, 1, n, f) != (size_t)n) {
        return 2;
    }
    ll[n] = 0;
    fclose(f);
    size_t count = argc - 3;
    uint32_t *idx = calloc(count + 1, 4), *sz = calloc(count + 1, 4);
    const uint8_t **pay = calloc(count + 1, sizeof(*pay));
    for (size_t i = 0; i < count; i++) {
        char *a = argv[3 + i], *colon = strchr(a, ':');
        if (!colon) {
            fprintf(stderr, "xlfc: %s isn't INDEX:HEXBYTES\n", a);
            return 2;
        }
        idx[i] = (uint32_t)strtoul(a, NULL, 0);
        size_t hex = strlen(colon + 1) / 2;
        uint8_t *b = malloc(hex ? hex : 1);
        for (size_t k = 0; k < hex; k++) {
            sscanf(colon + 1 + 2 * k, "%2hhx", &b[k]);
        }
        sz[i] = (uint32_t)hex;
        pay[i] = b;
    }
    uint8_t *out = NULL;
    size_t len = 0;
    char err[4096] = "";
    int r = count ? trfc(ll, argv[2], idx, sz, pay, count, &out, &len, err, sizeof(err))
                  : tr(ll, argv[2], &out, &len, err, sizeof(err));
    if (r || !out) {
        printf("xlfc: FAIL %s\n", err);
        return 1;
    }
    printf("xlfc: %zu bytes of SPIR-V\n", len);
    if (getenv("XLFC_OUT")) {
        FILE *o = fopen(getenv("XLFC_OUT"), "wb");
        fwrite(out, 1, len, o);
        fclose(o);
    }
    return 0;
}
