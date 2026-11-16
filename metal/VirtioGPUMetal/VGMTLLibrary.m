// Shader libraries: a .metallib's AIR bitcode -> LLVM IR text (Apple's own LLVM in GPUCompiler.framework, dyld
// cache) -> SPIR-V + reflection (NV's metal2vulkan wrapper, Contents/Resources/libnvmtl_translate.dylib, LGPL).
// The path is NV's (plugin/NVMTLLibraryLoad.m): bitcode blobs found by their wrapper magic, entry name and stage from
// the !air.kernel / !air.vertex / !air.fragment metadata.
#import "vg.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// ---- Apple's LLVM ----------------------------------------------------------------------------------------------

static void *(*pLLVMContextCreate)(void);
static void (*pLLVMContextDispose)(void *);
static void *(*pLLVMCreateMemoryBufferWithMemoryRangeCopy)(const char *, size_t, const char *);
static void (*pLLVMDisposeMemoryBuffer)(void *);
static int (*pLLVMParseBitcodeInContext2)(void *, void *, void **);
static char *(*pLLVMPrintModuleToString)(void *);
static void (*pLLVMDisposeModule)(void *);
static void (*pLLVMDisposeMessage)(char *);

static BOOL vg_llvm_ready(void) {
    static dispatch_once_t once;
    static BOOL ready;
    dispatch_once(&once, ^{
        const char *path = "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib";
        void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            vglog("library: no LLVM: %s", dlerror());
            return;
        }
#define LOAD(name)                                                                                                  \
    p##name = dlsym(h, #name);                                                                                      \
    if (!p##name) {                                                                                                 \
        vglog("library: LLVM lacks " #name);                                                                        \
        return;                                                                                                     \
    }
        LOAD(LLVMContextCreate) LOAD(LLVMContextDispose) LOAD(LLVMCreateMemoryBufferWithMemoryRangeCopy)
        LOAD(LLVMDisposeMemoryBuffer) LOAD(LLVMParseBitcodeInContext2) LOAD(LLVMPrintModuleToString)
        LOAD(LLVMDisposeModule) LOAD(LLVMDisposeMessage)
#undef LOAD
        ready = YES;
    });
    return ready;
}

// The translator folds function constants by evaluating the module's air.static_init text, and that evaluator (like
// its other constant-space readers) knows only opaque-pointer loads and stores: `load i32, ptr addrspace(2) @g`. Apple's
// LLVM prints typed pointers (`load i32, i32 addrspace(2)* @g`), so values computed there -- RenderBox's render target
// index and argument predicates, all derived from its _shader_state constant -- weren't folded. Loads and stores of a
// scalar or vector straight from or to a constant-space global are spelled the opaque way (5d); nothing else changes.
static NSString *vg_opaque_constant_access(NSString *ll) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      re = [NSRegularExpression regularExpressionWithPattern:@", (?:<[0-9]+ x [a-z0-9]+>|i[0-9]+|half|float|double) addrspace\\(2\\)\\* @"
                                                     options:0 error:NULL];
    });
    if ([ll rangeOfString:@"addrspace(2)* @"].location == NSNotFound) {
        return ll;
    }
    return [re stringByReplacingMatchesInString:ll options:0 range:NSMakeRange(0, ll.length)
                                   withTemplate:@", ptr addrspace(2) @"];
}
static NSString *vg_air_to_text_typed(NSData *air);
NSString *vg_air_to_text(NSData *air) {
    NSString *t = vg_air_to_text_typed(air);
    static int on = -1;
    if (on < 0) {
        on = access("/Library/GPUBundles/VirtioGPUMetal-typedconst", F_OK) != 0;   // the flag file turns it off
    }
    return on && t ? vg_opaque_constant_access(t) : t;
}
static NSString *vg_air_to_text_typed(NSData *air) {
    if (!vg_llvm_ready()) {
        return nil;
    }
    void *ctx = pLLVMContextCreate();
    void *buf = pLLVMCreateMemoryBufferWithMemoryRangeCopy(air.bytes, air.length, "vgmtl-air");
    void *module = NULL;
    NSString *text = nil;
    if (buf && !pLLVMParseBitcodeInContext2(ctx, buf, &module) && module) {
        char *s = pLLVMPrintModuleToString(module);
        if (s) {
            text = @(s);
            pLLVMDisposeMessage(s);
        }
        pLLVMDisposeModule(module);
    } else {
        vglog("library: LLVM couldn't read a %lu-byte bitcode blob", (unsigned long)air.length);
    }
    if (buf) {
        pLLVMDisposeMemoryBuffer(buf);   // ParseBitcodeInContext2 doesn't take ownership
    }
    pLLVMContextDispose(ctx);
    return text;
}

// ---- the translator ------------------------------------------------------------------------------------------------

typedef int (*xl_fn)(const char *, const char *, uint8_t **, size_t *, char *, size_t);
typedef int (*xl_fc_fn)(const char *, const char *, const uint32_t *, const uint32_t *, const uint8_t *const *, size_t,
                        uint8_t **, size_t *, char *, size_t);
static xl_fn pTranslate, pReflect;
static xl_fc_fn pTranslateFC, pReflectFC;
// One translation per function whatever its function constants (5d): nvmtl_translate_spec makes a module whose function
// constants are specialization constants (plus a table of them), nvmtl_spec_apply fixes one set of values in it in a
// single pass. WebKit's canvas fragment shader has 60 constants and took 5-8 s for each new combination.
typedef int (*xl_spec_fn)(const char *, const char *, uint8_t **, size_t *, uint8_t **, size_t *, char *, size_t);
typedef int (*xl_spec_apply_fn)(const uint8_t *, size_t, const uint8_t *, size_t, const uint32_t *, const uint32_t *,
                                const uint8_t *const *, size_t, uint8_t **, size_t *, char *, size_t);
static xl_spec_fn pTranslateSpec;
static xl_spec_apply_fn pSpecApply;
static void (*pTranslateFree)(uint8_t *, size_t);
static void (*pSetSamples)(uint32_t);   // nvmtl_translate_set_raster_sample_count (5d)
static void (*pSetTgLengths)(const uint32_t *, uint32_t);

static BOOL vg_translator_ready(void) {
    static dispatch_once_t once;
    static BOOL ready;
    dispatch_once(&once, ^{
        // Per-slot descriptors (texture n at binding 32+n), not NV's bindless heap (set 2, indexed through a table at
        // binding 640) the translator emits by default; the variable is read once, at its first translation.
        setenv("NVMTL_NO_BINDLESS_ALL", "1", 1);
        NSString *path = vg_resource_path("libnvmtl_translate.dylib");
        void *h = path ? dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL) : NULL;
        if (!h) {
            vglog("library: no translator: %s", dlerror());
            return;
        }
        pTranslate = (xl_fn)dlsym(h, "nvmtl_translate");
        pReflect = (xl_fn)dlsym(h, "nvmtl_reflect");
        pTranslateFree = dlsym(h, "nvmtl_translate_free");
        pTranslateFC = (xl_fc_fn)dlsym(h, "nvmtl_translate_fc");
        pReflectFC = (xl_fc_fn)dlsym(h, "nvmtl_reflect_fc");
        pSetTgLengths = dlsym(h, "nvmtl_translate_set_threadgroup_lengths");
        pSetSamples = dlsym(h, "nvmtl_translate_set_raster_sample_count");   // optional
        pTranslateSpec = (xl_spec_fn)dlsym(h, "nvmtl_translate_spec");   // optional
        pSpecApply = (xl_spec_apply_fn)dlsym(h, "nvmtl_spec_apply");
        void (*setCaps)(uint32_t) = dlsym(h, "nvmtl_translate_set_caps");
        ready = pTranslate && pReflect && pTranslateFree && pSetTgLengths && setCaps && pTranslateFC && pReflectFC;
        // bits 0/1: the device reads/writes storage images without a declared format, so a typeless Metal
        // texture's storage image is declared Unknown instead of R32f (the wrapper's formatless_options)
        if (setCaps && gVk.formatlessStorage) {
            setCaps(3);
        }
        if (!ready) {
            vglog("library: the translator lacks an entry point");
        }
    });
    return ready;
}

