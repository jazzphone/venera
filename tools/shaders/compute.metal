// Stage 4b test kernels (tools/mtlcompute.m): built on the Mac into compute.metallib.
#include <metal_stdlib>
using namespace metal;

kernel void vadd(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]],
                 device float *c [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    c[i] = a[i] + b[i];
}

// Each threadgroup sums its slice in threadgroup memory and adds its total to out[0] atomically.
kernel void reduce_sum(device const uint *in [[buffer(0)]], device atomic_uint *out [[buffer(1)]],
                       constant uint &count [[buffer(2)]], threadgroup uint *scratch [[threadgroup(0)]],
                       uint gid [[thread_position_in_grid]], uint lid [[thread_position_in_threadgroup]],
                       uint tgsize [[threads_per_threadgroup]]) {
    scratch[lid] = gid < count ? in[gid] : 0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = tgsize / 2; s > 0; s >>= 1) {
        if (lid < s) {
            scratch[lid] += scratch[lid + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) {
        atomic_fetch_add_explicit(out, scratch[0], memory_order_relaxed);
    }
}
