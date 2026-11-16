// Pipeline reflection (stage 5d): what MTLRenderPipelineReflection / MTLComputePipelineReflection report for our
// functions: each stage's buffer, texture and sampler arguments, with a buffer's struct members by name and offset.
// Engines and Apple's own layers bind by it; Apple's OpenGL-on-Metal renderer writes GL uniforms into a buffer by the
// member names and offsets reflected here. Built from the translator's reflection (vg_reflect: bindings, sizes,
// argument-buffer fields, vertex attributes) and the names in the function's AIR metadata (air.arg_name,
// struct_type_info).
//
// After nullmoth/nvidia-macos-driver's plugin/NVMTLObjects.m and NVMTLLibraryLoad.m (NVMTLType ... NVMTLArgument,
// nvmtl_arguments_for_function, nvmtl_build_buffer_argument, nvmtl_air_names and its walkers; PolyForm Noncommercial
// 1.0.0, Copyright (c) 2026 NullMoth Systems).
#import "objects.h"
#import <objc/runtime.h>

@interface VGReflType : NSObject {
@public
    MTLDataType _dataType;
}
@end
@implementation VGReflType
- (MTLDataType)dataType { return _dataType; }
@end
@interface VGReflTextureReferenceType : VGReflType {
@public
    MTLDataType _texDataType;
    MTLTextureType _texType;
    MTLBindingAccess _access;
    BOOL _depth;
}
@end
@implementation VGReflTextureReferenceType
- (MTLDataType)textureDataType { return _texDataType; }
- (MTLTextureType)textureType { return _texType; }
- (MTLBindingAccess)access { return _access; }
- (BOOL)isDepthTexture { return _depth; }
@end
@interface VGReflStructType : VGReflType {
@public
    NSArray *_members;
}
@end
@interface VGReflStructMember : NSObject {
@public
    NSString *_name;
    NSUInteger _offset, _argIndex;
    MTLDataType _dataType;
    id _arr, _struct, _texRef, _ptr;
}
@end
@implementation VGReflStructType
- (NSArray *)members { return _members ?: @[]; }
- (id)memberByName:(NSString *)n {
    for (VGReflStructMember *m in _members) {
        if ([m->_name isEqualToString:n]) {
            return m;
        }
    }
    return nil;
}
@end
@interface VGReflArrayType : VGReflType {
@public
    MTLDataType _elem;
    NSUInteger _len, _stride;
}
@end
@implementation VGReflArrayType
- (MTLDataType)elementType { return _elem; }
- (NSUInteger)arrayLength { return _len; }
- (NSUInteger)stride { return _stride; }
- (NSUInteger)argumentIndexStride { return 0; }
- (id)elementStructType { return nil; }
- (id)elementArrayType { return nil; }
- (id)elementTextureReferenceType { return nil; }
- (id)elementPointerType { return nil; }
@end
@interface VGReflPointerType : VGReflType {
@public
    MTLDataType _elem;
    MTLBindingAccess _access;
    NSUInteger _align, _size;
    BOOL _isArgBuf;
    VGReflStructType *_elemStruct;
}
@end
@implementation VGReflPointerType
- (MTLDataType)elementType { return _elem; }
- (MTLBindingAccess)access { return _access; }
- (NSUInteger)alignment { return _align ?: 16; }
- (NSUInteger)dataSize { return _size; }
- (BOOL)elementIsArgumentBuffer { return _isArgBuf; }
- (id)elementStructType { return _elemStruct; }
- (id)elementArrayType { return nil; }
@end
@implementation VGReflStructMember
- (NSString *)name { return _name ?: @""; }
- (NSUInteger)offset { return _offset; }
- (MTLDataType)dataType { return _dataType; }
- (NSUInteger)argumentIndex { return _argIndex; }
- (id)structType { return _struct; }
- (id)arrayType { return _arr; }
- (id)textureReferenceType { return _texRef; }
- (id)pointerType { return _ptr; }
@end
// _type holds MTLArgumentType values; MTLBindingType numbers them the same.
@interface VGReflArgument : NSObject {
@public
    NSString *_name;
    NSUInteger _type, _index, _arrayLength, _bufAlign, _bufSize;
    MTLBindingAccess _access;
    BOOL _active, _depth;
    MTLDataType _bufDataType, _texDataType;
    VGReflStructType *_bufStruct;
    VGReflPointerType *_bufPtr;
    MTLTextureType _texType;
}
@end
@implementation VGReflArgument
- (NSString *)name { return _name ?: @""; }
- (NSUInteger)type { return _type; }
- (MTLBindingAccess)access { return _access; }
- (NSUInteger)index { return _index; }
- (BOOL)isActive { return _active; }
- (BOOL)isUsed { return _active; }
- (BOOL)isArgument { return YES; }
- (NSUInteger)arrayLength { return _arrayLength ?: 1; }
- (NSUInteger)bufferAlignment { return _bufAlign ?: 16; }
- (NSUInteger)bufferDataSize { return _bufSize; }
- (MTLDataType)bufferDataType { return _bufDataType; }
- (id)bufferStructType { return _bufStruct; }
- (id)bufferPointerType { return _bufPtr; }
- (MTLTextureType)textureType { return _texType; }
- (MTLDataType)textureDataType { return _texDataType; }
- (BOOL)isDepthTexture { return _depth; }
- (NSUInteger)threadgroupMemoryAlignment { return 16; }
- (NSUInteger)threadgroupMemoryDataSize { return 0; }
@end
@interface VGReflStageInArgument : VGReflArgument
@end
@implementation VGReflStageInArgument
- (BOOL)isArgument { return NO; }
@end

