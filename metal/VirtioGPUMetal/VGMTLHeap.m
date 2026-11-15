// MTLHeap (stage 5a: CoreDisplay makes one when WindowServer creates its Metal device). No sub-allocation yet: each
// resource from the heap is an ordinary device allocation, the heap only keeps the books Metal callers read (size,
// used size). Placement offsets are ignored, so aliasing resources don't alias (nothing in WindowServer's path needs it
// so far). Resources report their heap and offset (vg_heap_of).
#import "objects.h"
#import <objc/runtime.h>

// Resources made by a heap keep it (Metal's resources retain their heap) and their place in it: Core Animation finds its
// transient surfaces again through -heap / -heapOffset ("transient surface not found" asserts when the heap is nil).
static char kHeapKey, kOffsetKey, kAliasKey;
id<MTLHeap> vg_heap_of(id r) { return objc_getAssociatedObject(r, &kHeapKey); }
NSUInteger vg_heap_offset_of(id r) { return [objc_getAssociatedObject(r, &kOffsetKey) unsignedIntegerValue]; }
BOOL vg_heap_aliasable(id r) { return [objc_getAssociatedObject(r, &kAliasKey) boolValue]; }
void vg_heap_make_aliasable(id r) {
    if (vg_heap_of(r)) {
        objc_setAssociatedObject(r, &kAliasKey, @YES, OBJC_ASSOCIATION_RETAIN);
    }
}
static void vg_heap_adopt(id r, id<MTLHeap> heap, NSUInteger offset) {
    objc_setAssociatedObject(r, &kHeapKey, heap, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(r, &kOffsetKey, @(offset), OBJC_ASSOCIATION_RETAIN);
}

@interface VGMTLHeap : NSObject <MTLHeap> {
@public
    id<MTLDevice> _dev;
    NSUInteger _size, _used;
    MTLStorageMode _storage;
    MTLCPUCacheMode _cache;
    MTLHazardTrackingMode _hazard;
    MTLHeapType _type;
}
@property(copy, atomic) NSString *label;
@end

static NSUInteger vg_align(NSUInteger v, NSUInteger a) { return (v + a - 1) / a * a; }

// What a texture takes: no format table here, so 8 bytes per pixel (the widest WindowServer uses, RGBA16F) and a
// third more for a mip chain, rounded to 64 KB.
MTLSizeAndAlign vg_heap_texture_size(MTLTextureDescriptor *d) {
    NSUInteger px = MAX(d.width, 1u) * MAX(d.height, 1u) * MAX(d.depth, 1u) * MAX(d.arrayLength, 1u);
    if (d.textureType == MTLTextureTypeCube || d.textureType == MTLTextureTypeCubeArray) {
        px *= 6;
    }
    NSUInteger bytes = px * 8;
    if (d.mipmapLevelCount > 1) {
        bytes += bytes / 3;
    }
    return (MTLSizeAndAlign){vg_align(bytes, 65536), 65536};
}

MTLSizeAndAlign vg_heap_buffer_size(NSUInteger length) {
    return (MTLSizeAndAlign){vg_align(MAX(length, 1u), 256), 256};
}

@implementation VGMTLHeap
@synthesize label = _label;
- (id<MTLDevice>)device { return _dev; }
- (MTLStorageMode)storageMode { return _storage; }
- (MTLCPUCacheMode)cpuCacheMode { return _cache; }
- (MTLHazardTrackingMode)hazardTrackingMode { return _hazard; }
- (MTLResourceOptions)resourceOptions {
    return ((MTLResourceOptions)_storage << MTLResourceStorageModeShift) | ((MTLResourceOptions)_cache << MTLResourceCPUCacheModeShift) |
           ((MTLResourceOptions)_hazard << MTLResourceHazardTrackingModeShift);
}
- (NSUInteger)size { return _size; }
- (NSUInteger)usedSize { return _used; }
- (NSUInteger)currentAllocatedSize { return _size; }
- (MTLHeapType)type { return _type; }
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)alignment { return _size > _used ? _size - _used : 0; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return MTLPurgeableStateNonVolatile; }
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    id<MTLBuffer> b = vg_new_buffer(_dev, length, options, NULL);
    if (b) {
        @synchronized(self) {
            vg_heap_adopt(b, self, _used);
            _used += vg_heap_buffer_size(length).size;
        }
    }
    return b;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset {
    id<MTLBuffer> b = vg_new_buffer(_dev, length, options, NULL);
    if (b) {
        vg_heap_adopt(b, self, offset);
    }
    return b;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d {
    id<MTLTexture> t = vg_new_texture(_dev, d);
    if (t) {
        @synchronized(self) {
            vg_heap_adopt(t, self, _used);
            _used += vg_heap_texture_size(d).size;
        }
    }
    return t;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset {
    id<MTLTexture> t = vg_new_texture(_dev, d);
    if (t) {
        vg_heap_adopt(t, self, offset);
    }
    return t;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VGMTLHeap %p size %lu used %lu %@>", self, (unsigned long)_size,
                                      (unsigned long)_used, _label ?: @""];
}
@end

id<MTLHeap> vg_new_heap(id<MTLDevice> device, MTLHeapDescriptor *d) {
    VGMTLHeap *h = [VGMTLHeap new];
    h->_dev = device;
    h->_size = d.size;
    h->_storage = d.storageMode;
    h->_cache = d.cpuCacheMode;
    h->_hazard = d.hazardTrackingMode;
    h->_type = d.type;
    vglog("heap: %lu bytes, storage %lu, type %ld", (unsigned long)d.size, (unsigned long)d.storageMode, (long)d.type);
    return h;
}
