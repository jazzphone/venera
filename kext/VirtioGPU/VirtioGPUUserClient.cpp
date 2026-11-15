#include "VirtioGPUUserClient.hpp"

#include <IOKit/IOLib.h>

#include "../VirtioGPUUserAPI.h"
#include "VirtioGPU.hpp"
#include "VirtioGPUProtocol.h"

void probeLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#define LOG(fmt, ...) probeLog("uc: " fmt, ##__VA_ARGS__)

OSDefineMetaClassAndStructors(VirtioGPUUserClient, IOUserClient)

bool VirtioGPUUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type) {
    if (!IOUserClient::initWithTask(owningTask, securityID, type)) {
        return false;
    }
    task_ = owningTask;
    lock_ = IOLockAlloc();
    resources_ = static_cast<Resource *>(IOMallocZero(kMaxResources * sizeof(Resource)));
    return lock_ && resources_;
}

bool VirtioGPUUserClient::start(IOService *provider) {
    core_ = OSDynamicCast(VirtioGPU, provider);
    return core_ && IOUserClient::start(provider);
}

void VirtioGPUUserClient::free() {
    if (resources_) {
        IOFree(resources_, kMaxResources * sizeof(Resource));
        resources_ = nullptr;
    }
    if (lock_) {
        IOLockFree(lock_);
        lock_ = nullptr;
    }
    IOUserClient::free();
}

static bool noPending(void *self) {
    return *static_cast<volatile uint32_t *>(self) == 0;
}

IOReturn VirtioGPUUserClient::clientClose() {
    IOLockLock(lock_);
    closed_ = true;
    IOLockUnlock(lock_);
    // Let the host finish what we submitted before the context and its memory go away.
    if (core_ && !core_->waitUntil(noPending, (void *)&pending_, 2000ULL * 1000 * 1000)) {
        LOG("close: %u requests still in flight", pending_);
    }
    destroyAll();
    if (core_ && ctx_) {
        vgpu::CtrlHdr destroy = {};
        destroy.type = vgpu::kCmdCtxDestroy;
        destroy.ctxID = ctx_;
        vgpu::CtrlHdr reply = {};
        core_->transact(&destroy, sizeof(destroy), &reply, sizeof(reply));
        LOG("ctx %u closed", ctx_);
        ctx_ = 0;
    }
    terminate();
    return kIOReturnSuccess;
}

void VirtioGPUUserClient::requestCompleted(uint32_t ring, uint64_t fence) {
    if (fence && ring < kMaxRings && fence > signaled_[ring]) {
        signaled_[ring] = fence; // fences on one ring complete in order
    }
    if (pending_) {
        pending_--;
    }
}

VirtioGPUUserClient::Resource *VirtioGPUUserClient::find(uint32_t id) {
    for (unsigned i = 0; i < resourceCount_; i++) {
        if (resources_[i].id == id) {
            return &resources_[i];
        }
    }
    return nullptr;
}

IOReturn VirtioGPUUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                                             IOExternalMethodDispatch *, OSObject *, void *) {
    if (!core_ || !core_->ready() || closed_) {
        return kIOReturnNotReady;
    }
    switch (selector) {
    case kVGUCGetInfo: return getInfo(args);
    case kVGUCGetCapset: return getCapset(args);
    case kVGUCContextInit: return contextInit(args);
    case kVGUCCreateBlob: return createBlob(args);
    case kVGUCMapBlob: return mapBlob(args);
    case kVGUCDestroyResource:
        if (args->scalarInputCount < 1) {
            return kIOReturnBadArgument;
        }
        return destroyResource((uint32_t)args->scalarInput[0]);
    case kVGUCSubmit: return submit(args);
    case kVGUCWaitFence: return waitFence(args);
    default: return kIOReturnUnsupported;
    }
}

IOReturn VirtioGPUUserClient::getInfo(IOExternalMethodArguments *args) {
    if (!args->structureOutput || args->structureOutputSize < sizeof(vgpu_info)) {
        return kIOReturnBadArgument;
    }
    vgpu_info info = {};
    core_->fillInfo(&info);
    memcpy(args->structureOutput, &info, sizeof(info));
    args->structureOutputSize = sizeof(info);
    return kIOReturnSuccess;
}