@interface VGMTLRenderPipelineReflection : NSObject {
@public
    NSArray *_v, *_f;
    NSData *_vpr, *_fpr;   // OpenGL: what Apple's GL code generator returned for each stage (VGMTLGL.m)
}
@end
@implementation VGMTLRenderPipelineReflection
- (NSData *)vertexPluginReturnData { return _vpr; }
- (NSData *)fragmentPluginReturnData { return _fpr; }
- (NSArray *)vertexArguments { return _v ?: @[]; }
- (NSArray *)fragmentArguments { return _f ?: @[]; }
- (NSArray *)tileArguments { return @[]; }
- (NSArray *)vertexBindings { return _v ?: @[]; }
- (NSArray *)fragmentBindings { return _f ?: @[]; }
- (NSArray *)tileBindings { return @[]; }
- (NSArray *)objectBindings { return @[]; }
- (NSArray *)meshBindings { return @[]; }
- (uint64_t)usageFlags { return 0; }
- (NSDictionary *)performanceStatistics { return @{}; }
@end
@interface VGMTLComputePipelineReflection : NSObject {
@public
    NSArray *_a;
}
@end
@implementation VGMTLComputePipelineReflection
- (NSArray *)arguments { return _a ?: @[]; }
- (NSArray *)bindings { return _a ?: @[]; }
- (uint64_t)usageFlags { return 0; }
- (NSDictionary *)performanceStatistics { return @{}; }
@end

// ---- from names and the translator's words ------------------------------------------------------------------------

