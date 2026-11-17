// Harness 5: whole sessions on the software-decoder copy of the daemon (gen/venera-videod-sw.c: no VA-API, FFmpeg decodes
// in software, download() skips the pixel copy but keeps its size math).  Input = ops, each [code u8][len u16 BE][data]:
//   0 a raw message (its UUID bytes 16..31 forced to a fixed one, so it finds the session)   1 SLOTDONE (slot, err)
//   2 the guest's Dbuf answer to the Nth host request (valid shape; data[0] picks which)     3 UUID gone
//   4 engine_reset (a new driver run)                                                          5 pump
#include "common.h"
static uint64_t dbuf_reqs[64];
static unsigned ndbuf;
static void sink_msg(const buf *m) {
    msg mm;
    if (!msg_parse(m->p, m->n, &mm)) {
        if (!strcmp(mm.type, "Dbuf") && (mm.flags & 2)) {
            dbuf_reqs[ndbuf++ % 64] = mm.req;
        }
        volatile uint8_t x = 0;
        for (size_t i = 0; i < m->n; i++) {
            x ^= m->p[i];
        }
    }
}
int LLVMFuzzerInitialize(int *argc, char ***argv) {
    shm = fake_shm();
    out.msg = sink_msg, out.fill = sink_fill_nop;
    hwdev = (AVBufferRef *)1;   // "a GPU": only tested for non-NULL (the sw copy drops every use)
    av_log_set_level(AV_LOG_QUIET);
    return 0;
}
int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    engine_reset();
    ndbuf = 0;
    host_req = 100;
    int ops = 0;
    for (size_t i = 0; i + 3 <= n && ops++ < 96;) {
        uint8_t code = d[i];
        size_t len = (size_t)d[i + 1] << 8 | d[i + 2];
        i += 3;
        if (len > n - i) {
            len = n - i;
        }
        const uint8_t *data = d + i;
        i += len;
        struct vv_surf sf = {.id = 700};
        switch (code % 6) {
        case 0: {
            uint8_t *p = exact_copy(data, len);
            if (len >= 32) {
                memcpy(p + 16, FIXED_UUID, 16);
            }
            engine_msg(p, len, &sf, 1);
            free(p);
            break;
        }
        case 1:
            engine_slotdone(len ? (int)(int8_t)data[0] : 0, len > 1 ? data[1] : 0);
            break;
        case 2: {
            uint64_t req = ndbuf ? dbuf_reqs[(len ? data[0] : 0) % (ndbuf < 64 ? ndbuf : 64)] : 100 + (len ? data[0] : 0);
            buf m = {0};
            msg_header(&m, "Dbuf", 8, FIXED_UUID, req);
            field(&m, "uui", "uui", FIXED_UUID, 16);
            field_s32(&m, "err", len > 1 ? (int32_t)data[1] * (data[1] > 200) : 0);
            engine_msg(m.p, m.n, &sf, len > 2 ? data[2] & 1 : 1);
            free(m.p);
            break;
        }
        case 3:
            engine_uuid_gone(FIXED_UUID);
            break;
        case 4:
            engine_reset();
            break;
        case 5: {
            session *s = find_session(FIXED_UUID);
            if (s) {
                pump(s);
            }
            break;
        }
        }
    }
    engine_reset();
    return 0;
}
