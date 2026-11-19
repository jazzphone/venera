// venera-clipboard: the clipboard between a macOS VM and the Proxmox console, both ways. It speaks the SPICE agent
// protocol (spice-protocol's vd_agent.h) on QEMU's port com.redhat.spice.0, as spice-vdagent does in Linux guests, and
// keeps it in step with the Mac's pasteboard. On the other end is QEMU's own vdagent when the VM's display has
// clipboard=vnc (Proxmox's noVNC console: text), or a SPICE client (remote-viewer: text and images).
//
//   venera-clipboard [--verbose]       (a LaunchAgent in each logged-in user's session: local.venera.clipboard)
//
// It talks to the port through VeneraConsole.kext, which lets the console user open it. The protocol, on demand:
// a copy on one side announces what it has (CLIPBOARD_GRAB, with types), the other side asks for one type
// (CLIPBOARD_REQUEST) and gets it (CLIPBOARD). Here a copy in the VM is seen by polling the pasteboard's change count
// (macOS sends no notification for it); a grab from the host is answered with a request right away, and the text or
// image goes onto the pasteboard when it comes.
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#include "../kext/VeneraConsole/VeneraConsoleAPI.h"

#ifndef VENERA_VERSION
#define VENERA_VERSION "dev"
#endif

// vd_agent.h
enum { VDP_CLIENT_PORT = 1, VD_AGENT_PROTOCOL = 1, VD_AGENT_MAX_DATA_SIZE = 2048 };
enum {
    VD_AGENT_CLIPBOARD = 4, VD_AGENT_ANNOUNCE_CAPABILITIES = 6, VD_AGENT_CLIPBOARD_GRAB = 7,
    VD_AGENT_CLIPBOARD_REQUEST = 8, VD_AGENT_CLIPBOARD_RELEASE = 9, VD_AGENT_CLIENT_DISCONNECTED = 13,
    VD_AGENT_MAX_CLIPBOARD = 14,
};
enum { VD_AGENT_CLIPBOARD_NONE = 0, VD_AGENT_CLIPBOARD_UTF8_TEXT = 1, VD_AGENT_CLIPBOARD_IMAGE_PNG = 2 };
enum {
    VD_AGENT_CAP_CLIPBOARD_BY_DEMAND = 5, VD_AGENT_CAP_CLIPBOARD_SELECTION = 6, VD_AGENT_CAP_GUEST_LINEEND_LF = 8,
    VD_AGENT_CAP_MAX_CLIPBOARD = 10,
};
enum { kSelectionClipboard = 0 };
#pragma pack(push, 1)
typedef struct { uint32_t port, size; } VDIChunkHeader;
typedef struct { uint32_t protocol, type; uint64_t opaque; uint32_t size; } VDAgentMessage;
#pragma pack(pop)

static const size_t kMaxClipboard = 32u << 20;   // a copy bigger than this isn't offered
static BOOL gVerbose;
static io_connect_t gConn;
static uint32_t gHostCaps;
static NSInteger gOurChange = -1;     // the pasteboard change count after we set it from the host
static NSInteger gSeenChange = -1;    // the last change count we announced (or set)
static NSMutableData *gIn;            // chunk bytes as they come
static NSMutableData *gMsg;           // a message being put together from chunks
static uint32_t gMsgWant;

static void say(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@", s);   // the unified log: log show --last 1h --predicate 'process == "venera-clipboard"'
}

static BOOL selections(void) { return (gHostCaps & (1u << VD_AGENT_CAP_CLIPBOARD_SELECTION)) != 0; }

// ---- sending ------------------------------------------------------------------------------------------------------

static BOOL portWrite(const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        uint64_t timeout = 5000, took = 0;
        uint32_t outs = 1;
        if (IOConnectCallMethod(gConn, kVCMethodWrite, &timeout, 1, b, MIN(n, (size_t)1 << 20), &took, &outs, NULL, NULL) !=
                KERN_SUCCESS || took == 0) {
            return NO;
        }
        b += took;
        n -= (size_t)took;
    }
    return YES;
}