static MTLDataType vg_datatype_for_air_name(NSString *t) {
    if (![t isKindOfClass:[NSString class]] || !t.length) {
        return MTLDataTypeNone;
    }
    if ([t hasPrefix:@"texture"] || [t hasPrefix:@"depth"]) {
        return MTLDataTypeTexture;
    }
    if ([t isEqualToString:@"sampler"]) {
        return MTLDataTypeSampler;
    }
    static NSDictionary *tab;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      tab = @{@"float" : @(MTLDataTypeFloat), @"float2" : @(MTLDataTypeFloat2), @"float3" : @(MTLDataTypeFloat3),
              @"float4" : @(MTLDataTypeFloat4), @"float2x2" : @(MTLDataTypeFloat2x2), @"float3x3" : @(MTLDataTypeFloat3x3),
              @"float4x4" : @(MTLDataTypeFloat4x4), @"float3x4" : @(MTLDataTypeFloat3x4), @"float4x3" : @(MTLDataTypeFloat4x3),
              @"half" : @(MTLDataTypeHalf), @"half2" : @(MTLDataTypeHalf2), @"half3" : @(MTLDataTypeHalf3),
              @"half4" : @(MTLDataTypeHalf4), @"int" : @(MTLDataTypeInt), @"int2" : @(MTLDataTypeInt2),
              @"int3" : @(MTLDataTypeInt3), @"int4" : @(MTLDataTypeInt4), @"uint" : @(MTLDataTypeUInt),
              @"uint2" : @(MTLDataTypeUInt2), @"uint3" : @(MTLDataTypeUInt3), @"uint4" : @(MTLDataTypeUInt4),
              @"short" : @(MTLDataTypeShort), @"ushort" : @(MTLDataTypeUShort), @"char" : @(MTLDataTypeChar),
              @"uchar" : @(MTLDataTypeUChar), @"bool" : @(MTLDataTypeBool), @"long" : @(MTLDataTypeLong),
              @"ulong" : @(MTLDataTypeULong)};
    });
    NSNumber *n = tab[t];
    if (n) {
        return (MTLDataType)n.integerValue;
    }
    if ([t hasSuffix:@"*"] || [t hasPrefix:@"device "] || [t hasPrefix:@"constant "]) {
        return MTLDataTypePointer;
    }
    return MTLDataTypeStruct;
}
static MTLBindingAccess vg_access_for(id a) {
    NSString *s = [a isKindOfClass:[NSString class]] ? a : nil;
    if ([s isEqualToString:@"ReadWrite"] || [s isEqualToString:@"Storage"]) {
        return MTLBindingAccessReadWrite;
    }
    if ([s isEqualToString:@"WriteOnly"]) {
        return MTLBindingAccessWriteOnly;
    }
    return MTLBindingAccessReadOnly;
}
static MTLTextureType vg_textype_for_shape(id shape) {
    NSString *s = [shape isKindOfClass:[NSString class]] ? shape : [shape description];
    if (!s.length) {
        return MTLTextureType2D;
    }
    if ([s rangeOfString:@"CubeArray"].location != NSNotFound) {
        return MTLTextureTypeCubeArray;
    }
    if ([s rangeOfString:@"Cube"].location != NSNotFound) {
        return MTLTextureTypeCube;
    }
    if ([s rangeOfString:@"3D"].location != NSNotFound || [s rangeOfString:@"3d"].location != NSNotFound ||
        [s rangeOfString:@"Three"].location != NSNotFound) {
        return MTLTextureType3D;
    }
    if ([s rangeOfString:@"1D"].location != NSNotFound || [s rangeOfString:@"1d"].location != NSNotFound ||
        [s rangeOfString:@"One"].location != NSNotFound) {
        return [s rangeOfString:@"Array"].location != NSNotFound ? MTLTextureType1DArray : MTLTextureType1D;
    }
    if ([s rangeOfString:@"Multisample"].location != NSNotFound || [s rangeOfString:@"MS"].location != NSNotFound) {
        return MTLTextureType2DMultisample;
    }
    return [s rangeOfString:@"Array"].location != NSNotFound ? MTLTextureType2DArray : MTLTextureType2D;
}
static MTLDataType vg_texdatatype_for_air_name(NSString *tn) {
    if (![tn isKindOfClass:[NSString class]]) {
        return MTLDataTypeFloat;
    }
    if ([tn rangeOfString:@"<uint"].location != NSNotFound || [tn rangeOfString:@"<ushort"].location != NSNotFound) {
        return MTLDataTypeUInt;
    }
    if ([tn rangeOfString:@"<int"].location != NSNotFound || [tn rangeOfString:@"<short"].location != NSNotFound) {
        return MTLDataTypeInt;
    }
    if ([tn rangeOfString:@"<half"].location != NSNotFound) {
        return MTLDataTypeHalf;
    }
    return MTLDataTypeFloat;
}
static BOOL vg_binding_active(NSDictionary *b) {
    id acc = b[@"access"];
    return !([acc isKindOfClass:[NSString class]] && [acc isEqualToString:@"Unused"]);
}

// ---- names from the AIR metadata ----------------------------------------------------------------------------------

