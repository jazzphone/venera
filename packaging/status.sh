#!/bin/bash
# Venera status: what runs, in the macOS guest (root for the logs: sudo ./status.sh).
echo "Venera $(cat '/Library/Application Support/Venera/VERSION' 2>/dev/null || echo '(not installed by install.sh)')"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)); boot-args: $(nvram boot-args 2>/dev/null | cut -f2-)"
echo
echo "== kexts"
kmutil showloaded 2>/dev/null | grep -E 'homelab\.VirtioGPU' | awk '{print "  " $6, $7}' || true
[ -d /Library/GPUBundles/VirtioGPUMetal.bundle ] && echo "  Metal driver: /Library/GPUBundles/VirtioGPUMetal.bundle" ||
  echo "  Metal driver: not installed"
echo
echo "== display"
ioreg -w0 -rc VirtioGPUAccel -d1 2>/dev/null | grep -E '"(VirtioGPUArmState|VirtioGPUGuard|VirtioGPUGuardWhy|MetalPluginName|VirtioGPUBlobFlips|VirtioGPUPipeTiming)"' |
  sed 's/^ */  /' | cut -c1-200
system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset|Metal|Resolution|Vendor' | sed 's/^ */  /'
echo
echo "== WindowServer"
P=$(pgrep -x WindowServer)
echo "  pid $P, started $(ps -o lstart= -p "$P" 2>/dev/null)"
ls -t /Library/Logs/DiagnosticReports/ 2>/dev/null | grep -m3 WindowServer | sed 's/^/  crash report: /'
echo
echo "== the Metal driver's log (last 2 minutes)"
log show --last 2m --predicate 'subsystem == "local.homelab.VirtioGPUMetal"' 2>/dev/null | grep -v 'perf 5 s' |
  cut -c1-220 | tail -12