// Function constants as the translator's _fc entry points take them: parallel index / size / payload arrays.
typedef struct {
    size_t n;
    uint32_t idx[64], sz[64];
    const uint8_t *pay[64];
} vg_fc_args;
static void vg_fc_unpack(NSDictionary<NSNumber *, NSData *> *fc, vg_fc_args *a) {
    a->n = 0;
    for (NSNumber *k in fc) {
        if (a->n == 64) {
            break;
        }
        a->idx[a->n] = k.unsignedIntValue;
        a->sz[a->n] = (uint32_t)fc[k].length;
        a->pay[a->n] = fc[k].bytes;
        a->n++;
    }
}

// Translations are cached by (module text object -- the function keeps it for the library's life -- its hash, stage, constants, threadgroup lengths): Core Animation's fixed-function
// shaders are ~690 KB of SPIR-V and ~4 s each, asked again for every pipeline that uses them (5b).
// The pipeline's raster sample count for the next translations on this thread (5d, multisampling): shaders that read
// it (air.get_num_samples, ANGLE's) translate differently, so it is part of every cache key when it isn't 1.
static __thread uint32_t gSamples;
void vg_translate_set_samples(uint32_t n) { gSamples = n > 1 ? n : 0; }

static NSString *vg_translate_key(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc,
                                  const uint32_t *tg, uint32_t tgCount) {
    NSMutableString *k = [NSMutableString stringWithFormat:@"%p:%lx:%lu:%s", ll, (unsigned long)ll.hash, (unsigned long)ll.length, stage];
    if (gSamples) {
        [k appendFormat:@"|samples=%u", gSamples];
    }
    for (NSNumber *i in [fc.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [k appendFormat:@"|%@=%@", i, fc[i]];
    }
    for (uint32_t i = 0; tg && i < tgCount; i++) {
        if (tg[i]) {
            [k appendFormat:@"|t%u=%u", i, tg[i]];
        }
    }
    return k;
}

// ---- on-disk translation cache (5c) ----------------------------------------------------------------------------
// Translating Core Animation's shaders is seconds of WindowServer's own thread per new pipeline variant, at every
// boot and every new effect on screen. Translations (and reflections) are kept on disk, in the process's Darwin cache
// directory (WindowServer's sandbox allows it), keyed by a SHA-256 of what decides them: a version tag, the
// translator (a hash of the file), the stage, the function constants, the threadgroup lengths and the module
// text. VGMTL_NODISKCACHE=1 turns it off.
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *vg_disk_dir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *off = getenv("VGMTL_NODISKCACHE");
        char base[PATH_MAX];
        if ((off && off[0] == '1') || !confstr(_CS_DARWIN_USER_CACHE_DIR, base, sizeof(base))) {
            return;
        }
        NSString *d = [@(base) stringByAppendingPathComponent:@"local.homelab.VirtioGPUMetal/spirv"];
        if ([[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil]) {
            dir = d;
        }
        vglog("translation cache: %s", dir ? dir.UTF8String : "none (can't make the directory)");
    });
    return dir;
}

static NSString *vg_disk_key(const char *kind, NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc,
                             const uint32_t *tg, uint32_t tgCount) {
    // the translator by its content (a reinstalled bundle with the same translator keeps the cache)
    static char tool[96];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = vg_resource_path("libnvmtl_translate.dylib");
        NSData *bin = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] : nil;
        unsigned char d[CC_SHA256_DIGEST_LENGTH] = {0};
        if (bin) {
            CC_SHA256(bin.bytes, (CC_LONG)bin.length, d);
        }
        snprintf(tool, sizeof(tool), "vgmtl-cache-2|%02x%02x%02x%02x%02x%02x%02x%02x", d[0], d[1], d[2], d[3], d[4], d[5],
                 d[6], d[7]);
    });
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    CC_SHA256_Update(&c, tool, (CC_LONG)strlen(tool));
    CC_SHA256_Update(&c, kind, (CC_LONG)strlen(kind) + 1);
    CC_SHA256_Update(&c, stage, (CC_LONG)strlen(stage) + 1);
    for (NSNumber *i in [fc.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        uint32_t idx = i.unsignedIntValue, n = (uint32_t)fc[i].length;
        CC_SHA256_Update(&c, &idx, 4);
        CC_SHA256_Update(&c, &n, 4);
        CC_SHA256_Update(&c, fc[i].bytes, n);
    }
    for (uint32_t i = 0; tg && i < tgCount; i++) {
        CC_SHA256_Update(&c, &tg[i], 4);
    }
    if (gSamples) {
        CC_SHA256_Update(&c, "samples", 8);
        CC_SHA256_Update(&c, &gSamples, 4);
    }
    const char *text = ll.UTF8String;
    CC_SHA256_Update(&c, text, (CC_LONG)strlen(text));
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(md, &c);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", md[i]];
    }
    return hex;
}

static NSData *vg_disk_get(NSString *key) {
    NSString *dir = vg_disk_dir();
    return dir ? [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:key]] : nil;
}

static void vg_disk_put(NSString *key, NSData *data) {
    NSString *dir = vg_disk_dir();
    if (!dir || !data.length) {
        return;
    }
    // A temporary file renamed into place, so a reader never sees half of one; no fsync (5d: Safari's GPU process may
    // not call it, so NSData's atomic write failed there and every new GPU process translated everything again).
    NSString *path = [dir stringByAppendingPathComponent:key];
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s.%d.%llx.tmp", path.fileSystemRepresentation, getpid(), (unsigned long long)vg_now());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    const char *why = NULL;
    if (fd < 0) {
        why = "create";
    } else {
        ssize_t w = write(fd, data.bytes, data.length);
        close(fd);
        if (w != (ssize_t)data.length) {
            why = "write";
        } else if (rename(tmp, path.fileSystemRepresentation)) {
            why = "rename";
        }
        if (why) {
            unlink(tmp);
        }
    }
    if (why) {
        static int logged;
        if (logged++ < 3) {
            vglog("translation cache: can't %s %s: %s", why, key.UTF8String, strerror(errno));
        }
    }
}

static NSData *vg_translate_uncached(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc,
                                     const uint32_t *tgLengths, uint32_t tgCount, NSString **error);

NSData *vg_translate(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc, const uint32_t *tgLengths,
                     uint32_t tgCount, NSString **error) {
    static NSMutableDictionary<NSString *, NSData *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *key = vg_translate_key(ll, stage, fc, tgLengths, tgCount);
    @synchronized(cache) {
        NSData *hit = cache[key];
        if (hit) {
            return hit;
        }
    }
    NSString *dkey = vg_disk_dir() ? vg_disk_key("spirv", ll, stage, fc, tgLengths, tgCount) : nil;
    NSData *spv = dkey ? vg_disk_get(dkey) : nil;
    if (spv) {
        vg_perf(VG_PERF_DISK_HIT, spv.length, 0);
    } else {
        uint64_t t0 = vg_now();
        spv = vg_translate_uncached(ll, stage, fc, tgLengths, tgCount, error);
        vg_perf(VG_PERF_TRANSLATE, spv.length, vg_now() - t0);
        if (spv && dkey) {
            vg_disk_put(dkey, spv);
        }
    }
    if (spv) {
        @synchronized(cache) {
            if (cache.count > 1024) {
                [cache removeAllObjects];
            }
            cache[key] = spv;
        }
    }
    return spv;
}

// Opt-in (/Library/GPUBundles/VirtioGPUMetal-fcspec holding 1), as in NullMoth's driver (NVMTL_FC_SPEC=1): on VM 108
// WebKit's pages drew wrong with it (white page, black WebGL, no backdrop blur) and right with a translation per set.
// A set is translated once and kept in the disk cache, so the cost is the first time only.
static BOOL vg_fc_spec_on(void) {
    static int on = -1;
    if (on < 0) {
        on = 0;
        FILE *f = fopen("/Library/GPUBundles/VirtioGPUMetal-fcspec", "r");
        if (f) {
            on = fgetc(f) == '1';
            fclose(f);
        }
        vglog("function constants: %s", on ? "one translation per function (specialization constants)"
                                            : "a translation per set of values");
    }
    return on;
}

