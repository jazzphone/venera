// mtlprobe: what Metal lists in this process (stage 4a). Every property is read inside @try, so a selector the plugin
// or its base class doesn't answer yet prints as "(throws)" instead of ending the run.
// Build: tools/build-tools.sh. Run in the VM after `acceltest arm` (VGMTL_LOG=1 echoes the plugin's log to stderr).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

#define TRY(label, expr)                                                                                            \
    do {                                                                                                            \
        @try {                                                                                                      \
            printf("  %-34s %s\n", label, [[NSString stringWithFormat:@"%@", (expr)] UTF8String]);                 \
        } @catch (NSException * e) {                                                                                \
            printf("  %-34s (throws: %s)\n", label, e.reason.UTF8String);                                           \
        }                                                                                                           \
    } while (0)

int main(void) {
    @autoreleasepool {
        NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
        printf("MTLCopyAllDevices: %lu device(s)\n", (unsigned long)all.count);
        for (id<MTLDevice> d in all) {
            printf("device %p class %s\n", (__bridge void *)d, class_getName([(NSObject *)d class]));
            TRY("name", d.name);
            TRY("registryID", @(d.registryID));
            TRY("location / number", ([NSString stringWithFormat:@"%lu / %lu", (unsigned long)d.location, (unsigned long)d.locationNumber]));
            TRY("headless / lowPower / removable", ([NSString stringWithFormat:@"%d / %d / %d", d.headless, d.lowPower, d.removable]));
            TRY("hasUnifiedMemory", @(d.hasUnifiedMemory));
            TRY("recommendedMaxWorkingSetSize", @(d.recommendedMaxWorkingSetSize));
            TRY("maxBufferLength", @(d.maxBufferLength));
            TRY("maxThreadsPerThreadgroup", ([NSString stringWithFormat:@"%lu x %lu x %lu", (unsigned long)d.maxThreadsPerThreadgroup.width, (unsigned long)d.maxThreadsPerThreadgroup.height, (unsigned long)d.maxThreadsPerThreadgroup.depth]));
            TRY("supportsFamily Mac2", @([d supportsFamily:MTLGPUFamilyMac2]));
            TRY("supportsFamily Common3", @([d supportsFamily:MTLGPUFamilyCommon3]));
            TRY("supportsFamily Metal3", @([d supportsFamily:MTLGPUFamilyMetal3]));
        }
        id<MTLDevice> def = MTLCreateSystemDefaultDevice();
        printf("MTLCreateSystemDefaultDevice: %s\n", def ? [[def name] UTF8String] : "nil");
        return all.count ? 0 : 1;
    }
}
