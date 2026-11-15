// virtio-gpu wire protocol (virtio 1.2 section 5.7.6). Little-endian, same as x86.
#pragma once

#include <stddef.h>

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

enum Format : uint32_t {
    kFormatB8G8R8A8 = 1,
    kFormatB8G8R8X8 = 2, // matches macOS's 32-bit framebuffers (BGRA in memory, alpha ignored)
    kFormatA8R8G8B8 = 3,
    kFormatX8R8G8B8 = 4,
    kFormatR8G8B8A8 = 67,
    kFormatX8B8G8R8 = 68,
    kFormatA8B8G8R8 = 121,
    kFormatR8G8B8X8 = 134,
};

struct CmdResourceCreate2D {
    CtrlHdr hdr;
    uint32_t resourceID;
    uint32_t format;
    uint32_t width;
    uint32_t height;
};

struct MemEntry {
    uint64_t addr;
    uint32_t length;
    uint32_t padding;
};

struct CmdResourceAttachBacking {
    CtrlHdr hdr;
    uint32_t resourceID;
    uint32_t nrEntries;
    // followed by nrEntries MemEntry
};

struct CmdResourceDetachBacking {
    CtrlHdr hdr;
    uint32_t resourceID;
    uint32_t padding;
};

struct CmdResourceUnref {
    CtrlHdr hdr;
    uint32_t resourceID;
    uint32_t padding;
};

struct CmdSetScanout {
    CtrlHdr hdr;
    Rect r;
    uint32_t scanoutID;
    uint32_t resourceID; // 0 disables the scanout
};

struct CmdTransferToHost2D {
    CtrlHdr hdr;
    Rect r;
    uint64_t offset; // byte offset of r's origin in the backing
    uint32_t resourceID;
    uint32_t padding;
};

struct CmdResourceFlush {
    CtrlHdr hdr;
    Rect r;
    uint32_t resourceID;
    uint32_t padding;
};

// cursor queue
struct CursorPos {
    uint32_t scanoutID;
    uint32_t x;
    uint32_t y;
    uint32_t padding;
};

struct CmdUpdateCursor {
    CtrlHdr hdr;
    CursorPos pos;
    uint32_t resourceID; // 64x64 B8G8R8A8 resource, 0 hides the cursor
    uint32_t hotX;
    uint32_t hotY;
    uint32_t padding;
};

// capability sets (GET_CAPSET_INFO)
enum CapsetID : uint32_t {
    kCapsetVirgl = 1,
    kCapsetVirgl2 = 2,
    kCapsetGfxstreamVulkan = 3,
    kCapsetVenus = 4,
    kCapsetCrossDomain = 5,
    kCapsetDRM = 6,
};

struct CmdGetCapsetInfo {
    CtrlHdr hdr;
    uint32_t capsetIndex;
    uint32_t padding;
};

struct RespCapsetInfo {
    CtrlHdr hdr;
    uint32_t capsetID;
    uint32_t capsetMaxVersion;
    uint32_t capsetMaxSize;
    uint32_t padding;
};

// struct virtio_gpu_config (device config space)
struct Config {
    uint32_t eventsRead;
    uint32_t eventsClear;
    uint32_t numScanouts;
    uint32_t numCapsets;
};

} // namespace vgpu
