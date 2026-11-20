// Metal tessellation on Vulkan (5d: Setup Assistant's Memoji draw with it): the stages a post-tessellation vertex
// function needs around it, written as SPIR-V words.
//
// Ported from nullmoth/nvidia-macos-driver's plugin/nvmtl_vk.c (PolyForm Noncommercial 1.0.0, Copyright (c) 2026
// NullMoth Systems): the SPIR-V builders (nvt_*), nvt_scan_tese, nvmtl_spirv_tess_info, nvmtl_tess_patch_tese, the
// vertex format table (k_nvt_fmt), nvmtl_tess_make_vs and nvmtl_tess_make_tcs are theirs. Their design, unchanged:
// - The translator makes a post-tessellation vertex function ([[patch(quad|triangle, n)]]) a TessellationEvaluation
//   module: control-point inputs are arrays of n at their attribute Locations, per-patch inputs carry Patch,
//   [[instance_id]] is a per-patch input after them, and [[patch_id]] is the PrimitiveId built-in. The descriptor's
//   partition mode and winding are written into its spacing and vertex-order execution modes, and [[patch_id]] becomes
//   a per-patch input after the others (PrimitiveId would count from 0 in each draw and ignore a patch index buffer).
// - A generated vertex stage passes each patch's draw position (VertexIndex) and InstanceIndex on: a patch draw is
//   vkCmdDraw(patchCount, instances, patchStart, baseInstance) on a patch list of one control point.
// - A generated tessellation-control stage of n invocations writes the evaluation stage's inputs: it reads the patch's
//   half-float factors from the factor buffer and each input from the app's vertex buffers, by device address, from a
//   96-byte push-constant block (vg_tess_push).
// What changed: Venera's names and types (vg_tess_input for nvk_vertex_input, vg_tess_desc for nvk_tess_desc), one
// entry point that builds all three modules, and small functions in place of GNU statement expressions.
#include "VGMTLTess.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- a SPIR-V module, built section by section --------------------------------------------------------------------

typedef struct {
    uint32_t *w;
    size_t n, cap;
    int bad;
} vgt_words;

static void vgt_put(vgt_words *b, uint32_t v) {
    if (b->bad) {
        return;
    }
    if (b->n == b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 256;
        uint32_t *nw = (uint32_t *)realloc(b->w, nc * 4);
        if (!nw) {
            b->bad = 1;
            return;
        }
        b->w = nw;
        b->cap = nc;
    }
    b->w[b->n++] = v;
}
static void vgt_ins(vgt_words *b, uint32_t op, const uint32_t *a, uint32_t na) {
    vgt_put(b, ((na + 1) << 16) | op);
    for (uint32_t i = 0; i < na; i++) {
        vgt_put(b, a[i]);
    }
}
// One instruction: opcode, then its operand words.
#define VGT(b, op, ...)                                                                                                \
    do {                                                                                                               \
        const uint32_t a_[] = {__VA_ARGS__};                                                                           \
        vgt_ins((b), (op), a_, (uint32_t)(sizeof a_ / sizeof a_[0]));                                                  \
    } while (0)
// An instruction with a literal string between other operands.
static void vgt_str(vgt_words *b, uint32_t op, const uint32_t *pre, uint32_t npre, const char *s, const uint32_t *post,
                    uint32_t npost) {
    size_t sl = strlen(s), sw = sl / 4 + 1;
    vgt_put(b, (uint32_t)((1 + npre + sw + npost) << 16) | op);
    for (uint32_t i = 0; i < npre; i++) {
        vgt_put(b, pre[i]);
    }
    for (size_t i = 0; i < sw; i++) {
        uint32_t v = 0;
        for (int k = 0; k < 4; k++) {
            size_t j = i * 4 + k;
            if (j < sl) {
                v |= (uint32_t)(uint8_t)s[j] << (8 * k);
            }
        }
        vgt_put(b, v);
    }
    for (uint32_t i = 0; i < npost; i++) {
        vgt_put(b, post[i]);
    }
}

enum { VGT_F = 0, VGT_I = 1, VGT_U = 2, VGT_OTHER = 99 };   // float, int, uint (a scalar's kind)

// The sections in module order, the next id, the GLSL.std.450 import, the current block's label, the common types,
// and the constants and pointer types made so far (each made once).
typedef struct {
    vgt_words caps, ep, deco, glob, fn;
    uint32_t id, glsl, cur;
    uint32_t t_void, t_fn, t_bool, t_u64, t_vec[3][5];
    struct {
        uint32_t ty, lo, hi, id;
    } k[96];
    int nk;
    struct {
        uint32_t sc, ty, id;
    } p[48];
    int np;
    int err;
} vgt_ctx;

