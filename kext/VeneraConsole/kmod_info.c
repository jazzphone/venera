// The kmod_info record Xcode generates for kext targets (KextName_info.c). The kernel and
// OpenCore's prelinker read it to name, version and start the kext. IOKit drivers start through
// their personalities, so the real start/stop routines are null.
#include <mach/mach_types.h>

extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);

__attribute__((visibility("default")))
KMOD_EXPLICIT_DECL(local.homelab.VeneraConsole, "0.1.0", _start, _stop)

__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