IOReturn VirtioGPUUserClient::getCapset(IOExternalMethodArguments *args) {
    if (args->scalarInputCount < 2 || !args->structureOutput || args->structureOutputSize == 0 ||
        args->structureOutputSize > 4096) {
        return kIOReturnBadArgument;
    }
    vgpu::CmdGetCapset req = {};
    req.hdr.type = vgpu::kCmdGetCapset;
    req.capsetID = (uint32_t)args->scalarInput[0];
    req.capsetVersion = (uint32_t)args->scalarInput[1];
    uint32_t replyLength = sizeof(vgpu::CtrlHdr) + args->structureOutputSize;
    uint8_t *reply = static_cast<uint8_t *>(IOMallocZero(replyLength));
    if (!reply) {
        return kIOReturnNoMemory;
    }
    uint32_t type = core_->transact(&req, sizeof(req), reply, replyLength);
    if (type == vgpu::kRespOkCapset) {
        memcpy(args->structureOutput, reply + sizeof(vgpu::CtrlHdr), args->structureOutputSize);
    }
    IOFree(reply, replyLength);
    return type == vgpu::kRespOkCapset ? kIOReturnSuccess : kIOReturnError;
}

IOReturn VirtioGPUUserClient::contextInit(IOExternalMethodArguments *args) {
    if (args->scalarInputCount < 1 || args->scalarOutputCount < 1) {
        return kIOReturnBadArgument;
    }
    IOLockLock(lock_);
    if (!ctx_) {
        uint32_t ctx = core_->allocateContextID() + 1; // the probe used 1
        vgpu::CmdCtxCreate req = {};
        req.hdr.type = vgpu::kCmdCtxCreate;
        req.hdr.ctxID = ctx;
        req.contextInit = (uint32_t)args->scalarInput[0] & vgpu::kContextInitCapsetIDMask;
        strlcpy(req.debugName, "macos-venus", sizeof(req.debugName));
        req.nlen = (uint32_t)strlen(req.debugName);
        vgpu::CtrlHdr reply = {};
        uint32_t type = core_->transact(&req, sizeof(req), &reply, sizeof(reply));
        if (type == vgpu::kRespOkNoData) {
            ctx_ = ctx;
        }
        LOG("CTX_CREATE ctx %u capset %u -> 0x%x", ctx, req.contextInit, type);
    }
    args->scalarOutput[0] = ctx_;
    IOLockUnlock(lock_);
    return ctx_ ? kIOReturnSuccess : kIOReturnError;
}

IOReturn VirtioGPUUserClient::createBlob(IOExternalMethodArguments *args) {
    if (args->scalarInputCount < 4 || args->scalarOutputCount < 1) {
        return kIOReturnBadArgument;
    }
    IOLockLock(lock_);
    if (!ctx_ || resourceCount_ == kMaxResources) {
        IOLockUnlock(lock_);
        return ctx_ ? kIOReturnNoResources : kIOReturnNotReady;
    }
    uint32_t id = core_->allocateResourceID();
    vgpu::CmdResourceCreateBlob req = {};
    req.hdr.type = vgpu::kCmdResourceCreateBlob;
    req.hdr.ctxID = ctx_;
    req.resourceID = id;
    req.blobMem = (uint32_t)args->scalarInput[0];
    req.blobFlags = (uint32_t)args->scalarInput[1];
    req.size = args->scalarInput[2];
    req.blobID = args->scalarInput[3];
    vgpu::CtrlHdr reply = {};
    uint32_t type = 0;
    if (req.blobMem != vgpu::kBlobMemHost3D) {
        type = vgpu::kRespErrInvalidParameter; // guest-memory blobs: not yet
    } else {
        type = core_->transact(&req, sizeof(req), &reply, sizeof(reply));
    }
    if (type == vgpu::kRespOkNoData) {
        vgpu::CmdCtxResource attach = {};
        attach.hdr.type = vgpu::kCmdCtxAttachResource;
        attach.hdr.ctxID = ctx_;
        attach.resourceID = id;
        core_->transact(&attach, sizeof(attach), &reply, sizeof(reply));
        resources_[resourceCount_++] = {id, req.size, false, 0, 0};
        args->scalarOutput[0] = id;
    } else {
        LOG("CREATE_BLOB res %u ctx %u mem %u flags 0x%x size %llu id %llu -> 0x%x", id, ctx_, req.blobMem,
            req.blobFlags,
            (unsigned long long)req.size, (unsigned long long)req.blobID, type);
    }
    IOLockUnlock(lock_);
    return type == vgpu::kRespOkNoData ? kIOReturnSuccess : kIOReturnError;
}