static NSString *vg_air_quoted_after(NSString *line, NSString *key, NSUInteger from) {
    NSString *k = [NSString stringWithFormat:@"!\"%@\", !\"", key];
    NSRange r = [line rangeOfString:k options:0 range:NSMakeRange(from, line.length - from)];
    if (r.location == NSNotFound) {
        return nil;
    }
    NSUInteger s = r.location + r.length;
    NSRange q = [line rangeOfString:@"\"" options:0 range:NSMakeRange(s, line.length - s)];
    return q.location == NSNotFound ? nil : [line substringWithRange:NSMakeRange(s, q.location - s)];
}
static NSInteger vg_air_i32_after(NSString *line, NSString *key) {
    NSString *k = [NSString stringWithFormat:@"!\"%@\", i32 ", key];
    NSRange r = [line rangeOfString:k];
    if (r.location == NSNotFound) {
        return -1;
    }
    return [[line substringFromIndex:r.location + r.length] integerValue];
}
static NSString *vg_air_node_after(NSString *line, NSString *key, NSUInteger from, NSUInteger *end) {
    NSString *k = [NSString stringWithFormat:@"!\"%@\", !", key];
    NSRange r = [line rangeOfString:k options:0 range:NSMakeRange(from, line.length - from)];
    if (r.location == NSNotFound) {
        return nil;
    }
    NSUInteger s = r.location + r.length, e = s;
    while (e < line.length && isdigit([line characterAtIndex:e])) {
        e++;
    }
    if (end) {
        *end = e;
    }
    return e > s ? [@"!" stringByAppendingString:[line substringWithRange:NSMakeRange(s, e - s)]] : nil;
}
static NSString *vg_air_quoted_before(NSString *line, NSUInteger at, NSUInteger *start) {
    if (at < 4 || [line characterAtIndex:at - 1] != '"') {
        return nil;
    }
    NSRange q = [line rangeOfString:@"!\"" options:NSBackwardsSearch range:NSMakeRange(0, at - 1)];
    if (q.location == NSNotFound) {
        return nil;
    }
    if (start) {
        *start = q.location;
    }
    return [line substringWithRange:NSMakeRange(q.location + 2, at - 1 - (q.location + 2))];
}
static void vg_air_walk_struct(NSDictionary *nodes, NSString *node, NSString *bufKey, NSMutableDictionary *members,
                               NSMutableDictionary *types, NSMutableSet *seen) {
    if (!node || [seen containsObject:node]) {
        return;
    }
    [seen addObject:node];
    NSString *line = nodes[node];
    if (!line) {
        return;
    }
    NSString *tag = @"!\"air.indirect_argument\", ";
    NSRange r = [line rangeOfString:tag];
    while (r.location != NSNotFound) {
        NSUInteger nameStart = 0;
        NSString *name = r.location >= 2 ? vg_air_quoted_before(line, r.location - 2, &nameStart) : nil;
        NSString *type = (name && nameStart >= 2) ? vg_air_quoted_before(line, nameStart - 2, NULL) : nil;
        NSUInteger after = r.location + r.length;
        NSInteger id_ = -1;
        if ([line rangeOfString:@"i32 " options:NSAnchoredSearch range:NSMakeRange(after, line.length - after)].location != NSNotFound) {
            id_ = [[line substringFromIndex:after + 4] integerValue];
        } else if (after < line.length && [line characterAtIndex:after] == '!') {
            NSUInteger e = after + 1;
            while (e < line.length && isdigit([line characterAtIndex:e])) {
                e++;
            }
            NSString *argLine = nodes[[line substringWithRange:NSMakeRange(after, e - after)]];
            if (argLine) {
                id_ = vg_air_i32_after(argLine, @"air.location_index");
                NSRange i0 = [argLine rangeOfString:@"!{i32 "];
                if (id_ < 0 && i0.location != NSNotFound) {
                    id_ = [[argLine substringFromIndex:i0.location + 6] integerValue];
                }
            }
        }
        if (name && id_ >= 0) {
            NSString *k = [NSString stringWithFormat:@"%@:%ld", bufKey, (long)id_];
            if (!members[k]) {
                members[k] = name;
                if (type) {
                    types[k] = type;
                }
            }
        }
        r = [line rangeOfString:tag options:0 range:NSMakeRange(after, line.length - after)];
    }
}
static void vg_air_plain_struct(NSDictionary *nodes, NSString *node, NSInteger loc, NSMutableDictionary *plain) {
    NSString *line = node ? nodes[node] : nil;
    if (!line || loc < 0 || [line rangeOfString:@"!\"air.indirect_argument\""].location != NSNotFound) {
        return;
    }
    NSRange br = [line rangeOfString:@"!{"];
    if (br.location == NSNotFound) {
        return;
    }
    NSMutableArray *tok = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    BOOL q = NO;
    for (NSUInteger i = br.location + 2; i < line.length; i++) {
        unichar c = [line characterAtIndex:i];
        if (c == '"') {
            q = !q;
        }
        if (!q && (c == ',' || c == '}')) {
            NSString *t = [cur stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length) {
                [tok addObject:t];
            }
            [cur setString:@""];
            if (c == '}') {
                break;
            }
            continue;
        }
        [cur appendFormat:@"%C", c];
    }
    NSMutableArray *ms = [NSMutableArray array];
    for (NSUInteger i = 0; i + 4 < tok.count;) {
        NSString *a = tok[i], *b = tok[i + 1], *c = tok[i + 2], *t = tok[i + 3], *n = tok[i + 4];
        if ([a hasPrefix:@"i32 "] && [b hasPrefix:@"i32 "] && [c hasPrefix:@"i32 "] && [t hasPrefix:@"!\""] &&
            [n hasPrefix:@"!\""] && t.length > 3 && n.length > 3) {
            [ms addObject:@{@"off" : @([[a substringFromIndex:4] integerValue]),
                            @"size" : @([[b substringFromIndex:4] integerValue]),
                            @"count" : @([[c substringFromIndex:4] integerValue]),
                            @"type" : [t substringWithRange:NSMakeRange(2, t.length - 3)],
                            @"name" : [n substringWithRange:NSMakeRange(2, n.length - 3)]}];
            i += 5;
        } else {
            i++;
        }
    }
    if (ms.count) {
        plain[@(loc)] = ms;
    }
}

static char kNamesKey, kReflKey, kArgsKey;