static uint32_t vgt_id(vgt_ctx *c) { return c->id++; }
static uint32_t vgt_ptr(vgt_ctx *c, uint32_t sc, uint32_t ty) {
    for (int i = 0; i < c->np; i++) {
        if (c->p[i].sc == sc && c->p[i].ty == ty) {
            return c->p[i].id;
        }
    }
    if (c->np == 48) {
        c->err = 1;
        return 0;
    }
    uint32_t id = vgt_id(c);
    VGT(&c->glob, 32, id, sc, ty);   // OpTypePointer
    c->p[c->np].sc = sc;
    c->p[c->np].ty = ty;
    c->p[c->np++].id = id;
    return id;
}
static uint32_t vgt_k2(vgt_ctx *c, uint32_t ty, uint32_t lo, uint32_t hi, int wide) {
    for (int i = 0; i < c->nk; i++) {
        if (c->k[i].ty == ty && c->k[i].lo == lo && c->k[i].hi == hi) {
            return c->k[i].id;
        }
    }
    if (c->nk == 96) {
        c->err = 1;
        return 0;
    }
    uint32_t id = vgt_id(c);
    if (wide) {
        VGT(&c->glob, 43, ty, id, lo, hi);   // OpConstant
    } else {
        VGT(&c->glob, 43, ty, id, lo);
    }
    c->k[c->nk].ty = ty;
    c->k[c->nk].lo = lo;
    c->k[c->nk].hi = hi;
    c->k[c->nk++].id = id;
    return id;
}
static uint32_t vgt_ku(vgt_ctx *c, uint32_t v) { return vgt_k2(c, c->t_vec[VGT_U][1], v, 0, 0); }
static uint32_t vgt_ki(vgt_ctx *c, int32_t v) { return vgt_k2(c, c->t_vec[VGT_I][1], (uint32_t)v, 0, 0); }
static uint32_t vgt_kf(vgt_ctx *c, float f) {
    uint32_t v;
    memcpy(&v, &f, 4);
    return vgt_k2(c, c->t_vec[VGT_F][1], v, 0, 0);
}
static uint32_t vgt_k64(vgt_ctx *c, uint64_t v) { return vgt_k2(c, c->t_u64, (uint32_t)v, (uint32_t)(v >> 32), 1); }
static uint32_t vgt_op1(vgt_ctx *c, uint32_t op, uint32_t ty, uint32_t a) {
    uint32_t r = vgt_id(c);
    VGT(&c->fn, op, ty, r, a);
    return r;
}
static uint32_t vgt_op2(vgt_ctx *c, uint32_t op, uint32_t ty, uint32_t a, uint32_t b) {
    uint32_t r = vgt_id(c);
    VGT(&c->fn, op, ty, r, a, b);
    return r;
}
static uint32_t vgt_ext1(vgt_ctx *c, uint32_t ty, uint32_t inst, uint32_t a) {
    uint32_t r = vgt_id(c);
    VGT(&c->fn, 12, ty, r, c->glsl, inst, a);   // OpExtInst
    return r;
}
static uint32_t vgt_ext2(vgt_ctx *c, uint32_t ty, uint32_t inst, uint32_t a, uint32_t b) {
    uint32_t r = vgt_id(c);
    VGT(&c->fn, 12, ty, r, c->glsl, inst, a, b);
    return r;
}
static uint32_t vgt_sel(vgt_ctx *c, uint32_t ty, uint32_t cond, uint32_t a, uint32_t b) {
    uint32_t r = vgt_id(c);
    VGT(&c->fn, 169, ty, r, cond, a, b);   // OpSelect
    return r;
}
static uint32_t vgt_ex(vgt_ctx *c, uint32_t ty, uint32_t comp, uint32_t i) {
    uint32_t r = vgt_id(c);
    VGT(&c->fn, 81, ty, r, comp, i);   // OpCompositeExtract
    return r;
}
static uint32_t vgt_bits(vgt_ctx *c, uint32_t op, uint32_t ty, uint32_t v, uint32_t off, uint32_t count) {
    uint32_t r = vgt_id(c);
    VGT(&c->fn, op, ty, r, v, vgt_ku(c, off), vgt_ku(c, count));   // OpBitFieldSExtract (202) / UExtract (203)
    return r;
}
static uint32_t vgt_add64(vgt_ctx *c, uint32_t a, uint32_t b) { return vgt_op2(c, 128, c->t_u64, a, b); }   // OpIAdd
static uint32_t vgt_widen(vgt_ctx *c, uint32_t u32) { return vgt_op1(c, 113, c->t_u64, u32); }            // OpUConvert
// A 32-bit word at a device address (PhysicalStorageBuffer, aligned 4).
static uint32_t vgt_load32(vgt_ctx *c, uint32_t addr) {
    uint32_t pt = vgt_ptr(c, 5349, c->t_vec[VGT_U][1]), p = vgt_op1(c, 120, pt, addr), v = vgt_id(c);   // OpConvertUToPtr
    VGT(&c->fn, 61, c->t_vec[VGT_U][1], v, p, 2, 4);                                                     // OpLoad Aligned 4
    return v;
}
// A load through an access chain into a variable (one or two indices).
static uint32_t vgt_chain_load(vgt_ctx *c, uint32_t ptrty, uint32_t ty, uint32_t var, uint32_t i0, uint32_t i1, int two) {
    uint32_t p = vgt_id(c), v = vgt_id(c);
    if (two) {
        VGT(&c->fn, 65, ptrty, p, var, i0, i1);   // OpAccessChain
    } else {
        VGT(&c->fn, 65, ptrty, p, var, i0);
    }
    VGT(&c->fn, 61, ty, v, p);
    return v;
}
static void vgt_types(vgt_ctx *c, int wide) {
    c->id = 1;
    c->t_void = vgt_id(c);
    VGT(&c->glob, 19, c->t_void);
    c->t_fn = vgt_id(c);
    VGT(&c->glob, 33, c->t_fn, c->t_void);
    c->t_bool = vgt_id(c);
    VGT(&c->glob, 20, c->t_bool);
    c->t_vec[VGT_F][1] = vgt_id(c);
    VGT(&c->glob, 22, c->t_vec[VGT_F][1], 32);
    c->t_vec[VGT_I][1] = vgt_id(c);
    VGT(&c->glob, 21, c->t_vec[VGT_I][1], 32, 1);
    c->t_vec[VGT_U][1] = vgt_id(c);
    VGT(&c->glob, 21, c->t_vec[VGT_U][1], 32, 0);
    if (wide) {
        c->t_u64 = vgt_id(c);
        VGT(&c->glob, 21, c->t_u64, 64, 0);
    }
    for (int k = 0; k < 3; k++) {
        for (uint32_t n = 2; n <= 4; n++) {
            c->t_vec[k][n] = vgt_id(c);
            VGT(&c->glob, 23, c->t_vec[k][n], c->t_vec[k][1], n);   // OpTypeVector
        }
    }
}
static void vgt_drop(vgt_ctx *c) {
    vgt_words *s[5] = {&c->caps, &c->ep, &c->deco, &c->glob, &c->fn};
    for (int i = 0; i < 5; i++) {
        free(s[i]->w);
        s[i]->w = NULL;
    }
}
// The header and the sections joined (SPIR-V 1.3), or NULL when anything ran out.
static uint32_t *vgt_link(vgt_ctx *c, size_t *outn) {
    vgt_words *s[5] = {&c->caps, &c->ep, &c->deco, &c->glob, &c->fn};
    size_t n = 5;
    for (int i = 0; i < 5; i++) {
        if (s[i]->bad) {
            c->err = 1;
        }
        n += s[i]->n;
    }
    uint32_t *w = c->err ? NULL : (uint32_t *)malloc(n * 4);
    if (w) {
        w[0] = 0x07230203;
        w[1] = 0x00010300;
        w[2] = 0;
        w[3] = c->id;
        w[4] = 0;
        size_t o = 5;
        for (int i = 0; i < 5; i++) {
            if (s[i]->n) {
                memcpy(w + o, s[i]->w, s[i]->n * 4);
            }
            o += s[i]->n;
        }
        *outn = n;
    }
    vgt_drop(c);
    return w;
}

