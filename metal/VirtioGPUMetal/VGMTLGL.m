// OpenGL over Metal (stage 5d): Apple's AppleMetalOpenGLRenderer on this device.
//
// With the accelerator's IOGLBundleName = AppleMetalOpenGLRenderer (boot-arg vgpugl=1), an OpenGL process gets Apple's
// GL-on-Metal renderer instead of the software one. Its shaders reach us as Apple GL functions: GL IR plus "plugin
// data", which Apple's own code generator (libGLDPlugin, with GPUCompiler's LLVM) lowers to AIR in this process. The
// AIR then goes through our translator like any other function, and the renderer reads what the lowering returned
// (the plugin return data) back from the pipeline's reflection.
//
// After nullmoth/nvidia-macos-driver's plugin/NVMTLGL.m (PolyForm Noncommercial 1.0.0, Copyright (c) 2026 NullMoth
// Systems): the lowering calls, the function test, the descriptor rewrite and the reflection getters are theirs.
#import "objects.h"
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define VG_GL_LLVM "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib"
#define VG_GL_PLUGIN "/System/Library/Extensions/AppleMetalOpenGLRenderer.bundle/Contents/PlugIns/libGLDPlugin32023.dylib"

id<MTLFunction> vg_function_from_ll(id<MTLDevice> device, NSString *ll, NSString *stage, NSString *name);

typedef void *(*vg_gl_gen_fn)(void *, const void *, size_t, void *, size_t, void **, size_t *);
static struct {
    void *(*ctx_create)(void);
    void (*ctx_dispose)(void *);
    void (*mod_dispose)(void *);
    void *(*write_bc)(void *);
    const char *(*buf_start)(void *);
    size_t (*buf_size)(void *);
    void (*buf_dispose)(void *);
    vg_gl_gen_fn gen;
} gGL;
static NSString *gGLWhy;
static char gGLRetKey;

static BOOL vg_gl_ready(void) {
    static dispatch_once_t once;
    static BOOL ready;
    dispatch_once(&once, ^{
      void *llvm = dlopen(VG_GL_LLVM, RTLD_NOW | RTLD_LOCAL);
      void *plug = llvm ? dlopen(VG_GL_PLUGIN, RTLD_NOW | RTLD_LOCAL) : NULL;
      if (!llvm || !plug) {
          const char *e = dlerror();
          gGLWhy = [NSString stringWithFormat:@"GL lowering unavailable: %s", e ?: "dlopen failed"];
          vglog("GL: %s", gGLWhy.UTF8String);
          return;
      }
      gGL.ctx_create = dlsym(llvm, "LLVMContextCreate");
      gGL.ctx_dispose = dlsym(llvm, "LLVMContextDispose");
      gGL.mod_dispose = dlsym(llvm, "LLVMDisposeModule");
      gGL.write_bc = dlsym(llvm, "LLVMWriteBitcodeToMemoryBuffer");
      gGL.buf_start = dlsym(llvm, "LLVMGetBufferStart");
      gGL.buf_size = dlsym(llvm, "LLVMGetBufferSize");
      gGL.buf_dispose = dlsym(llvm, "LLVMDisposeMemoryBuffer");
      void (*init)(void) = dlsym(plug, "oglCodeGenServiceInitialize");
      gGL.gen = (vg_gl_gen_fn)dlsym(plug, "oglCodeGenServiceGenerateIRWithPluginDataAndPluginReturnData");
      if (!gGL.ctx_create || !gGL.ctx_dispose || !gGL.mod_dispose || !gGL.write_bc || !gGL.buf_start || !gGL.buf_size ||
          !gGL.buf_dispose || !init || !gGL.gen) {
          gGLWhy = @"GL lowering unavailable: a symbol is missing from libLLVM 32023 or libGLDPlugin32023";
          vglog("GL: %s", gGLWhy.UTF8String);
          return;
      }
      init();
      ready = YES;
      vglog("GL: in-process lowering ready (libGLDPlugin32023 + GPUCompiler 32023 libLLVM)");
    });
    return ready;
}

// GL IR + plugin data -> AIR bitcode (and the plugin's return data, which the renderer reads from the reflection).
static NSData *vg_gl_lower(NSData *ir, NSData *pd, NSData **retData, NSString **why) {
    if (!vg_gl_ready()) {
        *why = gGLWhy;
        return nil;
    }
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized(lock) {
        void *ctx = gGL.ctx_create(), *ret = NULL;
        size_t retn = 0;
        void *mod = gGL.gen(ctx, ir.bytes, ir.length, (void *)pd.bytes, pd.length, &ret, &retn);
        NSData *bc = nil;
        if (mod) {
            void *mb = gGL.write_bc(mod);
            if (mb) {
                bc = [NSData dataWithBytes:gGL.buf_start(mb) length:gGL.buf_size(mb)];
                gGL.buf_dispose(mb);
            }
            gGL.mod_dispose(mod);
        }
        if (ret && retn) {
            *retData = [NSData dataWithBytes:ret length:retn];
        }
        free(ret);
        gGL.ctx_dispose(ctx);
        if (!bc) {
            *why = mod ? @"the GL plugin's module would not serialize" : @"the GL plugin returned no module";
        }
        return bc;
    }
}