// The function's specialization-constant module: from memory, the disk cache, or translated now. The entry is
// 'SPC1', the table's length, the table, the module. Called with the threadgroup lengths already set (they're part of
// the key, as for any translation).
static NSData *vg_spec_entry(NSString *ll, const char *stage, const uint32_t *tgLengths, uint32_t tgCount,
                             NSString **why) {
    static NSCache *memo;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      memo = [NSCache new];
      memo.totalCostLimit = 64 << 20;
    });
    NSString *key = [@"spec|" stringByAppendingString:vg_translate_key(ll, stage, nil, tgLengths, tgCount)];
    NSData *entry = [memo objectForKey:key];
    if (entry) {
        return entry;
    }
    NSString *dkey = vg_disk_dir() ? vg_disk_key("spec", ll, stage, nil, tgLengths, tgCount) : nil;
    entry = dkey ? vg_disk_get(dkey) : nil;
    if (!entry) {
        uint8_t *mod = NULL, *tab = NULL;
        size_t modLen = 0, tabLen = 0;
        char err[1024] = "";
        uint64_t t0 = vg_now();
        if (pTranslateSpec(ll.UTF8String, stage, &mod, &modLen, &tab, &tabLen, err, sizeof(err)) || !mod) {
            *why = [NSString stringWithFormat:@"no specialization-constant module: %s", err];
            return nil;
        }
        NSMutableData *made = [NSMutableData dataWithCapacity:8 + tabLen + modLen];
        uint32_t hdr[2] = {0x31435053u, (uint32_t)tabLen};
        [made appendBytes:hdr length:8];
        [made appendBytes:tab length:tabLen];
        [made appendBytes:mod length:modLen];
        pTranslateFree(mod, modLen);
        pTranslateFree(tab, tabLen);
        entry = made;
        vg_perf(VG_PERF_TRANSLATE, modLen, vg_now() - t0);
        vglog("function constants: one module for this %s function, %zu B, %zu constants, %.0f ms", stage, modLen,
              tabLen / 20, (vg_now() - t0) / 1e6);
        if (dkey) {
            vg_disk_put(dkey, entry);
        }
    }
    [memo setObject:entry forKey:key cost:entry.length];
    return entry;
}

static NSData *vg_translate_uncached(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc,
                                     const uint32_t *tgLengths, uint32_t tgCount, NSString **error) {
    if (!vg_translator_ready()) {
        if (error) {
            *error = @"no translator";
        }
        return nil;
    }
    uint8_t *out = NULL;
    size_t len = 0;
    char err[2048] = "";
    pSetTgLengths(tgLengths, tgCount);   // per thread, read by the next translation on this thread
    if (pSetSamples) {
        pSetSamples(gSamples ? gSamples : 1);
    }
    int r;
    if (fc.count && pTranslateSpec && pSpecApply && vg_fc_spec_on()) {
        NSString *why = nil;
        NSData *entry = vg_spec_entry(ll, stage, tgLengths, tgCount, &why);
        const uint32_t *hdr = entry.bytes;
        if (entry && entry.length >= 8 && hdr[0] == 0x31435053u && entry.length >= 8 + (size_t)hdr[1]) {
            vg_fc_args a;
            vg_fc_unpack(fc, &a);
            const uint8_t *tab = (const uint8_t *)entry.bytes + 8, *mod = tab + hdr[1];
            if (!pSpecApply(mod, entry.length - 8 - hdr[1], tab, hdr[1], a.idx, a.sz, a.pay, a.n, &out, &len, err,
                            sizeof(err)) &&
                out) {
                pSetTgLengths(NULL, 0);
                NSData *spv = [NSData dataWithBytes:out length:len];
                pTranslateFree(out, len);
                return spv;
            }
            why = [NSString stringWithFormat:@"applying the values failed: %s", err];
        }
        static int logged;
        if (logged++ < 10) {
            vglog("function constants: the one-module path declined (%s): translating this set", why.UTF8String);
        }
        out = NULL, len = 0, err[0] = 0;
    }
    if (fc.count) {
        vg_fc_args a;
        vg_fc_unpack(fc, &a);
        r = pTranslateFC(ll.UTF8String, stage, a.idx, a.sz, a.pay, a.n, &out, &len, err, sizeof(err));
    } else {
        r = pTranslate(ll.UTF8String, stage, &out, &len, err, sizeof(err));
    }
    pSetTgLengths(NULL, 0);
    if (r || !out) {
        if (error) {
            *error = [NSString stringWithFormat:@"translation failed: %s", err];
        }
        return nil;
    }
    NSData *spv = [NSData dataWithBytes:out length:len];
    pTranslateFree(out, len);
    return spv;
}

static NSDictionary *vg_reflect_uncached(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc,
                                         NSString **error, NSData **jsonOut);

NSDictionary *vg_reflect(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc, NSString **error) {
    NSString *dkey = vg_disk_dir() ? vg_disk_key("reflect", ll, stage, fc, NULL, 0) : nil;
    NSData *json = dkey ? vg_disk_get(dkey) : nil;
    if (json) {
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        if ([d isKindOfClass:[NSDictionary class]]) {
            return d;
        }
    }
    json = nil;
    NSDictionary *d = vg_reflect_uncached(ll, stage, fc, error, &json);
    if (d && json && dkey) {
        vg_disk_put(dkey, json);
    }
    return d;
}

static NSDictionary *vg_reflect_uncached(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc,
                                         NSString **error, NSData **jsonOut) {
    if (!vg_translator_ready()) {
        if (error) {
            *error = @"no translator";
        }
        return nil;
    }
    uint8_t *out = NULL;
    size_t len = 0;
    char err[2048] = "";
    int r;
    if (fc.count) {
        vg_fc_args a;
        vg_fc_unpack(fc, &a);
        r = pReflectFC(ll.UTF8String, stage, a.idx, a.sz, a.pay, a.n, &out, &len, err, sizeof(err));
    } else {
        r = pReflect(ll.UTF8String, stage, &out, &len, err, sizeof(err));
    }
    if (r || !out) {
        if (error) {
            *error = [NSString stringWithFormat:@"reflection failed: %s", err];
        }
        return nil;
    }
    NSData *json = [NSData dataWithBytes:out length:len];
    pTranslateFree(out, len);
    *jsonOut = json;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]] && error) {
        *error = @"reflection isn't a JSON object";
    }
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

// ---- MTLLibrary / MTLFunction ----------------------------------------------------------------------------------

@class VGMTLLibrary;
NSDictionary *vg_ci_entry(id fn);          // VGMTLReflection.m
NSDictionary *vg_ci_stitch_entry(id fn);
static NSString *vg_linked_ll(VGMTLLibrary *lib, NSString *ll, NSString *name);
static NSSet<NSString *> *vg_undefined_externs(NSArray<NSString *> *modules);
@interface VGMTLFunction : NSObject <MTLFunction> {
@public
    __weak VGMTLLibrary *_lib;   // for its compile-time dynamic libraries (5d)
    NSString *_linked;           // _ll with its externs linked in from them, made on first use
    unsigned char _bcHash[32];   // bitCodeHash (5d: Core Image keys its kernels by it)
    BOOL _bcHashed;
    NSString *_ll;      // LLVM IR text of this entry's module
    NSString *_stage;   // "kernel" | "vertex" | "fragment"
    NSDictionary<NSNumber *, NSData *> *_fc;   // function-constant values (newFunctionWithName:constantValues:)
    NSString *_specName;   // MTLFunctionDescriptor.specializedName: the name a linking caller refers to it by
}
@property(readonly) id<MTLDevice> device;
@property(readonly) NSString *name;
@property(copy, atomic) NSString *label;
@end

