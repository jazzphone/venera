#!/bin/bash
# fetch-compare (stage 5c round 6): boot with framebuffer fetch MODE (0 copies, 4 in place), take a Cmd-Shift-3
# screenshot of the idle desktop and measure a drag with GPU timings; snapshots land in build/bench/fetchMODE-idle.png for pngdiff.
#   tools/fetch-compare.sh MODE
set -u
M=${1:?mode}
. "$(dirname "$0")/host.sh"
"${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'echo $M > /Library/GPUBundles/VirtioGPUMetal-fetchmode; touch /Library/GPUBundles/VirtioGPUMetal-gputime; (sleep 1; shutdown -r now) >/dev/null 2>&1 &' 20" >/dev/null
sleep 70
"${SSH[@]}" $H 'for i in $(seq 1 40); do qm guest cmd 108 ping >/dev/null 2>&1 && break; sleep 5; done; sleep 70'
# the idle desktop doesn't present; a Cmd-Shift-3 screenshot composites the whole screen with the same shaders
"${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'log show --last 3m --predicate \"subsystem == \\\"local.homelab.VirtioGPUMetal\\\"\" 2>/dev/null | grep -E \"framebuffer fetch: mode|fetch (in place|by copies)\" | cut -c120-260 | sort -u | head -3; rm -f /Users/dev/Desktop/Screenshot*' 40"
"${SSH[@]}" $H "qm sendkey 108 meta_l-shift-3; sleep 9; bash /root/vgpu/vm-remote.sh run 'cp /Users/dev/Desktop/Screenshot*.png /var/tmp/fetch$M-idle.png; rm -f /Users/dev/Desktop/Screenshot*' 30"
mkdir -p build/bench
tools/deploy.sh pull "/var/tmp/fetch$M-idle.png" >/dev/null 2>&1 && mv build/pull/fetch$M-idle.png build/bench/
tools/drag-perf.sh 7 drag 2>&1 | grep -E "frame gaps|GPU time|commit->done|commit -> GPU|framebuffer fetch" | sed 's/ | /\n   /g' | grep -v "flip took"
ls build/bench/fetch$M-idle.png
