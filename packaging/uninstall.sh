#!/bin/bash
# Venera uninstaller: run inside the macOS guest, as root.
#
#   sudo ./uninstall.sh [--oc /Volumes/EFI] [--no-opencore] [--dry-run]
#
# Removes the Metal driver, the Venera app, the guest agent (mac-guest-agent back if Venera's took its place), the two
# Auxiliary KC kexts (and rebuilds the Auxiliary KC from what is left in
# /Library/Extensions), and in OpenCore the VirtioGPU.kext entry and folder and vgpuaccel from boot-args (config.plist
# backed up first). SIP and amfi_get_out_of_my_way are left as they are: put them back from a config.plist backup
# (EFI/OC/config.plist.venera-*) or by hand. Then reboot: the VM is back on the firmware's framebuffer.
set -u
OC_ROOT=
NO_OC=0
DRY=0
GUID=7C436110-AB2A-4BBB-A880-FE41995C9F82
MOUNTED=

say() { printf '%s\n' "$*"; }
cleanup() { [ -n "$MOUNTED" ] && diskutil unmount "$MOUNTED" >/dev/null 2>&1; MOUNTED=; }
die() {
  printf 'error: %s\n' "$*" >&2
  cleanup
  exit 1
}
run() {
  say "  + $*"
  [ $DRY = 1 ] || "$@"
}

while [ $# -gt 0 ]; do
  case $1 in
  --oc) OC_ROOT=$2; shift ;;
  --no-opencore) NO_OC=1 ;;
  --dry-run) DRY=1 ;;
  -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
  *) die "unknown option $1 (--help)" ;;
  esac
  shift
done
[ "$(id -u)" = 0 ] || die "run as root: sudo $0"

# ---- the app, the watcher, the Metal driver and its files ------------------------------------------------------------
CUID=$(stat -f %u /dev/console)
if [ -f /Library/LaunchAgents/local.venera.helper.plist ]; then
  [ $DRY = 1 ] || { [ "$CUID" != 0 ] && launchctl bootout "gui/$CUID/local.venera.helper" 2>/dev/null; }
  run rm -f /Library/LaunchAgents/local.venera.helper.plist
fi
[ $DRY = 1 ] || pkill -x Venera 2>/dev/null
[ -d /Applications/Venera.app ] && run rm -rf /Applications/Venera.app
# an install's second pass that hasn't run yet
if [ -f /Library/LaunchDaemons/local.venera.finish.plist ]; then
  run rm -f /Library/LaunchDaemons/local.venera.finish.plist "/Library/Application Support/Venera/finish-args" "/Library/Application Support/Venera/finish-tries"
fi
if [ -f /Library/LaunchDaemons/local.venera.watch.plist ]; then
  [ $DRY = 1 ] || launchctl bootout system/local.venera.watch 2>/dev/null
  run rm -f /Library/LaunchDaemons/local.venera.watch.plist
fi
if [ -d /System/Library/Extensions/VirtioGPUMetal.bundle ]; then
  if [ -x "/Library/Application Support/Venera/sysvol.sh" ] &&
    csrutil authenticated-root status 2>/dev/null | grep -qi disabled; then
    say "system volume: taking the driver out (a new snapshot, after the reboot)"
    run "/Library/Application Support/Venera/sysvol.sh" remove
  else
    say "warning: the driver stays in /System/Library/Extensions until authenticated root is off (then:"
    say "  sudo sysvol.sh remove); nothing loads it with the rest gone"
  fi
fi
run rm -rf /Library/GPUBundles/VirtioGPUMetal.bundle /Library/GPUBundles/Venera
for f in /Library/GPUBundles/VirtioGPUMetal-*; do [ -e "$f" ] && run rm -f "$f"; done
# translated shaders (and WindowServer's display snapshots) every process kept, in its own cache folder
# These folders are the users': root never walks one with rm (a user could swap a folder for a link mid-delete and
# make it remove something else), the folder's owner does. Root's own, under /private/var/folders/zz, is root's to remove.
while IFS= read -r d; do
  [ -n "$d" ] && [ -d "$d" ] && [ ! -L "$d" ] || continue
  o=$(stat -f %u "$d" 2>/dev/null) || continue
  if [ "$o" != 0 ]; then
    run sudo -u "#$o" /bin/rm -rf "$d"
  else
    case "$d" in /private/var/folders/zz/*) run rm -rf "$d" ;; esac
  fi
done < <(find /private/var/folders /Users/*/Library/Containers -type d -name local.homelab.VirtioGPUMetal -prune 2>/dev/null)
# the guest agent, stopped by a one-time job once this has finished (it may be carrying this very uninstall: stopping
# it now would end this script with it), and mac-guest-agent back if Venera's took its place
if [ -f /Library/LaunchDaemons/local.venera.agent.plist ]; then
  run rm -f /Library/LaunchDaemons/local.venera.agent.plist
  START=""
  if [ -f "/Library/Application Support/Venera/replaced/com.macos.guest-agent.plist" ]; then
    run mv "/Library/Application Support/Venera/replaced/com.macos.guest-agent.plist" /Library/LaunchDaemons/
    START="launchctl bootstrap system /Library/LaunchDaemons/com.macos.guest-agent.plist;"
    say "guest agent: mac-guest-agent back once this has finished"
  fi
  SW=/Library/LaunchDaemons/local.venera.agent-swap.plist
  if [ $DRY = 0 ]; then
    cat >"$SW" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.venera.agent-swap</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
  <string>sleep 10; while pgrep -f "Venera/release/install.sh|uninstall.sh" >/dev/null; do sleep 2; done; launchctl bootout system/local.venera.agent 2>/dev/null; sleep 1; $START rm -f '$SW'; launchctl bootout system/local.venera.agent-swap</string></array>
  <key>RunAtLoad</key><true/>
  <key>LaunchOnlyOnce</key><true/>