// ---- reading the evaluation module ---------------------------------------------------------------------------------

typedef struct {
    uint32_t op, a, b;
} vgt_def;
typedef struct {
    uint32_t var, loc, patch, kind, comps, arrlen;
} vgt_in;
// What the evaluation module declares: execution model, domain, where its spacing and vertex-order modes and the
// PrimitiveId decoration are (word indices), the PrimitiveId variable and kind, and its Location inputs.
typedef struct {
    uint32_t model, domain, spacing_at, order_at, pid_deco_at, pid_var, pid_kind, maxloc;
    int has_loc;
    int nin;
    vgt_in in[40];
} vgt_tese;

static int vgt_scan_tese(const uint32_t *w, size_t n, vgt_tese *t) {
    memset(t, 0, sizeof *t);
    t->model = ~0u;
    if (n < 5 || w[0] != 0x07230203) {
        return -1;
    }
    uint32_t bound = w[3];
    if (!bound || bound > (1u << 22)) {
        return -1;
    }
    vgt_def *d = (vgt_def *)calloc(bound, sizeof *d);
    uint32_t *loc = (uint32_t *)calloc(bound, 4), *fl = (uint32_t *)calloc(bound, 4);
    if (!d || !loc || !fl) {
        free(d);
        free(loc);
        free(fl);
        return -1;
    }
    int rc = 0;
#define VGT_ID_OK(x) ((x) < bound)
    for (size_t i = 5; i < n;) {
        uint32_t wc = w[i] >> 16, op = w[i] & 0xffff;
        if (!wc || i + wc > n) {
            rc = -1;
            break;
        }
        const uint32_t *o = w + i + 1;
        if (op == 15 && wc >= 3) {   // OpEntryPoint
            t->model = o[0];
        } else if (op == 16 && wc >= 3) {   // OpExecutionMode
            if (o[1] == 22 || o[1] == 24 || o[1] == 25) {   // Triangles, Quads, Isolines
                t->domain = o[1];
            } else if (o[1] >= 1 && o[1] <= 3) {   // SpacingEqual / FractionalEven / FractionalOdd
                t->spacing_at = (uint32_t)(i + 2);
            } else if (o[1] == 4 || o[1] == 5) {   // VertexOrderCw / Ccw
                t->order_at = (uint32_t)(i + 2);
            }
        } else if (op == 71 && wc >= 3 && VGT_ID_OK(o[0])) {   // OpDecorate
            if (o[1] == 30 && wc >= 4) {   // Location
                loc[o[0]] = o[2] + 1;
            } else if (o[1] == 15) {   // Patch
                fl[o[0]] |= 1;
            } else if (o[1] == 11 && wc >= 4) {   // BuiltIn
                fl[o[0]] |= 2;
                if (o[2] == 7) {   // PrimitiveId
                    t->pid_deco_at = (uint32_t)i;
                    t->pid_var = o[0];
                }
            }
        } else if ((op == 21 || op == 22 || op == 23 || op == 28 || op == 32) && wc >= 3 && VGT_ID_OK(o[0])) {
            d[o[0]].op = op;   // int, float, vector, array, pointer types
            d[o[0]].a = o[1];
            d[o[0]].b = wc >= 4 ? o[2] : 0;
        } else if (op == 43 && wc >= 4 && VGT_ID_OK(o[1])) {   // OpConstant
            d[o[1]].op = 43;
            d[o[1]].a = o[0];
            d[o[1]].b = o[2];
        } else if (op == 59 && wc >= 4 && VGT_ID_OK(o[1]) && o[2] == 1) {   // OpVariable Input
            d[o[1]].op = 59;
            d[o[1]].a = o[0];
        }
        i += wc;
    }
    for (uint32_t id = 0; rc == 0 && id < bound; id++) {
        if (d[id].op != 59 || !loc[id] || (fl[id] & 2)) {
            continue;
        }
        uint32_t L = loc[id] - 1;
        if (!t->has_loc || L > t->maxloc) {
            t->maxloc = L;
        }
        t->has_loc = 1;
        if (t->nin == 40) {
            rc = -2;
            break;
        }
        vgt_in *e = &t->in[t->nin++];
        e->var = id;
        e->loc = L;
        e->patch = fl[id] & 1;
        uint32_t ty = d[id].a < bound && d[d[id].a].op == 32 ? d[d[id].a].b : 0;
        if (ty < bound && d[ty].op == 28) {
            uint32_t len = d[ty].b;
            e->arrlen = len < bound && d[len].op == 43 ? d[len].b : 0;
            ty = d[ty].a;
        }
        e->comps = 1;
        if (ty < bound && d[ty].op == 23) {
            e->comps = d[ty].b;
            ty = d[ty].a;
        }
        if (ty < bound && d[ty].op == 22 && d[ty].a == 32) {
            e->kind = VGT_F;
        } else if (ty < bound && d[ty].op == 21 && d[ty].a == 32) {
            e->kind = d[ty].b ? VGT_I : VGT_U;
        } else {
            e->kind = VGT_OTHER;
        }
    }
    if (rc == 0 && t->pid_var) {
        uint32_t pt = t->pid_var < bound ? d[t->pid_var].a : 0, ty = pt < bound && d[pt].op == 32 ? d[pt].b : 0;
        t->pid_kind = ty < bound && d[ty].op == 21 && d[ty].a == 32 ? (d[ty].b ? VGT_I : VGT_U) : VGT_OTHER;
    }
#undef VGT_ID_OK
    free(d);
    free(loc);
    free(fl);
    return rc;
}

int vg_spirv_tess_info(const void *spv, size_t bytes, uint32_t *patchType, uint32_t *cps) {
    vgt_tese t;
    if (!spv || vgt_scan_tese((const uint32_t *)spv, bytes / 4, &t) || t.model != 2) {   // TessellationEvaluation
        return 0;
    }
    *patchType = t.domain == 22 ? 1 : t.domain == 24 ? 2 : 0;
    *cps = 0;
    for (int i = 0; i < t.nin; i++) {
        if (!t.in[i].patch && t.in[i].arrlen) {
            *cps = t.in[i].arrlen;
            break;
        }
    }
    return *patchType != 0;
}

