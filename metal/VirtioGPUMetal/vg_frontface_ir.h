// vg_frontface_ir (5d): a workaround for the host GPU's compiler (Mesa 25.0's Intel backend), which gets
// [[front_facing]] wrong when the boolean feeds a 16-bit value: `half2(x, ff ? 1.0h : -1.0h)` came out as the two
// halves of a float32 -1.0 in alternate columns (0x0000, 0xBF80). RenderBox fills paths by adding +1 or -1 by
// front_facing (path_interior_fragment), so every path filled that way -- the Dock's menu shapes -- was striped.
// The same boolean feeding a 32-bit select is right (tools/mtlmrt.m, cases fd/fg against fh/fi).
//
// So in a function with an i1 parameter (a fragment function's only possible bool input is [[front_facing]]; a helper
// may be passed it), each `select i1 %ff, T a, T b` with T half or <2 x half> becomes a 32-bit integer select
// of the operands' bits:  bitcast to i16/i32 -> zext -> select i32 -> trunc -> bitcast back. Exact for every value.
// Header-only C, like vg_opaque_ir.h.
#ifndef VG_FRONTFACE_IR_H
#define VG_FRONTFACE_IR_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *p;
    size_t n, cap;
} vgf_buf;
static void vgf_put(vgf_buf *b, const char *s, size_t n) {
    if (b->n + n + 1 > b->cap) {
        b->cap = (b->n + n + 1) * 2;
        b->p = realloc(b->p, b->cap);
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}
static void vgf_puts(vgf_buf *b, const char *s) { vgf_put(b, s, strlen(s)); }

// The names of a define line's i1 parameters (up to 4), from "define ... @f(i1 noundef %0, ...)".
static int vgf_bool_params(const char *line, size_t len, char names[4][64]) {
    const char *open = memchr(line, '(', len);
    int n = 0;
    if (!open) {
        return 0;
    }
    // the parameter list: from '(' after the function name to its matching ')'
    const char *at = strstr(line, " @");
    if (at && at < line + len) {
        const char *o2 = memchr(at, '(', (size_t)(line + len - at));
        if (o2) {
            open = o2;
        }
    }
    int depth = 0;
    const char *start = open + 1;
    for (const char *p = open; p < line + len; p++) {
        if (*p == '(' || *p == '<' || *p == '{' || *p == '[') {
            depth++;
        } else if (*p == ')' || *p == '>' || *p == '}' || *p == ']') {
            depth--;
        }
        if ((depth == 1 && *p == ',') || (depth == 0 && *p == ')')) {
            const char *s = start;
            while (s < p && *s == ' ') {
                s++;
            }
            if (p - s > 3 && !strncmp(s, "i1 ", 3)) {
                const char *pct = NULL;
                for (const char *q = s; q < p; q++) {
                    if (*q == '%') {
                        pct = q;
                    }
                }
                if (pct && n < 4 && (size_t)(p - pct) < 63) {
                    memcpy(names[n], pct, (size_t)(p - pct));
                    names[n][p - pct] = 0;
                    n++;
                }
            }
            start = p + 1;
            if (depth == 0) {
                break;
            }
        }
    }
    return n;
}

// Rewrites one instruction line if it is a select on one of `ff`; returns 1 when it wrote the replacement.
static int vgf_rewrite(vgf_buf *out, const char *line, size_t len, char ff[4][64], int nff, int *counter) {
    char l[1024];
    if (len >= sizeof(l)) {
        return 0;
    }
    memcpy(l, line, len);
    l[len] = 0;
    char *eq = strstr(l, " = select ");
    if (!eq) {
        return 0;
    }
    char *p = eq + 10;
    static const char *flags[] = {"fast ", "nnan ", "ninf ", "nsz ", "arcp ", "contract ", "afn ", "reassoc "};
    for (int again = 1; again;) {
        again = 0;
        for (int i = 0; i < 8; i++) {
            if (!strncmp(p, flags[i], strlen(flags[i]))) {
                p += strlen(flags[i]);
                again = 1;
            }
        }
    }
    if (strncmp(p, "i1 ", 3)) {
        return 0;
    }
    p += 3;
    int which = -1;
    for (int i = 0; i < nff; i++) {
        size_t k = strlen(ff[i]);
        if (!strncmp(p, ff[i], k) && p[k] == ',') {
            which = i;
            p += k + 2;
        }
    }
    if (which < 0) {
        return 0;
    }
    const char *type = NULL, *ity = NULL, *nty = NULL;   // value type, its bits, the 32-bit select's
    if (!strncmp(p, "half ", 5)) {
        type = "half", ity = "i16", nty = "i32";
    } else if (!strncmp(p, "<2 x half> ", 11)) {
        type = "<2 x half>", ity = "i32", nty = NULL;
    } else {
        return 0;
    }
    p += strlen(type) + 1;
    // "A, TYPE B" (A and B have no top-level commas: values, constants)
    char a[256], b[256], sep[64];
    snprintf(sep, sizeof(sep), ", %s ", type);
    char *mid = strstr(p, sep);
    if (!mid || (size_t)(mid - p) >= sizeof(a)) {
        return 0;
    }
    memcpy(a, p, (size_t)(mid - p));
    a[mid - p] = 0;
    char *bs = mid + strlen(sep);
    size_t bl = strcspn(bs, ",\n");   // trailing metadata, if any, is dropped
    if (bl >= sizeof(b)) {
        return 0;
    }
    memcpy(b, bs, bl);
    b[bl] = 0;
    while (bl && b[bl - 1] == ' ') {
        b[--bl] = 0;
    }
    // the result's name and indentation
    char *ind_end = l;
    while (*ind_end == ' ') {
        ind_end++;
    }
    size_t rl = (size_t)(eq - ind_end);
    char r[128];
    if (rl >= sizeof(r)) {
        return 0;
    }
    memcpy(r, ind_end, rl);
    r[rl] = 0;
    int k = (*counter)++;
    char s[2048];
    if (nty) {   // 16-bit: widen the bits so the select is 32-bit
        snprintf(s, sizeof(s),
                 "  %%vgff.%d.a = bitcast %s %s to %s\n  %%vgff.%d.b = bitcast %s %s to %s\n"
                 "  %%vgff.%d.c = zext %s %%vgff.%d.a to %s\n  %%vgff.%d.d = zext %s %%vgff.%d.b to %s\n"
                 "  %%vgff.%d.e = select i1 %s, %s %%vgff.%d.c, %s %%vgff.%d.d\n"
                 "  %%vgff.%d.f = trunc %s %%vgff.%d.e to %s\n  %s = bitcast %s %%vgff.%d.f to %s\n",
                 k, type, a, ity, k, type, b, ity, k, ity, k, nty, k, ity, k, nty, k, ff[which], nty, k, nty, k, k, nty,
                 k, ity, r, ity, k, type);
    } else {
        snprintf(s, sizeof(s),
                 "  %%vgff.%d.a = bitcast %s %s to %s\n  %%vgff.%d.b = bitcast %s %s to %s\n"
                 "  %%vgff.%d.e = select i1 %s, %s %%vgff.%d.a, %s %%vgff.%d.b\n  %s = bitcast %s %%vgff.%d.e to %s\n",
                 k, type, a, ity, k, type, b, ity, k, ff[which], ity, k, ity, k, r, ity, k, type);
    }
    vgf_puts(out, s);
    return 1;
}

// Returns a malloc'd rewritten module (the caller frees it), or NULL when nothing needed changing.
static char *vg_frontface_ir(const char *in) {
    if (!strstr(in, " = select ") || (!strstr(in, "(i1 ") && !strstr(in, ", i1 "))) {
        return NULL;
    }
    vgf_buf out = {0};
    char ff[4][64];
    int nff = 0, changed = 0, counter = 0;
    const char *p = in;
    while (*p) {
        const char *e = strchr(p, '\n');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (!strncmp(p, "define ", 7)) {
            nff = vgf_bool_params(p, len, ff);
        } else if (len && p[0] == '}') {
            nff = 0;
        }
        if (nff && vgf_rewrite(&out, p, len, ff, nff, &counter)) {
            changed = 1;
        } else {
            vgf_put(&out, p, len);
            if (e) {
                vgf_put(&out, "\n", 1);
            }
        }
        if (!e) {
            break;
        }
        p = e + 1;
    }
    if (!changed) {
        free(out.p);
        return NULL;
    }
    return out.p;
}
#endif