@implementation VGMTLFunction
@synthesize device = _device, name = _name, label = _label;
- (instancetype)initWithDevice:(id<MTLDevice>)device name:(NSString *)name stage:(NSString *)stage ll:(NSString *)ll {
    if ((self = [super init])) {
        _device = device;
        _name = [name copy];
        _stage = [stage copy];
        _ll = [ll copy];
    }
    return self;
}
- (MTLFunctionType)functionType {
    if ([_stage isEqualToString:@"visible"]) {   // a Core Image kernel is Core Image's own type 4 (NullMoth's reading)
        return vg_ci_entry(self) ? (MTLFunctionType)4 : MTLFunctionTypeVisible;
    }
    return [_stage isEqualToString:@"vertex"]     ? MTLFunctionTypeVertex
           : [_stage isEqualToString:@"fragment"] ? MTLFunctionTypeFragment
                                                  : MTLFunctionTypeKernel;
}
// Core Image's reflection of a visible function (VGMTLReflection.m)
- (NSArray *)arguments { return (vg_ci_entry(self) ?: vg_ci_stitch_entry(self))[@"args"]; }
- (id)returnType { return (vg_ci_entry(self) ?: vg_ci_stitch_entry(self))[@"ret"]; }
- (NSDictionary<NSString *, MTLFunctionConstant *> *)functionConstantsDictionary { return @{}; }
- (MTLFunctionOptions)options { return MTLFunctionOptionNone; }
- (NSString *)description { return [NSString stringWithFormat:@"<VGMTLFunction %@ (%@)>", _name, _stage]; }
- (NSString *)vgLL {
    @synchronized(self) {
        if (!_linked) {
            _linked = vg_linked_ll(_lib, _ll, _name) ?: _ll;
        }
        return _linked;
    }
}
- (NSString *)vgStage { return _stage; }
- (id)vgLibrary { return _lib; }
- (NSArray *)importedLibraries { return @[]; }
// A 32-byte digest of the function (name, IR, constants): Core Image keys its kernel caches by it (5d; nil crashed).
- (const void *)bitCodeHash {
    @synchronized(self) {
        if (!_bcHashed) {
            NSMutableData *d = [NSMutableData data];
            [d appendData:[(_name ?: @"") dataUsingEncoding:NSUTF8StringEncoding]];
            [d appendData:[(_ll ?: @"") dataUsingEncoding:NSUTF8StringEncoding]];
            if (_fc.count) {
                [d appendData:[[_fc description] dataUsingEncoding:NSUTF8StringEncoding]];
            }
            CC_SHA256(d.bytes, (CC_LONG)d.length, _bcHash);
            _bcHashed = YES;
        }
        return _bcHash;
    }
}
- (NSDictionary<NSNumber *, NSData *> *)vgFC { return _fc; }
- (VGMTLFunction *)specializedWith:(NSDictionary<NSNumber *, NSData *> *)fc {
    VGMTLFunction *f = [[VGMTLFunction alloc] initWithDevice:_device name:_name stage:_stage ll:_ll];
    f->_fc = [fc copy];
    f->_lib = _lib;
    f->_specName = _specName;
    return f;
}
@end

// Bytes per value of a Metal data type (scalars and their 2-4 vectors), 0 for one we don't encode. NV's table.
static size_t vg_fc_width(NSUInteger t) {
    const struct {
        NSUInteger base;
        size_t bytes;
    } fam[] = {{MTLDataTypeFloat, 4}, {MTLDataTypeHalf, 2},  {MTLDataTypeInt, 4},   {MTLDataTypeUInt, 4},
               {MTLDataTypeShort, 2}, {MTLDataTypeUShort, 2}, {MTLDataTypeChar, 1},  {MTLDataTypeUChar, 1},
               {MTLDataTypeBool, 1},  {MTLDataTypeLong, 8},   {MTLDataTypeULong, 8}};
    for (size_t i = 0; i < sizeof(fam) / sizeof(fam[0]); i++) {
        if (t >= fam[i].base && t <= fam[i].base + 3) {
            return fam[i].bytes * (t - fam[i].base + 1);
        }
    }
    return 0;
}

static NSError *vg_lib_error(NSString *what) {
    return [NSError errorWithDomain:MTLLibraryErrorDomain code:MTLLibraryErrorUnsupported
                           userInfo:@{NSLocalizedDescriptionKey : what}];
}

@interface VGMTLLibrary : NSObject <MTLLibrary> {
@public
    NSDictionary<NSString *, VGMTLFunction *> *_functions;
    NSArray<NSString *> *_modules;   // every module's IR text, entry points or not (a dynamic library's exports)
    NSArray *_dylibs;                // VGMTLDynamicLibrary given when this library was compiled (5d)
    NSData *_raw;                    // the metallib
}
@property(readonly) id<MTLDevice> device;
@property(copy, atomic) NSString *label;
@end

// "!air.kernel = !{!12, !20}" + "!12 = !{ptr @vadd, ..." (or a typed "void (...)* @vadd") -> vadd, kernel.
static BOOL vg_entry_of(NSString *ll, NSString **name, NSString **stage) {
    for (NSString *st in @[ @"kernel", @"vertex", @"fragment" ]) {
        NSString *key = [NSString stringWithFormat:@"!air.%@ = !{!", st];
        NSRange r = [ll rangeOfString:key];
        if (r.location == NSNotFound) {
            continue;
        }
        NSScanner *sc = [NSScanner scannerWithString:[ll substringFromIndex:NSMaxRange(r)]];
        NSInteger id = -1;
        if (![sc scanInteger:&id]) {
            continue;
        }
        NSRange def = [ll rangeOfString:[NSString stringWithFormat:@"\n!%ld = !{", (long)id]];
        if (def.location == NSNotFound) {
            continue;
        }
        NSRange line = [ll lineRangeForRange:NSMakeRange(def.location + 1, 1)];
        NSString *l = [ll substringWithRange:line];
        NSRange at = [l rangeOfString:@"@"];
        if (at.location == NSNotFound) {
            continue;
        }
        NSCharacterSet *stop = [NSCharacterSet characterSetWithCharactersInString:@", )}\"\n"];
        NSString *rest = [l substringFromIndex:at.location + 1];
        if ([rest hasPrefix:@"\""]) {   // a quoted symbol: an entry in a namespace, @"Grid::grid_vertex" (5d: Maps)
            NSRange q = [rest rangeOfString:@"\"" options:0 range:NSMakeRange(1, rest.length - 1)];
            if (q.location == NSNotFound) {
                continue;
            }
            *name = [rest substringWithRange:NSMakeRange(1, q.location - 1)];
            *stage = st;
            return YES;
        }
        NSRange end = [rest rangeOfCharacterFromSet:stop];
        *name = end.location == NSNotFound ? rest : [rest substringToIndex:end.location];
        *stage = st;
        return YES;
    }
    return NO;
}

