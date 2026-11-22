// VeneraBalloon's user client: what venera-agent calls (as root) to hand the kext macOS's memory figures, which the
// kext gives QEMU's virtio-balloon device as the guest's statistics (Proxmox's memory figure for the VM).
// IOServiceOpen on the VeneraBalloon service, then IOConnectCallScalarMethod with these selectors.
#pragma once
#include <stdint.h>

enum {
    kVBMethodSetStats = 0,   // scalar in: kVBStatCount values in kVBStat* order; nothing out
    kVBMethodState = 1,      // scalar out: stats buffers the host has taken, ms since the last figures (~0 for none),
                             // the host's balloon target in 4 KB pages (never acted on), the figures' age limit (ms)
};

// What the agent hands over each time, all of it in bytes except the two fault counts.
enum {
    kVBTotal = 0,     // physical memory (hw.memsize)
    kVBFree,          // what macOS can give back: the total less Activity Monitor's Memory Used (anonymous, wired and
                      // compressed pages)
    kVBAvail,         // the same (QEMU's stat-available-memory)
    kVBCaches,        // Activity Monitor's Cached Files (file-backed and purgeable pages)
    kVBSwapIn,        // bytes swapped in since boot
    kVBSwapOut,       // bytes swapped out since boot
    kVBMajorFaults,   // page-ins since boot
    kVBMinorFaults,   // the other page faults since boot
    kVBStatCount
};
