#!/bin/bash
# soak (stage 5c): drag, resize, scroll and minimize over dragtest for MINUTES, printing WindowServer's memory, the
# flip count and new crash reports after each cycle (a leak or a slowdown shows as a trend).
#   tools/soak.sh [MINUTES]
set -u
M=${1:-15}
. "$(dirname "$0")/host.sh"
run() { "${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run '$1' ${2:-60}" 2>&1; }
app() { run "pkill -x dragtest; U=\$(id -u dev); cd /var/tmp/vgpu; (launchctl asuser \$U sudo -u dev ./dragtest 600 $1 >/dev/null 2>&1 &); sleep 2" 30 >/dev/null; }
state() {
  run "P=\$(pgrep -x WindowServer); echo \"pid \$P rss \$((\$(ps -o rss= -p \$P) / 1024)) MB, \$(vm_stat | awk \"/Pages free/ {printf \\\"%d MB free\\\", \\\$3 * 4096 / 1048576}\"), \$(ioreg -r -c VirtioGPUAccel -l -d 1 | grep -oE \"[0-9]+ flips\"), crashes \$(ls /Library/Logs/DiagnosticReports | grep -c WindowServer)\"" 30
}
echo "start: $(state)"
end=$(($(date +%s) + M * 60))
n=0
while [ "$(date +%s)" -lt $end ]; do
  n=$((n + 1))
  app ""; "${SSH[@]}" $H "python3 /root/vgpu/qmpinput.py 108 drag 520 216 20 140" >/dev/null
  app ""; "${SSH[@]}" $H "python3 /root/vgpu/qmpinput.py 108 drag 838 648 20 100" >/dev/null
  app scroll; sleep 20
  app minimize; sleep 20
  echo "cycle $n $(date +%H:%M): $(state)"
done
run "pkill -x dragtest" 20 >/dev/null
echo "pacing: $(run '/var/tmp/vgpu/acceltest pace | tail -1' 20)"
