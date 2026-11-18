#!/bin/bash
# drag-perf (stage 5c): one gesture over dragtest + WindowServer's plugin counters and the kext's pacing.
#   tools/drag-perf.sh [SECONDS] [drag|resize|scroll|minimize]   (drag and resize injected, scroll and minimize animated)
set -u
T=${1:-8}
G=${2:-drag}
case $G in scroll|minimize) MODE=$G ;; *) MODE= ;; esac
. "$(dirname "$0")/host.sh"
"${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'touch /Library/GPUBundles/VirtioGPUMetal-perf; pkill -x dragtest; U=\$(id -u dev); cd /var/tmp/vgpu; (launchctl asuser \$U sudo -u dev ./dragtest 60 $MODE >/dev/null 2>&1 &); sleep 4; /var/tmp/vgpu/acceltest pacereset >/dev/null; date \"+%Y-%m-%d %H:%M:%S\" > /var/tmp/t0' 30" >/dev/null
case $G in
drag) "${SSH[@]}" $H "python3 /root/vgpu/qmpinput.py 108 drag 520 216 $T 140" >/dev/null ;;
resize) "${SSH[@]}" $H "python3 /root/vgpu/qmpinput.py 108 drag 838 648 $T 100" >/dev/null ;;
*) sleep "$T" ;;
esac
sleep 6
"${SSH[@]}" $H 'bash /root/vgpu/vm-remote.sh run "/var/tmp/vgpu/acceltest pace | tail -1; P=\$(pgrep WindowServer); log show --start \"\$(cat /var/tmp/t0)\" --predicate \"processID == \$P AND eventMessage CONTAINS \\\"perf 5\\\"\" 2>/dev/null | grep -oE \"perf 5 s: [^|]*\" | awk -F\" x,\" \"{split(\\\$1,a,\\\" \\\"); k=\\\$1; sub(/ [0-9]+\$/,\\\"\\\",k); n[k]+=a[length(a)]; split(\\\$2,b,\\\",\\\"); t[k]+=b[2]+0} END {for (k in n) printf \\\"  %-66s %6d x %7.2f ms each\\\\n\\\", k, n[k], t[k]/n[k]}\" | sort; pkill -x dragtest" 60'
