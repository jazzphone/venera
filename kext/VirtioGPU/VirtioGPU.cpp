// VirtioGPU - stage 0: probe only.
//
// Claims the virtio-gpu PCI function (1af4:1050) in the default match category, so Apple's
// generic AppleVirtIOPCITransport (probe score 10000) doesn't, and logs what the device offers:
// PCI header, BARs, the virtio-pci capability list (virtio 1.2 section 4.1.4), the device
// feature bits and the GPU's device config (section 5.7.4). It never resets the device or
// writes device_status, so the firmware's VGA framebuffer (IONDRVFramebuffer, its own match
// category) keeps drawing the screen.

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/pci/IOPCIDevice.h>

// IOLog from an OpenCore-injected kext doesn't reach dmesg or the unified log on Tahoe, so every
// line also goes into the "ProbeLog" registry property (read it with ioreg).
static OSArray *gProbeLog;

static void probeLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void probeLog(const char *fmt, ...) {
    char line[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    IOLog("VirtioGPU: %s\n", line);
    if (gProbeLog) {
        if (OSString *s = OSString::withCString(line)) {
            gProbeLog->setObject(s);
            s->release();
        }
    }
}

#define LOG(fmt, ...) probeLog(fmt, ##__VA_ARGS__)

namespace {

// virtio-pci capability types (struct virtio_pci_cap.cfg_type)
enum : uint8_t {
    kCapCommon = 1,
    kCapNotify = 2,
    kCapISR = 3,
    kCapDevice = 4,
    kCapPCI = 5,
    kCapSharedMem = 8,
};

const char *capName(uint8_t type) {
    switch (type) {
    case kCapCommon: return "common";
    case kCapNotify: return "notify";
    case kCapISR: return "isr";
    case kCapDevice: return "device";
    case kCapPCI: return "pci-cfg";
    case kCapSharedMem: return "shared-mem";
    default: return "?";
    }
}

struct Region {
    bool present = false;
    uint8_t bar = 0;
    uint32_t offset = 0;
    uint32_t length = 0;
};

// virtio_pci_common_cfg offsets
enum : uint32_t {
    kDeviceFeatureSelect = 0x00,
    kDeviceFeature = 0x04,
    kNumQueues = 0x12,
    kDeviceStatus = 0x14,
    kConfigGeneration = 0x15,
};

// Feature bits worth naming (section 5.7.3 and 6)
const struct { uint32_t bit; const char *name; } kFeatures[] = {
    {0, "VIRGL"}, {1, "EDID"}, {2, "RESOURCE_UUID"}, {3, "RESOURCE_BLOB"}, {4, "CONTEXT_INIT"},
    {28, "INDIRECT_DESC"}, {29, "EVENT_IDX"}, {32, "VERSION_1"}, {33, "ACCESS_PLATFORM"},
    {34, "RING_PACKED"}, {35, "IN_ORDER"}, {36, "ORDER_PLATFORM"}, {37, "SR_IOV"},
    {38, "NOTIFICATION_DATA"},
};

} // namespace

class VirtioGPU : public IOService {
    OSDeclareDefaultStructors(VirtioGPU)

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;

private:
    void logHeader(IOPCIDevice *pci);
    void logCapabilities(IOPCIDevice *pci, Region regions[9]);
    void logDevice(IOPCIDevice *pci, const Region regions[9]);
};

OSDefineMetaClassAndStructors(VirtioGPU, IOService)

IOService *VirtioGPU::probe(IOService *provider, SInt32 *score) {
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci) {
        return nullptr;
    }
    uint16_t vendor = pci->configRead16(kIOPCIConfigVendorID);
    uint16_t device = pci->configRead16(kIOPCIConfigDeviceID);
    LOG("probe %04x:%04x score %d", vendor, device, score ? (int)*score : -1);
    if (vendor != 0x1af4 || device != 0x1050) {
        return nullptr;
    }
    return IOService::probe(provider, score);
}

bool VirtioGPU::start(IOService *provider) {
    if (!IOService::start(provider)) {
        return false;
    }
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci) {
        return false;
    }
    gProbeLog = OSArray::withCapacity(64);
    LOG("start: stage 0 probe (no device writes except feature select)");
    pci->setMemoryEnable(true);

    Region regions[9] = {};
    logHeader(pci);
    logCapabilities(pci, regions);
    logDevice(pci, regions);

    if (gProbeLog) {
        setProperty("ProbeLog", gProbeLog);
        gProbeLog->release();
        gProbeLog = nullptr;
    }
    registerService();
    LOG("probe done; device left as the firmware set it");
    return true;
}

void VirtioGPU::stop(IOService *provider) {
    LOG("stop");
    IOService::stop(provider);
}

void VirtioGPU::logHeader(IOPCIDevice *pci) {
    LOG("pci %04x:%04x sub %04x:%04x rev %02x class %06x cmd %04x status %04x",
        pci->configRead16(kIOPCIConfigVendorID), pci->configRead16(kIOPCIConfigDeviceID),
        pci->configRead16(kIOPCIConfigSubSystemVendorID), pci->configRead16(kIOPCIConfigSubSystemID),
        pci->configRead8(kIOPCIConfigRevisionID), pci->configRead32(kIOPCIConfigRevisionID) >> 8,
        pci->configRead16(kIOPCIConfigCommand), pci->configRead16(kIOPCIConfigStatus));
    for (uint8_t bar = 0; bar < 6; bar++) {
        uint8_t reg = kIOPCIConfigBaseAddress0 + bar * 4;
        uint32_t raw = pci->configRead32(reg);
        if (!raw) {
            continue;
        }
        IODeviceMemory *mem = pci->getDeviceMemoryWithRegister(reg);
        LOG("BAR%u raw %08x %s%s phys 0x%llx len 0x%llx", bar, raw,
            (raw & 1) ? "io" : "mem", (raw & 0x6) == 0x4 ? "64" : "32",
            mem ? (unsigned long long)mem->getPhysicalAddress() : 0ULL,
            mem ? (unsigned long long)mem->getLength() : 0ULL);
        if (!(raw & 1) && (raw & 0x6) == 0x4) {
            bar++; // upper half of a 64-bit BAR
        }
    }
}

