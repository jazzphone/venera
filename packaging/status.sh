#!/bin/bash
# Venera status: what runs, in the macOS guest (root for the logs: sudo ./status.sh).
echo "Venera $(cat '/Library/Application Support/Venera/VERSION' 2>/dev/null || echo '(not installed by install.sh)')"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)); boot-args: $(nvram boot-args 2>/dev/null | cut -f2-)"
echo
echo "== kexts"
kmutil showloaded 2>/dev/null | grep -E 'homelab\.VirtioGPU' | awk '{print "  " $6, $7}' || true
G=/Library/GPUBundles/VirtioGPUMetal.bundle
if [ -L "$G" ]; then
  echo "  Metal driver: $G -> $(readlink "$G")$([ -e "$G" ] || echo ' (MISSING)')"
elif [ -d "$G" ]; then
  echo "  Metal driver: $G"
else
  echo "  Metal driver: not installed"
fi
[ -d /System/Library/Extensions/VirtioGPUMetal.bundle ] && echo "  system-volume copy: yes (Safari's WebGL can load it)" ||
  echo "  system-volume copy: no (every app but Safari's WebGL)"
echo "  authenticated root: $(csrutil authenticated-root status 2>/dev/null | grep -qi disabled && echo off || echo on)"
[ -f /Library/LaunchDaemons/local.venera.finish.plist ] && echo "  install: finishes after the next restart (local.venera.finish)"
launchctl print system/local.venera.watch >/dev/null 2>&1 && echo "  watcher: local.venera.watch loaded" ||
  echo "  watcher: not loaded"
tail -2 "/Library/Application Support/Venera/watch.log" 2>/dev/null | sed 's/^/    /' 
if launchctl print system/local.venera.agent >/dev/null 2>&1; then
  echo "  guest agent: local.venera.agent loaded ($(tail -1 /var/log/venera-agent.log 2>/dev/null | cut -c21- | cut -c1-90))"
  ioreg -rc VeneraConsole -d1 -w0 2>/dev/null | sed -n 's/.*"VeneraConsolePorts" = (\(.*\))/    VeneraConsole ports: \1/p' 
  ioreg -rc VeneraBalloon -d1 -w0 2>/dev/null | sed -n 's/.*"VeneraBalloonState" = "\(.*\)"/    VeneraBalloon (Proxmox'"'"'s memory figure): \1/p'
elif [ -f /Library/LaunchDaemons/com.macos.guest-agent.plist ]; then echo "  guest agent: mac-guest-agent (not Venera's)"
else echo "  guest agent: none (Proxmox can't shut the VM down cleanly or show its addresses)"; fi
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
# Metal calls the driver doesn't have yet: answered with nil/0 (lenient mode) and logged once a process. What an app
# asked for that drew wrong or not at all is here; a report of these lines is what the driver needs next.
echo "== Metal calls the driver lacks (last day; app: call)"
L=$(log show --last 1d --style compact --predicate 'subsystem == "local.homelab.VirtioGPUMetal" AND eventMessage CONTAINS "LENIENT"' 2>/dev/null |
  sed -nE 's/^.* ([^ []+)\[[0-9]+:[0-9a-f]+\] .*LENIENT: (.*) not implemented.*/\1: \2/p' | sort | uniq -c | sort -rn | head -15)
[ -n "$L" ] && echo "$L" | sed 's/^ */  /' || echo "  none"
echo
echo "== the Metal driver's log (last 2 minutes)"
log show --last 2m --predicate 'subsystem == "local.homelab.VirtioGPUMetal"' 2>/dev/null | grep -v 'perf 5 s' |
  cut -c1-220 | tail -12
