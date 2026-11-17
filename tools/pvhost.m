// pvhost (video, runs on a Mac): Apple's own host side of paravirtualized VideoToolbox, fed messages a guest sent
// (files saved by pvshim), to learn the protocol: each reply the host session sends back is printed and saved next
// to the input as reply-N.bin.
// It also answers the host's requests for output buffers (Dbuf) as a guest would: an IOSurface made from the last
// pixel buffer attributes (Dpba), sent with a reply carrying a buffer UUID; when a frame comes back (Demt), the
// surface's first pixels are printed.
//   pvhost MSG.bin...
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#include <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <uuid/uuid.h>

typedef OSStatus (*create_fn)(void (^)(CMBlockBufferRef), CFTypeRef *);
typedef OSStatus (*deliver_fn)(CFTypeRef, CMBlockBufferRef, void *, const void *, const void *, size_t);

static int nreply;
static NSDictionary *gPba;
static NSMutableArray *gSurfaces;

static void box(NSMutableData *m, const char *name, const void *v, size_t n) {
    uint32_t size = htonl((uint32_t)(4 + strlen(name) + n));
    [m appendBytes:&size length:4];
    [m appendBytes:name length:strlen(name)];
    [m appendBytes:v length:n];
}
// The value of field `name` ("para,NAME=TYPE") in a message, or nil.
static NSData *fieldOf(NSData *msg, const char *key) {
    const uint8_t *b = msg.bytes;
    size_t i = 48;
    while (i + 8 <= msg.length) {
        uint32_t size = ntohl(*(const uint32_t *)(b + i));
        if (size < 8 || i + size > msg.length) {
            break;
        }
        const char *body = (const char *)b + i + 4;
        size_t kl = strlen(key);
        if (size > 9 + kl && !memcmp(body, "para,", 5) && !memcmp(body + 5, key, kl) && body[5 + kl] == '=') {
            const char *v = body + 6 + kl;
            while (v < (const char *)b + i + size && *v >= 'a' && *v <= 'z') {
                v++;
            }
            if (!strncmp(body + 6 + kl, "pls", 3)) {
                v = body + 9 + kl;
            }
            return [NSData dataWithBytes:v length:(const char *)b + i + size - v];
        }
        i += size;
    }
    return nil;
}
static NSString *outDir;
static id gSession;

static void dump(const char *what, const uint8_t *p, size_t n) {
    printf("%s (%zu bytes):", what, n);
    for (size_t i = 0; i < n && i < 160; i++) {
        printf("%s%02x", i % 32 ? " " : "\n  ", p[i]);
    }
    printf("\n");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        create_fn create = dlsym(RTLD_DEFAULT, "VTParavirtualizationHostSessionCreate");
        deliver_fn deliver = dlsym(RTLD_DEFAULT, "VTParavirtualizationHostSessionDeliverMessageFromGuest");
        if (!create || !deliver) {
            printf("no host session in this VideoToolbox\n");
            return 1;
        }
        CFTypeRef session = NULL;
        gSurfaces = [NSMutableArray array];
        OSStatus st = create(^(CMBlockBufferRef m) {
          size_t n = CMBlockBufferGetDataLength(m);
          NSMutableData *d = [NSMutableData dataWithLength:n];
          CMBlockBufferCopyDataBytes(m, 0, n, d.mutableBytes);
          char what[64];
          snprintf(what, sizeof(what), "reply %d", nreply);
          dump(what, d.bytes, n);
          [d writeToFile:[outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"reply-%d.bin", nreply]]
              atomically:YES];
          nreply++;
          const uint8_t *h = d.bytes;
          if (!memcmp(h + 8, "Dpba", 4)) {
              gPba = [NSPropertyListSerialization propertyListWithData:fieldOf(d, "pba") options:0 format:NULL error:NULL];
          } else if (!memcmp(h + 8, "Dbuf", 4) && gPba) {
              // a guest's answer: an IOSurface for the frame, and its buffer UUID
              size_t w = [gPba[@"Width"] unsignedIntValue], ht = [gPba[@"Height"] unsignedIntValue];
              CVPixelBufferRef pb = NULL;
              NSDictionary *a = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{},
                                  (id)kCVPixelBufferExtendedPixelsBottomKey : gPba[@"ExtendedPixelsBottom"] ?: @0,
                                  (id)kCVPixelBufferPlaneAlignmentKey : gPba[@"PlaneAlignment"] ?: @16,
                                  (id)kCVPixelBufferBytesPerRowAlignmentKey : gPba[@"BytesPerRowAlignment"] ?: @16};
              CVPixelBufferCreate(NULL, w, ht, [gPba[@"PixelFormatType"][0] unsignedIntValue], (__bridge CFDictionaryRef)a, &pb);
              IOSurfaceRef surf = CVPixelBufferGetIOSurface(pb);
              [gSurfaces addObject:(__bridge id)pb];
              NSMutableData *r = [NSMutableData dataWithBytes:h length:48];
              uint32_t flags = htonl(8);
              [r replaceBytesInRange:NSMakeRange(12, 4) withBytes:&flags];
              int32_t err = 0;
              box(r, "para,err=s32", &err, 4);
              uuid_t u;
              uuid_generate(u);
              box(r, "para,uui=uui", u, 16);
              CMBlockBufferRef bb = NULL;
              CMBlockBufferCreateWithMemoryBlock(NULL, NULL, r.length, NULL, NULL, 0, r.length, 0, &bb);
              CMBlockBufferReplaceDataBytes(r.bytes, bb, 0, r.length);
              const void *surfs[1] = {surf};
              uint64_t ids[1] = {IOSurfaceGetID(surf)};
              deliver_fn deliver = dlsym(RTLD_DEFAULT, "VTParavirtualizationHostSessionDeliverMessageFromGuest");
              CFTypeRef ses = (__bridge CFTypeRef)gSession;
              OSStatus st = deliver(ses, bb, NULL, surfs, ids, 1);
              printf("answered Dbuf with surface %u (%zux%zu): status %d\n", IOSurfaceGetID(surf), w, ht, (int)st);
          } else if (!memcmp(h + 8, "Demt", 4)) {
              for (id o in gSurfaces) {
                  CVPixelBufferRef pb = (__bridge CVPixelBufferRef)o;
                  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                  const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
                  size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), w = CVPixelBufferGetWidth(pb), ht = CVPixelBufferGetHeight(pb);
                  printf("surface %u luma %u %u %u %u\n", IOSurfaceGetID(CVPixelBufferGetIOSurface(pb)), y[0], y[w / 2],
                         y[(ht / 2) * bpr + w / 2], y[(ht - 1) * bpr + w - 1]);
                  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
              }
          }
        }, &session);
        printf("host session: status %d, %p\n", (int)st, session);
        gSession = (__bridge id)session;
        for (int i = 1; i < argc; i++) {
            NSData *msg = [NSData dataWithContentsOfFile:@(argv[i])];
            outDir = [@(argv[i]) stringByDeletingLastPathComponent];
            CMBlockBufferRef bb = NULL;
            CMBlockBufferCreateWithMemoryBlock(NULL, NULL, msg.length, NULL, NULL, 0, msg.length, 0, &bb);
            CMBlockBufferReplaceDataBytes(msg.bytes, bb, 0, msg.length);
            st = deliver(session, bb, NULL, NULL, NULL, 0);
            printf("delivered %s: status %d\n", argv[i], (int)st);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        }
        return 0;
    }
}