void VirtioGPU::logCapabilities(IOPCIDevice *pci, Region regions[9]) {
    if (!(pci->configRead16(kIOPCIConfigStatus) & 0x10)) {
        LOG("no capability list");
        return;
    }
    uint8_t ptr = pci->configRead8(kIOPCIConfigCapabilitiesPtr) & 0xfc;
    for (int guard = 0; ptr && guard < 48; guard++) {
        uint8_t id = pci->configRead8(ptr);
        uint8_t next = pci->configRead8(ptr + 1) & 0xfc;
        if (id == 0x09) { // vendor specific: struct virtio_pci_cap
            uint8_t capLen = pci->configRead8(ptr + 2);
            uint8_t type = pci->configRead8(ptr + 3);
            uint8_t bar = pci->configRead8(ptr + 4);
            uint8_t capId = pci->configRead8(ptr + 5);
            uint32_t offset = pci->configRead32(ptr + 8);
            uint32_t length = pci->configRead32(ptr + 12);
            if (type == kCapNotify && capLen >= 20) {
                LOG("cap @%02x virtio %-10s bar %u off 0x%x len 0x%x id %u notify_off_multiplier %u",
                    ptr, capName(type), bar, offset, length, capId, pci->configRead32(ptr + 16));
            } else if (type == kCapSharedMem && capLen >= 24) {
                uint64_t off64 = ((uint64_t)pci->configRead32(ptr + 16) << 32) | offset;
                uint64_t len64 = ((uint64_t)pci->configRead32(ptr + 20) << 32) | length;
                LOG("cap @%02x virtio %-10s bar %u off 0x%llx len 0x%llx shmid %u", ptr,
                    capName(type), bar, (unsigned long long)off64, (unsigned long long)len64, capId);
            } else {
                LOG("cap @%02x virtio %-10s bar %u off 0x%x len 0x%x id %u", ptr, capName(type), bar,
                    offset, length, capId);
            }
            if (type < 9 && !regions[type].present) {
                regions[type].present = true;
                regions[type].bar = bar;
                regions[type].offset = offset;
                regions[type].length = length;
            }
        } else if (id == 0x11) { // MSI-X
            uint16_t ctrl = pci->configRead16(ptr + 2);
            uint32_t table = pci->configRead32(ptr + 4);
            uint32_t pba = pci->configRead32(ptr + 8);
            LOG("cap @%02x msi-x vectors %u enabled %u table bar %u off 0x%x pba bar %u off 0x%x", ptr,
                (ctrl & 0x7ff) + 1, (ctrl >> 15) & 1, table & 7, table & ~7u, pba & 7, pba & ~7u);
        } else {
            LOG("cap @%02x id 0x%02x", ptr, id);
        }
        ptr = next;
    }
}

void VirtioGPU::logDevice(IOPCIDevice *pci, const Region regions[9]) {
    const Region &common = regions[kCapCommon];
    const Region &device = regions[kCapDevice];
    if (!common.present) {
        LOG("no common config: not a modern virtio device?");
        return;
    }
    IODeviceMemory *mem = pci->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0 + common.bar * 4);
    IOMemoryMap *map = mem ? mem->map(kIOMapInhibitCache) : nullptr;
    if (!map) {
        LOG("could not map BAR%u", common.bar);
        return;
    }
    volatile uint8_t *base = reinterpret_cast<volatile uint8_t *>(map->getVirtualAddress());
    volatile uint8_t *cfg = base + common.offset;

    uint64_t features = 0;
    for (uint32_t select = 0; select < 2; select++) {
        *reinterpret_cast<volatile uint32_t *>(cfg + kDeviceFeatureSelect) = select;
        uint32_t word = *reinterpret_cast<volatile uint32_t *>(cfg + kDeviceFeature);
        features |= (uint64_t)word << (32 * select);
    }
    LOG("device features 0x%016llx", (unsigned long long)features);
    for (const auto &f : kFeatures) {
        if (features & (1ULL << f.bit)) {
            LOG("  feature %u %s", f.bit, f.name);
        }
    }
    LOG("num_queues %u device_status 0x%02x config_generation %u",
        *reinterpret_cast<volatile uint16_t *>(cfg + kNumQueues), cfg[kDeviceStatus],
        cfg[kConfigGeneration]);

    if (device.present && device.bar == common.bar) {
        volatile uint32_t *gpu = reinterpret_cast<volatile uint32_t *>(base + device.offset);
        LOG("gpu config: events_read %u events_clear %u num_scanouts %u num_capsets %u", gpu[0],
            gpu[1], gpu[2], gpu[3]);
    } else if (device.present) {
        LOG("device config is in BAR%u, not mapped by the probe", device.bar);
    }
    map->release();
}
