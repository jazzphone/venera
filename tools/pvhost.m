// pvhost (video, runs on a Mac): Apple's own host side of paravirtualized VideoToolbox, fed messages a guest sent
// (files saved by pvshim), to learn the protocol: each reply the host session sends back is printed and saved next
// to the input as reply-N.bin.
//   pvhost MSG.bin...
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef OSStatus (*create_fn)(void (^)(CMBlockBufferRef), CFTypeRef *);
typedef OSStatus (*deliver_fn)(CFTypeRef, CMBlockBufferRef, void *, const void *, const void *, size_t);

static int nreply;
static NSString *outDir;

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
        }, &session);
        printf("host session: status %d, %p\n", (int)st, session);
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
