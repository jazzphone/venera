// vv_bplist.h (Venera video): just enough binary property list for the host side of Apple's paravirtualized
// VideoToolbox protocol, which passes CoreFoundation objects as "bplist00": a writer for dictionaries, arrays, ASCII
// strings, integers, booleans and data, and a reader for a top-level string. Header-only C.
#ifndef VV_BPLIST_H
#define VV_BPLIST_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { BP_DICT, BP_ARRAY, BP_STR, BP_INT, BP_BOOL, BP_DATA };
typedef struct bp {
    int type;
    int64_t i;
    char *s;
    int n, cap;
    struct bp **items;   // arrays: values; dicts: key, value, key, value...
    int index;
} bp;

static bp *bp_new(int type) {
    bp *b = calloc(1, sizeof(bp));
    b->type = type;
    return b;
}
static bp *bp_dict(void) { return bp_new(BP_DICT); }
static bp *bp_array(void) { return bp_new(BP_ARRAY); }
static bp *bp_int(int64_t v) {
    bp *b = bp_new(BP_INT);
    b->i = v;
    return b;
}
static bp *bp_bool(int v) {
    bp *b = bp_new(BP_BOOL);
    b->i = !!v;
    return b;
}
static bp *bp_str(const char *s) {
    bp *b = bp_new(BP_STR);
    b->s = strdup(s);
    return b;
}
static bp *bp_data(const void *d, size_t n) {   // bytes (b->s holds them, b->i their count)
    bp *b = bp_new(BP_DATA);
    b->s = malloc(n ? n : 1);
    memcpy(b->s, d, n);
    b->i = (int64_t)n;
    return b;
}
static void bp_add(bp *c, bp *v) {
    if (c->n == c->cap) {
        c->cap = c->cap ? c->cap * 2 : 8;
        c->items = realloc(c->items, sizeof(bp *) * c->cap);
    }
    c->items[c->n++] = v;
}
static void bp_push(bp *a, bp *v) { bp_add(a, v); }
static void bp_set(bp *d, const char *k, bp *v) {
    bp_add(d, bp_str(k));
    bp_add(d, v);
}
static void bp_free(bp *b) {
    for (int i = 0; i < b->n; i++) {
        bp_free(b->items[i]);
    }
    free(b->items);
    free(b->s);
    free(b);
}

typedef struct {
    bp **objs;
    int n, cap;
} bp_list;
static void bp_collect(bp *b, bp_list *l) {
    if (l->n == l->cap) {
        l->cap = l->cap ? l->cap * 2 : 32;
        l->objs = realloc(l->objs, sizeof(bp *) * l->cap);
    }
    b->index = l->n;
    l->objs[l->n++] = b;
    for (int i = 0; i < b->n; i++) {
        bp_collect(b->items[i], l);
    }
}
typedef struct {
    uint8_t *p;
    size_t n, cap;
} bp_buf;
static void bp_put(bp_buf *o, const void *d, size_t n) {
    if (o->n + n > o->cap) {
        o->cap = (o->n + n) * 2 + 64;
        o->p = realloc(o->p, o->cap);
    }
    memcpy(o->p + o->n, d, n);
    o->n += n;
}
static void bp_be(bp_buf *o, uint64_t v, int size) {
    uint8_t b[8];
    for (int i = 0; i < size; i++) {
        b[i] = (uint8_t)(v >> (8 * (size - 1 - i)));
    }
    bp_put(o, b, (size_t)size);
}
static void bp_intobj(bp_buf *o, int64_t v) {
    uint8_t m;
    int size;
    if (v < 0) {
        m = 0x13, size = 8;
    } else if (v < 0x100) {
        m = 0x10, size = 1;
    } else if (v < 0x10000) {
        m = 0x11, size = 2;
    } else if (v < 0x100000000LL) {
        m = 0x12, size = 4;
    } else {
        m = 0x13, size = 8;
    }
    bp_put(o, &m, 1);
    bp_be(o, (uint64_t)v, size);
}
static void bp_marker(bp_buf *o, uint8_t hi, size_t count) {
    uint8_t m = (uint8_t)(hi | (count < 15 ? count : 15));
    bp_put(o, &m, 1);
    if (count >= 15) {
        bp_intobj(o, (int64_t)count);
    }
}