// One message, cut into chunks of at most VD_AGENT_MAX_DATA_SIZE bytes each (what spice-server takes).
static void sendMessage(uint32_t type, NSData *body) {
    NSMutableData *msg = [NSMutableData dataWithLength:sizeof(VDAgentMessage)];
    VDAgentMessage *h = msg.mutableBytes;
    h->protocol = VD_AGENT_PROTOCOL;
    h->type = type;
    h->opaque = 0;
    h->size = (uint32_t)body.length;
    [msg appendData:body];
    NSMutableData *out = [NSMutableData dataWithCapacity:msg.length + msg.length / VD_AGENT_MAX_DATA_SIZE * 8 + 8];
    for (size_t off = 0; off < msg.length;) {
        uint32_t n = (uint32_t)MIN(msg.length - off, (size_t)VD_AGENT_MAX_DATA_SIZE);
        VDIChunkHeader c = {VDP_CLIENT_PORT, n};
        [out appendBytes:&c length:sizeof c];
        [out appendBytes:(const uint8_t *)msg.bytes + off length:n];
        off += n;
    }
    if (!portWrite(out.bytes, out.length)) say(@"couldn't send message %u (%zu bytes)", type, msg.length);
}

static NSMutableData *withSelection(void) {
    NSMutableData *d = [NSMutableData data];
    if (selections()) {
        uint8_t sel[4] = {kSelectionClipboard, 0, 0, 0};
        [d appendBytes:sel length:4];
    }
    return d;
}

static void sendCaps(BOOL request) {
    uint32_t body[2] = {request ? 1u : 0u,
                        (1u << VD_AGENT_CAP_CLIPBOARD_BY_DEMAND) | (1u << VD_AGENT_CAP_CLIPBOARD_SELECTION) |
                            (1u << VD_AGENT_CAP_GUEST_LINEEND_LF) | (1u << VD_AGENT_CAP_MAX_CLIPBOARD)};
    sendMessage(VD_AGENT_ANNOUNCE_CAPABILITIES, [NSData dataWithBytes:body length:sizeof body]);
}

// ---- the pasteboard -----------------------------------------------------------------------------------------------

static NSData *pasteboardPNG(NSPasteboard *pb) {
    NSData *png = [pb dataForType:NSPasteboardTypePNG];
    if (png) return png;
    NSData *tiff = [pb dataForType:NSPasteboardTypeTIFF];
    if (!tiff) return nil;
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

// A copy in the VM: tell the host what there is (text first; an image as PNG).
static void announceCopy(void) {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSInteger cc = pb.changeCount;
    if (cc == gSeenChange) return;
    gSeenChange = cc;
    if (cc == gOurChange) return;   // what the host just gave us
    NSMutableData *grab = withSelection();
    uint32_t types[2];
    unsigned n = 0;
    if ([pb availableTypeFromArray:@[NSPasteboardTypeString]]) types[n++] = VD_AGENT_CLIPBOARD_UTF8_TEXT;
    if ([pb availableTypeFromArray:@[NSPasteboardTypePNG, NSPasteboardTypeTIFF]]) types[n++] = VD_AGENT_CLIPBOARD_IMAGE_PNG;
    if (!n) {
        if (gVerbose) say(@"copy with nothing to offer");
        NSMutableData *rel = withSelection();
        sendMessage(VD_AGENT_CLIPBOARD_RELEASE, rel);
        return;
    }
    [grab appendBytes:types length:n * sizeof(uint32_t)];
    sendMessage(VD_AGENT_CLIPBOARD_GRAB, grab);
    if (gVerbose) say(@"offered %u type%s", n, n == 1 ? "" : "s");
}

static void answerRequest(uint32_t type) {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSData *data = nil;
    if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
        data = [[pb stringForType:NSPasteboardTypeString] dataUsingEncoding:NSUTF8StringEncoding];
    } else if (type == VD_AGENT_CLIPBOARD_IMAGE_PNG) {
        data = pasteboardPNG(pb);
    }
    if (data.length > kMaxClipboard) data = nil;
    NSMutableData *m = withSelection();
    uint32_t t = data ? type : VD_AGENT_CLIPBOARD_NONE;   // nothing of that type: an empty answer
    [m appendBytes:&t length:4];
    if (data) [m appendData:data];
    sendMessage(VD_AGENT_CLIPBOARD, m);
    if (gVerbose) say(@"sent %zu bytes of type %u", data.length, type);
}