@implementation VGMTLLibrary
@synthesize device = _device, label = _label;
- (instancetype)initWithDevice:(id<MTLDevice>)device functions:(NSDictionary *)functions {
    if ((self = [super init])) {
        _device = device;
        _functions = [functions copy];
        for (VGMTLFunction *f in _functions.allValues) {
            f->_lib = self;
        }
    }
    return self;
}
- (NSArray<NSString *> *)functionNames { return _functions.allKeys; }
- (NSData *)vgRaw { return _raw; }
- (VGMTLLibrary *)vgSelf { return self; }
// What the library calls and doesn't define, linked from dynamic libraries (Core Image asks).
- (NSArray<NSString *> *)externFunctionNames { return vg_undefined_externs(_modules ?: @[]).allObjects; }
// A name in a namespace ("Clear::clear_vertex", Maps) is the entry's C++ symbol: _ZN5Clear12clear_vertexE...
static VGMTLFunction *vg_function_by_cxx_name(NSDictionary<NSString *, VGMTLFunction *> *fns, NSString *name) {
    NSArray *parts = [name componentsSeparatedByString:@"::"];
    if (parts.count < 2) {
        return nil;
    }
    NSMutableString *prefix = [NSMutableString stringWithString:@"_ZN"];
    for (NSString *p in parts) {
        [prefix appendFormat:@"%lu%@", (unsigned long)p.length, p];
    }
    [prefix appendString:@"E"];
    for (NSString *k in fns) {
        if ([k hasPrefix:prefix]) {
            return fns[k];
        }
    }
    return nil;
}
- (MTLLibraryType)type { return MTLLibraryTypeExecutable; }
- (NSString *)installName { return nil; }
- (id<MTLFunction>)newFunctionWithName:(NSString *)name {
    VGMTLFunction *f = _functions[name] ?: vg_function_by_cxx_name(_functions, name);
    if (!f) {
        vglog("library: no function %s", name.UTF8String);
    }
    return f;
}
// Callers may hand an uninitialized NSError * and test it afterwards (CoreDisplay does): *error is always written.
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values
                                 error:(NSError **)error {
    if (error) {
        *error = nil;
    }
    VGMTLFunction *f = _functions[name];
    if (!f) {
        vglog("library: no function %s", name.UTF8String);
        if (error) {
            *error = vg_lib_error([NSString stringWithFormat:@"no function %@", name]);
        }
        return nil;
    }
    // MTLFunctionConstantValues keeps MTLIndexedConstantValue objects (_index, _dataType, _data), as NV reads them.
    NSMutableDictionary<NSNumber *, NSData *> *fc = [NSMutableDictionary dictionary];
    SEL idxSel = NSSelectorFromString(@"newIndexedConstantArray"), namedSel = NSSelectorFromString(@"newNamedConstantArray");
    NSArray *indexed = [values respondsToSelector:idxSel] ? ((id(*)(id, SEL))objc_msgSend)(values, idxSel) : nil;
    NSArray *named = [values respondsToSelector:namedSel] ? ((id(*)(id, SEL))objc_msgSend)(values, namedSel) : nil;
    for (id v in indexed) {
        Ivar ii = class_getInstanceVariable([v class], "_index"), ti = class_getInstanceVariable([v class], "_dataType"),
             di = class_getInstanceVariable([v class], "_data");
        if (!ii || !ti || !di) {
            if (error) {
                *error = vg_lib_error(@"unrecognized MTLFunctionConstantValues representation");
            }
            return nil;
        }
        const uint8_t *base = (const uint8_t *)(__bridge void *)v;
        NSUInteger index = *(const NSUInteger *)(base + ivar_getOffset(ii));
        NSUInteger type = *(const NSUInteger *)(base + ivar_getOffset(ti));
        const void *data = *(const void *const *)(base + ivar_getOffset(di));
        size_t w = vg_fc_width(type);
        if (!w || !data) {
            if (error) {
                *error = vg_lib_error([NSString stringWithFormat:@"function constant %lu: data type %lu isn't supported",
                                                                 (unsigned long)index, (unsigned long)type]);
            }
            return nil;
        }
        fc[@(index)] = [NSData dataWithBytes:data length:w];
    }
    if (named.count) {
        // Named constants (MTLNamedConstantValue: _name, _dataType, _data) go by the index the module's own metadata
        // gives each name: "!N = !{ptr @...MTL_FC_INIT_..., !\"type\", !\"name\", i32 INDEX, i1 ...}" (NV's reading).
        static NSRegularExpression *re;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            re = [NSRegularExpression
                regularExpressionWithPattern:@"^![0-9]+ = !\\{[^\\n]*\\.MTL_FC_INIT_[^\\n]*, !\"[^\"]+\", !\"([^\"]+)\", i32 ([0-9]+), i1 (?:true|false)\\}$"
                                     options:NSRegularExpressionAnchorsMatchLines
                                       error:NULL];
        });
        NSString *ll = [f vgLL];
        NSMutableDictionary<NSString *, NSNumber *> *indices = [NSMutableDictionary dictionary];
        for (NSTextCheckingResult *m in [re matchesInString:ll options:0 range:NSMakeRange(0, ll.length)]) {
            indices[[ll substringWithRange:[m rangeAtIndex:1]]] = @([[ll substringWithRange:[m rangeAtIndex:2]] longLongValue]);
        }
        NSUInteger applied = 0;
        for (id v in named) {
            Ivar ni = class_getInstanceVariable([v class], "_name"), ti = class_getInstanceVariable([v class], "_dataType"),
                 di = class_getInstanceVariable([v class], "_data");
            if (!ni || !ti || !di) {
                if (error) {
                    *error = vg_lib_error(@"unrecognized named function constant representation");
                }
                return nil;
            }
            NSNumber *index = indices[object_getIvar(v, ni)];
            if (!index) {
                continue;   // a name this function doesn't declare
            }
            const uint8_t *base = (const uint8_t *)(__bridge void *)v;
            NSUInteger type = *(const NSUInteger *)(base + ivar_getOffset(ti));
            const void *data = *(const void *const *)(base + ivar_getOffset(di));
            size_t w = vg_fc_width(type);
            if (!w || !data) {
                if (error) {
                    *error = vg_lib_error([NSString stringWithFormat:@"function constant %@: data type %lu isn't supported",
                                                                     object_getIvar(v, ni), (unsigned long)type]);
                }
                return nil;
            }
            if (!fc[index]) {   // an indexed value for the same constant wins, as in Metal
                fc[index] = [NSData dataWithBytes:data length:w];
            }
            applied++;
        }
        vglog("library: %s: %lu of %lu named function constants apply (%lu declared)", name.UTF8String,
              (unsigned long)applied, (unsigned long)named.count, (unsigned long)indices.count);
    }
    vglog("library: %s with %lu function constants", name.UTF8String, (unsigned long)fc.count);
    return fc.count ? [f specializedWith:fc] : f;
}
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d error:(NSError **)error {
    id<MTLFunction> f;
    if (d.constantValues) {
        f = [self newFunctionWithName:d.name constantValues:d.constantValues error:error];
    } else {
        if (error) {
            *error = nil;
        }
        f = [self newFunctionWithName:d.name];
        if (!f && error) {
            *error = vg_lib_error([NSString stringWithFormat:@"no function %@", d.name]);
        }
    }
    // RenderBox asks for each custom shader (clampToEdges_v1, glow_v1, ...) with specializedName "custom_fn" and links
    // it into a pipeline whose fragment refers to "custom_fn" (5d): kept on a copy, applied when it is linked.
    if (d.specializedName.length && [(NSObject *)f isKindOfClass:[VGMTLFunction class]] &&
        ![d.specializedName isEqualToString:f.name]) {
        VGMTLFunction *o = (VGMTLFunction *)f, *c = [o specializedWith:o->_fc];
        c->_specName = [d.specializedName copy];
        f = c;
    }
    return f;
}
@end

// Libraries loaded with this set list no visible functions (see vg_new_library_from_url).
static __thread BOOL gNoVisible;

// Functions a module defines with external linkage (not internal/private, not intrinsics).
static NSArray<NSString *> *vg_exported_defs(NSString *ll) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [ll componentsSeparatedByString:@"\n"]) {
        if (![line hasPrefix:@"define "] || [line hasPrefix:@"define internal"] || [line hasPrefix:@"define private"] ||
            [line rangeOfString:@" internal "].location != NSNotFound) {
            continue;
        }
        NSRange at = [line rangeOfString:@"@"];
        if (at.location == NSNotFound) {
            continue;
        }
        NSUInteger s = at.location + 1, e;
        BOOL q = s < line.length && [line characterAtIndex:s] == '"';
        if (q) {
            s++;
        }
        for (e = s; e < line.length; e++) {
            unichar c = [line characterAtIndex:e];
            if (q ? c == '"' : c == '(') {
                break;
            }
        }
        NSString *nm = e > s ? [line substringWithRange:NSMakeRange(s, e - s)] : nil;
        if (nm && ![nm hasPrefix:@"air."] && ![nm hasPrefix:@"llvm."]) {
            [out addObject:nm];
        }
    }
    return out;
}

