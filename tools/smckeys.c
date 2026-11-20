// smckeys: the SMC's key count (#KEY) and every key by index, as macOS's power logger (PerfPowerServices) reads them at
// its start, with the time it took. QEMU's applesmc can't answer either (it spun PerfPowerServices for good);
// VirtualSMC (Venera's OpenCore, 0.1.9) answers both.
//   ./smckeys          the count, the time, the first keys
// Built by tools/build-tools.sh (x86_64).
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef struct {   // AppleSMC's user-client parameter block (80 bytes), as libSMC and the open-source SMC tools use it
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } vers;
    struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } plimit;
    struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

static kern_return_t call(io_connect_t c, SMCParam *in, SMCParam *out) {
    size_t n = sizeof(*out);
    memset(out, 0, sizeof(*out));
    return IOConnectCallStructMethod(c, kSMCHandleYPCEvent, in, sizeof(*in), out, &n);
}
static uint32_t fourcc(const char *s) { return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3]; }

int main(void) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    io_connect_t c = 0;
    if (!s || IOServiceOpen(s, mach_task_self(), 0, &c) != KERN_SUCCESS) {
        printf("smckeys: no AppleSMC connection\n");
        return 1;
    }
    SMCParam in = {0}, out;
    in.key = fourcc("#KEY");
    in.data8 = kSMCGetKeyInfo;
    kern_return_t r = call(c, &in, &out);
    uint32_t count = 0;
    if (r == KERN_SUCCESS && !out.result) {
        in.keyInfo.dataSize = out.keyInfo.dataSize;
        in.data8 = kSMCReadKey;
        r = call(c, &in, &out);
        if (r == KERN_SUCCESS && !out.result) {
            count = (uint32_t)out.bytes[0] << 24 | (uint32_t)out.bytes[1] << 16 | (uint32_t)out.bytes[2] << 8 | out.bytes[3];
        }
    }
    printf("#KEY: %u keys (kr 0x%x, result %u)\n", count, r, out.result);
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    uint32_t ok = 0, bad = 0, limit = count && count < 100000 ? count : 64;
    char first[8 * 5 + 1] = "";
    for (uint32_t i = 0; i < limit; i++) {
        memset(&in, 0, sizeof(in));
        in.data8 = kSMCGetKeyFromIndex;
        in.data32 = i;
        if (call(c, &in, &out) == KERN_SUCCESS && !out.result) {
            if (ok < 8) {
                char k[6] = {(char)(out.key >> 24), (char)(out.key >> 16), (char)(out.key >> 8), (char)out.key, ' ', 0};
                strcat(first, k);
            }
            ok++;
        } else {
            bad++;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    printf("by index: %u of %u answered, %u refused, %.1f ms (%.3f ms each); first: %s\n", ok, limit, bad, ms,
           limit ? ms / limit : 0, first);
    IOServiceClose(c);
    return 0;
}
