// vg_frontface_ir (5d): a workaround for the host GPU's compiler (Mesa 25.0's Intel backend), which gets
// [[front_facing]] wrong when the boolean feeds a 16-bit value: `half2(x, ff ? 1.0h : -1.0h)` came out as the two
// halves of a float32 -1.0 in alternate columns (0x0000, 0xBF80). RenderBox fills paths by adding +1 or -1 by
// front_facing (path_interior_fragment), so every path filled that way -- the Dock's menu shapes -- was striped.
// The same boolean feeding a 32-bit select is right (tools/mtlmrt.m, cases fd/fg against fh/fi). The backend's
// front-facing shortcut (a ?: of +-1.0 on gl_FrontFacing, made without looking at the result's bit size) is the likely
// cause, so its inverse (`!ff ? ..`), which the compiler folds into the same shape, and every vector width count too.
//
// So in a function with an i1 parameter (a fragment function's only possible bool input is [[front_facing]]; a helper
// may be passed it), each select on that parameter -- or on its inverse, `xor i1 %ff, true` -- whose values are 16-bit
// (half, i16, or vectors of them) becomes a 32-bit integer select of the operands' bits: bitcast to i16 lanes -> zext
// to i32 -> select -> trunc -> bitcast back. Exact for every value. A 16-bit phi in such a function (a branch on the
// boolean, which the compiler may also turn into the select) in a function that branches on it is counted in
// vg_frontface_unhandled for the driver's log. Header-only C, like vg_opaque_ir.h.
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

#define VGF_MAX 16
static int vg_frontface_unhandled;   // 16-bit phis in functions that branch on a bool parameter (not rewritten)
static char vg_frontface_where[96];   // the last such function

// The 16-bit type at p ("half", "i16", "<N x half>", "<N x i16>"): its spelling, its lanes as i16 and as i32, and
// whether it is a float. 0 when p holds some other type.
static int vgf_type16(const char *p, char *type, char *ity, char *wty, int *isfloat) {
    int n = 0;
    char el[8];
    if (!strncmp(p, "half ", 5) || !strncmp(p, "i16 ", 4)) {
        *isfloat = p[0] == 'h';
        strcpy(type, *isfloat ? "half" : "i16");
        strcpy(ity, "i16"), strcpy(wty, "i32");
        return 1;
    }
    if (sscanf(p, "<%d x %7[a-z0-9]>", &n, el) == 2 && n >= 2 && n <= 16 && (!strcmp(el, "half") || !strcmp(el, "i16"))) {
        *isfloat = el[0] == 'h';
        sprintf(type, "<%d x %s>", n, el);
        sprintf(ity, "<%d x i16>", n);
        sprintf(wty, "<%d x i32>", n);
        return 1;
    }
    return 0;
}

// Rewrites one instruction line if it is a select on one of `ff`; returns 1 when it wrote the replacement.
static int vgf_rewrite(vgf_buf *out, const char *line, size_t len, char ff[VGF_MAX][64], int nff, int *counter) {
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
    for (int i = 0; i < nff && which < 0; i++) {
        size_t k = strlen(ff[i]);
        if (!strncmp(p, ff[i], k) && p[k] == ',') {
            which = i;
            p += k + 2;
        }
    }
    if (which < 0) {
        return 0;
    }
    char type[32], ity[32], wty[32];
    int isfloat = 0;
    if (!vgf_type16(p, type, ity, wty, &isfloat)) {
        return 0;
    }
    p += strlen(type) + 1;
    // "A, TYPE B" (A and B have no top-level ", TYPE ": values, constants)
    char a[256], b[256], sep[64];
    snprintf(sep, sizeof(sep), ", %s ", type);
    char *mid = strstr(p, sep);
    if (!mid || (size_t)(mid - p) >= sizeof(a)) {
        return 0;
    }
    memcpy(a, p, (size_t)(mid - p));
    a[mid - p] = 0;
    char *bs = mid + strlen(sep);
    // B runs to the end, or to ", !" (metadata, dropped); a vector constant's own commas sit inside <...>
    size_t bl = 0;
    for (int depth = 0; bs[bl] && bs[bl] != '\n'; bl++) {
        if (bs[bl] == '<' || bs[bl] == '[' || bs[bl] == '{' || bs[bl] == '(') {
            depth++;
        } else if (bs[bl] == '>' || bs[bl] == ']' || bs[bl] == '}' || bs[bl] == ')') {
            depth--;
        } else if (bs[bl] == ',' && depth == 0) {
            break;
        }
    }
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
    char s[2048], ia[300], ib[300];
    if (isfloat) {   // the bits, as i16 lanes
        snprintf(s, sizeof(s), "  %%vgff.%d.a = bitcast %s %s to %s\n  %%vgff.%d.b = bitcast %s %s to %s\n", k, type, a, ity,
                 k, type, b, ity);
        vgf_puts(out, s);
        snprintf(ia, sizeof(ia), "%%vgff.%d.a", k);
        snprintf(ib, sizeof(ib), "%%vgff.%d.b", k);
    } else {
        snprintf(ia, sizeof(ia), "%s", a);
        snprintf(ib, sizeof(ib), "%s", b);
    }
    snprintf(s, sizeof(s),
             "  %%vgff.%d.c = zext %s %s to %s\n  %%vgff.%d.d = zext %s %s to %s\n"
             "  %%vgff.%d.e = select i1 %s, %s %%vgff.%d.c, %s %%vgff.%d.d\n",
             k, ity, ia, wty, k, ity, ib, wty, k, ff[which], wty, k, wty, k);
    vgf_puts(out, s);
    if (isfloat) {
        snprintf(s, sizeof(s), "  %%vgff.%d.f = trunc %s %%vgff.%d.e to %s\n  %s = bitcast %s %%vgff.%d.f to %s\n", k, wty, k,
                 ity, r, ity, k, type);
    } else {
        snprintf(s, sizeof(s), "  %s = trunc %s %%vgff.%d.e to %s\n", r, wty, k, ity);
    }
    vgf_puts(out, s);
    return 1;
}

