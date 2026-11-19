// VeneraConsole's user client: what venera-agent (and anything else as root) calls to use a port of QEMU's
// virtio-serial device. IOServiceOpen on the VeneraConsole service, then IOConnectCall* with these selectors.
#pragma once
#include <stdint.h>

enum {
    kVCMethodPorts = 0,   // struct out: VCPortInfo[] (up to kVCMaxPorts) for the ports the host has added
    kVCMethodOpen = 1,    // struct in: the port's name (NUL-terminated); scalar out: its id. One opener a port.
    kVCMethodRead = 2,    // scalar in: timeout (ms); struct out: up to its size; scalar out: bytes read (0 on timeout)
    kVCMethodWrite = 3,   // scalar in: timeout (ms); struct in: the bytes; scalar out: bytes taken (fewer on timeout)
    kVCMethodState = 4,   // scalar out: 1 when the host has the port open, then reads and writes counted so far
};

enum { kVCMaxPorts = 8 };
enum { kVCPortHostOpen = 1, kVCPortGuestOpen = 2, kVCPortConsole = 4 };

typedef struct {
    uint32_t id;
    uint32_t flags;        // kVCPort*
    char name[56];
} VCPortInfo;
