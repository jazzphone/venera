#!/bin/bash
# gesture-sample (stage 5c): sample WindowServer and dragtest (macOS `sample`, 4 s) during one gesture.
#   tools/gesture-sample.sh drag|resize|scroll|minimize   -> build/pull/ws-GESTURE.txt, build/pull/app-GESTURE.txt
set -u
G=${1:-resize}
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=pve-host -i ~/.ssh/vgpu_host_key)
H=root@pve-host
case $G in scroll|minimize) MODE=$G ;; *) MODE= ;; esac
"${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'pkill -x dragtest; U=\$(id -u dev); cd /var/tmp/vgpu; (launchctl asuser \$U sudo -u dev ./dragtest 60 $MODE >/dev/null 2>&1 &); sleep 4' 30" >/dev/null
case $G in
drag) "${SSH[@]}" $H "(python3 /root/vgpu/qmpinput.py 108 drag 520 216 9 140 >/dev/null 2>&1 &)" ;;
resize) "${SSH[@]}" $H "(python3 /root/vgpu/qmpinput.py 108 drag 838 648 9 100 >/dev/null 2>&1 &)" ;;
esac
"${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'sleep 1; sample WindowServer 4 -file /var/tmp/ws-$G.txt >/dev/null 2>&1 & sample dragtest 4 -file /var/tmp/app-$G.txt >/dev/null 2>&1; wait; sleep 5; pkill -x dragtest' 60" >/dev/null
tools/deploy.sh pull "/var/tmp/*-$G.txt" >/dev/null 2>&1
ls build/pull/*-$G.txt