// The binary plist of `root` (malloc'd; *len its size).
static uint8_t *bp_encode(bp *root, size_t *len) {
    bp_list l = {0};
    bp_collect(root, &l);
    int ref = l.n < 256 ? 1 : 2;
    uint64_t *offs = calloc((size_t)l.n, sizeof(uint64_t));
    bp_buf o = {0};
    bp_put(&o, "bplist00", 8);
    for (int i = 0; i < l.n; i++) {
        bp *b = l.objs[i];
        offs[i] = o.n;
        if (b->type == BP_BOOL) {
            uint8_t m = b->i ? 0x09 : 0x08;
            bp_put(&o, &m, 1);
        } else if (b->type == BP_INT) {
            bp_intobj(&o, b->i);
        } else if (b->type == BP_DATA) {
            bp_marker(&o, 0x40, (size_t)b->i);
            bp_put(&o, b->s, (size_t)b->i);
        } else if (b->type == BP_STR) {
            size_t sl = strlen(b->s);
            bp_marker(&o, 0x50, sl);
            bp_put(&o, b->s, sl);
        } else if (b->type == BP_ARRAY) {
            bp_marker(&o, 0xA0, (size_t)b->n);
            for (int k = 0; k < b->n; k++) {
                bp_be(&o, (uint64_t)b->items[k]->index, ref);
            }
        } else {   // dict: keys, then values
            bp_marker(&o, 0xD0, (size_t)(b->n / 2));
            for (int k = 0; k < b->n; k += 2) {
                bp_be(&o, (uint64_t)b->items[k]->index, ref);
            }
            for (int k = 1; k < b->n; k += 2) {
                bp_be(&o, (uint64_t)b->items[k]->index, ref);
            }
        }
    }
    uint64_t table = o.n;
    int osz = table < 0x100 ? 1 : table < 0x10000 ? 2 : 4;
    for (int i = 0; i < l.n; i++) {
        bp_be(&o, offs[i], osz);
    }
    uint8_t trailer[32] = {0};
    trailer[6] = (uint8_t)osz;
    trailer[7] = (uint8_t)ref;
    for (int i = 0; i < 8; i++) {
        trailer[8 + i] = (uint8_t)((uint64_t)l.n >> (56 - 8 * i));
        trailer[24 + i] = (uint8_t)(table >> (56 - 8 * i));
    }
    bp_put(&o, trailer, 32);
    free(offs);
    free(l.objs);
    *len = o.n;
    return o.p;
}

// The top-level object of a one-object binary plist, if it is a number or a boolean (an integer of 1-8 bytes, a real of 4
// or 8): into *v. 0 on success. Only the object right after the header is read, so every offset is the header's.
static int bp_read_number(const uint8_t *p, size_t n, double *v) {
    if (n < 8 + 1 + 32 || memcmp(p, "bplist00", 8)) {
        return -1;
    }
    uint8_t m = p[8];
    if (m == 0x08 || m == 0x09) {
        *v = m == 0x09;
        return 0;
    }
    int size = 1 << (m & 0x0f);
    if ((m & 0xf0) == 0x10 && size <= 8 && 9 + (size_t)size <= n) {
        uint64_t u = 0;
        for (int i = 0; i < size; i++) {
            u = u << 8 | p[9 + i];
        }
        *v = size == 8 ? (double)(int64_t)u : (double)u;
        return 0;
    }
    if ((m & 0xf0) == 0x20 && (size == 4 || size == 8) && 9 + (size_t)size <= n) {
        uint64_t u = 0;
        for (int i = 0; i < size; i++) {
            u = u << 8 | p[9 + i];
        }
        if (size == 4) {
            uint32_t w = (uint32_t)u;
            float f;
            memcpy(&f, &w, 4);
            *v = f;
        } else {
            memcpy(v, &u, 8);
        }
        return 0;
    }
    return -1;
}

// The top-level object of a binary plist, if it is an ASCII string: copied into out (NUL-terminated). 0 on success.
// Every offset the guest wrote is checked against the buffer before it is used.
static int bp_read_string(const uint8_t *p, size_t n, char *out, size_t outsz) {
    if (n < 40 || outsz == 0 || memcmp(p, "bplist00", 8)) {
        return -1;
    }
    const uint8_t *t = p + n - 32;
    uint64_t osz = t[6], top = 0, table = 0;
    for (int i = 0; i < 8; i++) {
        top = top << 8 | t[16 + i];
        table = table << 8 | t[24 + i];
    }
    uint64_t body = n - 32;   // the objects and the offset table lie before the trailer
    if (osz < 1 || osz > 8 || table < 8 || table > body || top >= (body - table) / osz) {   // top + 1 entries fit
        return -1;
    }
    uint64_t off = 0;
    for (uint64_t i = 0; i < osz; i++) {
        off = off << 8 | p[table + top * osz + i];
    }
    if (off < 8 || off >= table) {
        return -1;
    }
    uint8_t m = p[off];
    if ((m & 0xF0) != 0x50) {
        return -1;
    }
    size_t len = m & 0x0F, at = off + 1;
    if (len == 15) {   // an int object follows
        if (at >= table) {
            return -1;
        }
        uint8_t im = p[at++];
        unsigned sz = 1u << (im & 0x0F);
        if ((im & 0xF0) != 0x10 || sz > 8 || sz > table - at) {
            return -1;
        }
        len = 0;
        for (unsigned i = 0; i < sz; i++) {
            len = len << 8 | p[at++];
        }
    }
    if (len >= outsz || len > table - at) {
        return -1;
    }
    memcpy(out, p + at, len);
    out[len] = 0;
    return 0;
}
#endif
