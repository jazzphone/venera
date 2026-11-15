// llvmprobe: does the guest's own LLVM (GPUCompiler.framework, in the dyld shared cache) export the C API the Metal
// plugin's AIR reader needs? (STAGE4-5.md section 9, probe 4.) Build: tools/build-tools.sh. Run in the VM.
#include <dlfcn.h>
#include <stdio.h>
int main(void) {
    const char *libs[] = {
        "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib",
        "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libGPUCompiler.dylib",
        "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libGPUCompilerImplLazy.dylib",
    };
    const char *syms[] = {"LLVMParseBitcodeInContext2", "LLVMPrintModuleToString", "LLVMContextCreate",
                          "LLVMCreateMemoryBufferWithMemoryRange", "LLVMGetDefaultTargetTriple"};
    for (int i = 0; i < 3; i++) {
        void *h = dlopen(libs[i], RTLD_LAZY | RTLD_LOCAL);
        printf("%s: %s\n", libs[i], h ? "loaded" : dlerror());
        if (!h) continue;
        for (int j = 0; j < 5; j++) printf("  %-40s %s\n", syms[j], dlsym(h, syms[j]) ? "yes" : "no");
    }
    return 0;
}