// The functions a module lists as visible (!air.visible, and Core Image's !air.ci) and defines (after NullMoth's
// nvmtl_visible_of).
static NSArray<NSString *> *vg_visible_of(NSString *ll) {
    NSMutableArray *ids = [NSMutableArray array];
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    NSMutableSet *defined = [NSMutableSet set];
    for (NSString *line in [ll componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"define"]) {
            NSRange at = [line rangeOfString:@"@"];
            if (at.location == NSNotFound) {
                continue;
            }
            NSUInteger s = at.location + 1, e;
            BOOL q = s < line.length && [line characterAtIndex:s] == '"';
            if (q) {
                s++;
            }
            for (e = s; e < line.length; e++) {
                unichar c = [line characterAtIndex:e];
                if (q ? c == '"' : c == '(') {
                    break;
                }
            }
            if (e > s) {
                [defined addObject:[line substringWithRange:NSMakeRange(s, e - s)]];
            }
            continue;
        }
        if (![line hasPrefix:@"!"]) {
            continue;
        }
        if ([line hasPrefix:@"!air.visible = "] || [line hasPrefix:@"!air.ci = "]) {
            NSRange eq = [line rangeOfString:@"="];
            for (NSString *tok in [[line substringFromIndex:eq.location] componentsSeparatedByString:@"!"]) {
                NSUInteger d = 0;
                while (d < tok.length && [tok characterAtIndex:d] >= '0' && [tok characterAtIndex:d] <= '9') {
                    d++;
                }
                if (d) {
                    [ids addObject:[tok substringToIndex:d]];
                }
            }
            continue;
        }
        NSRange eq = [line rangeOfString:@" = !{"];
        if (eq.location == NSNotFound || eq.location < 2) {
            continue;
        }
        NSString *idn = [line substringWithRange:NSMakeRange(1, eq.location - 1)];
        NSRange at = [line rangeOfString:@"@" options:0 range:NSMakeRange(eq.location, line.length - eq.location)];
        if (at.location == NSNotFound) {
            continue;
        }
        NSUInteger s = at.location + 1, e;
        BOOL q = s < line.length && [line characterAtIndex:s] == '"';
        if (q) {
            s++;
        }
        for (e = s; e < line.length; e++) {
            unichar c = [line characterAtIndex:e];
            if (q ? c == '"' : (c == ',' || c == ')' || c == '}' || c == ' ')) {
                break;
            }
        }
        if (e > s) {
            node[idn] = [line substringWithRange:NSMakeRange(s, e - s)];
        }
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *i in ids) {
        NSString *nm = node[i];
        if (nm && [defined containsObject:nm] && ![out containsObject:nm]) {
            [out addObject:nm];
        }
    }
    return out;
}

id<MTLLibrary> vg_new_library(id<MTLDevice> device, NSData *lib, NSError **error) {
    if (error) {
        *error = nil;
    }
    NSMutableDictionary *fns = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *modules = [NSMutableArray array];
    const uint8_t *b = lib.bytes;
    NSUInteger n = lib.length;
    NSUInteger blobs = 0;
    for (NSUInteger i = 0; i + 20 <= n; i++) {
        // LLVM's bitcode wrapper header: 0x0B17C0DE, version, offset, size, cputype
        if (!(b[i] == 0xde && b[i + 1] == 0xc0 && b[i + 2] == 0x17 && b[i + 3] == 0x0b)) {
            continue;
        }
        uint32_t off = 0, size = 0;
        memcpy(&off, b + i + 8, 4);
        memcpy(&size, b + i + 12, 4);
        if ((uint64_t)i + off + size > n || !size) {
            continue;
        }
        blobs++;
        NSString *ll = vg_air_to_text([NSData dataWithBytes:b + i length:off + size]);
        if (ll) {
            [modules addObject:ll];
        }
        NSString *name = nil, *stage = nil;
        if (ll && vg_entry_of(ll, &name, &stage)) {
            fns[name] = [[VGMTLFunction alloc] initWithDevice:device name:name stage:stage ll:ll];
        } else if (ll && !gNoVisible) {
            // visible / stitchable functions (5d: SwiftUI's shader effects, Core Image's kernels): functions of the
            // library too, for stitching and linking
            NSArray *vis = vg_visible_of(ll);
            if (!vis.count) {
                vis = vg_exported_defs(ll);   // Apple's stitched output: the stitched function, no visible metadata
            }
            for (NSString *v in vis) {
                fns[v] = [[VGMTLFunction alloc] initWithDevice:device name:v stage:@"visible" ll:ll];
            }
        }
        i += off + size - 1;
    }
    vglog("library: %lu bytes, %lu bitcode blobs, entries: %s", (unsigned long)n, (unsigned long)blobs,
          [[fns.allKeys componentsJoinedByString:@", "] UTF8String]);
    if (!modules.count) {
        if (error) {
            *error = [NSError errorWithDomain:MTLLibraryErrorDomain code:MTLLibraryErrorUnsupported
                                     userInfo:@{NSLocalizedDescriptionKey : @"no modules could be read"}];
        }
        return nil;
    }
    // A library of functions without entry points is a library too (5d): Core Image's ci_stdlib, which its kernels
    // link against as a dynamic library. Refusing it made Core Image fail to convert any kernel-language source.
    VGMTLLibrary *l = [[VGMTLLibrary alloc] initWithDevice:device functions:fns];
    l->_modules = modules;
    l->_raw = lib;
    return l;
}

// ---- dynamic libraries and extern linking (5d) -------------------------------------------------------------------
// A dynamic library is one of our libraries whose modules other functions link against: Core Image compiles its
// kernels with options.libraries = its ci_stdlib. Before translation, a function's undefined externs (declared, not
// defined, not air./llvm. intrinsics) are linked in from the modules of the dynamic libraries its library was
// compiled with (the translator's nvmtl_link_externs), after nullmoth/nvidia-macos-driver's NVMTLLibraryLoad.m.

@implementation VGMTLDynamicLibrary
@synthesize label = _label;
- (id<MTLDevice>)device { return _lib.device; }
- (NSString *)installName { return _installName ?: @""; }
- (BOOL)serializeToURL:(NSURL *)url error:(NSError **)error {
    return [_lib->_raw writeToURL:url options:NSDataWritingAtomic error:error];
}
@end

id<MTLDynamicLibrary> vg_new_dynamic_library(id<MTLLibrary> lib, NSError **error) {
    if (![(NSObject *)lib isKindOfClass:[VGMTLLibrary class]]) {
        if (error) {
            *error = vg_lib_error([NSString stringWithFormat:@"newDynamicLibrary: %s isn't one of ours", object_getClassName(lib)]);
        }
        return nil;
    }
    VGMTLDynamicLibrary *d = [VGMTLDynamicLibrary new];
    d->_lib = (VGMTLLibrary *)lib;
    d->_installName = lib.installName;
    vglog("dynamic library: %lu module(s)", (unsigned long)d->_lib->_modules.count);
    return d;
}

void vg_library_set_dylibs(id<MTLLibrary> lib, NSArray *dylibs) {
    if ([(NSObject *)lib isKindOfClass:[VGMTLLibrary class]] && dylibs.count) {
        ((VGMTLLibrary *)lib)->_dylibs = [dylibs copy];
    }
}