// "%x = xor i1 %ff, true" (or "true, %ff"): %x is the inverse of a front-facing name. Its name, or 0.
static int vgf_inverse(const char *line, size_t len, char ff[VGF_MAX][64], int nff, char *name) {
    char l[512];
    if (len >= sizeof(l)) {
        return 0;
    }
    memcpy(l, line, len);
    l[len] = 0;
    char *eq = strstr(l, " = xor i1 ");
    if (!eq) {
        return 0;
    }
    char *ops = eq + 10;
    for (int i = 0; i < nff; i++) {
        char x1[96], x2[96];
        snprintf(x1, sizeof(x1), "%s, true", ff[i]);
        snprintf(x2, sizeof(x2), "true, %s", ff[i]);
        if ((!strncmp(ops, x1, strlen(x1)) && (!ops[strlen(x1)] || ops[strlen(x1)] == ',' || ops[strlen(x1)] == ' ')) ||
            (!strncmp(ops, x2, strlen(x2)) && (!ops[strlen(x2)] || ops[strlen(x2)] == ',' || ops[strlen(x2)] == ' '))) {
            char *b = l;
            while (*b == ' ') {
                b++;
            }
            size_t n = (size_t)(eq - b);
            if (n == 0 || n >= 64) {
                return 0;
            }
            memcpy(name, b, n);
            name[n] = 0;
            return 1;
        }
    }
    return 0;
}

// Returns a malloc'd rewritten module (the caller frees it), or NULL when nothing needed changing.
static char *vg_frontface_ir(const char *in) {
    if (!strstr(in, " = select ") || (!strstr(in, "(i1 ") && !strstr(in, ", i1 "))) {
        return NULL;
    }
    vgf_buf out = {0};
    char ff[VGF_MAX][64];
    int nff = 0, changed = 0, counter = 0, branches = 0, phis = 0;
    char fname[96] = "";
    const char *p = in;
    while (*p) {
        const char *e = strchr(p, '\n');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (!strncmp(p, "define ", 7)) {
            char params[4][64];
            nff = vgf_bool_params(p, len, params);
            for (int i = 0; i < nff; i++) {
                strcpy(ff[i], params[i]);
            }
            branches = phis = 0;
            const char *at = memchr(p, '@', len), *par = at ? memchr(at, '(', (size_t)(p + len - at)) : NULL;
            size_t fl = at && par ? (size_t)(par - at) : 0;
            fl = fl < sizeof(fname) ? fl : sizeof(fname) - 1;
            memcpy(fname, at ? at : "", fl);
            fname[fl] = 0;
        } else if (len && p[0] == '}') {
            if (branches && phis && strstr(in, "air.front_facing")) {   // a module where a bool may be front_facing   // a branch on the boolean and 16-bit phis: the shape the rewrite can't reach
                vg_frontface_unhandled += phis;
                snprintf(vg_frontface_where, sizeof(vg_frontface_where), "%s", fname);
            }
            nff = 0;
        } else if (nff && nff < VGF_MAX && vgf_inverse(p, len, ff, nff, ff[nff])) {
            nff++;
        }
        if (nff && len > 12 && memmem(p, len, " = phi ", 7)) {
            const char *t = (const char *)memmem(p, len, " = phi ", 7) + 7;
            char ty[32], it[32], wt[32];
            int f;
            if (vgf_type16(t, ty, it, wt, &f)) {
                phis++;
            }
        }
        if (nff && memmem(p, len, "br i1 ", 6)) {
            const char *c = (const char *)memmem(p, len, "br i1 ", 6) + 6;
            for (int i = 0; i < nff; i++) {
                size_t k = strlen(ff[i]);
                branches |= !strncmp(c, ff[i], k) && c[k] == ',';
            }
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
