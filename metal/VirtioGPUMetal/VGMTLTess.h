// Metal tessellation on Vulkan (VGMTLTess.c): the stages around a post-tessellation vertex function. Plain C.
#pragma once
#include <stddef.h>
#include <stdint.h>

enum {
    VG_TESS_NVB = 8,          // vertex buffers one tessellation pipeline can pull from
    VG_TESS_PC_BYTES = 96,    // the control stage's push-constant block (vg_tess_push)
    VG_TESS_NATTR = 31,       // vertex attributes and buffer layouts a vertex descriptor has
};
#define VG_TESS_STRIDE_DYNAMIC 0xFFFFFFFFu   // MTLBufferLayoutStrideDynamic, as 32 bits

// The pipeline's vertex descriptor: attribute n reads buffer `buffer` at `offset` in MTLVertexFormat `mtlfmt`, and
// shows up in the post-tessellation function at Location n. A layout's step is its MTLVertexStepFunction.
typedef struct {
    uint32_t nattr;
    struct {
        uint32_t location, buffer, mtlfmt, offset;
    } attr[VG_TESS_NATTR];
    struct {
        uint32_t stride, step, rate;
    } layout[VG_TESS_NATTR];
} vg_tess_input;

// The descriptor's tessellation state, in Metal's own enum values.
typedef struct {
    uint32_t patch_type;   // MTLPatchType: 1 triangle, 2 quad
    uint32_t n;            // control points per patch (1..32)
    uint32_t partition;    // MTLTessellationPartitionMode
    uint32_t winding;      // MTLWinding of the triangles the tessellator makes
    uint32_t stepfn;       // MTLTessellationFactorStepFunction
    uint32_t scale_en;     // tessellationFactorScaleEnabled
    uint32_t cpidx;        // MTLTessellationControlPointIndexType: 0 none, 1 uint16, 2 uint32
    float maxf;            // maxTessellationFactor
    int32_t inst_loc;      // the reflected [[instance_id]] Location, -1 when the reflection has none
} vg_tess_desc;

// What a patch draw pushes for the control stage: device addresses of the factor buffer, the control-point index
// buffer and the patch index buffer (0 for none), the factor buffer's per-instance stride, the factor scale, and the
// pipeline's vertex buffers in the order vg_tess_modules.vbmap names them (each already at its bound offset).
typedef struct {
    uint64_t fac, cpx, pix;
    uint32_t istride;
    float scale;
    uint64_t vb[VG_TESS_NVB];
} vg_tess_push;
_Static_assert(sizeof(vg_tess_push) == VG_TESS_PC_BYTES, "the control stage's push-constant block is 96 bytes, offsets 0/8/16/24/28/32");

typedef struct {
    uint32_t *tese, *vs, *tcs;   // malloc'd SPIR-V; vg_tess_free frees them
    size_t teseWords, vsWords, tcsWords;
    uint32_t vbmap[VG_TESS_NVB];   // push-constant slot k -> Metal vertex buffer index
    uint32_t nvb;
    int32_t pidloc;   // the Location [[patch_id]] became, -1 when the function doesn't read it
} vg_tess_modules;

// A TessellationEvaluation module (a translated post-tessellation vertex function): 1 with its patch type
// (MTLPatchType) and the control-point count its inputs are arrays of (0 when none is), else 0.
int vg_spirv_tess_info(const void *spv, size_t bytes, uint32_t *patchType, uint32_t *cps);
// Builds the three stages for one pipeline: the evaluation module with the descriptor's spacing and vertex order (and
// [[patch_id]] made an input), the vertex stage and the control stage. -1 with a reason in why when it can't.
int vg_tess_build(const uint32_t *tese, size_t words, const vg_tess_desc *td, const vg_tess_input *vin, vg_tess_modules *out,
                  char *why, size_t wl);
void vg_tess_free(vg_tess_modules *m);