static void takeData(uint32_t type, const uint8_t *p, size_t n) {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
        NSString *s = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding];
        // a VNC client's plain cut text is Latin-1, and QEMU passes it on as it is (noVNC sends UTF-8)
        if (!s) s = [[NSString alloc] initWithBytes:p length:n encoding:NSISOLatin1StringEncoding];
        if (!s) return;
        [pb clearContents];
        [pb setString:s forType:NSPasteboardTypeString];
    } else if (type == VD_AGENT_CLIPBOARD_IMAGE_PNG) {
        [pb clearContents];
        [pb setData:[NSData dataWithBytes:p length:n] forType:NSPasteboardTypePNG];
    } else {
        return;
    }
    gOurChange = gSeenChange = pb.changeCount;
    if (gVerbose) say(@"pasteboard set from the host (%zu bytes, type %u)", n, type);
}

// ---- receiving ----------------------------------------------------------------------------------------------------

static void handleMessage(const VDAgentMessage *m, const uint8_t *body) {
    uint32_t size = m->size;
    switch (m->type) {
    case VD_AGENT_ANNOUNCE_CAPABILITIES:
        if (size >= 8) {
            uint32_t request, caps;
            memcpy(&request, body, 4);
            memcpy(&caps, body + 4, 4);
            gHostCaps = caps;
            if (gVerbose) say(@"host capabilities 0x%x%s", caps, request ? " (asks for ours)" : "");
            if (request) sendCaps(NO);
            gSeenChange = -1;   // offer what the VM has now
            announceCopy();
        }
        return;
    case VD_AGENT_CLIENT_DISCONNECTED:
        if (gVerbose) say(@"the client went away");
        return;
    case VD_AGENT_CLIPBOARD_GRAB:
    case VD_AGENT_CLIPBOARD_REQUEST:
    case VD_AGENT_CLIPBOARD:
    case VD_AGENT_CLIPBOARD_RELEASE:
        break;
    default:
        return;
    }
    if (selections()) {
        if (size < 4) return;
        if (body[0] != kSelectionClipboard) return;   // PRIMARY and SECONDARY: X11's, nothing on a Mac
        body += 4;
        size -= 4;
    }
    switch (m->type) {
    case VD_AGENT_CLIPBOARD_GRAB: {   // the host copied: ask for the best type it has
        BOOL text = NO, png = NO;
        for (uint32_t i = 0; i + 4 <= size; i += 4) {
            uint32_t t;
            memcpy(&t, body + i, 4);
            text |= t == VD_AGENT_CLIPBOARD_UTF8_TEXT;
            png |= t == VD_AGENT_CLIPBOARD_IMAGE_PNG;
        }
        uint32_t want = text ? VD_AGENT_CLIPBOARD_UTF8_TEXT : png ? VD_AGENT_CLIPBOARD_IMAGE_PNG : 0;
        if (!want) return;
        NSMutableData *r = withSelection();
        [r appendBytes:&want length:4];
        sendMessage(VD_AGENT_CLIPBOARD_REQUEST, r);
        return;
    }
    case VD_AGENT_CLIPBOARD_REQUEST:
        if (size >= 4) {
            uint32_t t;
            memcpy(&t, body, 4);
            answerRequest(t);
        }
        return;
    case VD_AGENT_CLIPBOARD:
        if (size >= 4) {
            uint32_t t;
            memcpy(&t, body, 4);
            takeData(t, body + 4, size - 4);
        }
        return;
    default:
        return;
    }
}