IOReturn VirtioGPUUserClient::mapBlob(IOExternalMethodArguments *args) {
    if (args->scalarInputCount < 1 || args->scalarOutputCount < 2) {
        return kIOReturnBadArgument;
    }
    IOLockLock(lock_);
    Resource *r = find((uint32_t)args->scalarInput[0]);
    IOReturn result = kIOReturnSuccess;
    if (!r) {
        result = kIOReturnNotFound;
    } else if (!r->mapped) {
        uint64_t offset = 0;
        if (!core_->hostmemAllocate(r->size, &offset)) {
            result = kIOReturnNoSpace;
        } else {
            vgpu::CmdResourceMapBlob req = {};
            req.hdr.type = vgpu::kCmdResourceMapBlob;
            req.hdr.ctxID = ctx_;
            req.resourceID = r->id;
            req.offset = offset;
            vgpu::RespMapInfo reply = {};
            uint32_t type = core_->transact(&req, sizeof(req), &reply, sizeof(reply));
            if (type == vgpu::kRespOkMapInfo) {
                r->mapped = true;
                r->offset = offset;
                r->mapInfo = reply.mapInfo;
            } else {
                core_->hostmemFree(offset, r->size);
                LOG("MAP_BLOB res %u -> 0x%x", r->id, type);
                result = kIOReturnError;
            }
        }
    }
    if (result == kIOReturnSuccess) {
        args->scalarOutput[0] = r->size;
        args->scalarOutput[1] = r->mapInfo;
    }
    IOLockUnlock(lock_);
    return result;
}

IOReturn VirtioGPUUserClient::clientMemoryForType(UInt32 type, IOOptionBits *options, IOMemoryDescriptor **memory) {
    IOLockLock(lock_);
    Resource *r = find(type);
    if (!r || !r->mapped || !core_->hostmemPhys()) {
        IOLockUnlock(lock_);
        LOG("map: resource %u not mapped", type);
        return kIOReturnNotFound;
    }
    uint64_t phys = core_->hostmemPhys() + r->offset;
    uint32_t mapInfo = r->mapInfo;
    uint64_t size = r->size;
    IOLockUnlock(lock_);
    // The window is host memory behind a PCI BAR: describe it as physical, cacheable as the
    // host says (VIRTIO_GPU_MAP_CACHE_*).
    IOOptionBits cache = kIOMapCopybackCache;
    if (mapInfo == vgpu::kMapCacheWC) {
        cache = kIOMapWriteCombineCache;
    } else if (mapInfo == vgpu::kMapCacheUncached) {
        cache = kIOMapInhibitCache;
    }
    IOMemoryDescriptor *md = IOMemoryDescriptor::withAddressRange(phys, size, kIODirectionInOut | kIOMemoryMapperNone,
                                                                  TASK_NULL);
    if (!md) {
        LOG("map: no descriptor for phys 0x%llx size %llu", (unsigned long long)phys, (unsigned long long)size);
        return kIOReturnNoMemory;
    }
    if (mapProbe_ < 2) { // once or twice: can the kernel itself map it?
        mapProbe_++;
        IOMemoryMap *k = md->createMappingInTask(kernel_task, 0, kIOMapAnywhere | cache);
        if (k) {
            volatile uint32_t *p = reinterpret_cast<volatile uint32_t *>(k->getVirtualAddress());
            uint32_t before = p[0];
            p[0] = 0x56475055; // 'VGPU'
            LOG("map: kernel mapping of 0x%llx ok, word 0x%08x -> 0x%08x", (unsigned long long)phys, before, p[0]);
            k->release();
        } else {
            LOG("map: kernel mapping of 0x%llx (cache 0x%x) FAILED", (unsigned long long)phys, cache);
        }
    }
    *options = (*options & ~kIOMapCacheMask) | cache;
    *memory = md; // IOUserClient releases it after mapping
    LOG("map: resource %u phys 0x%llx size %llu cache 0x%x", type, (unsigned long long)phys,
        (unsigned long long)size, cache);
    return kIOReturnSuccess;
}

