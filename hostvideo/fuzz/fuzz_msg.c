// Harness 1: engine_msg for every message type, with no GPU (hwdev NULL, as in Docker): msg_parse, msg_field, field_int,
// the dcap/decs/+dec/dsta/dsup/dcop/dset/dfrm/dfin/dinv/-dec/Dbuf/unknown dispatch, bp_read_string through dcop/dset,
// sample_data through dfrm.  Input: byte 0 = (surface count & 7) | 0x40 to pre-create a session with the message's UUID,
// then the message bytes (copied to an exact-size heap block).
#include "common.h"
static size_t replies;
static void sink_msg(const buf *m) {
    msg mm;
    replies++;
    if (!msg_parse(m->p, m->n, &mm)) {
        volatile uint8_t x = 0;
        for (size_t i = 0; i < m->n; i++) {
            x ^= m->p[i];   // the reply must be a fully initialized, in-bounds buffer
        }
        size_t l;
        (void)msg_field(&mm, "err", "s32", &l);
    }
}
int LLVMFuzzerInitialize(int *argc, char ***argv) {
    shm = fake_shm();
    out.msg = sink_msg, out.fill = sink_fill_nop;
    return 0;
}
int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n < 2) {
        return 0;
    }
    int ns = d[0] & 7;
    uint8_t *p = exact_copy(d + 1, n - 1);
    engine_reset();
    if ((d[0] & 0x40) && n - 1 >= 32) {
        sessions[0].used = 1;
        memcpy(sessions[0].uuid, p + 16, 16);
    }
    struct vv_surf sf[8];
    memset(sf, 0, sizeof(sf));
    for (int i = 0; i < 8; i++) {
        sf[i].id = 500 + i;
    }
    engine_msg(p, n - 1, sf, ns > 5 ? 5 : ns);
    free(p);
    engine_reset();
    return 0;
}
