// pvshim (video): stands in for macOS's paravirtualized-video guest driver inside one process, to see what
// VideoToolbox does when it believes it runs in a guest. Interposes VideoToolboxParavirtualizationSupport's four
// entry points: setup succeeds (the three handler blocks are kept), UUID registrations are logged, and every message
// VideoToolbox sends "to the host" is logged and saved to /var/tmp/pvmsg-N.bin. A message whose type (the four bytes
// at 8) has a canned answer in /var/tmp/pvreply-TYPE.bin -- one Apple's host side gave (tools/pvhost.m) -- is answered
// with it, its UUID and request number (bytes 16-47) copied from the request; others go unanswered.
//   DYLD_INSERT_LIBRARIES=pvshim.dylib vtprobe FILE
#include <Block.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef int32_t OSStatus;
typedef struct { const void *base; size_t len; } pv_iov;

OSStatus VTParavirtualizationGuestSupportSetUpWithHandlers(void *, void *, void *);
OSStatus VTParavirtualizationGuestSupportRegisterGuestUUID(const uint8_t *);
OSStatus VTParavirtualizationGuestSupportDeregisterGuestUUID(const uint8_t *);
OSStatus VTParavirtualizationGuestSupportSendRawMessageToHost(const pv_iov *, size_t, uint64_t, uint64_t);

void *pvshim_handlers[3];
static int nmsg;

typedef int32_t (^pv_alloc)(uint32_t capacity, void **message, void **buffer);
typedef int32_t (^pv_deliver)(void *message, uint32_t length);
typedef void (^pv_release)(void *message);

// Deliver one host-to-guest message the way the support framework does: alloc, fill, deliver, release.
static void pv_to_guest(const uint8_t *bytes, uint32_t len) {
    void *msg = NULL, *buf = NULL;
    int32_t st = ((pv_alloc)pvshim_handlers[0])(len, &msg, &buf);
    if (st || !buf) {
        fprintf(stderr, "pvshim: alloc for a reply failed (%d)\n", st);
        return;
    }
    memcpy(buf, bytes, len);
    st = ((pv_deliver)pvshim_handlers[1])(msg, len);
    fprintf(stderr, "pvshim: reply of %u bytes delivered (%d)\n", len, st);
    if (msg) {
        ((pv_release)pvshim_handlers[2])(msg);
    }
}

static void uuid_str(const uint8_t *u, char *s) {
    for (int i = 0; i < 16; i++) {
        sprintf(s + 2 * i, "%02x", u[i]);
    }
}
static OSStatus my_setup(void *a, void *b, void *c) {
    pvshim_handlers[0] = Block_copy(a), pvshim_handlers[1] = Block_copy(b), pvshim_handlers[2] = Block_copy(c);
    fprintf(stderr, "pvshim: setup with handlers %p %p %p\n", a, b, c);
    return 0;
}
static OSStatus my_reg(const uint8_t *u) {
    char s[40];
    uuid_str(u, s);
    fprintf(stderr, "pvshim: register guest uuid %s\n", s);
    return 0;
}
static OSStatus my_dereg(const uint8_t *u) {
    char s[40];
    uuid_str(u, s);
    fprintf(stderr, "pvshim: deregister guest uuid %s\n", s);
    return 0;
}
static OSStatus my_send(const pv_iov *iov, size_t n, uint64_t a2, uint64_t a3) {
    size_t total = 0;
    char path[64];
    snprintf(path, sizeof(path), "/var/tmp/pvmsg-%d.bin", nmsg);
    FILE *f = fopen(path, "wb");
    for (size_t i = 0; i < n; i++) {
        total += iov[i].len;
        if (f) {
            fwrite(iov[i].base, 1, iov[i].len, f);
        }
    }
    if (f) {
        fclose(f);
    }
    fprintf(stderr, "pvshim: message %d to host: %zu pieces, %zu bytes, args 0x%llx 0x%llx; first bytes:", nmsg, n, total,
            (unsigned long long)a2, (unsigned long long)a3);
    const uint8_t *p = n ? iov[0].base : NULL;
    for (size_t i = 0; p && i < 48 && i < iov[0].len; i++) {
        fprintf(stderr, " %02x", p[i]);
    }
    fprintf(stderr, "\n");
    nmsg++;
    // a canned answer for this type?
    uint8_t head[48];
    size_t got = 0;
    for (size_t i = 0; i < n && got < sizeof(head); i++) {
        size_t k = iov[i].len < sizeof(head) - got ? iov[i].len : sizeof(head) - got;
        memcpy(head + got, iov[i].base, k);
        got += k;
    }
    if (got == sizeof(head)) {
        char rp[64];
        snprintf(rp, sizeof(rp), "/var/tmp/pvreply-%.4s.bin", (const char *)head + 8);
        FILE *r = fopen(rp, "rb");
        if (r) {
            fseek(r, 0, SEEK_END);
            long rl = ftell(r);
            fseek(r, 0, SEEK_SET);
            uint8_t *rb = malloc((size_t)rl);
            fread(rb, 1, (size_t)rl, r);
            fclose(r);
            memcpy(rb + 16, head + 16, 32);
            fprintf(stderr, "pvshim: answering %.4s with %s\n", (const char *)head + 8, rp);
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
              pv_to_guest(rb, (uint32_t)rl);
              free(rb);
            });
        }
    }
    return 0;
}

#define INTERPOSE(r, o) \
    __attribute__((used)) static struct { const void *n, *o; } _i_##o __attribute__((section("__DATA,__interpose"))) = {(const void *)r, (const void *)o}
INTERPOSE(my_setup, VTParavirtualizationGuestSupportSetUpWithHandlers);
INTERPOSE(my_reg, VTParavirtualizationGuestSupportRegisterGuestUUID);
INTERPOSE(my_dereg, VTParavirtualizationGuestSupportDeregisterGuestUUID);
INTERPOSE(my_send, VTParavirtualizationGuestSupportSendRawMessageToHost);
