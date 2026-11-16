#!/bin/sh
# Runs in VM 108 as root, from the transfer disk (tools/deploy.sh metal / mtl). Stage 4a.
#   metal-vm.sh install    VirtioGPUMetal.bundle -> /Library/GPUBundles, tools -> /var/tmp/vgpu
#   metal-vm.sh arm|disarm publish / withdraw MetalPluginName on VirtioGPUAccel (until the next boot)
#   metal-vm.sh probe      mtlprobe as the console user, then the plugin's log
X=/Volumes/VGPU
T=/var/tmp/vgpu
case "$1" in
install)
  set -e
  rm -rf /tmp/vgmetal && mkdir -p /tmp/vgmetal && tar -xzf $X/vgmetal.tgz -C /tmp/vgmetal
  mkdir -p /Library/GPUBundles $T
  if [ -L /Library/GPUBundles/VirtioGPUMetal.bundle ]; then
    # 5d: the driver lives on the system volume (packaging/sysvol.sh): a new copy there, a new snapshot, a reboot
    sh $X/sysvol.sh install /tmp/vgmetal/VirtioGPUMetal.bundle && echo "on the system volume: reboot to load it"
    # and the copy the watcher keeps (packaging/venera-watch.sh): it must match, or the watcher switches to it
    if [ -d /Library/GPUBundles/Venera ]; then
      rm -rf /Library/GPUBundles/Venera/VirtioGPUMetal.bundle
      ditto /tmp/vgmetal/VirtioGPUMetal.bundle /Library/GPUBundles/Venera/VirtioGPUMetal.bundle
    fi
  else
    rm -rf /Library/GPUBundles/VirtioGPUMetal.bundle
    mv /tmp/vgmetal/VirtioGPUMetal.bundle /Library/GPUBundles/
    chown -R root:wheel /Library/GPUBundles/VirtioGPUMetal.bundle
    chmod -R go-w,a+rX /Library/GPUBundles/VirtioGPUMetal.bundle
  fi
  for f in /tmp/vgmetal/*; do [ -d "$f" ] || cp "$f" $T/; done && chmod 755 $T $T/mtl* $T/acceltest && chmod 644 $T/*.metallib
  sudo -u _windowserver test -r /Library/GPUBundles/VirtioGPUMetal.bundle/Contents/MacOS/VirtioGPUMetal && echo "readable by _windowserver"
  ls -la /Library/GPUBundles /Library/GPUBundles/VirtioGPUMetal.bundle/Contents/*
  ;;
devinstall)   # 5d: the bundle in a writable folder, /Library/GPUBundles pointed at it: new processes load it, no reboot
  # (sandboxed ones, Safari's GPU process, refuse it; `install` puts it on the system volume for them)
  set -e
  D=/Library/GPUBundles/Venera/dev   # under /Library/GPUBundles: WindowServer (at the next boot) can load it too
  rm -rf /tmp/vgmetal && mkdir -p /tmp/vgmetal "$D" $T && tar -xzf $X/vgmetal.tgz -C /tmp/vgmetal
  rm -rf "$D/VirtioGPUMetal.bundle" && mv /tmp/vgmetal/VirtioGPUMetal.bundle "$D/"
  chown -R root:wheel "$D/VirtioGPUMetal.bundle" && chmod -R go-w,a+rX "$D/VirtioGPUMetal.bundle"
  for f in /tmp/vgmetal/*; do [ -d "$f" ] || cp "$f" $T/; done
  [ -L /Library/GPUBundles/VirtioGPUMetal.bundle ] || [ ! -e /Library/GPUBundles/VirtioGPUMetal.bundle ] || {
    echo "/Library/GPUBundles/VirtioGPUMetal.bundle is a folder: not replacing it"; exit 1; }
  ln -sfn "$D/VirtioGPUMetal.bundle" /Library/GPUBundles/VirtioGPUMetal.bundle
  ls -la /Library/GPUBundles/VirtioGPUMetal.bundle
  ;;
sysinstall)   # back to the system-volume copy (packaging/sysvol.sh install made it)
  ln -sfn /System/Library/Extensions/VirtioGPUMetal.bundle /Library/GPUBundles/VirtioGPUMetal.bundle
  ls -la /Library/GPUBundles/VirtioGPUMetal.bundle
  ;;
arm | disarm | wsarm | withdraw | legacy)
  $T/acceltest "$@"
  ;;
ws) # stage 5a: WindowServer's state: its pid, the accelerator's arm state, the plugin's and CoreDisplay's last lines
  pgrep -l WindowServer || echo "no WindowServer"
  ioreg -w0 -rc VirtioGPUAccel -d1 | grep -E '"(VirtioGPU|MetalPlugin|IOAccelDisplayPipe)' | cut -c1-160
  ioreg -w0 -rc VirtioGPUFramebuffer -d1 | grep -E '"VirtioGPU' | cut -c1-160
  ls -t /Library/Logs/DiagnosticReports/ | grep -m5 WindowServer
  log show --last "${2:-2m}" --predicate 'subsystem == "local.homelab.VirtioGPUMetal" OR (process == "WindowServer" AND (eventMessage CONTAINS[c] "compositor" OR eventMessage CONTAINS "display pipe" OR eventMessage CONTAINS "MetalDevice")) OR (process == "ReportCrash" AND eventMessage CONTAINS "ASI found [libsystem_c")' 2>/dev/null | cut -c1-260 | tail -${3:-40}
  ;;
compute) # stage 4b: mtlcompute (allow-listed by VGMTL_ENABLE), then the plugin's log
  rm -f /var/tmp/VirtioGPUMetal.log
  cd $T && sudo -u dev env VGMTL_ENABLE=1 ./mtlcompute compute.metallib 2>&1; echo "mtlcompute exit $?"
  echo "== plugin log"; cat /var/tmp/VirtioGPUMetal.log 2>/dev/null | tail -40
  ;;
tool) # tool NAME [ARGS]: one of the test tools as the console user (allow-listed by VGMTL_ENABLE), then the log
  shift
  rm -f /var/tmp/VirtioGPUMetal.log
  cd $T && sudo -u dev env VGMTL_ENABLE=1 VGMTL_TRACE=${VGMTL_TRACE:-0} ./"$@" 2>&1; echo "$1 exit $?"
  echo "== plugin log"; cat /var/tmp/VirtioGPUMetal.log 2>/dev/null | tail -40
  ;;
window) # window [SECONDS]: mtlwindow in dev's GUI session, a screenshot halfway (/var/tmp/vgwin.png), then the log
  rm -f /var/tmp/VirtioGPUMetal.log /var/tmp/vgwin.png /var/tmp/vgframe.png /var/tmp/mtlwindow.out
  U=$(id -u dev); S=${2:-8}
  cd $T && launchctl asuser $U sudo -u dev env VGMTL_ENABLE=1 ./mtlwindow $S render.metallib > /var/tmp/mtlwindow.out 2>&1 &
  sleep $(( S / 2 + 2 ))
  launchctl asuser $U screencapture -x /var/tmp/vgwin.png; echo "screenshot $?"
  wait; cat /var/tmp/mtlwindow.out
  echo "== plugin log"; grep -v "^$" /var/tmp/VirtioGPUMetal.log 2>/dev/null | grep -v "pull\|sync" | tail -30
  ;;
render) # stage 4c: mtlrender, then the plugin's log
  rm -f /var/tmp/VirtioGPUMetal.log
  cd $T && sudo -u dev env VGMTL_ENABLE=1 VGMTL_TRACE=${VGMTL_TRACE:-0} ./mtlrender render.metallib 2>&1; echo "mtlrender exit $?"
  echo "== plugin log"; cat /var/tmp/VirtioGPUMetal.log 2>/dev/null | tail -40
  ;;
refused) # a process the allow-list doesn't name (mtlprobe under another name): Metal must list nothing, no crash
  rm -f /var/tmp/VirtioGPUMetal.log
  cp $T/mtlprobe $T/notlisted && cd $T && sudo -u dev ./notlisted 2>&1; echo "notlisted exit $?"
  echo "== plugin log"; cat /var/tmp/VirtioGPUMetal.log 2>/dev/null
  ;;
health) # after a probe: Venus contexts closed, no user clients left, WindowServer's pid, new crash reports
  echo "== core ctx lines"; ioreg -w0 -r -c VirtioGPU -a | plutil -extract 0.ProbeLog xml1 -o - - 2>/dev/null | grep -E "ctx [0-9]+ (closed|open)|context" | tail -6
  echo "== VirtioGPUUserClient instances: $(ioreg -w0 -r -c VirtioGPUUserClient | grep -c '+-o')"
  echo "== accelerator children"; ioreg -w0 -rc VirtioGPUAccel -d2 | grep '+-o' | cut -c1-110
  echo "== WindowServer"; ps -axo pid,etime,command | grep '[W]indowServer' | cut -c1-90
  echo "== crash reports (newest)"; ls -t /Library/Logs/DiagnosticReports /Users/dev/Library/Logs/DiagnosticReports 2>/dev/null | grep -v shutdown_stall | head -8
  echo "== processes that loaded the plugin (os_log, last 30 min)"
  log show --last 30m --style compact --predicate 'subsystem == "local.homelab.VirtioGPUMetal"' 2>/dev/null | grep -v '^Timestamp' | sed -E 's/^[^ ]+ [^ ]+ +[A-Za-z]+ +//' | sed -E 's/\[[0-9]+:[0-9a-f]+\]//' | sort | uniq -c | sort -rn | head -15
  ;;
probe)
  rm -f /var/tmp/VirtioGPUMetal.log
  cd $T && sudo -u dev env VGMTL_LOG=1 ./mtlprobe 2>&1; echo "mtlprobe exit $?"
  echo "== plugin log"; cat /var/tmp/VirtioGPUMetal.log 2>/dev/null
  echo "== Metal / IOAccel log (last 2 min)"
  log show --last 2m --style compact --predicate '(process == "mtlprobe") OR (sender == "IOAcceleratorFamily2")' 2>/dev/null | grep -v '^Timestamp' | grep -viE 'activity|signpost' | cut -c1-220 | tail -40
  ;;
*)
  echo "usage: $0 install | arm [NAME [CLASS]] | disarm | probe | compute | render | tool NAME [ARGS] | window [SECONDS] | refused | health"; exit 2
  ;;
esac
