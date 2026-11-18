// vv_shm.h (Venera video): the memory VM 108 and the host's venera-videod share through QEMU's ivshmem-doorbell
// device, and the records they pass in it. Plain C, included by the guest kext (kext/VeneraVideo) and the host
// program (hostvideo/src/venera-videod.c).
//
// Layout (VV_SHM_SIZE bytes):
//   0          struct vv_ctl: magic, versions, and the two rings' head/tail counters
//   VV_G2H_OFF the guest-to-host ring: Apple's paravirtualized-VideoToolbox messages (with the IOSurfaces they name),
//              slots the guest has finished copying, a hello at driver start, guest UUIDs going away
//   VV_H2G_OFF the host-to-guest ring: messages for the guest's processes, "fill" orders (copy slot N into
//              IOSurface S: a decoded frame) and "pull" orders (copy IOSurface S into slot N: a frame to encode)
//   VV_SLOT_OFF VV_NSLOTS frame slots of VV_SLOT_SIZE: decoded frames and frames to encode, NV12 (or P010) rows
//              packed at a stride the order gives. A frame bigger than a slot (4K 10-bit) fills the next slots too,
//              when the guest says it can (VV_GF_SPAN): an order names the first, its size says how many
// Rings hold records: a 32-byte struct vv_rec, then len bytes, the whole padded to 32. head and tail are free-running
// byte counters (offset = counter % ring size); the producer writes a record, then a barrier, then moves head; the
// consumer reads at tail, then moves it. A record never wraps: when the space left before the end is too small, the
// producer writes a VV_PAD record covering it. After producing, the guest rings the host's doorbell (ivshmem
// Doorbell register, peer 0 vector 0) and the host signals the VM's interrupt (peer 1 vector 0); each side drains
// until empty.
#ifndef VV_SHM_H
#define VV_SHM_H
#include <stdint.h>

#define VV_MAGIC 0x56564431u   // 'VVD1'
#define VV_VERSION 1
#define VV_SHM_SIZE (256u << 20)
#define VV_G2H_OFF (64u << 10)
#define VV_G2H_SIZE (32u << 20)
#define VV_H2G_OFF (VV_G2H_OFF + VV_G2H_SIZE)
#define VV_H2G_SIZE (4u << 20)
#define VV_SLOT_OFF (40u << 20)
#define VV_SLOT_SIZE (16u << 20)   // a 4096x2160 frame at 8 bits, 4:2:0 (13.3 MB); one at 10 bits (P010, 26.5 MB)
                                   // takes two slots (VV_GF_SPAN)
#define VV_NSLOTS 13               // 40 MB + 13 x 16 MB = 248 MB
#define VV_HOST_PEER 0
#define VV_VM_PEER 1

struct vv_ring {
    volatile uint32_t head;   // producer's
    uint32_t pad0[15];
    volatile uint32_t tail;   // consumer's
    uint32_t pad1[15];
};

struct vv_ctl {
    uint32_t magic;            // VV_MAGIC once the host set the memory up
    uint32_t version;          // VV_VERSION
    volatile uint32_t host_gen;    // the host's run; the guest drops state when it changes
    volatile uint32_t guest_gen;   // the guest driver's run; the host drops sessions when it changes
    uint32_t guest_features;       // VV_GF_*: written by the guest driver as it starts and set again from its hello by
                                   // the host (0.1.1's driver writes nothing here and says 0), so it outlives restarts
    uint32_t pad[11];
    struct vv_ring g2h, h2g;
};

struct vv_rec {
    uint32_t len;     // payload bytes after this header
    uint16_t kind;    // VV_*
    uint16_t flags;
    uint32_t arg[6];
};

enum {
    VV_PAD = 0,   // filler to the ring's end
    // guest -> host
    VV_G_HELLO = 1,      // the guest driver started (arg0: guest_gen, arg1: VV_GF_*; 0.1.1's driver sends 0)
    VV_G_MSG = 2,        // payload: arg0 vv_surf, then the message (arg1 bytes)
    VV_G_SLOTDONE = 3,   // arg0: the slot, arg1: 0 or an error (the surface was gone)
    VV_G_UUIDGONE = 4,   // payload: a 16-byte UUID whose process went away
    VV_G_PULLDONE = 5,   // arg0: the slot, arg1: 0 or an error, arg2: the IOSurface (a pull order done)
    // host -> guest
    VV_H_MSG = 16,    // payload: a message, for the process that registered its UUID (bytes 16-31)
    VV_H_FILL = 17,   // copy slot arg1 into IOSurface arg0: arg2 width, arg3 height, arg4 the slot's luma stride
                      // (chroma follows at stride x height), arg5 bytes per sample (1: NV12, 2: P010)
    VV_H_PULL = 18,   // copy IOSurface arg0 into slot arg1, packed as a fill order's (the same args): a frame to encode
};

// What the guest driver can do, in its hello. VV_GF_ENCODE: pull orders, and it holds a send whose answer VideoToolbox
// can't wait for itself (kext/VeneraVideo, waitsForReply); without it the host offers no encoders (every frame would
// fail on the guest's broken reply wait).
#define VV_GF_ENCODE 1u
// VV_GF_SPAN: a fill or pull order may run past its slot into the next ones (up to the last), for frames bigger than a
// slot; without it (VeneraVideo before 0.2.1) the host fails such frames, as before.
#define VV_GF_SPAN 2u

// An IOSurface a guest message carries (an output buffer), as the guest driver found it.
struct vv_surf {
    uint32_t id;
    uint32_t format;   // CoreVideo pixel format ('420v', 'x420', ...)
    uint32_t width, height;
    uint32_t planes;
    uint32_t plane_bpr[2];
    uint32_t pad;
};

#define VV_ALIGN(n) (((n) + 31u) & ~31u)
#endif
