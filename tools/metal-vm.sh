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
  rm -rf /Library/GPUBundles/VirtioGPUMetal.bundle
  mv /tmp/vgmetal/VirtioGPUMetal.bundle /Library/GPUBundles/
  chown -R root:wheel /Library/GPUBundles/VirtioGPUMetal.bundle
  chmod -R go-w,a+rX /Library/GPUBundles/VirtioGPUMetal.bundle
  cp /tmp/vgmetal/mtlprobe /tmp/vgmetal/mtlcompute /tmp/vgmetal/compute.metallib /tmp/vgmetal/acceltest $T/ && chmod 755 $T $T/mtlprobe $T/mtlcompute $T/acceltest && chmod 644 $T/compute.metallib
  sudo -u _windowserver test -r /Library/GPUBundles/VirtioGPUMetal.bundle/Contents/MacOS/VirtioGPUMetal && echo "readable by _windowserver"
  ls -la /Library/GPUBundles /Library/GPUBundles/VirtioGPUMetal.bundle/Contents/*
  ;;
arm | disarm)
  $T/acceltest "$@"
  ;;
compute) # stage 4b: mtlcompute (allow-listed by VGMTL_ENABLE), then the plugin's log
  rm -f /var/tmp/VirtioGPUMetal.log
  cd $T && sudo -u dev env VGMTL_ENABLE=1 ./mtlcompute compute.metallib 2>&1; echo "mtlcompute exit $?"
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
  echo "usage: $0 install | arm [NAME [CLASS]] | disarm | probe | compute | refused | health"; exit 2
  ;;
esac
