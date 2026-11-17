// vv_bplist.h (Venera video): just enough binary property list for the host side of Apple's paravirtualized
// VideoToolbox protocol, which passes CoreFoundation objects as "bplist00": a writer for dictionaries, arrays, ASCII
// strings, integers and booleans, and a reader for a top-level string. Header-only C.
#ifndef VV_BPLIST_H
#define VV_BPLIST_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { BP_DICT, BP_ARRAY, BP_STR, BP_INT, BP_BOOL };
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

// The top-level object of a binary plist, if it is an ASCII string: copied into out (NUL-terminated). 0 on success.
static int bp_read_string(const uint8_t *p, size_t n, char *out, size_t outsz) {
    if (n < 40 || memcmp(p, "bplist00", 8)) {
        return -1;
    }
    const uint8_t *t = p + n - 32;
    int osz = t[6];
    uint64_t top = 0, table = 0;
    for (int i = 0; i < 8; i++) {
        top = top << 8 | t[16 + i];
        table = table << 8 | t[24 + i];
    }
    if (table + (top + 1) * (uint64_t)osz > n - 32) {
        return -1;
    }
    uint64_t off = 0;
    for (int i = 0; i < osz; i++) {
        off = off << 8 | p[table + top * (uint64_t)osz + (uint64_t)i];
    }
    if (off >= n) {
        return -1;
    }
    uint8_t m = p[off];
    if ((m & 0xF0) != 0x50) {
        return -1;
    }
    size_t len = m & 0x0F, at = off + 1;
    if (len == 15) {   // an int object follows
        uint8_t im = p[at++];
        int sz = 1 << (im & 0x0F);
        len = 0;
        for (int i = 0; i < sz; i++) {
            len = len << 8 | p[at++];
        }
    }
    if (at + len > n || len + 1 > outsz) {
        return -1;
    }
    memcpy(out, p + at, len);
    out[len] = 0;
    return 0;
}
#endif
