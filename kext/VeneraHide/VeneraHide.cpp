// VeneraHide: macOS doesn't learn from kern.hv_vmm_present that it runs in a VM, except in the processes that need to
// know (software update, which then takes the VM's update path). Apple's Account sign-in, among others, turns a VM
// away when it sees it. Venera's own replacement for VMHide (a Lilu plug-in with no license), written from scratch:
// no Lilu, nothing but the kernel's own exports.
//
// How: the kern node of the sysctl tree is exported to kexts (sysctl__kern_children); hv_vmm_present is one of its
// children, and its handler is swapped for ours, which answers 0 to everyone but the processes listed below and asks
// the original handler for those. The oid sits in memory the kernel write-protects once booted (Ventura on), so the
// swap clears CR0.WP for the one store, with interrupts off so nothing else runs on this CPU meanwhile.
//
// Boot-arg veneravmm=show leaves kern.hv_vmm_present as it is (to check whether this is what something needs).
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <libkern/libkern.h>

// sysctl__kern_children: declared by SYSCTL_DECL(_kern) in <sys/sysctl.h>

namespace {

// processes that still see the VM: software update (its VM path), as VMHide had it
const char *const kSeeTheVM[] = {"SoftwareUpdateNo", "softwareupdated", "com.apple.Mobile", "osinstallersetup"};

sysctl_handler_t gOriginal;
struct sysctl_oid *gOid;

int hiddenHandler(struct sysctl_oid *oidp, void *arg1, int arg2, struct sysctl_req *req) {
    char name[MAXCOMLEN + 1] = {};
    proc_selfname(name, sizeof(name));
    for (const char *p : kSeeTheVM) {
        if (!strncmp(name, p, sizeof(name))) {
            return gOriginal(oidp, arg1, arg2, req);
        }
    }
    int zero = 0;
    return SYSCTL_OUT(req, &zero, sizeof(zero));
}

// One store into write-protected kernel memory: interrupts off, CR0.WP clear, the store, all back as they were.
void storeProtected(sysctl_handler_t *where, sysctl_handler_t value) {
    uint64_t flags, cr0;
    __asm__ volatile("pushfq; popq %0; cli" : "=r"(flags)::"memory");
    __asm__ volatile("movq %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("movq %0, %%cr0" ::"r"(cr0 & ~(1ull << 16)) : "memory");
    *(volatile sysctl_handler_t *)where = value;
    __asm__ volatile("movq %0, %%cr0" ::"r"(cr0) : "memory");
    if (flags & (1ull << 9)) {
        __asm__ volatile("sti" ::: "memory");
    }
}

} // namespace

class VeneraHide : public IOService {
    OSDeclareDefaultStructors(VeneraHide);

public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
};

OSDefineMetaClassAndStructors(VeneraHide, IOService);

bool VeneraHide::start(IOService *provider) {
    if (!IOService::start(provider)) {
        return false;
    }
    char arg[16] = {};
    if (PE_parse_boot_argn("veneravmm", arg, sizeof(arg)) && !strncmp(arg, "show", sizeof(arg))) {
        IOLog("VeneraHide: veneravmm=show: kern.hv_vmm_present left as it is\n");
        setProperty("VeneraHide", "off (veneravmm=show)");
        return true;
    }
    if (gOid) {
        return true;   // a second instance: already done
    }
    struct sysctl_oid *oid;
    SLIST_FOREACH(oid, &sysctl__kern_children, oid_link) {
        if (oid->oid_name && !strcmp(oid->oid_name, "hv_vmm_present")) {
            break;
        }
    }
    if (!oid || !oid->oid_handler) {
        IOLog("VeneraHide: no kern.hv_vmm_present here: nothing to do\n");
        setProperty("VeneraHide", "no kern.hv_vmm_present");
        return true;
    }
    gOriginal = oid->oid_handler;
    gOid = oid;
    storeProtected(&oid->oid_handler, hiddenHandler);
    bool ok = oid->oid_handler == hiddenHandler;
    IOLog("VeneraHide: kern.hv_vmm_present %s\n", ok ? "hidden but from software update" : "COULD NOT be swapped");
    setProperty("VeneraHide", ok ? "hidden, but from software update" : "the swap didn't take");
    registerService();
    return true;
}

void VeneraHide::stop(IOService *provider) {
    if (gOid && gOriginal && gOid->oid_handler == hiddenHandler) {
        storeProtected(&gOid->oid_handler, gOriginal);
        gOid = nullptr;
    }
    IOService::stop(provider);
}