</dict></plist>
PL
    chown root:wheel "$SW" && chmod 644 "$SW" && launchctl bootstrap system "$SW"
  fi
  say "guest agent: local.venera.agent stops once this has finished"
fi
run rm -rf "/Library/Application Support/Venera"
# the installer package's receipts (Install Venera.pkg), so a reinstall starts clean
for r in $(pkgutil --pkgs 2>/dev/null | grep '^local\.homelab\.venera\.'); do run pkgutil --forget "$r" >/dev/null; done

# ---- the Auxiliary KC ----------------------------------------------------------------------------------------------
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
for k in VirtioGPUFramebuffer VirtioGPUAccel; do
  [ -d "/Library/Extensions/$k.kext" ] && run rm -rf "/Library/Extensions/$k.kext"
done
if [ $DRY = 0 ]; then
  if ls -d /Library/Extensions/*.kext >/dev/null 2>&1; then
    say "Auxiliary KC: rebuilding from what is left in /Library/Extensions"
    KLOG=$(mktemp /private/var/run/venera-kmutil.XXXXXX) || KLOG=/dev/null   # not a fixed /tmp name (a planted symlink)
    kmutil create -n aux --volume-root / --allow-missing-kdk --kernel /System/Library/Kernels/kernel \
      -B /System/Library/KernelCollections/BootKernelExtensions.kc \
      -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
      --repository /Library/Extensions -A "$KC.venera-new" -z >"$KLOG" 2>&1 &&
      mv -f "$KC.venera-new" "$KC" ||
      say "warning: kmutil failed ($KLOG); the old Auxiliary KC still lists the driver's kexts, which
  then fail to load harmlessly. Rebuild it once the other kexts are sorted out."
  elif [ -f "$KC" ]; then
    say "Auxiliary KC: no third-party kexts left; removing it"
    rm -f "$KC"
  fi
fi

# ---- OpenCore ------------------------------------------------------------------------------------------------------
pl() { plutil "$@" "$CONFIG"; }
if [ $NO_OC = 0 ]; then
  if [ -z "$OC_ROOT" ]; then
    for p in $(diskutil list | awk '/ EFI / {print $NF}'); do
      mp=$(diskutil info "$p" | awk -F': *' '/Mount Point/ {print $2}')
      fresh=
      if [ -z "$mp" ]; then
        diskutil mount "$p" >/dev/null 2>&1 || continue
        mp=$(diskutil info "$p" | awk -F': *' '/Mount Point/ {print $2}')
        fresh=$p
      fi
      if [ -n "$mp" ] && [ -f "$mp/EFI/OC/config.plist" ] && [ -z "$OC_ROOT" ]; then
        OC_ROOT=$mp
        MOUNTED=$fresh
      elif [ -n "$fresh" ]; then
        diskutil unmount "$fresh" >/dev/null 2>&1
      fi
    done
  fi
  if [ -z "$OC_ROOT" ]; then
    say "OpenCore: not found; remove VirtioGPU.kext and vgpuaccel from its config.plist yourself"
  else
    CONFIG=$OC_ROOT/EFI/OC/config.plist
    BACKUP=$CONFIG.venera-$(date +%Y%m%d-%H%M%S)
    run cp "$CONFIG" "$BACKUP"
    N=$(pl -extract Kernel.Add raw -o - 2>/dev/null || echo 0)
    i=$((N - 1))
    # VeneraVideo stays while the host still gives this VM its video device (1af4:1110): without it, Apple's VirtIO
    # driver takes the device and hangs on it, and the boot never publishes the OpenCore disk's partitions (round 11)
    KEEP_VIDEO=0
    if ioreg -r -c IOPCIDevice -d1 -w0 2>/dev/null | grep -q '"pci1af4,1110"'; then
      KEEP_VIDEO=1
      say "OpenCore: keeping VeneraVideo.kext: the host still gives this VM its video device. Take it out on the host"
      say "  (install-host.sh --remove-vm VMID), start the VM again, then run this again to remove VeneraVideo too."
    fi
    while [ $i -ge 0 ]; do   # from the end: removing shifts the ones after
      case "$(pl -extract Kernel.Add.$i.BundlePath raw -o - 2>/dev/null)" in
      VirtioGPU.kext) run pl -remove Kernel.Add.$i ;;
      VeneraVideo.kext) [ $KEEP_VIDEO = 1 ] || run pl -remove Kernel.Add.$i ;;
      esac
      i=$((i - 1))
    done
    run rm -rf "$OC_ROOT/EFI/OC/Kexts/VirtioGPU.kext"
    [ $KEEP_VIDEO = 1 ] || run rm -rf "$OC_ROOT/EFI/OC/Kexts/VeneraVideo.kext"
    OCARGS=$(pl -extract "NVRAM.Add.$GUID.boot-args" raw -o - 2>/dev/null)
    NEW=
    for a in $OCARGS; do
      case $a in vgpuaccel=* | vgpuflipms=* | vgpugl=* | -vgpu*) ;; *) NEW="$NEW $a" ;; esac
    done
    run pl -replace "NVRAM.Add.$GUID.boot-args" -string "${NEW# }"
    [ $DRY = 1 ] || plutil -lint "$CONFIG" >/dev/null || {
      cp "$BACKUP" "$CONFIG"
      die "config.plist didn't validate after the edit; restored the backup"
    }
    say "OpenCore: VirtioGPU.kext$([ $KEEP_VIDEO = 1 ] || echo " and VeneraVideo.kext") removed, boot-args \"${NEW# }\" (backup: $BACKUP)"
    cleanup
  fi
fi

say ""
say "Venera removed. Reboot to finish: sudo shutdown -r now"
