// frontface-test (5d): checks vg_frontface_ir.h on the Mac, no VM needed.
//   clang -I metal/VirtioGPUMetal -o build/frontface-test tools/frontface-test.c && build/frontface-test
// RenderBox's path_interior_fragment, reduced (tools/mtlmrt.m case fd): a select on [[front_facing]] between halves
// must become a 32-bit select, and a function without a bool parameter must stay as it is.
#include "vg_frontface_ir.h"
static const char *kIn =
    "define <{ <2 x half> }> @fd(i1 noundef %0) local_unnamed_addr #0 {\n"
    "  %2 = select fast i1 %0, half 1.000000e+00, half -1.000000e+00\n"
    "  %3 = select i1 %0, <2 x half> %v, <2 x half> zeroinitializer\n"
    "  %4 = insertelement <2 x half> <half 2.500000e-01, half poison>, half %2, i64 1\n"
    "  ret <{ <2 x half> }> undef\n"
    "}\n"
    "define half @other(float %x) {\n"
    "  %c = fcmp olt float %x, 0.0\n"
    "  %r = select i1 %c, half 1.000000e+00, half -1.000000e+00\n"
    "  ret half %r\n"
    "}\n";
int main(void) {
    char *o = vg_frontface_ir(kIn);
    int bad = !o || strstr(o, "select fast i1 %0, half") || strstr(o, "select i1 %0, <2 x half>") ||
              !strstr(o, "select i1 %0, i32 %vgff.0.c, i32 %vgff.0.d") || !strstr(o, "%2 = bitcast i16 %vgff.0.f to half") ||
              !strstr(o, "%3 = bitcast i32 %vgff.1.e to <2 x half>") ||
              !strstr(o, "%r = select i1 %c, half 1.000000e+00, half -1.000000e+00");
    fputs(o ? o : "(unchanged)\n", bad ? stderr : stdout);
    puts(bad ? "FAIL" : "PASS");
    free(o);
    return bad;
}
