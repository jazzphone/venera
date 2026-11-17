// Harness 4: the host-to-guest ring (ring_put / h2g / flush_outbox) against a hostile tail and head, with PROT_NONE pages
// on both sides of the ring.  Ops (4 bytes each): 0 h2g(kind=b1, payload n = b2*256+b3 scaled), 1 guest writes
// ctl->h2g.tail = next 4 bytes, 2 flush_outbox, 3 h2g_head = next 4 bytes (a restart reads it from shared memory).
#include "common.h"
static uint8_t *zeros;
static void free_outbox(void) {
    while (outbox) {
        ob *o = outbox;
        outbox = o->next;
        free(o->p);
        free(o);
    }
    outbox_tail = NULL;
    outbox_bytes = 0;
}
int LLVMFuzzerInitialize(int *argc, char ***argv) {
    shm = fake_shm();
    ctl = (struct vv_ctl *)shm;
    mprotect(shm + VV_H2G_OFF - 4096, 4096, PROT_NONE);
    mprotect(shm + VV_H2G_OFF + VV_H2G_SIZE, 4096, PROT_NONE);
    zeros = calloc(1, 4u << 20);
    return 0;
}
int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    free_outbox();
    ctl->h2g.head = ctl->h2g.tail = 0;
    h2g_head = 0;
    for (size_t i = 0; i + 4 <= n; i += 4) {
        uint32_t v = 0;
        switch (d[i] & 3) {
        case 0: {
            uint32_t len = ((uint32_t)d[i + 2] << 8 | d[i + 3]) * (d[i + 1] & 0x80 ? 32u : 1u);
            if (len > (2u << 20) - 64) {
                len = (2u << 20) - 64;   // beyond that the host's own messages never go
            }
            uint32_t a[6] = {1, 2, 3, 4, 5, 6};
            h2g(d[i + 1] & 0x7f, (d[i + 1] & 0x40) ? a : NULL, zeros, len);
            break;
        }
        case 1:
            if (i + 8 <= n) {
                memcpy(&v, d + i + 4, 4), i += 4;
                ctl->h2g.tail = v;
            }
            break;
        case 2:
            flush_outbox();
            if (h2g_head == ctl->h2g.tail && outbox) {   // an empty ring takes any record the host makes
                abort();
            }
            break;
        case 3:
            if (i + 8 <= n) {
                memcpy(&v, d + i + 4, 4), i += 4;
                v &= ~31u;   // as serve() does on a restart: the guest-writable counter rounded down to a record
                h2g_head = v;
            }
            break;
        }
        size_t sum = 0;
        for (ob *o = outbox; o; o = o->next) {
            sum += o->n;
        }
        if (sum != outbox_bytes) {
            abort();
        }
    }
    free_outbox();
    return 0;
}
