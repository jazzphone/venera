// Shader libraries: a .metallib's AIR bitcode -> LLVM IR text (Apple's own LLVM in GPUCompiler.framework, dyld
// cache) -> SPIR-V + reflection (NV's metal2vulkan wrapper, Contents/Resources/libnvmtl_translate.dylib, LGPL).
// The path is NV's (plugin/NVMTLLibraryLoad.m): bitcode blobs found by their wrapper magic, entry name and stage from
// the !air.kernel / !air.vertex / !air.fragment metadata.
#import "vg.h"
#import <dlfcn.h>

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
static xl_fn pTranslate, pReflect;
static void (*pTranslateFree)(uint8_t *, size_t);
static void (*pSetTgLengths)(const uint32_t *, uint32_t);

static BOOL vg_translator_ready(void) {
    static dispatch_once_t once;
    static BOOL ready;
    dispatch_once(&once, ^{
        NSString *path = vg_resource_path("libnvmtl_translate.dylib");
        void *h = path ? dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL) : NULL;
        if (!h) {
            vglog("library: no translator: %s", dlerror());
            return;
        }
        pTranslate = (xl_fn)dlsym(h, "nvmtl_translate");
        pReflect = (xl_fn)dlsym(h, "nvmtl_reflect");
        pTranslateFree = dlsym(h, "nvmtl_translate_free");
        pSetTgLengths = dlsym(h, "nvmtl_translate_set_threadgroup_lengths");
        ready = pTranslate && pReflect && pTranslateFree && pSetTgLengths;
        if (!ready) {
            vglog("library: the translator lacks an entry point");
        }
    });
    return ready;
}

NSData *vg_translate(NSString *ll, const char *stage, const uint32_t *tgLengths, uint32_t tgCount, NSString **error) {
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
    int r = pTranslate(ll.UTF8String, stage, &out, &len, err, sizeof(err));
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

NSDictionary *vg_reflect(NSString *ll, const char *stage, NSString **error) {
    if (!vg_translator_ready()) {
        if (error) {
            *error = @"no translator";
        }
        return nil;
    }
    uint8_t *out = NULL;
    size_t len = 0;
    char err[2048] = "";
    int r = pReflect(ll.UTF8String, stage, &out, &len, err, sizeof(err));
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
@end

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
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values
                                 error:(NSError **)error {
    return [self newFunctionWithName:name];
}
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d error:(NSError **)error {
    return [self newFunctionWithName:d.name];
}
@end

id<MTLLibrary> vg_new_library(id<MTLDevice> device, NSData *lib, NSError **error) {
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