static NSError *vg_gl_error(NSString *what) {
    return [NSError errorWithDomain:@"VirtioGPUMetal" code:1 userInfo:@{NSLocalizedDescriptionKey : what}];
}

BOOL vg_gl_is_apple_gl_function(id f) {
    if (!f || [f respondsToSelector:@selector(vgLL)]) {
        return NO;
    }
    SEL bt = sel_registerName("bitcodeType"), bd = sel_registerName("bitcodeDataInternal");
    if (![f respondsToSelector:bt] || ![f respondsToSelector:bd]) {
        return NO;
    }
    return ((unsigned char (*)(id, SEL))objc_msgSend)(f, bt) == 1;
}

// An Apple GL function as one of ours (cached by its IR and plugin data), or f itself when it isn't one.
static id<MTLFunction> vg_gl_function(id<MTLDevice> device, id f, NSError **err) {
    if (!vg_gl_is_apple_gl_function(f)) {
        return f;
    }
    NSData *ir = [NSData dataWithData:(NSData *)((id(*)(id, SEL))objc_msgSend)(f, sel_registerName("bitcodeDataInternal"))];
    id pdo = [f respondsToSelector:sel_registerName("pluginData")] ? ((id(*)(id, SEL))objc_msgSend)(f, sel_registerName("pluginData"))
                                                                  : nil;
    NSData *pd = [pdo isKindOfClass:[NSData class]] ? pdo : nil;
    NSUInteger ft = [(id<MTLFunction>)f functionType];
    NSString *stage = ft == MTLFunctionTypeVertex ? @"vertex" : ft == MTLFunctionTypeFragment ? @"fragment" : nil;
    if (!ir.length || !pd || !stage) {
        if (err) {
            *err = vg_gl_error([NSString stringWithFormat:@"GL: function not bridgeable (GL IR %lu B, plugin data %s, type %lu)",
                                                        (unsigned long)ir.length, pd ? "present" : "missing", (unsigned long)ft]);
        }
        return nil;
    }
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    CC_SHA256_Update(&c, stage.UTF8String, (CC_LONG)stage.length);
    CC_SHA256_Update(&c, ir.bytes, (CC_LONG)ir.length);
    CC_SHA256_Update(&c, pd.bytes, (CC_LONG)pd.length);
    CC_SHA256_Final(h, &c);
    NSData *key = [NSData dataWithBytes:h length:sizeof(h)];
    static NSMutableDictionary *cache;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      cache = [NSMutableDictionary new];
      lock = [NSObject new];
    });
    @synchronized(lock) {
        id hit = cache[key];
        if (hit) {
            return hit;
        }
    }
    NSString *why = nil;
    NSData *retData = nil;
    NSData *bc = vg_gl_lower(ir, pd, &retData, &why);
    NSString *ll = bc ? vg_air_to_text(bc) : nil;
    id<MTLFunction> mine = ll ? vg_function_from_ll(device, ll, stage, @"__main") : nil;
    if (!mine) {
        if (err) {
            *err = vg_gl_error([NSString stringWithFormat:@"GL: %@", why ?: @"the lowered AIR would not load"]);
        }
        return nil;
    }
    if (retData) {
        objc_setAssociatedObject(mine, &gGLRetKey, retData, OBJC_ASSOCIATION_RETAIN);
    }
    static int said;
    if (said++ < 16) {
        vglog("GL: %s lowered (GL IR %lu B + plugin data %lu B -> %lu B AIR)", stage.UTF8String, (unsigned long)ir.length,
              (unsigned long)pd.length, (unsigned long)bc.length);
    }
    @synchronized(lock) {
        if (cache.count >= 4096) {
            [cache removeAllObjects];
        }
        cache[key] = mine;
    }
    return mine;
}

MTLRenderPipelineDescriptor *vg_gl_rewrite_descriptor(id<MTLDevice> device, MTLRenderPipelineDescriptor *d, NSError **err) {
    id v = d.vertexFunction, f = d.fragmentFunction;
    if (!vg_gl_is_apple_gl_function(v) && !vg_gl_is_apple_gl_function(f)) {
        return d;
    }
    id<MTLFunction> v2 = vg_gl_function(device, v, err);
    if (v && !v2) {
        return nil;
    }
    id<MTLFunction> f2 = vg_gl_function(device, f, err);
    if (f && !f2) {
        return nil;
    }
    MTLRenderPipelineDescriptor *c = [d copy];
    c.vertexFunction = v2;
    c.fragmentFunction = f2;
    return c;
}

// What the lowering returned, onto the pipeline's reflection (VGMTLReflection.m), where the renderer reads it.
void vg_reflection_set_plugin_data(id r, NSData *v, NSData *f);
void vg_gl_tag_reflection(id r, MTLRenderPipelineDescriptor *d) {
    NSData *v = d.vertexFunction ? objc_getAssociatedObject(d.vertexFunction, &gGLRetKey) : nil;
    NSData *f = d.fragmentFunction ? objc_getAssociatedObject(d.fragmentFunction, &gGLRetKey) : nil;
    if (v || f) {
        vg_reflection_set_plugin_data(r, v, f);
    }
}

// The renderer's private calls.
@implementation VGMTLCommandBuffer (GL)
- (void)commitAndHold { [self commit]; }
@end
@implementation VGMTLTexture (GL)
- (void)waitUntilComplete { }   // reads of a texture (getBytes) wait for its writes themselves
@end
