// virtio-gpu wire protocol (virtio 1.2 section 5.7.6). Little-endian, same as x86.
#pragma once

#include <stdint.h>

namespace vgpu {

enum Feature : uint32_t {
    kFeatureVirgl = 0,
    kFeatureEDID = 1,
    kFeatureResourceUUID = 2,
    kFeatureResourceBlob = 3,
    kFeatureContextInit = 4,
};

enum CtrlType : uint32_t {
    // 2D commands
    kCmdGetDisplayInfo = 0x0100,
    kCmdResourceCreate2D,
    kCmdResourceUnref,
    kCmdSetScanout,
    kCmdResourceFlush,
    kCmdTransferToHost2D,
    kCmdResourceAttachBacking,
    kCmdResourceDetachBacking,
    kCmdGetCapsetInfo,
    kCmdGetCapset,
    kCmdGetEDID,
    kCmdResourceAssignUUID,
    kCmdResourceCreateBlob,
    kCmdSetScanoutBlob,

    // cursor commands
    kCmdUpdateCursor = 0x0300,
    kCmdMoveCursor,

    // success responses
    kRespOkNoData = 0x1100,
    kRespOkDisplayInfo,
    kRespOkCapsetInfo,
    kRespOkCapset,
    kRespOkEDID,
    kRespOkResourceUUID,
    kRespOkMapInfo,

    // error responses
    kRespErrUnspec = 0x1200,
    kRespErrOutOfMemory,
    kRespErrInvalidScanoutID,
    kRespErrInvalidResourceID,
    kRespErrInvalidContextID,
    kRespErrInvalidParameter,
};

constexpr uint32_t kFlagFence = 1u << 0;
constexpr unsigned kMaxScanouts = 16;

struct CtrlHdr {
    uint32_t type;
    uint32_t flags;
    uint64_t fenceID;
    uint32_t ctxID;
    uint8_t ringIdx;
    uint8_t padding[3];
};
static_assert(sizeof(CtrlHdr) == 24, "virtio_gpu_ctrl_hdr");

struct Rect {
    uint32_t x, y, width, height;
};

struct RespDisplayInfo {
    CtrlHdr hdr;
    struct {
        Rect r;
        uint32_t enabled;
        uint32_t flags;
    } pmodes[kMaxScanouts];
};
static_assert(sizeof(RespDisplayInfo) == 24 + 16 * 24, "virtio_gpu_resp_display_info");

struct CmdGetEDID {
    CtrlHdr hdr;
    uint32_t scanout;
    uint32_t padding;
};

struct RespEDID {
    CtrlHdr hdr;
    uint32_t size;
    uint32_t padding;
    uint8_t edid[1024];
};

// struct virtio_gpu_config (device config space)
struct Config {
    uint32_t eventsRead;
    uint32_t eventsClear;
    uint32_t numScanouts;
    uint32_t numCapsets;
};

} // namespace vgpu