// The evaluation module with its spacing and vertex order set, and PrimitiveId turned into a per-patch input at the
// Location after the last one (3 words longer then).
static uint32_t *vgt_patch_tese(const uint32_t *w, size_t n, uint32_t spacing, uint32_t order, size_t *outn,
                                uint32_t *pidloc, const char **why) {
    vgt_tese t;
    *pidloc = ~0u;
    if (vgt_scan_tese(w, n, &t)) {
        *why = "the post-tessellation module does not parse";
        return NULL;
    }
    if (t.model != 2) {
        *why = "the vertex function is not a post-tessellation (TessellationEvaluation) module";
        return NULL;
    }
    if (!t.spacing_at || !t.order_at) {
        *why = "the post-tessellation module declares no spacing or vertex order to set";
        return NULL;
    }
    uint32_t *o = (uint32_t *)malloc((n + 3) * 4);
    if (!o) {
        *why = "out of memory";
        return NULL;
    }
    size_t at = t.pid_deco_at;
    if (!at) {
        memcpy(o, w, n * 4);
        *outn = n;
    } else {
        memcpy(o, w, (at + 4) * 4);
        *pidloc = t.has_loc ? t.maxloc + 1 : 0;
        o[at + 2] = 30;   // BuiltIn PrimitiveId -> Location pidloc
        o[at + 3] = *pidloc;
        o[at + 4] = (3u << 16) | 71;   // + OpDecorate Patch
        o[at + 5] = t.pid_var;
        o[at + 6] = 15;
        memcpy(o + at + 7, w + at + 4, (n - at - 4) * 4);
        *outn = n + 3;
    }
    size_t sh = at && t.spacing_at > at ? 3 : 0, oh = at && t.order_at > at ? 3 : 0;
    o[t.spacing_at + sh] = spacing;
    o[t.order_at + oh] = order;
    return o;
}

// ---- pulling an attribute from a vertex buffer ---------------------------------------------------------------------

// MTLVertexFormat -> kind (0 float32, 1 half, 2 unorm, 3 snorm, 4 uint, 5 sint), bits per component, components, BGRA.
typedef struct {
    uint8_t fmt, kind, bits, comps, bgra;
} vgt_fmt;
static const vgt_fmt kVgtFmt[] = {
    {1, 4, 8, 2, 0},   {2, 4, 8, 3, 0},   {3, 4, 8, 4, 0},   {4, 5, 8, 2, 0},   {5, 5, 8, 3, 0},   {6, 5, 8, 4, 0},
    {7, 2, 8, 2, 0},   {8, 2, 8, 3, 0},   {9, 2, 8, 4, 0},   {10, 3, 8, 2, 0},  {11, 3, 8, 3, 0},  {12, 3, 8, 4, 0},
    {13, 4, 16, 2, 0}, {14, 4, 16, 3, 0}, {15, 4, 16, 4, 0}, {16, 5, 16, 2, 0}, {17, 5, 16, 3, 0}, {18, 5, 16, 4, 0},
    {19, 2, 16, 2, 0}, {20, 2, 16, 3, 0}, {21, 2, 16, 4, 0}, {22, 3, 16, 2, 0}, {23, 3, 16, 3, 0}, {24, 3, 16, 4, 0},
    {25, 1, 16, 2, 0}, {26, 1, 16, 3, 0}, {27, 1, 16, 4, 0}, {28, 0, 32, 1, 0}, {29, 0, 32, 2, 0}, {30, 0, 32, 3, 0},
    {31, 0, 32, 4, 0}, {32, 5, 32, 1, 0}, {33, 5, 32, 2, 0}, {34, 5, 32, 3, 0}, {35, 5, 32, 4, 0}, {36, 4, 32, 1, 0},
    {37, 4, 32, 2, 0}, {38, 4, 32, 3, 0}, {39, 4, 32, 4, 0}, {42, 2, 8, 4, 1},  {45, 4, 8, 1, 0},  {46, 5, 8, 1, 0},
    {47, 2, 8, 1, 0},  {48, 3, 8, 1, 0},  {49, 4, 16, 1, 0}, {50, 5, 16, 1, 0}, {51, 2, 16, 1, 0}, {52, 3, 16, 1, 0},
    {53, 1, 16, 1, 0},
};
static const vgt_fmt *vgt_fmt_of(uint32_t f) {
    for (size_t i = 0; i < sizeof kVgtFmt / sizeof kVgtFmt[0]; i++) {
        if (kVgtFmt[i].fmt == f) {
            return &kVgtFmt[i];
        }
    }
    return NULL;
}
static int vgt_fmt_class(const vgt_fmt *f) { return f->kind <= 3 ? VGT_F : f->kind == 4 ? VGT_U : VGT_I; }