// argument names (kind:index), struct member names (index:argument), their AIR type names, plain struct layouts
static NSDictionary *vg_air_names(id fn) {
    @synchronized(fn) {
        NSDictionary *have = objc_getAssociatedObject(fn, &kNamesKey);
        if (have) {
            return have;
        }
        NSMutableDictionary *args = [NSMutableDictionary new], *members = [NSMutableDictionary new],
                            *types = [NSMutableDictionary new], *plain = [NSMutableDictionary new];
        NSDictionary *out = @{@"args" : args, @"members" : members, @"types" : types, @"plain" : plain};
        objc_setAssociatedObject(fn, &kNamesKey, out, OBJC_ASSOCIATION_RETAIN);
        NSString *ll = [fn vgLL], *fname = [(id<MTLFunction>)fn name];
        if (!ll.length || !fname.length) {
            return out;
        }
        NSMutableDictionary *nodes = [NSMutableDictionary new];
        NSString *entryLine = nil;
        NSString *needle1 = [NSString stringWithFormat:@"@%@, ", fname], *needle2 = [NSString stringWithFormat:@"@\"%@\", ", fname];
        NSString *needle = nil;
        for (NSString *line in [ll componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"!"]) {
                continue;
            }
            NSRange eq = [line rangeOfString:@" = !{"];
            if (eq.location == NSNotFound) {
                continue;
            }
            nodes[[line substringToIndex:eq.location]] = line;
            if (!entryLine) {
                if ([line rangeOfString:needle1].location != NSNotFound) {
                    entryLine = line, needle = needle1;
                } else if ([line rangeOfString:needle2].location != NSNotFound) {
                    entryLine = line, needle = needle2;
                }
            }
        }
        if (!entryLine) {
            return out;
        }
        NSRange nr = [entryLine rangeOfString:needle];
        NSArray *erefs = [[entryLine substringFromIndex:nr.location + nr.length] componentsSeparatedByString:@", "];
        if (erefs.count < 2) {
            return out;
        }
        NSString *argsRef = [erefs[1] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"} "]];
        NSString *argsLine = nodes[argsRef];
        NSRange br = argsLine ? [argsLine rangeOfString:@"!{"] : (NSRange){NSNotFound, 0};
        if (br.location == NSNotFound) {
            return out;
        }
        NSArray *refs = [[[argsLine substringFromIndex:br.location + 2] stringByReplacingOccurrencesOfString:@"}" withString:@""]
            componentsSeparatedByString:@", "];
        for (NSString *ref0 in refs) {
            NSString *line = nodes[[ref0 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            if (!line) {
                continue;
            }
            NSString *kind = nil;
            if ([line rangeOfString:@"!\"air.buffer\""].location != NSNotFound ||
                [line rangeOfString:@"!\"air.indirect_buffer\""].location != NSNotFound) {
                kind = @"buffer";
            } else if ([line rangeOfString:@"!\"air.texture\""].location != NSNotFound) {
                kind = @"texture";
            } else if ([line rangeOfString:@"!\"air.sampler\""].location != NSNotFound) {
                kind = @"sampler";
            } else {
                continue;
            }
            NSInteger loc = vg_air_i32_after(line, @"air.location_index");
            NSString *name = vg_air_quoted_after(line, @"air.arg_name", 0);
            if (loc < 0 || !name) {
                continue;
            }
            NSString *k = [NSString stringWithFormat:@"%@:%ld", kind, (long)loc];
            args[k] = name;
            NSString *tn = vg_air_quoted_after(line, @"air.arg_type_name", 0);
            if (tn) {
                types[k] = tn;
            }
            if ([kind isEqualToString:@"buffer"]) {
                NSString *st = vg_air_node_after(line, @"air.struct_type_info", 0, NULL);
                if (st) {
                    vg_air_walk_struct(nodes, st, [NSString stringWithFormat:@"%ld", (long)loc], members, types, [NSMutableSet new]);
                    vg_air_plain_struct(nodes, st, loc, plain);
                }
            }
        }
        return out;
    }
}

static NSDictionary *vg_function_reflection(id fn) {
    @synchronized(fn) {
        NSDictionary *have = objc_getAssociatedObject(fn, &kReflKey);
        if (have) {
            return have.count ? have : nil;
        }
        NSString *why = nil;
        NSString *stage = [fn vgStage];
        NSDictionary *r = vg_reflect([fn vgLL], stage.UTF8String, [fn vgFC], &why);
        objc_setAssociatedObject(fn, &kReflKey, r ?: @{}, OBJC_ASSOCIATION_RETAIN);
        if (!r) {
            static int logged;
            if (logged++ < 5) {
                vglog("reflection: %s: %s", [(id<MTLFunction>)fn name].UTF8String, why.UTF8String ?: "failed");
            }
        }
        return r.count ? r : nil;
    }
}

