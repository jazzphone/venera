// frontface-test (5d, widened in round 11): checks vg_frontface_ir.h on the Mac, no VM needed.
//   clang -I metal/VirtioGPUMetal -o build/frontface-test tools/frontface-test.c && build/frontface-test
// RenderBox's path_interior_fragment, reduced (tools/mtlmrt.m case fd): a select on [[front_facing]] between 16-bit
// values must become a 32-bit select -- also on its inverse, for every vector width and for i16 -- and a function
// without a bool parameter must stay as it is.
#include "vg_frontface_ir.h"
static const char *kIn =
    "define <{ <2 x half> }> @fd(i1 noundef %0) local_unnamed_addr #0 {\n"
    "  %2 = select fast i1 %0, half 1.000000e+00, half -1.000000e+00\n"
    "  %3 = select i1 %0, <2 x half> %v, <2 x half> zeroinitializer\n"
    "  %4 = insertelement <2 x half> <half 2.500000e-01, half poison>, half %2, i64 1\n"
    "  %n = xor i1 %0, true\n"
    "  %5 = select i1 %n, <4 x half> <half 1.000000e+00, half 1.000000e+00, half 1.000000e+00, half 1.000000e+00>, <4 x half> %w, !dbg !7\n"
    "  %6 = select i1 %0, <3 x half> %a3, <3 x half> %b3\n"
    "  %7 = select i1 %n, i16 1, i16 -1\n"
    "  %8 = select i1 %0, float 1.000000e+00, float -1.000000e+00\n"
    "  br i1 %0, label %b1, label %b2\n"
    "  %9 = phi half [ 1.000000e+00, %b1 ], [ -1.000000e+00, %b2 ]\n"
    "  ret <{ <2 x half> }> undef\n"
    "}\n"
    "define half @nobranch(i1 %f) {\n"
    "  %p = phi half [ 1.000000e+00, %b1 ], [ -1.000000e+00, %b2 ]\n"
    "  ret half %p\n"
    "}\n"
    "define half @other(float %x) {\n"
    "  %c = fcmp olt float %x, 0.0\n"
    "  %r = select i1 %c, half 1.000000e+00, half -1.000000e+00\n"
    "  ret half %r\n"
    "}\n"
    "!9 = !{i32 0, !\"air.front_facing\"}\n";
int main(void) {
    char *o = vg_frontface_ir(kIn);
    const char *must[] = {
        "select i1 %0, i32 %vgff.0.c, i32 %vgff.0.d", "%2 = bitcast i16 %vgff.0.f to half",
        "%vgff.1.a = bitcast <2 x half> %v to <2 x i16>", "%3 = bitcast <2 x i16> %vgff.1.f to <2 x half>",
        "%vgff.2.e = select i1 %n, <4 x i32> %vgff.2.c, <4 x i32> %vgff.2.d", "%5 = bitcast <4 x i16> %vgff.2.f to <4 x half>",
        "%vgff.2.a = bitcast <4 x half> <half 1.000000e+00, half 1.000000e+00, half 1.000000e+00, half 1.000000e+00> to <4 x i16>",
        "%vgff.2.b = bitcast <4 x half> %w to <4 x i16>", "%6 = bitcast <3 x i16> %vgff.3.f to <3 x half>",
        "%vgff.4.c = zext i16 1 to i32", "%7 = trunc i32 %vgff.4.e to i16",
        "%8 = select i1 %0, float 1.000000e+00, float -1.000000e+00",   // 32-bit: left alone
        "%r = select i1 %c, half 1.000000e+00, half -1.000000e+00",       // no bool parameter: left alone
        NULL};
    int bad = !o || strstr(o, "select fast i1 %0, half") || strstr(o, "select i1 %0, <2 x half>") ||
              strstr(o, "select i1 %n, <4 x half>") || vg_frontface_unhandled != 1 || strcmp(vg_frontface_where, "@fd");
    for (int i = 0; o && must[i]; i++) {
        if (!strstr(o, must[i])) {
            fprintf(stderr, "missing: %s\n", must[i]);
            bad = 1;
        }
    }
    fputs(o ? o : "(unchanged)\n", bad ? stderr : stdout);
    printf("phis counted: %d\n", vg_frontface_unhandled);
    puts(bad ? "FAIL" : "PASS");
    free(o);
    return bad;
}