// One attribute at a device address, converted to the shader's type (kind, m components; missing ones are 0, 0, 0, 1).
static uint32_t vgt_pull(vgt_ctx *c, const vgt_fmt *f, uint32_t addr, uint32_t kind, uint32_t m) {
    uint32_t wd[4] = {0}, comp[4] = {0}, nw = (f->comps * f->bits / 8 + 3) / 4;
    uint32_t F = c->t_vec[VGT_F][1], U = c->t_vec[VGT_U][1], I = c->t_vec[VGT_I][1];
    for (uint32_t i = 0; i < nw; i++) {
        wd[i] = vgt_load32(c, i ? vgt_add64(c, addr, vgt_k64(c, 4 * i)) : addr);
    }
    for (uint32_t k = 0; k < f->comps; k++) {
        uint32_t word = wd[k * f->bits / 32], off = (k * f->bits) % 32;
        float scale = f->kind == 2 ? (float)((1u << f->bits) - 1) : f->kind == 3 ? (float)((1u << (f->bits - 1)) - 1) : 1.0f;
        switch (f->kind) {
        case 0:   // float32: the word itself
            comp[k] = vgt_op1(c, 124, F, word);   // OpBitcast
            break;
        case 1:   // half: UnpackHalf2x16, the low or high one
            comp[k] = vgt_ex(c, F, vgt_ext1(c, c->t_vec[VGT_F][2], 62, word), off / 16);
            break;
        case 2: {   // unorm: unsigned bits * 1/(2^bits - 1)
            uint32_t u = f->bits == 32 ? word : vgt_bits(c, 203, U, word, off, f->bits);
            comp[k] = vgt_op2(c, 133, F, vgt_op1(c, 112, F, u), vgt_kf(c, 1.0f / scale));   // OpFMul, OpConvertUToF
            break;
        }
        case 3: {   // snorm: signed bits * 1/(2^(bits-1) - 1), at least -1
            uint32_t s = vgt_bits(c, 202, I, vgt_op1(c, 124, I, word), off, f->bits);
            comp[k] = vgt_ext2(c, F, 40, vgt_op2(c, 133, F, vgt_op1(c, 111, F, s), vgt_kf(c, 1.0f / scale)), vgt_kf(c, -1.0f));
            break;
        }
        case 4:   // uint
            comp[k] = f->bits == 32 ? word : vgt_bits(c, 203, U, word, off, f->bits);
            break;
        default: {   // sint
            uint32_t iw = vgt_op1(c, 124, I, word);
            comp[k] = f->bits == 32 ? iw : vgt_bits(c, 202, I, iw, off, f->bits);
            break;
        }
        }
    }
    if (f->bgra) {
        uint32_t s = comp[0];
        comp[0] = comp[2];
        comp[2] = s;
    }
    uint32_t have = (uint32_t)vgt_fmt_class(f), v[4];
    for (uint32_t j = 0; j < m; j++) {
        if (j < f->comps) {
            v[j] = have == kind ? comp[j] : vgt_op1(c, 124, c->t_vec[kind][1], comp[j]);
        } else {
            v[j] = kind == VGT_F ? vgt_kf(c, j == 3 ? 1.0f : 0.0f) : kind == VGT_I ? vgt_ki(c, j == 3) : vgt_ku(c, j == 3);
        }
    }
    if (m == 1) {
        return v[0];
    }
    uint32_t r = vgt_id(c);
    if (m == 2) {
        VGT(&c->fn, 80, c->t_vec[kind][2], r, v[0], v[1]);   // OpCompositeConstruct
    } else if (m == 3) {
        VGT(&c->fn, 80, c->t_vec[kind][3], r, v[0], v[1], v[2]);
    } else {
        VGT(&c->fn, 80, c->t_vec[kind][4], r, v[0], v[1], v[2], v[3]);
    }
    return r;
}
// cond ? the word at addr : other (the load only runs when cond holds: the address may be 0).
static uint32_t vgt_load_if(vgt_ctx *c, uint32_t cond, uint32_t addr, uint32_t other) {
    uint32_t lt = vgt_id(c), lm = vgt_id(c), from = c->cur;
    VGT(&c->fn, 247, lm, 0);            // OpSelectionMerge
    VGT(&c->fn, 250, cond, lt, lm);     // OpBranchConditional
    VGT(&c->fn, 248, lt);               // OpLabel
    c->cur = lt;
    uint32_t v = vgt_load32(c, addr);
    VGT(&c->fn, 249, lm);   // OpBranch
    VGT(&c->fn, 248, lm);
    uint32_t r = vgt_id(c);
    VGT(&c->fn, 245, c->t_vec[VGT_U][1], r, v, lt, other, from);   // OpPhi
    c->cur = lm;
    return r;
}

// ---- the generated stages ------------------------------------------------------------------------------------------

// The vertex stage: Location 0 = (VertexIndex, InstanceIndex), one "control point" per patch.
static uint32_t *vgt_make_vs(size_t *n) {
    vgt_ctx c;
    memset(&c, 0, sizeof c);
    vgt_types(&c, 0);
    VGT(&c.caps, 17, 1);      // OpCapability Shader
    VGT(&c.caps, 14, 0, 1);   // OpMemoryModel Logical GLSL450
    uint32_t I = c.t_vec[VGT_I][1], U2 = c.t_vec[VGT_U][2];
    uint32_t pin = vgt_ptr(&c, 1, I), pout = vgt_ptr(&c, 3, U2);
    uint32_t vi = vgt_id(&c), ii = vgt_id(&c), out = vgt_id(&c), main_ = vgt_id(&c);
    VGT(&c.glob, 59, pin, vi, 1);
    VGT(&c.glob, 59, pin, ii, 1);
    VGT(&c.glob, 59, pout, out, 3);
    VGT(&c.deco, 71, vi, 11, 42);   // VertexIndex
    VGT(&c.deco, 71, ii, 11, 43);   // InstanceIndex
    VGT(&c.deco, 71, out, 30, 0);
    {
        const uint32_t pre[2] = {0, main_}, post[3] = {vi, ii, out};
        vgt_str(&c.ep, 15, pre, 2, "main", post, 3);
    }
    VGT(&c.fn, 54, c.t_void, main_, 0, c.t_fn);
    VGT(&c.fn, 248, vgt_id(&c));
    uint32_t a = vgt_id(&c), b = vgt_id(&c);
    VGT(&c.fn, 61, I, a, vi);
    VGT(&c.fn, 61, I, b, ii);
    uint32_t v = vgt_id(&c);
    VGT(&c.fn, 80, U2, v, vgt_op1(&c, 124, c.t_vec[VGT_U][1], a), vgt_op1(&c, 124, c.t_vec[VGT_U][1], b));
    VGT(&c.fn, 62, out, v);
    VGT(&c.fn, 253);   // OpReturn
    VGT(&c.fn, 56);    // OpFunctionEnd
    return vgt_link(&c, n);
}