static VGReflArgument *vg_build_buffer_argument(NSUInteger index, NSDictionary *binding, NSDictionary *refl,
                                                NSDictionary *names) {
    VGReflArgument *a = [VGReflArgument new];
    a->_type = MTLBindingTypeBuffer;
    a->_index = index;
    a->_active = vg_binding_active(binding);
    a->_arrayLength = 1;
    a->_bufAlign = 16;
    NSString *key = [NSString stringWithFormat:@"buffer:%lu", (unsigned long)index];
    a->_name = names[@"args"][key] ?: [NSString stringWithFormat:@"buffer%lu", (unsigned long)index];
    a->_access = vg_access_for(binding[@"access"]);
    id ds = binding[@"declared_size"];
    a->_bufSize = [ds isKindOfClass:[NSNumber class]] ? [ds unsignedLongValue] : 0;
    NSMutableArray *members = [NSMutableArray new];
    NSDictionary *memberNames = names[@"members"], *types = names[@"types"];
    NSString *bufKeyPrefix = [NSString stringWithFormat:@"%lu:", (unsigned long)index];
    NSMutableDictionary *kindAt = [NSMutableDictionary new];
    for (NSDictionary *b in refl[@"bindings"]) {
        NSDictionary *src = [b isKindOfClass:[NSDictionary class]] ? b[@"embedded_source"] : nil;
        if (![src isKindOfClass:[NSDictionary class]] || [src[@"buffer_index"] unsignedLongValue] != index) {
            continue;
        }
        kindAt[src[@"field_offset"]] = [b[@"kind"] isEqualToString:@"EmbeddedArgBufferSampler"] ? @"sampler" : @"texture";
    }
    NSUInteger end = 0;
    for (NSDictionary *f0 in refl[@"argument_buffer_fields"]) {
        if ([f0[@"buffer_index"] unsignedLongValue] != index) {
            continue;
        }
        VGReflStructMember *m = [VGReflStructMember new];
        m->_offset = [f0[@"field_offset"] unsignedLongValue];
        m->_argIndex = [f0[@"argument_index"] unsignedLongValue];
        NSString *mk = [bufKeyPrefix stringByAppendingFormat:@"%lu", (unsigned long)m->_argIndex];
        m->_name = memberNames[mk] ?: [NSString stringWithFormat:@"field%lu", (unsigned long)m->_argIndex];
        NSString *tn = types[mk], *kind = kindAt[f0[@"field_offset"]];
        if ([kind isEqualToString:@"sampler"]) {
            m->_dataType = MTLDataTypeSampler;
        } else if ([kind isEqualToString:@"texture"]) {
            m->_dataType = MTLDataTypeTexture;
        } else if ([f0[@"resource_buffer_index"] isKindOfClass:[NSNumber class]]) {
            m->_dataType = MTLDataTypePointer;
        } else {
            m->_dataType = tn ? vg_datatype_for_air_name(tn) : MTLDataTypePointer;
        }
        if (m->_dataType == MTLDataTypeTexture) {
            VGReflTextureReferenceType *t = [VGReflTextureReferenceType new];
            t->_dataType = MTLDataTypeTexture;
            t->_texDataType = MTLDataTypeFloat;
            t->_texType = [tn rangeOfString:@"cube"].location != NSNotFound       ? MTLTextureTypeCube
                          : [tn rangeOfString:@"3d"].location != NSNotFound       ? MTLTextureType3D
                          : [tn rangeOfString:@"2d_array"].location != NSNotFound ? MTLTextureType2DArray
                                                                                  : MTLTextureType2D;
            t->_depth = [tn hasPrefix:@"depth"];
            m->_texRef = t;
        }
        if (m->_dataType == MTLDataTypePointer) {
            VGReflPointerType *p = [VGReflPointerType new];
            p->_dataType = MTLDataTypePointer;
            p->_elem = MTLDataTypeStruct;
            p->_align = 16;
            m->_ptr = p;
        }
        NSUInteger e = m->_offset + (m->_dataType == MTLDataTypeFloat4x4 ? 64 : m->_dataType == MTLDataTypeFloat3x3 ? 48 : 8);
        end = MAX(end, e);
        [members addObject:m];
    }
    NSArray *airPlain = [names[@"plain"] isKindOfClass:[NSDictionary class]] ? names[@"plain"][@(index)] : nil;
    if (!members.count && [airPlain isKindOfClass:[NSArray class]] && airPlain.count) {
        NSUInteger i = 0;
        for (NSDictionary *am in airPlain) {
            VGReflStructMember *m = [VGReflStructMember new];
            m->_offset = [am[@"off"] unsignedLongValue];
            m->_argIndex = i++;
            m->_name = am[@"name"];
            m->_dataType = vg_datatype_for_air_name(am[@"type"]);
            if (m->_dataType == MTLDataTypeNone) {
                m->_dataType = MTLDataTypeStruct;
            }
            // an array member is reported as Apple does, MTLDataTypeArray with its MTLArrayType (engines size their
            // uniform copies from it)
            NSUInteger cnt = [am[@"count"] unsignedLongValue], sz = [am[@"size"] unsignedLongValue];
            if (cnt > 1) {
                VGReflArrayType *at = [VGReflArrayType new];
                at->_dataType = MTLDataTypeArray;
                at->_elem = m->_dataType;
                at->_len = cnt;
                at->_stride = sz;
                m->_arr = at;
                m->_dataType = MTLDataTypeArray;
            }
            end = MAX(end, m->_offset + sz * (cnt > 1 ? cnt : 1));
            [members addObject:m];
        }
    }
    if (!members.count && [binding[@"type_layout"] isKindOfClass:[NSDictionary class]]) {
        NSUInteger i = 0;
        for (NSDictionary *am in binding[@"type_layout"][@"Struct"]) {
            if (![am isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            VGReflStructMember *m = [VGReflStructMember new];
            m->_offset = [am[@"offset"] unsignedLongValue];
            m->_argIndex = i;
            NSString *mk = [bufKeyPrefix stringByAppendingFormat:@"%lu", (unsigned long)i];
            m->_name = memberNames[mk] ?: [NSString stringWithFormat:@"m%lu", (unsigned long)i];
            NSString *tn = types[mk];
            m->_dataType = tn ? vg_datatype_for_air_name(tn) : MTLDataTypeFloat;
            [members addObject:m];
            i++;
        }
    }
    if (members.count) {
        [members sortUsingComparator:^NSComparisonResult(VGReflStructMember *x, VGReflStructMember *y) {
          return x->_offset < y->_offset ? NSOrderedAscending : x->_offset > y->_offset ? NSOrderedDescending : NSOrderedSame;
        }];
        a->_bufDataType = MTLDataTypeStruct;
        a->_bufStruct = [VGReflStructType new];
        a->_bufStruct->_dataType = MTLDataTypeStruct;
        a->_bufStruct->_members = members;
        if (!a->_bufSize) {
            a->_bufSize = end;
        }
    } else {
        NSString *tn = names[@"types"][key];
        a->_bufDataType = tn ? vg_datatype_for_air_name(tn) : MTLDataTypeStruct;
        if (a->_bufDataType == MTLDataTypeTexture || a->_bufDataType == MTLDataTypeSampler || a->_bufDataType == MTLDataTypeNone) {
            a->_bufDataType = MTLDataTypeStruct;
        }
    }
    VGReflPointerType *p = [VGReflPointerType new];
    p->_dataType = MTLDataTypePointer;
    p->_elem = a->_bufDataType;
    p->_access = a->_access;
    p->_align = 16;
    p->_size = a->_bufSize;
    p->_isArgBuf = kindAt.count > 0 || [refl[@"argument_buffer_fields"] count] > 0;
    p->_elemStruct = a->_bufStruct;
    a->_bufPtr = p;
    return a;
}

static NSArray *vg_arguments_for_function(id fn) {
    if (![fn respondsToSelector:@selector(vgLL)]) {
        return @[];
    }
    @synchronized(fn) {
        NSArray *have = objc_getAssociatedObject(fn, &kArgsKey);
        if (have) {
            return have;
        }
        NSDictionary *refl = vg_function_reflection(fn), *names = vg_air_names(fn);
        NSMutableArray *out = [NSMutableArray new];
        NSMutableSet *seenBuf = [NSMutableSet new];
        for (NSDictionary *b in refl[@"bindings"]) {
            if (![b isKindOfClass:[NSDictionary class]] || ![b[@"param_index"] isKindOfClass:[NSNumber class]]) {
                continue;
            }
            NSString *kind = b[@"kind"];
            NSUInteger idx = [b[@"metal_index"] unsignedLongValue];
            if ([kind isEqualToString:@"Buffer"]) {
                if ([seenBuf containsObject:@(idx)]) {
                    continue;
                }
                [seenBuf addObject:@(idx)];
                [out addObject:vg_build_buffer_argument(idx, b, refl, names)];
            } else if ([kind isEqualToString:@"Texture"] || [kind isEqualToString:@"TextureArray"] ||
                       [kind isEqualToString:@"StorageImage"]) {
                VGReflArgument *a = [VGReflArgument new];
                a->_type = MTLBindingTypeTexture;
                a->_index = idx;
                a->_active = vg_binding_active(b);
                NSString *k = [NSString stringWithFormat:@"texture:%lu", (unsigned long)idx];
                a->_name = names[@"args"][k] ?: [NSString stringWithFormat:@"texture%lu", (unsigned long)idx];
                a->_access = [kind isEqualToString:@"StorageImage"] ? MTLBindingAccessReadWrite : vg_access_for(b[@"access"]);
                a->_texType = vg_textype_for_shape(b[@"texture_shape"]);
                // depth and component type from the AIR type name: Apple's GL picks a texture unit's sampler type by them
                NSString *ttn = names[@"types"][k];
                a->_depth = [ttn isKindOfClass:[NSString class]] && [ttn rangeOfString:@"depth"].location != NSNotFound;
                a->_texDataType = vg_texdatatype_for_air_name(ttn);
                id loc = b[@"descriptor"];
                a->_arrayLength = [loc isKindOfClass:[NSDictionary class]] && [loc[@"count"] unsignedLongValue] > 1
                                      ? [loc[@"count"] unsignedLongValue]
                                      : 1;
                [out addObject:a];
            } else if ([kind isEqualToString:@"Sampler"]) {
                VGReflArgument *a = [VGReflArgument new];
                a->_type = MTLBindingTypeSampler;
                a->_index = idx;
                a->_active = vg_binding_active(b);
                a->_arrayLength = 1;
                NSString *k = [NSString stringWithFormat:@"sampler:%lu", (unsigned long)idx];
                a->_name = names[@"args"][k] ?: [NSString stringWithFormat:@"sampler%lu", (unsigned long)idx];
                [out addObject:a];
            }
        }
        [out sortUsingComparator:^NSComparisonResult(VGReflArgument *x, VGReflArgument *y) {
          if (x->_type != y->_type) {
              return x->_type < y->_type ? NSOrderedAscending : NSOrderedDescending;
          }
          return x->_index < y->_index ? NSOrderedAscending : x->_index > y->_index ? NSOrderedDescending : NSOrderedSame;
        }];
        objc_setAssociatedObject(fn, &kArgsKey, out, OBJC_ASSOCIATION_RETAIN);
        return out;
    }
}

// the vertex descriptor's buffers, as Apple lists them ahead of the vertex function's own arguments
static NSArray *vg_stage_in_arguments(MTLRenderPipelineDescriptor *d) {
    MTLVertexDescriptor *vd = d.vertexDescriptor;
    if (!vd || !d.vertexFunction) {
        return @[];
    }
    NSMutableSet *used = [NSMutableSet set];
    for (NSDictionary *va in vg_function_reflection(d.vertexFunction)[@"vertex_attributes"]) {
        if ([va isKindOfClass:[NSDictionary class]] && [va[@"location"] isKindOfClass:[NSNumber class]]) {
            [used addObject:va[@"location"]];
        }
    }
    NSMutableIndexSet *bufs = [NSMutableIndexSet indexSet], *live = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < 31; i++) {
        MTLVertexAttributeDescriptor *at = vd.attributes[i];
        if (at.format == MTLVertexFormatInvalid) {
            continue;
        }
        [bufs addIndex:at.bufferIndex];
        if ([used containsObject:@(i)]) {
            [live addIndex:at.bufferIndex];
        }
    }
    NSMutableArray *out = [NSMutableArray array];
    __block NSUInteger n = 0;
    [bufs enumerateIndexesUsingBlock:^(NSUInteger bi, BOOL *stop) {
      VGReflStageInArgument *a = [VGReflStageInArgument new];
      a->_type = MTLBindingTypeBuffer;
      a->_index = bi;
      a->_active = [live containsIndex:bi];
      a->_arrayLength = 1;
      a->_bufAlign = 4;
      a->_access = MTLBindingAccessReadOnly;
      a->_bufSize = vd.layouts[bi].stride;
      a->_bufDataType = MTLDataTypeStruct;
      a->_name = [NSString stringWithFormat:@"vertexBuffer.%lu", (unsigned long)n++];
      [out addObject:a];
    }];
    return out;
}

id vg_render_reflection(MTLRenderPipelineDescriptor *d) {
    VGMTLRenderPipelineReflection *r = [VGMTLRenderPipelineReflection new];
    r->_v = [vg_stage_in_arguments(d) arrayByAddingObjectsFromArray:vg_arguments_for_function(d.vertexFunction)];
    r->_f = vg_arguments_for_function(d.fragmentFunction);
    return r;
}

id vg_compute_reflection(id<MTLFunction> fn) {
    VGMTLComputePipelineReflection *r = [VGMTLComputePipelineReflection new];
    r->_a = vg_arguments_for_function(fn);
    return r;
}

void vg_reflection_set_plugin_data(id r, NSData *v, NSData *f) {
    if ([r isKindOfClass:[VGMTLRenderPipelineReflection class]]) {
        ((VGMTLRenderPipelineReflection *)r)->_vpr = v;
        ((VGMTLRenderPipelineReflection *)r)->_fpr = f;
    }
}
