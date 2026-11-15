// Stage 4c test shaders (tools/mtlrender.m): built on the Mac into render.metallib.
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

// Vertices from a buffer indexed by vertex_id: float2 position, float2 uv, float4 color.
struct Vtx {
    float2 pos;
    float2 uv;
    float4 color;
};

vertex VOut tri_vertex(const device Vtx *v [[buffer(0)]], constant float2 &offset [[buffer(1)]],
                       uint vid [[vertex_id]]) {
    VOut o;
    o.position = float4(v[vid].pos + offset, 0.0, 1.0);
    o.color = v[vid].color;
    o.uv = v[vid].uv;
    return o;
}

fragment float4 color_fragment(VOut in [[stage_in]]) {
    return in.color;
}

fragment float4 texture_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv) * in.color;
}

// Vertex attributes through a vertex descriptor ([[stage_in]] on a vertex function).
struct VIn {
    float2 pos [[attribute(0)]];
    float4 color [[attribute(1)]];
};

vertex VOut attr_vertex(VIn in [[stage_in]]) {
    VOut o;
    o.position = float4(in.pos, 0.0, 1.0);
    o.color = in.color;
    o.uv = float2(0.0);
    return o;
}

// Compute writing a texture: out(x, y) = (x, y, x^y, 255) as 8-bit.
kernel void pattern(texture2d<float, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < out.get_width() && gid.y < out.get_height()) {
        out.write(float4(float(gid.x & 255), float(gid.y & 255), float((gid.x ^ gid.y) & 255), 255.0) / 255.0, gid);
    }
}

// Framebuffer fetch ([[color(0)]]): Core Animation's shaders read the destination this way (stage 5b).
fragment float4 fetch_swap_fragment(VOut in [[stage_in]], float4 dst [[color(0)]]) {
    return float4(dst.b, dst.g, dst.r, 1.0);
}
fragment float4 fetch_half_fragment(VOut in [[stage_in]], float4 dst [[color(0)]]) {
    return dst * 0.5;
}
