#!/bin/bash
# gesture-bench (stage 5c): drag, live resize, scroll and minimize on tools/dragtest's window (drag and resize as mouse
# gestures from the Proxmox host through VM 108's own QMP socket, tools/qmpinput.py; scroll and minimize animated by
# the app), with the kext's pacing histograms and a display snapshot taken during each.
#   tools/gesture-bench.sh [TAG] [SECONDS]  -> pacing printed, snapshots in build/bench/TAG-*.png
set -u
TAG=${1:-bench}
T=${2:-6}
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=pve-host -i ~/.ssh/vgpu_host_key)
H=root@pve-host
WSC=/var/folders/zz/zyxvpxvq6csfxvn_n00000b000002r/C/WindowServer/local.homelab.VirtioGPUMetal
run() { "${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run '$1' ${2:-60}" 2>&1; }
app() {   # MODE: (re)start dragtest
  run "pkill -x dragtest; U=\$(id -u dev); cd /var/tmp/vgpu; (launchctl asuser \$U sudo -u dev ./dragtest 60 $1 >/dev/null 2>&1 &); sleep 3" 30 >/dev/null
}
measure() {   # NAME SNAP SECONDS-TO-WAIT [QMPINPUT-ARGS...]
  local name=$1 n=$2 wait=$3; shift 3
  run "/var/tmp/vgpu/acceltest pacereset >/dev/null; echo $n > /Library/GPUBundles/VirtioGPUMetal-snap" 30 >/dev/null
  if [ $# -gt 0 ]; then "${SSH[@]}" $H "python3 /root/vgpu/qmpinput.py 108 $*" >/dev/null; else sleep "$wait"; fi
  printf "%-9s" "$name"
  run "/var/tmp/vgpu/acceltest pace | tail -1; cp $WSC/snap-$n.png /var/tmp/$TAG-$name.png 2>/dev/null; rm -f $WSC/snap-*.png" 30 \
    | sed 's/ | /\n         /g'
}
app ""
measure drag 301 0 drag 520 216 $T 140
app ""
measure resize 302 0 drag 838 648 $T 100
app scroll; sleep 1
measure scroll 303 $T
app minimize; sleep 1
measure minimize 304 $T
run "pkill -x dragtest" 30 >/dev/null
mkdir -p build/bench
tools/deploy.sh pull "/var/tmp/$TAG-*.png" >/dev/null 2>&1
for f in build/pull/$TAG-*.png; do [ -f "$f" ] && mv "$f" build/bench/; done
ls build/bench | grep "^$TAG-" | tr '\n' ' '; echo
