#!/bin/bash
# redeploy (stage 5d): build and install the Metal driver (on the system volume when it lives there), reboot VM 108,
# wait for the desktop, keep the session awake, and say whether it came back locked.
#   tools/redeploy.sh [--no-build]
set -u
cd "$(dirname "$0")/.." || exit 1
. tools/host.sh
run() { "${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run '$1' ${2:-60}" 2>&1; }
if [ "${1:-}" != --no-build ]; then
  tools/deploy.sh metal 2>&1 | grep -E "sysvol|error|reboot" | head -5
fi
# qm reboot returns before the guest is down: wait for a new boot time, then for the desktop
B0=$(run "sysctl -n kern.boottime | cut -d, -f1" 20 | tr -d '\r' | tail -1)
"${SSH[@]}" $H "qm reboot 108 --timeout 180" >/dev/null 2>&1
for i in $(seq 1 60); do
  sleep 10
  r=$(run "sysctl -n kern.boottime | cut -d, -f1; pgrep -x Dock >/dev/null && pgrep -x WindowServer" 20 | tr -d '\r')
  B=$(echo "$r" | grep -m1 "sec =")
  if [ -n "$B" ] && [ "$B" != "$B0" ] && echo "$r" | tail -1 | grep -qE '^[0-9]+$'; then echo "up after $((i * 10)) s"; break; fi
done
run "U=\$(id -u dev); (launchctl asuser \$U sudo -u dev caffeinate -dimu -t 28800 >/dev/null 2>&1 &); sleep 15; echo locked \$(ioreg -n Root -d1 | grep -c ScreenIsLocked); ls -la /System/Library/Extensions/VirtioGPUMetal.bundle/Contents/MacOS/VirtioGPUMetal 2>/dev/null | cut -c30-; ioreg -w0 -rc VirtioGPUAccel -d1 | grep -oE \"VirtioGPUBlobFlips.{0,40}\"" 60
