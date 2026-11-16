#!/bin/bash
# perfsum (stage 5d): the Metal driver's last 5-second cost summary per process (needs /Library/GPUBundles/VirtioGPUMetal-perf
# for processes other than WindowServer).   tools/perfsum.sh [PROCESS-REGEX] [SECONDS]
cd "$(dirname "$0")/.." || exit 1
. tools/host.sh
"${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'sh /var/tmp/vgpu/plog.sh ${2:-6} \"(${1:-.}).*(perf 5 s|pool miss)\" 80' 60" |
  grep -oE "[A-Za-z.]+: \(VirtioGPUMetal\).*" | sed -E 's/\(VirtioGPUMetal\) \[[^]]*\] //; s/, [0-9.]+ MB, / /; s/perf 5 s: //' | cut -c1-150
