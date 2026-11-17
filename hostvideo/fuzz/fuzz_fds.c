// Harness 6: open_decoder (the MP4 sample-description walk: avc1/hvc1/av01/vp09 + avcC/hvcC/av1C/vpcC) on the
// software-decoder copy, then a second open on the same session as a repeated dsta does.
#include "common.h"
static void sink_msg(const buf *m) {}
int LLVMFuzzerInitialize(int *argc, char ***argv) {
    shm = fake_shm();
    out.msg = sink_msg, out.fill = sink_fill_nop;
    hwdev = (AVBufferRef *)1;
    av_log_set_level(AV_LOG_QUIET);
    return 0;
}
int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    uint8_t *p = exact_copy(d, n);
    session *s = &sessions[0];
    memset(s, 0, sizeof(*s));
    s->used = 1;
    if (!open_decoder(s, p, n)) {
        send_pba(s);
    }
    free_session(s);
    free(p);
    return 0;
}
