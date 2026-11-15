// mtlcaps: what our Metal device answers to the capability questions Core Animation asks (CA::OGL::new_metal_context)
// and to supportsFamily:. Run as the console user with VGMTL_ENABLE=1 after `deploy.sh mtl arm`.
#import <Metal/Metal.h>
#import <objc/message.h>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) {
            printf("no Metal device\n");
            return 1;
        }
        printf("device: %s\n", d.name.UTF8String);
        const char *bools[] = {"supportsTileShaders", "supportsMemorylessRenderTargets", "isFramebufferReadSupported",
                               "supportsRasterOrderGroups", "areRasterOrderGroupsSupported", "supportsSIMDGroup",
                               "supportsSIMDShuffleAndFill", "supportsSIMDReduction", "supportsNativeHardwareFP16",
                               "supportsYCBCRFormats12", "supportsYCBCRPackedFormats12", "supportsLossyCompression",
                               "supportsExtendedXR10Formats", "supportsBufferlessClientStorageTexture",
                               "areProgrammableSamplePositionsSupported", "supportsShaderBarycentricCoordinates",
                               "isLowPower", "isHeadless", "isRemovable", "hasUnifiedMemory"};
        for (size_t i = 0; i < sizeof(bools) / sizeof(*bools); i++) {
            SEL s = sel_registerName(bools[i]);
            if ([(id)d respondsToSelector:s]) {
                printf("  %-40s %d\n", bools[i], ((BOOL(*)(id, SEL))objc_msgSend)(d, s));
            } else {
                printf("  %-40s (no answer)\n", bools[i]);
            }
        }
        printf("  %-40s %llu\n", "currentAllocatedSize", (unsigned long long)d.currentAllocatedSize);
        printf("  %-40s %llu\n", "recommendedMaxWorkingSetSize", (unsigned long long)d.recommendedMaxWorkingSetSize);
        printf("  %-40s %llu\n", "maxBufferLength", (unsigned long long)d.maxBufferLength);
        const char *nums[] = {"maxFragmentTextures", "maxFragmentSamplers", "maxTextureWidth2D", "maxTextureHeight2D",
                              "maxColorAttachments", "deviceLinearReadOnlyTextureAlignmentBytes"};
        for (size_t i = 0; i < sizeof(nums) / sizeof(*nums); i++) {
            SEL s = sel_registerName(nums[i]);
            if ([(id)d respondsToSelector:s]) {
                printf("  %-40s %lu\n", nums[i], ((NSUInteger(*)(id, SEL))objc_msgSend)(d, s));
            } else {
                printf("  %-40s (no answer)\n", nums[i]);
            }
        }
        struct { MTLGPUFamily f; const char *n; } fam[] = {
            {MTLGPUFamilyApple1, "Apple1"}, {MTLGPUFamilyApple4, "Apple4"}, {MTLGPUFamilyApple7, "Apple7"},
            {MTLGPUFamilyApple9, "Apple9"}, {MTLGPUFamilyMac2, "Mac2"}, {MTLGPUFamilyCommon3, "Common3"},
            {MTLGPUFamilyMetal3, "Metal3"}};
        for (size_t i = 0; i < sizeof(fam) / sizeof(*fam); i++) {
            printf("  supportsFamily %-24s %d\n", fam[i].n, [d supportsFamily:fam[i].f]);
        }
    }
    return 0;
}