typedef int (*xl_link_fn)(const char *, const char *const *, size_t, uint8_t **, size_t *, char *, size_t);
static NSString *vg_linked_ll(VGMTLLibrary *lib, NSString *ll, NSString *name) {
    if (!lib.class || !ll) {
        return nil;
    }
    NSMutableArray *mods = [NSMutableArray array];
    for (id d in lib->_dylibs) {
        if ([d isKindOfClass:[VGMTLDynamicLibrary class]]) {
            [mods addObjectsFromArray:((VGMTLDynamicLibrary *)d)->_lib->_modules ?: @[]];
        }
    }
    if (!mods.count) {
        return nil;
    }
    static dispatch_once_t once;
    static xl_link_fn pLink;
    dispatch_once(&once, ^{
      NSString *path = vg_resource_path("libnvmtl_translate.dylib");
      void *h = path ? dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL) : NULL;
      pLink = h ? (xl_link_fn)dlsym(h, "nvmtl_link_externs") : NULL;
    });
    NSSet *decl = vg_undefined_externs(@[ ll ]);
    if (!decl.count || !pLink || !vg_translator_ready()) {
        return nil;
    }
    const char **ms = calloc(mods.count, sizeof(*ms));
    for (NSUInteger i = 0; i < mods.count; i++) {
        ms[i] = [mods[i] UTF8String];
    }
    uint8_t *out = NULL;
    size_t len = 0;
    char err[1024] = "";
    int r = pLink(ll.UTF8String, ms, mods.count, &out, &len, err, sizeof(err));
    free(ms);
    if (r || !out) {
        vglog("link: %s needs %s: %s", name.UTF8String, [[decl.allObjects componentsJoinedByString:@","] UTF8String], err);
        return nil;
    }
    NSString *linked = [[NSString alloc] initWithBytes:out length:(len && out[len - 1] == 0) ? len - 1 : len
                                              encoding:NSUTF8StringEncoding];
    pTranslateFree(out, len);
    vglog("link: %s: %lu extern(s) from %lu module(s), %lu -> %lu B", name.UTF8String, (unsigned long)decl.count,
          (unsigned long)mods.count, (unsigned long)ll.length, (unsigned long)linked.length);
    return linked;
}

// Functions the modules declare and none of them defines (not air./llvm. intrinsics).
static NSSet<NSString *> *vg_undefined_externs(NSArray<NSString *> *modules) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      re = [NSRegularExpression regularExpressionWithPattern:@"^(declare|define)[^@\\n]*@(\"[^\"]+\"|[A-Za-z0-9_.$]+)\\("
                                                     options:NSRegularExpressionAnchorsMatchLines
                                                       error:NULL];
    });
    NSMutableSet *decl = [NSMutableSet set], *def = [NSMutableSet set];
    for (NSString *ll in modules) {
        for (NSTextCheckingResult *m in [re matchesInString:ll options:0 range:NSMakeRange(0, ll.length)]) {
            NSString *sym = [ll substringWithRange:[m rangeAtIndex:2]];
            if ([sym hasPrefix:@"air."] || [sym hasPrefix:@"llvm."] || [sym hasPrefix:@"\"air."]) {
                continue;
            }
            [([[ll substringWithRange:[m rangeAtIndex:1]] isEqual:@"declare"] ? decl : def) addObject:sym];
        }
    }
    [decl minusSet:def];
    return decl;
}

// ---- binary archives (5d) -----------------------------------------------------------------------------------------
// Ours, always empty: pipelines are translated and cached by this driver, so an archive records nothing and every
// lookup misses. Apple's own archive class (made when the device doesn't make one) asked our device for a slice ID it
// has no answer for and Metal asserted: SwiftUI's RenderBox opens archives with its custom shader effects, and the
// Dock's extras and Spotlight crashed in a loop. After nullmoth/nvidia-macos-driver's NVMTLBinaryArchive.
@interface VGMTLBinaryArchive : NSObject <MTLBinaryArchive>
@property(copy, atomic) NSString *label;
@property(readonly) id<MTLDevice> device;
@end
@implementation VGMTLBinaryArchive {
    id<MTLDevice> _dev;
}
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (BOOL)addComputePipelineFunctionsWithDescriptor:(MTLComputePipelineDescriptor *)d error:(NSError **)error { return YES; }
- (BOOL)addRenderPipelineFunctionsWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error { return YES; }
- (BOOL)addTileRenderPipelineFunctionsWithDescriptor:(MTLTileRenderPipelineDescriptor *)d error:(NSError **)error { return YES; }
- (BOOL)addMeshRenderPipelineFunctionsWithDescriptor:(MTLMeshRenderPipelineDescriptor *)d error:(NSError **)error { return YES; }
- (BOOL)addLibraryWithDescriptor:(MTLStitchedLibraryDescriptor *)d error:(NSError **)error { return YES; }
- (BOOL)addFunctionWithDescriptor:(MTLFunctionDescriptor *)d library:(id<MTLLibrary>)l error:(NSError **)error { return YES; }
- (BOOL)serializeToURL:(NSURL *)url error:(NSError **)error {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:@{@"format" : @"VeneraBinaryArchive", @"version" : @1}
                                                           format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return d && [d writeToURL:url options:NSDataWritingAtomic error:error];
}
@end

id<MTLBinaryArchive> vg_new_binary_archive(id<MTLDevice> device, MTLBinaryArchiveDescriptor *d, NSError **error) {
    if (error) {
        *error = nil;
    }
    VGMTLBinaryArchive *a = [VGMTLBinaryArchive new];
    [a setValue:device forKey:@"_dev"];
    return a;
}

// One of our functions from IR text (5d: OpenGL's lowered shaders): its entry from the module's metadata, else `name`.
id<MTLFunction> vg_function_from_ll(id<MTLDevice> device, NSString *ll, NSString *stage, NSString *name) {
    NSString *entry = nil, *st = nil;
    if (vg_entry_of(ll, &entry, &st)) {
        name = entry;
        stage = st;
    }
    return [[VGMTLFunction alloc] initWithDevice:device name:name stage:stage ll:ll];
}

// A library from a file. Core Image's own libraries (its framework's ci_*_stitchable.metallib) list no visible
// functions (5d): with them Core Image stitches its filters, and our translator refuses some stitched modules
// (lanczos: "owned Load violates its pointer-pointee contract") while Core Image doesn't fall back; without them it
// compiles its filters from source, which translates.
id<MTLLibrary> vg_new_library_from_url(id<MTLDevice> device, NSData *lib, NSURL *url, NSError **error) {
    gNoVisible = [url.path containsString:@"/CoreImage.framework/"];
    id<MTLLibrary> l = vg_new_library(device, lib, error);
    gNoVisible = NO;
    return l;
}

// ---- linked visible functions (5d) ---------------------------------------------------------------------------------
// A pipeline stage that calls visible functions handed to it in its MTLLinkedFunctions (SwiftUI's and RenderBox's
// shader effects: the Dock's Calendar icon, Spotlight) is linked with their modules before translation (the
// translator's nvmtl_link_visible). After NullMoth's nvmtl_link_stage (NVMTLLibraryLoad.m): the references come from
// the translator (nvmtl_visible_refs), each is supplied by the linked function that defines it, under its
// specializedName when it has one, and the linked functions' constants join the stage's. Direct calls only: a stage
// that reads a visible function table is left to fail with the translator's reason.
typedef int (*xl_linkvis_fn)(const char *, const char *, const char *const *, const char *const *, size_t, uint8_t **,
                             size_t *, char *, size_t);
