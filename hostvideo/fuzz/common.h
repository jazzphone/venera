// Shared by the fuzz harnesses: includes the daemon's source itself (VIDEOD_SRC, set by run.sh) with main renamed and its
// log output silenced, so every static function and global is reachable.  The daemon source is never edited.
#ifndef FUZZ_COMMON_H
#define FUZZ_COMMON_H
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#define fprintf(...) 0
#define vfprintf(...) 0
#define main venera_main
#include VIDEOD_SRC
#undef main
#undef fprintf
#undef vfprintf

static uint8_t *exact_copy(const uint8_t *d, size_t n) {   // a heap block of exactly n bytes, so ASan sees any overrun
    uint8_t *p = malloc(n ? n : 1);
    memcpy(p, d, n);
    return p;
}
static uint8_t *fake_shm(void) {   // the 256 MB region, lazily backed
    uint8_t *m = mmap(NULL, VV_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (m == MAP_FAILED) {
        abort();
    }
    return m;
}
static void sink_fill_nop(uint32_t surf, int slot, int w, int h, int stride, int bps) {}
static const uint8_t FIXED_UUID[16] = {0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF};
#endif