// The control stage: n invocations; each writes its control point's inputs, all write the patch's (the same values),
// [[patch_id]] and the tessellation levels.
static uint32_t *vgt_make_tcs(const vgt_tese *t, const vg_tess_desc *td, const vg_tess_input *vin, uint32_t pidloc,
                              uint32_t *vbmap, uint32_t *nvb, size_t *n, char *why, size_t wl) {
    vgt_ctx c;
    memset(&c, 0, sizeof c);
    vgt_types(&c, 1);
    uint32_t F = c.t_vec[VGT_F][1], U = c.t_vec[VGT_U][1], I = c.t_vec[VGT_I][1], U64 = c.t_u64, quad = td->patch_type == 2;
    *nvb = 0;
    struct {
        const vgt_in *in;
        const vgt_fmt *f;
        uint32_t off, slot, stride, step;
        int sys;
    } pl[40];
    int npl = 0;
    int inst_found = 0;
    for (int i = 0; i < t->nin; i++) {
        const vgt_in *e = &t->in[i];
        if (e->loc == pidloc && e->patch) {
            continue;
        }
        if (e->kind == VGT_OTHER) {
            snprintf(why, wl, "TESE input Location %u is not a 32-bit scalar/vector", e->loc);
            goto refuse;
        }
        if (!e->patch && e->arrlen != td->n) {
            snprintf(why, wl, "TESE control-point input Location %u has %u elements, the patch has %u", e->loc, e->arrlen, td->n);
            goto refuse;
        }
        int a = -1;
        for (uint32_t k = 0; vin && k < vin->nattr; k++) {
            if (vin->attr[k].location == e->loc) {
                a = (int)k;
            }
        }
        int is_inst = e->patch && ((td->inst_loc >= 0 && (uint32_t)td->inst_loc == e->loc) ||
                                   (td->inst_loc < 0 && a < 0 && !inst_found && e->comps == 1 && e->kind != VGT_F));
        if (is_inst) {
            if (e->comps != 1 || e->kind == VGT_F) {
                snprintf(why, wl, "instance_id Location %u is not an integer scalar", e->loc);
                goto refuse;
            }
            pl[npl].in = e;
            pl[npl++].sys = 1;
            inst_found = 1;
            continue;
        }
        if (a < 0) {
            snprintf(why, wl, "TESE reads Location %u and the vertex descriptor has no attribute %u", e->loc, e->loc);
            goto refuse;
        }
        const vgt_fmt *f = vgt_fmt_of(vin->attr[a].mtlfmt);
        if (!f) {
            snprintf(why, wl, "attribute %u: MTLVertexFormat %u is not carried for tessellation", e->loc, vin->attr[a].mtlfmt);
            goto refuse;
        }
        if ((vgt_fmt_class(f) == VGT_F) != (e->kind == VGT_F)) {
            snprintf(why, wl, "attribute %u: format %u and the shader's type disagree on float vs integer", e->loc,
                     vin->attr[a].mtlfmt);
            goto refuse;
        }
        uint32_t b = vin->attr[a].buffer;
        if (b >= VG_TESS_NATTR) {
            snprintf(why, wl, "attribute %u: buffer index %u is out of range", e->loc, b);
            goto refuse;
        }
        uint32_t step = vin->layout[b].step, rate = vin->layout[b].rate;
        if (step == 1) {
            snprintf(why, wl, "attribute %u: buffer %u steps PER VERTEX, which a post-tessellation function cannot fetch", e->loc, b);
            goto refuse;
        }
        if (step == 2 && rate != 1) {
            snprintf(why, wl, "attribute %u: per-instance step rate %u is not carried for tessellation", e->loc, rate);
            goto refuse;
        }
        if (step > 4) {
            snprintf(why, wl, "attribute %u: buffer %u has step function %u", e->loc, b, step);
            goto refuse;
        }
        if (step && vin->layout[b].stride == VG_TESS_STRIDE_DYNAMIC) {
            snprintf(why, wl, "attribute %u: buffer %u has a dynamic stride (MTLBufferLayoutStrideDynamic), which the "
                              "tessellation pull does not carry", e->loc, b);
            goto refuse;
        }
        if (vin->attr[a].offset & 3 || (step && vin->layout[b].stride & 3)) {
            snprintf(why, wl, "attribute %u: offset/stride not 4-byte aligned", e->loc);
            goto refuse;
        }
        uint32_t s = 0;
        while (s < *nvb && vbmap[s] != b) {
            s++;
        }
        if (s == *nvb) {
            if (*nvb == VG_TESS_NVB) {
                snprintf(why, wl, "more than %d vertex buffers feed one tessellation pipeline", VG_TESS_NVB);
                goto refuse;
            }
            vbmap[(*nvb)++] = b;
        }
        pl[npl].in = e;
        pl[npl].f = f;
        pl[npl].off = vin->attr[a].offset;
        pl[npl].slot = s;
        pl[npl].stride = step ? vin->layout[b].stride : 0;
        pl[npl].step = step;
        pl[npl++].sys = 0;
    }

    VGT(&c.caps, 17, 1);      // Shader
    VGT(&c.caps, 17, 3);      // Tessellation
    VGT(&c.caps, 17, 11);     // Int64
    VGT(&c.caps, 17, 5347);   // PhysicalStorageBufferAddresses
    {
        const uint32_t none[1] = {0};
        vgt_str(&c.caps, 10, none, 0, "SPV_KHR_physical_storage_buffer", none, 0);   // OpExtension
        c.glsl = vgt_id(&c);
        const uint32_t pre[1] = {c.glsl};
        vgt_str(&c.caps, 11, pre, 1, "GLSL.std.450", none, 0);   // OpExtInstImport
    }
    VGT(&c.caps, 14, 5348, 1);   // OpMemoryModel PhysicalStorageBuffer64 GLSL450
    // the push-constant block: { u64 fac, cpx, pix; u32 istride; f32 scale; u64 vb[8] } (vg_tess_push)
    uint32_t arr8 = vgt_id(&c);
    VGT(&c.glob, 28, arr8, U64, vgt_ku(&c, VG_TESS_NVB));
    VGT(&c.deco, 71, arr8, 6, 8);   // ArrayStride 8
    uint32_t pcs = vgt_id(&c);
    VGT(&c.glob, 30, pcs, U64, U64, U64, U, F, arr8);   // OpTypeStruct
    VGT(&c.deco, 71, pcs, 2);                           // Block
    {
        const uint32_t offs[6] = {0, 8, 16, 24, 28, 32};
        for (uint32_t m = 0; m < 6; m++) {
            VGT(&c.deco, 72, pcs, m, 35, offs[m]);   // OpMemberDecorate Offset
        }
    }
    uint32_t pc = vgt_id(&c);
    VGT(&c.glob, 59, vgt_ptr(&c, 9, pcs), pc, 9);   // PushConstant
    uint32_t inids_t = vgt_id(&c);
    VGT(&c.glob, 28, inids_t, c.t_vec[VGT_U][2], vgt_ku(&c, 32));
    uint32_t inids = vgt_id(&c);
    VGT(&c.glob, 59, vgt_ptr(&c, 1, inids_t), inids, 1);
    VGT(&c.deco, 71, inids, 30, 0);
    uint32_t invid = vgt_id(&c);
    VGT(&c.glob, 59, vgt_ptr(&c, 1, I), invid, 1);
    VGT(&c.deco, 71, invid, 11, 8);   // InvocationId
    uint32_t f4 = vgt_id(&c);
    VGT(&c.glob, 28, f4, F, vgt_ku(&c, 4));
    uint32_t f2 = vgt_id(&c);
    VGT(&c.glob, 28, f2, F, vgt_ku(&c, 2));
    uint32_t outer = vgt_id(&c);
    VGT(&c.glob, 59, vgt_ptr(&c, 3, f4), outer, 3);
    VGT(&c.deco, 71, outer, 11, 11);   // TessLevelOuter
    VGT(&c.deco, 71, outer, 15);
    uint32_t inner = vgt_id(&c);
    VGT(&c.glob, 59, vgt_ptr(&c, 3, f2), inner, 3);
    VGT(&c.deco, 71, inner, 11, 12);   // TessLevelInner
    VGT(&c.deco, 71, inner, 15);
    uint32_t iface[48];
    uint32_t nif = 0;
    iface[nif++] = inids;
    iface[nif++] = invid;
    iface[nif++] = outer;
    iface[nif++] = inner;
    uint32_t outv[40], pidout = 0;
    for (int i = 0; i < npl; i++) {
        const vgt_in *e = pl[i].in;
        uint32_t ty = c.t_vec[e->kind][e->comps];
        if (!e->patch) {
            uint32_t at = vgt_id(&c);
            VGT(&c.glob, 28, at, ty, vgt_ku(&c, td->n));
            ty = at;
        }
        outv[i] = vgt_id(&c);
        VGT(&c.glob, 59, vgt_ptr(&c, 3, ty), outv[i], 3);
        VGT(&c.deco, 71, outv[i], 30, e->loc);
        if (e->patch) {
            VGT(&c.deco, 71, outv[i], 15);
        }
        iface[nif++] = outv[i];
    }
    if (pidloc != ~0u && t->pid_kind == VGT_OTHER) {
        snprintf(why, wl, "the post-tessellation patch_id is not a 32-bit integer");
        goto refuse;
    }
    if (pidloc != ~0u) {
        pidout = vgt_id(&c);
        VGT(&c.glob, 59, vgt_ptr(&c, 3, c.t_vec[t->pid_kind][1]), pidout, 3);
        VGT(&c.deco, 71, pidout, 30, pidloc);
        VGT(&c.deco, 71, pidout, 15);
        iface[nif++] = pidout;
    }
    uint32_t main_ = vgt_id(&c);
    {
        const uint32_t pre[2] = {1, main_};   // TessellationControl
        vgt_str(&c.ep, 15, pre, 2, "main", iface, nif);
    }
    VGT(&c.ep, 16, main_, 26, td->n);   // OutputVertices n

    VGT(&c.fn, 54, c.t_void, main_, 0, c.t_fn);
    c.cur = vgt_id(&c);
    VGT(&c.fn, 248, c.cur);
    uint32_t pu64 = vgt_ptr(&c, 9, U64), pu32 = vgt_ptr(&c, 9, U), pf32 = vgt_ptr(&c, 9, F);
    uint32_t fac = vgt_chain_load(&c, pu64, U64, pc, vgt_ku(&c, 0), 0, 0);
    uint32_t cpx = vgt_chain_load(&c, pu64, U64, pc, vgt_ku(&c, 1), 0, 0);
    uint32_t pix = vgt_chain_load(&c, pu64, U64, pc, vgt_ku(&c, 2), 0, 0);
    uint32_t istr = vgt_chain_load(&c, pu32, U, pc, vgt_ku(&c, 3), 0, 0);
    uint32_t scl = vgt_chain_load(&c, pf32, F, pc, vgt_ku(&c, 4), 0, 0);
    uint32_t ids = vgt_chain_load(&c, vgt_ptr(&c, 1, c.t_vec[VGT_U][2]), c.t_vec[VGT_U][2], inids, vgt_ku(&c, 0), 0, 0);
    uint32_t pos = vgt_ex(&c, U, ids, 0), iid = vgt_ex(&c, U, ids, 1);
    uint32_t inv;
    {
        uint32_t v = vgt_id(&c);
        VGT(&c.fn, 61, I, v, invid);
        inv = vgt_op1(&c, 124, U, v);
    }
    uint32_t z64 = vgt_k64(&c, 0);
    // the patch: patchIndexBuffer[position] when there is one, else the position itself
    uint32_t pid = vgt_load_if(&c, vgt_op2(&c, 171, c.t_bool, pix, z64),   // OpINotEqual
                               vgt_add64(&c, pix, vgt_op2(&c, 132, U64, vgt_widen(&c, pos), vgt_k64(&c, 4))), pos);
    // this invocation's control point: patch * n + invocation, through the control-point index buffer when indexed
    uint32_t cpv = vgt_op2(&c, 128, U, vgt_op2(&c, 132, U, pid, vgt_ku(&c, td->n)), inv);
    if (td->cpidx) {
        uint32_t w4 = td->cpidx == 1 ? 2 : 4, byte = vgt_op2(&c, 132, U64, vgt_widen(&c, cpv), vgt_k64(&c, w4));
        uint32_t ea = vgt_add64(&c, cpx, byte), wa = vgt_op2(&c, 199, U64, ea, vgt_k64(&c, ~3ull));   // OpBitwiseAnd
        uint32_t word = vgt_load_if(&c, vgt_op2(&c, 171, c.t_bool, cpx, z64), wa, cpv);
        if (td->cpidx == 1) {
            uint32_t sh = vgt_op2(&c, 132, U, vgt_op2(&c, 199, U, vgt_op1(&c, 113, U, ea), vgt_ku(&c, 2)), vgt_ku(&c, 8));
            uint32_t hv = vgt_id(&c);
            VGT(&c.fn, 203, U, hv, word, sh, vgt_ku(&c, 16));
            cpv = vgt_sel(&c, U, vgt_op2(&c, 171, c.t_bool, cpx, z64), hv, cpv);
        } else {
            cpv = word;
        }
    }
    for (int i = 0; i < npl; i++) {
        const vgt_in *e = pl[i].in;
        uint32_t ty = c.t_vec[e->kind][e->comps], val;
        if (pl[i].sys) {
            val = e->kind == VGT_U ? iid : vgt_op1(&c, 124, I, iid);
        } else {
            uint32_t idx = pl[i].step == 4 ? cpv : pl[i].step == 3 ? pid : pl[i].step == 2 ? iid : vgt_ku(&c, 0);
            uint32_t vb = vgt_chain_load(&c, pu64, U64, pc, vgt_ku(&c, 5), vgt_ku(&c, pl[i].slot), 1);
            uint32_t addr = vgt_add64(&c, vgt_add64(&c, vb, vgt_op2(&c, 132, U64, vgt_widen(&c, idx), vgt_k64(&c, pl[i].stride))),
                                      vgt_k64(&c, pl[i].off));
            val = vgt_pull(&c, pl[i].f, addr, e->kind, e->comps);
        }
        if (e->patch) {
            VGT(&c.fn, 62, outv[i], val);
        } else {
            uint32_t p_ = vgt_id(&c);
            VGT(&c.fn, 65, vgt_ptr(&c, 3, ty), p_, outv[i], inv);
            VGT(&c.fn, 62, p_, val);
        }
    }
    if (pidout) {
        VGT(&c.fn, 62, pidout, t->pid_kind == VGT_U ? pid : vgt_op1(&c, 124, I, pid));
    }
    // the factors: half edge[4], inside[2] (quad, 12 bytes) or edge[3], inside (triangle, 8 bytes)
    uint32_t fsz = quad ? 12 : 8, fa = fac;
    if (td->stepfn & 2) {   // per instance
        fa = vgt_add64(&c, fa, vgt_op2(&c, 132, U64, vgt_widen(&c, iid), vgt_widen(&c, istr)));
    }
    if (td->stepfn & 1) {   // per patch
        fa = vgt_add64(&c, fa, vgt_op2(&c, 132, U64, vgt_widen(&c, pos), vgt_k64(&c, fsz)));
    }
    uint32_t h[3], e[6], ne = quad ? 4 : 3, ni = quad ? 2 : 1;
    for (uint32_t k = 0; k < (quad ? 3u : 2u); k++) {
        h[k] = vgt_ext1(&c, c.t_vec[VGT_F][2], 62, vgt_load32(&c, k ? vgt_add64(&c, fa, vgt_k64(&c, 4 * k)) : fa));
    }
    for (uint32_t k = 0; k < ne + ni; k++) {
        e[k] = vgt_ex(&c, F, h[k / 2], k % 2);
    }
    // a patch with an edge factor of 0 or less (or NaN) is culled
    uint32_t ok = 0;
    for (uint32_t k = 0; k < ne; k++) {
        uint32_t g = vgt_op2(&c, 186, c.t_bool, e[k], vgt_kf(&c, 0.0f));   // OpFOrdGreaterThan
        ok = k ? vgt_op2(&c, 167, c.t_bool, ok, g) : g;                    // OpLogicalAnd
    }
    uint32_t kmax = vgt_kf(&c, td->maxf), z = vgt_kf(&c, 0.0f);
    for (uint32_t k = 0; k < ne + ni; k++) {
        uint32_t x = e[k];
        if (td->scale_en) {
            x = vgt_op2(&c, 133, F, x, scl);
        }
        x = vgt_sel(&c, F, vgt_op2(&c, 186, c.t_bool, x, kmax), kmax, x);
        if (td->partition == 0) {   // pow2: 2^ceil(log2 x)
            x = vgt_ext1(&c, F, 29, vgt_ext1(&c, F, 9, vgt_ext1(&c, F, 30, x)));
        }
        if (k < ne) {
            x = vgt_sel(&c, F, ok, x, z);
        }
        uint32_t p_ = vgt_id(&c), dst = k < ne ? outer : inner, di = k < ne ? k : k - ne;
        VGT(&c.fn, 65, vgt_ptr(&c, 3, F), p_, dst, vgt_ki(&c, (int32_t)di));
        VGT(&c.fn, 62, p_, x);
    }
    for (uint32_t k = ne; k < 4; k++) {
        uint32_t p_ = vgt_id(&c);
        VGT(&c.fn, 65, vgt_ptr(&c, 3, F), p_, outer, vgt_ki(&c, (int32_t)k));
        VGT(&c.fn, 62, p_, z);
    }
    if (!quad) {
        uint32_t p_ = vgt_id(&c);
        VGT(&c.fn, 65, vgt_ptr(&c, 3, F), p_, inner, vgt_ki(&c, 1));
        VGT(&c.fn, 62, p_, z);
    }
    VGT(&c.fn, 253);
    VGT(&c.fn, 56);
    uint32_t *out = vgt_link(&c, n);
    if (!out) {
        snprintf(why, wl, "out of memory (or too many constants) building the tessellation control stage");
    }
    return out;
refuse:
    vgt_drop(&c);
    return NULL;
}

