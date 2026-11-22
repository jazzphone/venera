#!/bin/sh
# streamprobe.sh (round 23), in the VM as root: build/streamprobe.dylib inside Apple's ScreensharingAgent, as a Screen
# Sharing client's reader with nobody connected, for SECS seconds; prints its report.
#   streamprobe.sh USER LABEL SECS [VAR=VALUE ...]      (VG_SP_... settings: tools/streamprobe.m)
#   streamprobe.sh --start USER LABEL SECS [...]        start it and return (drive the screen meanwhile)
#   streamprobe.sh --wait LABEL                         wait for it to end, print its report
# The dylib is /var/tmp/vgpu/streamprobe.dylib; the report and images go to /var/tmp/vgpu/sp/sp-LABEL*. Launch
# constraints let only Apple's own job (com.apple.screensharing.agent in USER's session) start the agent, so the job's
# next launch gets the library (launchctl debug: that one launch only) and is kickstarted. Not while someone is
# connected (the agent would be the probe, not their session's), and AMFI must be off for the library to load.
D=/var/tmp/vgpu
start() {
  U=$(id -u "$1") || exit 1; L=$2; S=$3; shift 3
  J=gui/$U/com.apple.screensharing.agent
  if netstat -an -p tcp | grep -qE '\.5900 .*ESTABLISHED'; then echo "someone is connected: not now"; exit 1; fi
  pgrep -x ScreensharingAgent >/dev/null && { echo "ScreensharingAgent is running already"; exit 1; }
  pkill -f "launchctl debug $J"
  mkdir -p $D/sp && chmod 1777 $D/sp
  rm -f $D/sp/sp-$L.txt $D/sp/sp-$L-* $D/sp/err.txt
  # launchctl debug waits for the launch it configures: in the background, then the kickstart
  (launchctl debug $J --stderr $D/sp/err.txt --environment DYLD_INSERT_LIBRARIES=$D/streamprobe.dylib \
    VG_SP_SECS=$S VG_SP_OUT=$D/sp/sp-$L "$@" >/dev/null 2>&1 &)
  sleep 0.5
  launchctl kickstart $J >/dev/null || exit 1
  for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x ScreensharingAgent >/dev/null && return 0; sleep 0.2; done
  echo "the agent did not start"; exit 1
}
wait_report() {
  for i in $(seq 1 120); do pgrep -x ScreensharingAgent >/dev/null || break; sleep 1; done
  pgrep -x ScreensharingAgent >/dev/null && echo "the agent is still running"
  pkill -f "launchctl debug gui/"
  cat $D/sp/sp-$1.txt 2>/dev/null || { echo "no report"; tail -5 $D/sp/err.txt 2>/dev/null; }
}
case $1 in
  --start) shift; start "$@" ;;
  --wait) wait_report "$2" ;;
  *) L=$2; start "$@"; wait_report "$L" ;;
esac
