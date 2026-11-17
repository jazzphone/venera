// Harness 3: drain_g2h against a fake shared memory whose guest-to-host ring is bordered by PROT_NONE pages (a read past
// either end of the ring faults).  Input: head u32, tail u32 (the host's own counter), then ring bytes, placed at the
// tail's offset and, if they run past the end, wrapped to the ring's start; a second copy is always placed at offset 0.
// Records dispatch into engine_msg, so a VV_G_MSG record reaches the message parser with its surfaces.
#include "common.h"
static void sink_msg(const buf *m) {}
int LLVMFuzzerInitialize(int *argc, char ***argv) {
    shm = fake_shm();
    ctl = (struct vv_ctl *)shm;
    mprotect(shm + VV_G2H_OFF - 4096, 4096, PROT_NONE);
    mprotect(shm + VV_G2H_OFF + VV_G2H_SIZE, 4096, PROT_NONE);
    out.msg = sink_msg, out.fill = sink_fill_nop;
    return 0;
}
int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n < 8) {
        return 0;
    }
    uint32_t head, tail;
    memcpy(&head, d, 4), memcpy(&tail, d + 4, 4);
    const uint8_t *data = d + 8;
    size_t dn = n - 8;
    uint8_t *base = shm + VV_G2H_OFF;
    size_t at = tail % VV_G2H_SIZE, first = dn < VV_G2H_SIZE - at ? dn : VV_G2H_SIZE - at;
    memcpy(base + at, data, first);
    if (first < dn) {
        memcpy(base, data + first, dn - first);
    }
    memcpy(base, data, dn);
    engine_reset();
    ctl->g2h.head = head;
    ctl->g2h.tail = tail;
    g2h_tail = tail;
    drain_g2h();
    // the host's counter must end where the guest's head was, or (on corruption) at it; never somewhere new
    if (g2h_tail != ctl->g2h.tail) {
        abort();
    }
    memset(base + at, 0, first);
    memset(base, 0, dn > first ? dn : first);
    engine_reset();
    return 0;
}