// Chunks (header + up to 2 KB) carry messages (header + body), a message across as many chunks as it takes.
static void feed(const uint8_t *p, size_t n) {
    [gIn appendBytes:p length:n];
    for (;;) {
        if (gIn.length < sizeof(VDIChunkHeader)) return;
        VDIChunkHeader c;
        memcpy(&c, gIn.bytes, sizeof c);
        if (c.size > (1u << 20)) {   // nonsense: start over
            say(@"bad chunk size %u: resetting", c.size);
            gIn.length = 0;
            gMsg.length = 0;
            gMsgWant = 0;
            return;
        }
        if (gIn.length < sizeof c + c.size) return;
        [gMsg appendBytes:(const uint8_t *)gIn.bytes + sizeof c length:c.size];
        [gIn replaceBytesInRange:NSMakeRange(0, sizeof c + c.size) withBytes:NULL length:0];
        if (!gMsgWant && gMsg.length >= sizeof(VDAgentMessage)) {
            VDAgentMessage m;
            memcpy(&m, gMsg.bytes, sizeof m);
            if (m.size > kMaxClipboard + 64) {
                say(@"a message of %u bytes: dropped", m.size);
                gMsg.length = 0;
                continue;
            }
            gMsgWant = (uint32_t)sizeof m + m.size;
        }
        if (gMsgWant && gMsg.length >= gMsgWant) {
            VDAgentMessage m;
            memcpy(&m, gMsg.bytes, sizeof m);
            NSData *whole = [gMsg subdataWithRange:NSMakeRange(0, gMsgWant)];
            [gMsg replaceBytesInRange:NSMakeRange(0, gMsgWant) withBytes:NULL length:0];
            gMsgWant = 0;
            dispatch_sync(dispatch_get_main_queue(), ^{   // the pasteboard on the main thread
                handleMessage(&m, (const uint8_t *)whole.bytes + sizeof(VDAgentMessage));
            });
        }
    }
}

// ---- the port -----------------------------------------------------------------------------------------------------

static io_connect_t openPort(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("VeneraConsole"), &it) != KERN_SUCCESS) return 0;
    io_connect_t found = 0;
    io_service_t svc;
    static const char name[] = "com.redhat.spice.0";
    while (!found && (svc = IOIteratorNext(it))) {
        io_connect_t c = 0;
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c);
        if (kr == KERN_SUCCESS) {
            uint64_t id = 0;
            uint32_t outs = 1;
            kr = IOConnectCallMethod(c, kVCMethodOpen, NULL, 0, name, strlen(name), &id, &outs, NULL, NULL);
            if (kr == KERN_SUCCESS) {
                found = c;
            } else {
                if (gVerbose) say(@"a VeneraConsole: no %s there (0x%x)", name, kr);
                IOServiceClose(c);
            }
        } else if (gVerbose) {
            say(@"a VeneraConsole wouldn't open for us (0x%x)", kr);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found;
}

static void readLoop(void) {
    static uint8_t buf[65536];
    NSString *state = nil;
    for (;;) {
        @autoreleasepool {
            if (!gConn) {
                gConn = openPort();
                if (!gConn) {
                    if (![state isEqual:@"none"]) say(@"no clipboard port (VeneraConsole.kext, com.redhat.spice.0) yet, or another session has it");
                    state = @"none";
                    sleep(5);
                    continue;
                }
                say(@"on com.redhat.spice.0");
                state = @"open";
                gIn.length = 0;
                gMsg.length = 0;
                gMsgWant = 0;
                gHostCaps = 0;
                dispatch_sync(dispatch_get_main_queue(), ^{ sendCaps(YES); });
            }
            uint64_t timeout = 1000, got = 0;
            uint32_t outs = 1;
            size_t size = sizeof buf;
            kern_return_t kr = IOConnectCallMethod(gConn, kVCMethodRead, &timeout, 1, NULL, 0, &got, &outs, buf, &size);
            if (kr != KERN_SUCCESS) {
                say(@"read: 0x%x: reopening", kr);
                IOServiceClose(gConn);
                gConn = 0;
                sleep(1);
                continue;
            }
            if (size) feed(buf, size);
        }
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--verbose")) gVerbose = YES;
            else if (!strcmp(argv[i], "--version")) { printf("venera-clipboard %s\n", VENERA_VERSION); return 0; }
            else { fprintf(stderr, "usage: venera-clipboard [--verbose] [--version]\n"); return 2; }
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        gIn = [NSMutableData data];
        gMsg = [NSMutableData data];
        say(@"%s starting", VENERA_VERSION);
        [NSThread detachNewThreadWithBlock:^{ readLoop(); }];
        // macOS sends no notification for a copy: the change count, twice a second (a counter read, nothing more)
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            if (gConn && (gHostCaps & (1u << VD_AGENT_CAP_CLIPBOARD_BY_DEMAND))) announceCopy();
        }];
        [NSApp run];
    }
    return 0;
}
