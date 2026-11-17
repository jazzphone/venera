// Harness 2: the leaf parsers on exact-size heap blocks.  Byte 0 selects: 0 bp_read_string (out buffer of 1 + byte1 bytes,
// heap, exact), 1 sample_data, 2 msg_parse + msg_field/field_int over a list of names and types.
#include "common.h"
int LLVMFuzzerInitialize(int *argc, char ***argv) {
    shm = fake_shm();
    return 0;
}
int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n < 2) {
        return 0;
    }
    uint8_t sel = d[0] % 3, a = d[1];
    const uint8_t *body = d + 2;
    size_t bn = n - 2;
    uint8_t *p = exact_copy(body, bn);
    if (sel == 0) {
        size_t osz = 1 + a % 200;
        char *o = malloc(osz);
        if (!bp_read_string(p, bn, o, osz)) {
            volatile size_t l = strlen(o);   // NUL-terminated inside the buffer
            (void)l;
        }
        free(o);
    } else if (sel == 1) {
        size_t l = 0;
        const uint8_t *s = sample_data(p, bn, &l);
        if (s) {
            if (s < p || s + l > p + bn) {
                abort();   // the returned span must lie inside the input
            }
            volatile uint8_t x = 0;
            for (size_t i = 0; i < l; i++) {
                x ^= s[i];
            }
        }
    } else {
        msg m;
        if (!msg_parse(p, bn, &m)) {
            static const char *names[][2] = {{"frm", "s64"}, {"dfl", "u32"}, {"sbf", "sbf"}, {"fds", "fds"}, {"key", "pls"}, {"uui", "uui"},
                                              {"err", "s32"}, {"cod", "s32"}};
            for (int i = 0; i < 8; i++) {
                size_t l = 0;
                const uint8_t *v = msg_field(&m, names[i][0], names[i][1], &l);
                if (v) {
                    if (v < p + 48 || v + l > p + bn) {
                        abort();
                    }
                    volatile uint8_t x = l ? v[l - 1] : 0;   // last byte readable
                    (void)x;
                }
                (void)field_int(&m, names[i][0], names[i][1], 0);
            }
        }
    }
    free(p);
    return 0;
}
