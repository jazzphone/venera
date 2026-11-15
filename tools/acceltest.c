// acceltest: stage 4.0 probe of VirtioGPUAccel's family user clients (IOAcceleratorFamily2 answers them, not us).
//   acceltest            find the accelerator, print its state
//   acceltest arm [NAME [CLASS]]   publish MetalPluginName (default VirtioGPUMetal) + class (default VGMTLDevice)
//   acceltest disarm               withdraw them
//   acceltest legacy on|off        stage 5b probe: legacy IOAccelSurfaces for an armed WindowServer
//   acceltest wsarm | withdraw     stage 5a: arm the display for WindowServer / withdraw it (needs vgpuaccel=3 or 4)
//   acceltest T...       for each user-client type T: IOServiceOpen, print the class the family made, close;
//                        on an IOAccelDevice2 also call get_config (sel 0) and get_name (sel 1) -- nothing else
//                        is called on any client
// Every step is appended to /var/tmp/acceltest.log and synced first, so a panic still says which type did it.
// Build: tools/build-tools.sh. Run in the VM as root.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int logfd = -1;

static void say(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    fputs(line, stdout);
    fflush(stdout);
    if (logfd >= 0) {
        write(logfd, line, strlen(line));
        fsync(logfd);
    }
}

// The user client the family just made for us: a child of the accelerator whose creator is this process.
static void client_class(io_service_t svc, char *out, size_t outlen) {
    snprintf(out, outlen, "?");
    io_iterator_t it = 0;
    if (IORegistryEntryGetChildIterator(svc, kIOServicePlane, &it) != KERN_SUCCESS) {
        return;
    }
    char want[32];
    snprintf(want, sizeof(want), "pid %d,", getpid());
    io_object_t child;
    while ((child = IOIteratorNext(it))) {
        CFTypeRef c = IORegistryEntryCreateCFProperty(child, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
        char creator[128] = "";
        if (c && CFGetTypeID(c) == CFStringGetTypeID()) {
            CFStringGetCString(c, creator, sizeof(creator), kCFStringEncodingUTF8);
        }
        if (c) {
            CFRelease(c);
        }
        if (!strncmp(creator, want, strlen(want))) {
            io_name_t cls;
            IOObjectGetClass(child, cls);
            snprintf(out, outlen, "%s", cls);
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(it);
}

static void hex(const char *what, const uint8_t *p, size_t n) {
    say("  %s:", what);
    for (size_t i = 0; i < n; i++) {
        say("%s%02x", (i % 16) ? " " : "\n    ", p[i]);
    }
    say("\n");
}

int main(int argc, char **argv) {
    logfd = open("/var/tmp/acceltest.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("VirtioGPUAccel"));
    if (!svc) {
        say("no registered VirtioGPUAccel (vgpuaccel=2 registers it)\n");
        return 1;
    }
    io_name_t cls;
    IOObjectGetClass(svc, cls);
    uint64_t id = 0;
    IORegistryEntryGetRegistryEntryID(svc, &id);
    say("service %s id 0x%llx, conforms to IOAccelerator: %d, IOGraphicsAccelerator2: %d\n", cls, id,
        IOObjectConformsTo(svc, "IOAccelerator"), IOObjectConformsTo(svc, "IOGraphicsAccelerator2"));
    CFTypeRef mp = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginName"), kCFAllocatorDefault, 0);
    say("MetalPluginName: %s\n", mp ? "PRESENT" : "absent (unarmed)");
    if (mp) {
        CFRelease(mp);
    }

    if (argc > 2 && !strcmp(argv[1], "legacy")) {
        // stage 5b probe: legacy IOAccelSurfaces for an armed WindowServer, on or off
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(d, CFSTR("VirtioGPULegacySurfaces"), !strcmp(argv[2], "on") ? kCFBooleanTrue : kCFBooleanFalse);
        kern_return_t kr = IORegistryEntrySetCFProperties(svc, d);
        CFRelease(d);
        say("legacy %s -> 0x%x\n", argv[2], kr);
        return kr == KERN_SUCCESS ? 0 : 1;
    }
    if (argc > 1 && (!strcmp(argv[1], "wsarm") || !strcmp(argv[1], "withdraw"))) {
        // stage 5a: arm the display for WindowServer / withdraw it (AGDC, pipe capabilities, MetalPluginName)
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(d, !strcmp(argv[1], "wsarm") ? CFSTR("VirtioGPUArmWindowServer") : CFSTR("VirtioGPUWithdraw"),
                             kCFBooleanTrue);
        kern_return_t kr = IORegistryEntrySetCFProperties(svc, d);
        CFRelease(d);
        say("%s -> 0x%x (the arm work loop does it)\n", argv[1], kr);
        return kr == KERN_SUCCESS ? 0 : 1;
    }
    if (argc > 1 && (!strcmp(argv[1], "arm") || !strcmp(argv[1], "disarm"))) {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
        if (!strcmp(argv[1], "arm")) {
            CFMutableDictionaryRef a = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                 &kCFTypeDictionaryValueCallBacks);
            CFStringRef n = CFStringCreateWithCString(NULL, argc > 2 ? argv[2] : "VirtioGPUMetal", kCFStringEncodingUTF8);
            CFStringRef c = CFStringCreateWithCString(NULL, argc > 3 ? argv[3] : "VGMTLDevice", kCFStringEncodingUTF8);
            CFDictionarySetValue(a, CFSTR("MetalPluginName"), n);
            CFDictionarySetValue(a, CFSTR("MetalPluginClassName"), c);
            CFDictionarySetValue(d, CFSTR("VirtioGPUArm"), a);
            CFRelease(n);
            CFRelease(c);
            CFRelease(a);
        } else {
            CFDictionarySetValue(d, CFSTR("VirtioGPUDisarm"), kCFBooleanTrue);
        }
        kern_return_t kr = IORegistryEntrySetCFProperties(svc, d);
        CFRelease(d);
        mp = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginName"), kCFAllocatorDefault, 0);
        char name[256] = "absent";
        if (mp && CFGetTypeID(mp) == CFStringGetTypeID()) {
            CFStringGetCString(mp, name, sizeof(name), kCFStringEncodingUTF8);
        }
        if (mp) {
            CFRelease(mp);
        }
        say("%s -> 0x%x; MetalPluginName now: %s\n", argv[1], kr, name);
        return kr == KERN_SUCCESS ? 0 : 1;
    }
    for (int i = 1; i < argc; i++) {
        uint32_t type = (uint32_t)strtoul(argv[i], NULL, 0);
        say("type %u: opening\n", type);
        io_connect_t conn = 0;
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
        if (kr != KERN_SUCCESS) {
            say("type %u: IOServiceOpen 0x%x\n", type, kr);
            continue;
        }
        char ucls[128];
        client_class(svc, ucls, sizeof(ucls));
        say("type %u: opened, user client class %s\n", type, ucls);
        if (!strcmp(ucls, "IOAccelDevice2")) {
            uint8_t cfg[64] = {0}, name[64] = {0};
            size_t n = sizeof(cfg);
            kr = IOConnectCallStructMethod(conn, 0, NULL, 0, cfg, &n);
            say("  get_config -> 0x%x, %zu bytes\n", kr, n);
            if (kr == KERN_SUCCESS) {
                hex("config", cfg, n);
            }
            n = sizeof(name);
            kr = IOConnectCallStructMethod(conn, 1, NULL, 0, name, &n);
            name[sizeof(name) - 1] = 0;
            say("  get_name -> 0x%x, \"%s\"\n", kr, (char *)name);
        }
        kr = IOServiceClose(conn);
        say("type %u: closed 0x%x\n", type, kr);
    }
    IOObjectRelease(svc);
    return 0;
}