IOReturn VirtioGPUUserClient::destroyResource(uint32_t id) {
    IOLockLock(lock_);
    Resource *r = find(id);
    if (!r) {
        IOLockUnlock(lock_);
        return kIOReturnNotFound;
    }
    vgpu::CtrlHdr reply = {};
    if (r->mapped) {
        vgpu::CmdResourceUnmapBlob unmap = {};
        unmap.hdr.type = vgpu::kCmdResourceUnmapBlob;
        unmap.hdr.ctxID = ctx_;
        unmap.resourceID = id;
        core_->transact(&unmap, sizeof(unmap), &reply, sizeof(reply));
        core_->hostmemFree(r->offset, r->size);
    }
    vgpu::CmdCtxResource detach = {};
    detach.hdr.type = vgpu::kCmdCtxDetachResource;
    detach.hdr.ctxID = ctx_;
    detach.resourceID = id;
    core_->transact(&detach, sizeof(detach), &reply, sizeof(reply));
    vgpu::CmdResourceUnref unref = {};
    unref.hdr.type = vgpu::kCmdResourceUnref;
    unref.resourceID = id;
    core_->transact(&unref, sizeof(unref), &reply, sizeof(reply));
    *r = resources_[--resourceCount_];
    IOLockUnlock(lock_);
    return kIOReturnSuccess;
}

void VirtioGPUUserClient::destroyAll() {
    while (resourceCount_) {
        destroyResource(resources_[resourceCount_ - 1].id);
    }
}

IOReturn VirtioGPUUserClient::submit(IOExternalMethodArguments *args) {
    if (args->scalarInputCount < 2 || args->scalarOutputCount < 1) {
        return kIOReturnBadArgument;
    }
    uint32_t ring = (uint32_t)args->scalarInput[0];
    bool wantFence = args->scalarInput[1] != 0;
    uint32_t size = args->structureInputDescriptor ? (uint32_t)args->structureInputDescriptor->getLength()
                                                   : args->structureInputSize;
    if (!ctx_ || ring >= kMaxRings || size > 1024 * 1024) {
        return kIOReturnBadArgument;
    }
    IOLockLock(lock_);
    uint64_t fence = wantFence ? ++nextFence_[ring] : 0;
    IOLockUnlock(lock_);
    OSIncrementAtomic(reinterpret_cast<volatile SInt32 *>(&pending_));
    bool ok = core_->submit3D(ctx_, ring, fence, args->structureInput, size, args->structureInputDescriptor, this);
    if (!ok) {
        OSDecrementAtomic(reinterpret_cast<volatile SInt32 *>(&pending_));
        return kIOReturnNoResources;
    }
    args->scalarOutput[0] = fence;
    return kIOReturnSuccess;
}

namespace {
struct FenceWait {
    volatile uint64_t *signaled;
    uint64_t fence;
};
bool fenceDone(void *context) {
    auto *w = static_cast<FenceWait *>(context);
    return *w->signaled >= w->fence;
}
} // namespace

IOReturn VirtioGPUUserClient::waitFence(IOExternalMethodArguments *args) {
    if (args->scalarInputCount < 3 || args->scalarOutputCount < 1) {
        return kIOReturnBadArgument;
    }
    uint32_t ring = (uint32_t)args->scalarInput[0];
    if (ring >= kMaxRings) {
        return kIOReturnBadArgument;
    }
    FenceWait w = {&signaled_[ring], args->scalarInput[1]};
    uint64_t timeout = args->scalarInput[2];
    bool done = fenceDone(&w) || (timeout && core_->waitUntil(fenceDone, &w, timeout));
    if (!done && !timeout) {
        done = core_->waitUntil(fenceDone, &w, 0); // drains finished requests once
    }
    args->scalarOutput[0] = done ? 1 : 0;
    return kIOReturnSuccess;
}