typedef int (*xl_vrefs_fn)(const char *, uint8_t **, size_t *, char *, size_t);
static BOOL vg_llvm_plain(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' ||
           c == '$' || c == '-';
}
// The global's spelling in LLVM text: @name, or @"name" with \ and " escaped.
static NSString *vg_llvm_global(NSString *sym) {
    if (!sym.length) {
        return nil;
    }
    BOOL plain = YES;
    for (NSUInteger i = 0; i < sym.length; i++) {
        plain = plain && vg_llvm_plain([sym characterAtIndex:i]);
    }
    if (plain) {
        return [@"@" stringByAppendingString:sym];
    }
    NSString *q = [[sym stringByReplacingOccurrencesOfString:@"\\" withString:@"\\5C"]
        stringByReplacingOccurrencesOfString:@"\"" withString:@"\\22"];
    return [NSString stringWithFormat:@"@\"%@\"", q];
}
static BOOL vg_module_defines(NSString *ll, NSString *sym) {
    NSString *g = vg_llvm_global(sym);
    if (!g || !ll.length) {
        return NO;
    }
    NSString *call = [g stringByAppendingString:@"("];
    for (NSString *line in [ll componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"define "] && [line rangeOfString:call options:NSLiteralSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}
// Every whole-token use of global `from` becomes `to`; nil when nothing changed or `to` is already defined.
static NSString *vg_rename_global(NSString *ll, NSString *from, NSString *to) {
    NSString *gf = vg_llvm_global(from), *gt = vg_llvm_global(to);
    if (!gf || !gt || vg_module_defines(ll, to)) {
        return nil;
    }
    BOOL quoted = [gf hasPrefix:@"@\""];
    NSMutableString *o = [NSMutableString stringWithCapacity:ll.length + 64];
    NSUInteger pos = 0, n = ll.length, hits = 0;
    for (;;) {
        NSRange r = [ll rangeOfString:gf options:NSLiteralSearch range:NSMakeRange(pos, n - pos)];
        if (r.location == NSNotFound) {
            break;
        }
        NSUInteger end = NSMaxRange(r);
        unichar next = end < n ? [ll characterAtIndex:end] : 0;
        BOOL whole = quoted || end >= n || next >= 128 || !vg_llvm_plain(next);
        [o appendString:[ll substringWithRange:NSMakeRange(pos, r.location - pos)]];
        [o appendString:whole ? gt : gf];
        hits += whole;
        pos = end;
    }
    if (!hits) {
        return nil;
    }
    [o appendString:[ll substringFromIndex:pos]];
    return o;
}
// The translator reads a reference as !{!"air.visible_function_reference", ptr @stub, ...} (opaque pointers); AIR
// built with typed pointers names the stub's whole function-pointer type there instead, so that type becomes `ptr`.
static NSString *vg_opaque_vrefs(NSString *ll) {
    static NSString *const marker = @"!\"air.visible_function_reference\", ";
    if ([ll rangeOfString:marker].location == NSNotFound) {
        return ll;
    }
    NSMutableArray *lines = [[ll componentsSeparatedByString:@"\n"] mutableCopy];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange m = [line rangeOfString:marker];
        if (m.location == NSNotFound) {
            continue;
        }
        NSUInteger from = NSMaxRange(m);
        NSRange at = [line rangeOfString:@"@" options:0 range:NSMakeRange(from, line.length - from)];
        if (at.location == NSNotFound || [[line substringWithRange:NSMakeRange(from, at.location - from)] isEqualToString:@"ptr "]) {
            continue;
        }
        lines[i] = [NSString stringWithFormat:@"%@ptr %@", [line substringToIndex:from], [line substringFromIndex:at.location]];
    }
    return [lines componentsJoinedByString:@"\n"];
}
id<MTLFunction> vg_function_with_linked(id<MTLFunction> f, MTLLinkedFunctions *lf, NSError **error) {
    if (![(NSObject *)f isKindOfClass:[VGMTLFunction class]] || !lf) {
        return f;
    }
    NSMutableArray *cands = [NSMutableArray array];
    [cands addObjectsFromArray:lf.functions ?: @[]];
    [cands addObjectsFromArray:lf.privateFunctions ?: @[]];
    for (NSArray *g in lf.groups.allValues) {
        if ([g isKindOfClass:[NSArray class]]) {
            [cands addObjectsFromArray:g];
        }
    }
    if (!cands.count) {
        return f;
    }
    static xl_linkvis_fn pLinkVis;
    static xl_vrefs_fn pVRefs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSString *path = vg_resource_path("libnvmtl_translate.dylib");
      void *h = path ? dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL) : NULL;
      pLinkVis = h ? (xl_linkvis_fn)dlsym(h, "nvmtl_link_visible") : NULL;
      pVRefs = h ? (xl_vrefs_fn)dlsym(h, "nvmtl_visible_refs") : NULL;
    });
    if (!vg_translator_ready() || !pLinkVis || !pVRefs) {   // ready: pTranslateFree (cached pipelines skip it)
        return f;
    }
    VGMTLFunction *fn = (VGMTLFunction *)f;
    NSString *entry = vg_opaque_vrefs([fn vgLL]);
    uint8_t *out = NULL;
    size_t len = 0;
    char err[1024] = "";
    NSArray *refs = nil;
    if (pVRefs(entry.UTF8String, &out, &len, err, sizeof(err)) == 0 && out) {
        refs = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:out length:len] options:0 error:NULL];
        pTranslateFree(out, len);
        out = NULL;
    }
    if (![refs isKindOfClass:[NSArray class]] || !refs.count) {
        static int said;
        if (said++ < 4) {
            vglog("link: %s: %s", fn.name.UTF8String, refs ? "no visible references" : err);
            NSString *dir = vg_disk_dir();
            if (dir && [[NSFileManager defaultManager] fileExistsAtPath:@"/Library/GPUBundles/VirtioGPUMetal-dumplink"]) {
                [entry writeToFile:[dir stringByAppendingFormat:@"/link-%@.ll", fn.name] atomically:YES
                          encoding:NSUTF8StringEncoding error:NULL];
            }
        }
        return f;   // nothing to link (or unreadable: the translator gives its own reason)
    }
    NSMutableDictionary<NSString *, NSString *> *mods = [NSMutableDictionary dictionary];
    NSMutableDictionary *fc = [NSMutableDictionary dictionary];
    for (id c in cands) {
        if (![c isKindOfClass:[VGMTLFunction class]]) {
            continue;
        }
        VGMTLFunction *cf = c;
        NSString *ll = vg_opaque_vrefs([cf vgLL]);
        if (cf->_specName.length && !vg_module_defines(ll, cf->_specName)) {
            ll = vg_rename_global(ll, cf.name, cf->_specName) ?: ll;
        }
        for (NSString *nm in @[ cf->_specName ?: @"", cf.name ?: @"" ]) {
            if (nm.length && !mods[nm] && vg_module_defines(ll, nm)) {
                mods[nm] = ll;
            }
        }
        [cf->_fc enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
          if (!fc[k]) {
              fc[k] = v;
          }
        }];
    }
    [fc addEntriesFromDictionary:fn->_fc ?: @{}];
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *r in refs) {
        if ([r isKindOfClass:[NSString class]] && !mods[r]) {
            [missing addObject:r];
        }
    }
    NSArray *keys = mods.allKeys;
    const char **syms = calloc(keys.count + 1, sizeof(*syms)), **mls = calloc(keys.count + 1, sizeof(*mls));
    for (NSUInteger i = 0; i < keys.count; i++) {
        syms[i] = [keys[i] UTF8String];
        mls[i] = [mods[keys[i]] UTF8String];
    }
    int r = pLinkVis(entry.UTF8String, fn->_stage.UTF8String, syms, mls, keys.count, &out, &len, err, sizeof(err));
    free(syms);
    free(mls);
    if (r || !out) {
        vglog("link: %s (refs %s) failed: %s", fn.name.UTF8String, [[refs componentsJoinedByString:@","] UTF8String], err);
        if (error) {
            *error = vg_lib_error([NSString stringWithFormat:@"linking visible functions into %@: %s", fn.name, err]);
        }
        return nil;
    }
    NSString *linked = [[NSString alloc] initWithBytes:out length:(len && out[len - 1] == 0) ? len - 1 : len
                                              encoding:NSUTF8StringEncoding];
    pTranslateFree(out, len);
    VGMTLFunction *lfn = [[VGMTLFunction alloc] initWithDevice:fn.device name:fn.name stage:fn->_stage ll:linked];
    lfn->_fc = fc.count ? fc : nil;
    lfn->_lib = fn->_lib;
    lfn->_linked = linked;   // already linked: no dylib pass over it
    static int logged;
    if (logged++ < 10 || missing.count) {
        vglog("link: %s refs %s, linked %s%s%s", fn.name.UTF8String, [[refs componentsJoinedByString:@","] UTF8String],
              [[keys componentsJoinedByString:@","] UTF8String], missing.count ? "; nothing supplies " : "",
              [[missing componentsJoinedByString:@","] UTF8String]);
    }
    return lfn;
}
