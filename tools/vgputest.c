// vgputest: exercises VirtioGPU.kext's user client the way Venus will (no Mesa needed).
// Build: tools/build-tools.sh. Run in the VM as root or the console user.
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "../kext/VirtioGPUUserAPI.h"

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

#define CHECK(what, kr)                                                                            \
    do {                                                                                           \
        kern_return_t r_ = (kr);                                                                   \
        printf("%-34s %s (0x%x)\n", what, r_ == KERN_SUCCESS ? "ok" : "FAILED", r_);              \
        if (r_ != KERN_SUCCESS) goto out;                                                          \
    } while (0)

int main(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kVGUCServiceClass));
    if (!service) {
        printf("no %s service\n", kVGUCServiceClass);
        return 1;
    }
    io_connect_t conn = 0;
    int status = 1;
    uint32_t res = 0;
    mach_vm_address_t addr = 0;
    mach_vm_size_t mapped = 0;
    CHECK("IOServiceOpen", IOServiceOpen(service, mach_task_self(), 0, &conn));

    struct vgpu_info info;
    size_t infoSize = sizeof(info);
    CHECK("getInfo", IOConnectCallStructMethod(conn, kVGUCGetInfo, NULL, 0, &info, &infoSize));
    printf("  features 0x%llx, hostmem %llu MB, pci %04x:%04x, %u capsets:", (unsigned long long)info.features,
           (unsigned long long)(info.hostmem_size >> 20), info.pci_vendor, info.pci_device, info.num_capsets);
    for (uint32_t i = 0; i < info.num_capsets; i++) {
        printf(" %u(v%u,%uB)", info.capset_id[i], info.capset_max_version[i], info.capset_max_size[i]);
    }
    printf("\n");

    uint32_t capset[40] = {0};
    size_t capsetSize = 160;
    uint64_t capIn[2] = {VGPU_CAPSET_VENUS, 0};
    CHECK("getCapset venus", IOConnectCallMethod(conn, kVGUCGetCapset, capIn, 2, NULL, 0, NULL, NULL, capset, &capsetSize));
    printf("  wire format %u, vk.xml %u.%u.%u, serialization %u, venus protocol %u\n", capset[0],
           (capset[1] >> 22) & 0x7f, (capset[1] >> 12) & 0x3ff, capset[1] & 0xfff, capset[2], capset[3]);

    uint64_t ctxIn[1] = {VGPU_CAPSET_VENUS}, ctx = 0;
    uint32_t one = 1;
    CHECK("contextInit venus", IOConnectCallScalarMethod(conn, kVGUCContextInit, ctxIn, 1, &ctx, &one));
    printf("  context %llu\n", (unsigned long long)ctx);

    uint64_t blobIn[4] = {VGPU_BLOB_MEM_HOST3D, VGPU_BLOB_FLAG_MAPPABLE, 1 << 20, 0}, resOut = 0;
    CHECK("createBlob host3d 1 MB id 0", IOConnectCallScalarMethod(conn, kVGUCCreateBlob, blobIn, 4, &resOut, &one));
    res = (uint32_t)resOut;
    printf("  resource %u\n", res);

    uint64_t mapIn[1] = {res}, mapOut[2] = {0};
    uint32_t two = 2;
    CHECK("mapBlob", IOConnectCallScalarMethod(conn, kVGUCMapBlob, mapIn, 1, mapOut, &two));
    printf("  size %llu, cache %llu (1 cached, 2 uncached, 3 wc)\n", (unsigned long long)mapOut[0],
           (unsigned long long)mapOut[1]);
    CHECK("IOConnectMapMemory64", IOConnectMapMemory64(conn, res, mach_task_self(), &addr, &mapped, kIOMapAnywhere));
    volatile uint32_t *p = (volatile uint32_t *)addr;
    uint64_t t0 = now_ns();
    for (uint32_t i = 0; i < mapped / 4; i++) p[i] = i * 2654435761u;
    uint32_t bad = 0;
    for (uint32_t i = 0; i < mapped / 4; i++) bad += p[i] != i * 2654435761u;
    printf("  wrote + read %llu KB at 0x%llx in %llu us, %u mismatches\n", (unsigned long long)(mapped >> 10),
           (unsigned long long)addr, (unsigned long long)((now_ns() - t0) / 1000), bad);

    uint64_t subIn[2] = {0, 1}, fence = 0;
    t0 = now_ns();
    CHECK("submit ring 0 (empty) + fence", IOConnectCallMethod(conn, kVGUCSubmit, subIn, 2, NULL, 0, &fence, &one, NULL, NULL));
    uint64_t waitIn[3] = {0, fence, 1000000000ull}, signaled = 0;
    CHECK("waitFence", IOConnectCallScalarMethod(conn, kVGUCWaitFence, waitIn, 3, &signaled, &one));
    printf("  fence %llu %s in %llu us\n", (unsigned long long)fence, signaled ? "signaled" : "NOT signaled",
           (unsigned long long)((now_ns() - t0) / 1000));

    status = bad || !signaled;
out:
    if (addr) IOConnectUnmapMemory64(conn, res, mach_task_self(), addr);
    if (res) {
        uint64_t in[1] = {res};
        printf("%-34s %s\n", "destroyResource", IOConnectCallScalarMethod(conn, kVGUCDestroyResource, in, 1, NULL, NULL) ? "FAILED" : "ok");
    }
    if (conn) IOServiceClose(conn);
    IOObjectRelease(service);
    printf("%s\n", status ? "FAIL" : "PASS");
    return status;
}