int vg_tess_build(const uint32_t *tese, size_t words, const vg_tess_desc *td, const vg_tess_input *vin, vg_tess_modules *out,
                  char *why, size_t wl) {
    memset(out, 0, sizeof *out);
    out->pidloc = -1;
    vgt_tese t0;
    if (vgt_scan_tese(tese, words, &t0) || t0.model != 2) {
        snprintf(why, wl, "the vertex module is not a TessellationEvaluation module");
        return -1;
    }
    // Metal's partition modes (pow2, integer, fractional odd, fractional even) -> SpacingEqual / FractionalOdd /
    // FractionalEven; pow2 is equal spacing of factors the control stage rounds up to a power of two.
    uint32_t spacing = td->partition == 2 ? 3 : td->partition == 3 ? 2 : 1;
    // Clockwise (0) -> VertexOrderCcw: the domain's origin and the negative-height viewport turn it around (NullMoth's
    // reading, with the same viewport and front-face mapping as ours).
    uint32_t order = td->winding == 0 ? 5 : 4;
    uint32_t pidloc = ~0u;
    const char *w1 = NULL;
    out->tese = vgt_patch_tese(tese, words, spacing, order, &out->teseWords, &pidloc, &w1);
    if (!out->tese) {
        snprintf(why, wl, "%s", w1 ? w1 : "?");
        return -1;
    }
    out->pidloc = pidloc == ~0u ? -1 : (int32_t)pidloc;
    out->tcs = vgt_make_tcs(&t0, td, vin, pidloc, out->vbmap, &out->nvb, &out->tcsWords, why, wl);
    if (!out->tcs) {
        vg_tess_free(out);
        return -1;
    }
    out->vs = vgt_make_vs(&out->vsWords);
    if (!out->vs) {
        snprintf(why, wl, "out of memory building the tessellation vertex stage");
        vg_tess_free(out);
        return -1;
    }
    return 0;
}

void vg_tess_free(vg_tess_modules *m) {
    free(m->tese);
    free(m->vs);
    free(m->tcs);
    m->tese = m->vs = m->tcs = NULL;
}
