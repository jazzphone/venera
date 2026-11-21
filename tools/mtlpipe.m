// mtlpipe: build one render pipeline from a metallib, to bring back a pipeline an app was refused (with the faildump
// flag file naming mtlpipe, the shader the translator can't take is saved). Every function constant gets VALUE
// (default 0; bool constants true when VALUE isn't 0).
//   VGMTL_ENABLE=1 ./mtlpipe LIB.metallib VERTEX FRAGMENT [VALUE]
// Prints the functions' constants, then "mtlpipe: ok" or "mtlpipe: FAIL <error>".
// The driver lists no constants (functionConstantsDictionary is empty), so name one by hand: MTLPIPE_FC=INDEX:HEX sets
// that index to those bytes as a uint4 (16 bytes) or uint (4); MTLPIPE_FUZZ=N tries N random 16-byte values at that
// index instead, one pipeline each, and prints the ones refused.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static MTLFunctionConstantValues *gHand;   // MTLPIPE_FC's value, when set

static id<MTLFunction> function(id<MTLLibrary> lib, NSString *name, int value) {
    id<MTLFunction> plain = [lib newFunctionWithName:name];
    if (plain && gHand) {
        NSError *err = nil;
        id<MTLFunction> fn = [lib newFunctionWithName:name constantValues:gHand error:&err];
        return fn ? fn : plain;
    }
    if (!plain) {
        printf("mtlpipe: no function %s\n", name.UTF8String);
        exit(2);
    }
    if (!plain.functionConstantsDictionary.count) {
        return plain;
    }
    MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
    for (NSString *key in plain.functionConstantsDictionary) {
        MTLFunctionConstant *c = plain.functionConstantsDictionary[key];
        printf("  %s: constant %s (index %lu, type %lu%s)\n", name.UTF8String, key.UTF8String,
               (unsigned long)c.index, (unsigned long)c.type, c.required ? ", required" : "");
        uint64_t raw = (uint64_t)(int64_t)value;
        float f = value;
        uint16_t h;
        __fp16 hf = value;
        memcpy(&h, &hf, 2);
        bool b = value != 0;
        const void *p = &raw;
        switch (c.type) {
        case MTLDataTypeBool:
            p = &b;
            break;
        case MTLDataTypeFloat:
            p = &f;
            break;
        case MTLDataTypeHalf:
            p = &h;
            break;
        default:
            break;
        }
        [values setConstantValue:p type:c.type atIndex:c.index];
    }
    NSError *err = nil;
    id<MTLFunction> fn = [lib newFunctionWithName:name constantValues:values error:&err];
    if (!fn) {
        printf("mtlpipe: FAIL specializing %s: %s\n", name.UTF8String, err.localizedDescription.UTF8String);
        exit(1);
    }
    return fn;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: mtlpipe LIB.metallib VERTEX FRAGMENT [VALUE]\n");
            return 2;
        }
        int value = argc > 4 ? atoi(argv[4]) : 0;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("mtlpipe: device %s\n", dev.name.UTF8String);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&err];
        if (!lib) {
            printf("mtlpipe: FAIL library: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        const char *hand = getenv("MTLPIPE_FC");
        int fuzz = getenv("MTLPIPE_FUZZ") ? atoi(getenv("MTLPIPE_FUZZ")) : 0;
        if (hand) {
            unsigned idx = (unsigned)strtoul(hand, NULL, 0);
            const char *hex = strchr(hand, ':');
            uint8_t bytes[16] = {0};
            size_t nb = hex ? strlen(hex + 1) / 2 : 16;
            for (size_t k = 0; hex && k < nb && k < 16; k++) {
                sscanf(hex + 1 + 2 * k, "%2hhx", &bytes[k]);
            }
            for (int round = 0; round < (fuzz ? fuzz : 1); round++) {
                if (fuzz) {
                    arc4random_buf(bytes, 16);
                }
                gHand = [MTLFunctionConstantValues new];
                [gHand setConstantValue:bytes type:nb <= 4 && !fuzz ? MTLDataTypeUInt : MTLDataTypeUInt4 atIndex:idx];
                MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
                d.vertexFunction = function(lib, @(argv[2]), value);
                d.fragmentFunction = function(lib, @(argv[3]), value);
                d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
                id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&err];
                printf("mtlpipe: %d:", idx);
                for (int k = 0; k < 16; k++) {
                    printf("%02x", bytes[k]);
                }
                printf(" %s\n", ps ? "ok" : [NSString stringWithFormat:@"FAIL %@", err.localizedDescription].UTF8String);
            }
            return 0;
        }
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = function(lib, @(argv[2]), value);
        d.fragmentFunction = function(lib, @(argv[3]), value);
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        if (!ps) {
            printf("mtlpipe: FAIL %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        printf("mtlpipe: ok\n");
        return 0;
    }
}
