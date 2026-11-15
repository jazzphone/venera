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

NSString *vg_air_to_text(NSData *air) {
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
static void (*pTranslateFree)(uint8_t *, size_t);
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
static NSString *vg_translate_key(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc,
                                  const uint32_t *tg, uint32_t tgCount) {
    NSMutableString *k = [NSMutableString stringWithFormat:@"%p:%lx:%lu:%s", ll, (unsigned long)ll.hash, (unsigned long)ll.length, stage];
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
    NSData *spv = vg_translate_uncached(ll, stage, fc, tgLengths, tgCount, error);
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
    int r;
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

NSDictionary *vg_reflect(NSString *ll, const char *stage, NSDictionary<NSNumber *, NSData *> *fc, NSString **error) {
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
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]] && error) {
        *error = @"reflection isn't a JSON object";
    }
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

// ---- MTLLibrary / MTLFunction ----------------------------------------------------------------------------------

@interface VGMTLFunction : NSObject <MTLFunction> {
@public
    NSString *_ll;      // LLVM IR text of this entry's module
    NSString *_stage;   // "kernel" | "vertex" | "fragment"
    NSDictionary<NSNumber *, NSData *> *_fc;   // function-constant values (newFunctionWithName:constantValues:)
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
    return [_stage isEqualToString:@"vertex"]     ? MTLFunctionTypeVertex
           : [_stage isEqualToString:@"fragment"] ? MTLFunctionTypeFragment
                                                  : MTLFunctionTypeKernel;
}
- (NSDictionary<NSString *, MTLFunctionConstant *> *)functionConstantsDictionary { return @{}; }
- (MTLFunctionOptions)options { return MTLFunctionOptionNone; }
- (NSString *)description { return [NSString stringWithFormat:@"<VGMTLFunction %@ (%@)>", _name, _stage]; }
- (NSString *)vgLL { return _ll; }
- (NSString *)vgStage { return _stage; }
- (NSDictionary<NSNumber *, NSData *> *)vgFC { return _fc; }
- (VGMTLFunction *)specializedWith:(NSDictionary<NSNumber *, NSData *> *)fc {
    VGMTLFunction *f = [[VGMTLFunction alloc] initWithDevice:_device name:_name stage:_stage ll:_ll];
    f->_fc = [fc copy];
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
    NSDictionary<NSString *, VGMTLFunction *> *_functions;
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
    }
    return self;
}
- (NSArray<NSString *> *)functionNames { return _functions.allKeys; }
- (MTLLibraryType)type { return MTLLibraryTypeExecutable; }
- (NSString *)installName { return nil; }
- (id<MTLFunction>)newFunctionWithName:(NSString *)name {
    VGMTLFunction *f = _functions[name];
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
    if (d.constantValues) {
        return [self newFunctionWithName:d.name constantValues:d.constantValues error:error];
    }
    if (error) {
        *error = nil;
    }
    id<MTLFunction> f = [self newFunctionWithName:d.name];
    if (!f && error) {
        *error = vg_lib_error([NSString stringWithFormat:@"no function %@", d.name]);
    }
    return f;
}
@end

id<MTLLibrary> vg_new_library(id<MTLDevice> device, NSData *lib, NSError **error) {
    if (error) {
        *error = nil;
    }
    NSMutableDictionary *fns = [NSMutableDictionary dictionary];
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
        NSString *name = nil, *stage = nil;
        if (ll && vg_entry_of(ll, &name, &stage)) {
            fns[name] = [[VGMTLFunction alloc] initWithDevice:device name:name stage:stage ll:ll];
        }
        i += off + size - 1;
    }
    vglog("library: %lu bytes, %lu bitcode blobs, entries: %s", (unsigned long)n, (unsigned long)blobs,
          [[fns.allKeys componentsJoinedByString:@", "] UTF8String]);
    if (!fns.count) {
        if (error) {
            *error = [NSError errorWithDomain:MTLLibraryErrorDomain code:MTLLibraryErrorUnsupported
                                     userInfo:@{NSLocalizedDescriptionKey : @"no entry points could be read"}];
        }
        return nil;
    }
    return [[VGMTLLibrary alloc] initWithDevice:device functions:fns];
}
