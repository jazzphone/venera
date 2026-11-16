#!/bin/bash
# apptest (stage 5d, app Metal): give one app our Metal device and look at it.
#   tools/apptest.sh APP [PROCESS...] [-- SECONDS]
# Writes the allow-list (/Library/GPUBundles/VirtioGPUMetal-allow.txt) with the PROCESS names (default: the app's
# name), relaunches APP as the console user, waits SECONDS (default 12), takes a screenshot with Cmd-Shift-3 (QMP, so
# no Screen Recording permission is involved) and pulls it to build/apptest/APP.png, then prints the Metal driver's
# log for those processes and any new crash reports. `tools/apptest.sh none` empties the allow-list.
set -u
APP=$1; shift
PROCS=(); WAIT=12
while [ $# -gt 0 ]; do
  if [ "$1" = -- ]; then WAIT=$2; break; fi
  PROCS+=("$1"); shift
done
[ ${#PROCS[@]} -eq 0 ] && PROCS=("$APP")
cd "$(dirname "$0")/.." || exit 1
. tools/host.sh
OUT=build/apptest; mkdir -p $OUT
run() { "${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run '$1' ${2:-60}" 2>&1; }
if [ "$APP" = none ]; then
  run "rm -f /Library/GPUBundles/VirtioGPUMetal-allow.txt" 30
  exit 0
fi
LIST=$(printf '%s\\n' "${PROCS[@]}")
RX=$(IFS='|'; echo "${PROCS[*]}")
run "printf \"$LIST\" > /Library/GPUBundles/VirtioGPUMetal-allow.txt; pkill -x \"$APP\"; rm -f /Users/dev/Desktop/Screenshot*; date +%s > /var/tmp/apptest.t0; sleep 1; U=\$(id -u dev); launchctl asuser \$U sudo -u dev open -a \"$APP\"" 30 >/dev/null
sleep "$WAIT"
"${SSH[@]}" $H "qm sendkey 108 meta_l-shift-3"
sleep 4
# the screenshot's name has a narrow no-break space before AM/PM: renamed in the guest before the pull
F=$(run "F=\$(ls -t /Users/dev/Desktop/Screenshot*.png 2>/dev/null | head -1); [ -n \"\$F\" ] && mv \"\$F\" /var/tmp/apptest.png && echo ok" 30 | tail -1 | tr -d '\r')
if [ "$F" = ok ]; then
  rm -f build/pull/apptest.png
  tools/deploy.sh pull /var/tmp/apptest.png >/dev/null 2>&1 && mv build/pull/apptest.png "$OUT/$APP.png" && sips -Z 1000 "$OUT/$APP.png" >/dev/null
  echo "screenshot: $OUT/$APP.png"
else
  echo "no screenshot"
fi
S=$(($(date +%s) - $(run "cat /var/tmp/apptest.t0" 30 | tail -1 | tr -d '\r') + 5))
run "sh /var/tmp/vgpu/plog.sh $((WAIT + 40)) \"($RX)(\\\\[[0-9]+\\\\])?: \" 80" 90 | sed -E 's/^.{0,40}[0-9]+ +0 +//; s/\(VirtioGPUMetal\) \[local.homelab.VirtioGPUMetal:plugin\] //' | cut -c1-230
run "find /Library/Logs/DiagnosticReports /Users/dev/Library/Logs/DiagnosticReports -newer /var/tmp/apptest.t0 -name \"*.ips\" 2>/dev/null" 30
