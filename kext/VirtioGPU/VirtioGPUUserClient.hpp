// VirtioGPUUserClient: the user-space door to the core for Venus (see ../VirtioGPUUserAPI.h).
// One connection = one host context (CTX_CREATE with the Venus capset), its blob resources (mapped
// from the host-visible window into the caller), and per-ring fence timelines.
#pragma once

#include <IOKit/IOUserClient.h>

class VirtioGPU;

class VirtioGPUUserClient : public IOUserClient {
    OSDeclareDefaultStructors(VirtioGPUUserClient)

public:
    bool initWithTask(task_t owningTask, void *securityID, UInt32 type) override;
    bool start(IOService *provider) override;
    IOReturn clientClose() override;
    void free() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *dispatch, OSObject *target, void *reference) override;
    IOReturn clientMemoryForType(UInt32 type, IOOptionBits *options, IOMemoryDescriptor **memory) override;

    // Called by the core (its command lock held) when an async request of ours completes.
    void requestCompleted(uint32_t ring, uint64_t fence);

private:
    struct Resource {
        uint32_t id;
        uint64_t size;
        bool mapped;
        uint64_t offset;
        uint32_t mapInfo;
    };
    static constexpr unsigned kMaxResources = 4096;
    static constexpr unsigned kMaxRings = 64;

    IOReturn getInfo(IOExternalMethodArguments *args);
    IOReturn getCapset(IOExternalMethodArguments *args);
    IOReturn contextInit(IOExternalMethodArguments *args);
    IOReturn createBlob(IOExternalMethodArguments *args);
    IOReturn mapBlob(IOExternalMethodArguments *args);
    IOReturn destroyResource(uint32_t id);
    IOReturn submit(IOExternalMethodArguments *args);
    IOReturn waitFence(IOExternalMethodArguments *args);
    Resource *find(uint32_t id);
    void destroyAll();

    VirtioGPU *core_ = nullptr;
    task_t task_ = nullptr;
    IOLock *lock_ = nullptr;
    uint32_t ctx_ = 0;
    Resource *resources_ = nullptr;
    unsigned resourceCount_ = 0;
    uint64_t nextFence_[kMaxRings] = {};
    volatile uint64_t signaled_[kMaxRings] = {};
    volatile uint32_t pending_ = 0;
    bool closed_ = false;
    uint32_t mapProbe_ = 0;
};
