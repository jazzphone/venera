#!/bin/bash
# Venera uninstaller: run inside the macOS guest, as root.
#
#   sudo ./uninstall.sh [--oc /Volumes/EFI] [--no-opencore] [--dry-run]
#
# Removes the Metal driver, the two Auxiliary KC kexts (and rebuilds the Auxiliary KC from what is left in
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

# ---- the watcher, the Metal driver and its files ---------------------------------------------------------------------
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
while IFS= read -r d; do
  [ -n "$d" ] && [ -d "$d" ] && run rm -rf "$d"
done < <(find /private/var/folders /Users/*/Library/Containers -type d -name local.homelab.VirtioGPUMetal -prune 2>/dev/null)
run rm -rf "/Library/Application Support/Venera"

# ---- the Auxiliary KC ----------------------------------------------------------------------------------------------
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
for k in VirtioGPUFramebuffer VirtioGPUAccel; do
  [ -d "/Library/Extensions/$k.kext" ] && run rm -rf "/Library/Extensions/$k.kext"
done
if [ $DRY = 0 ]; then
  if ls -d /Library/Extensions/*.kext >/dev/null 2>&1; then
    say "Auxiliary KC: rebuilding from what is left in /Library/Extensions"
    kmutil create -n aux --volume-root / --allow-missing-kdk --kernel /System/Library/Kernels/kernel \
      -B /System/Library/KernelCollections/BootKernelExtensions.kc \
      -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
      --repository /Library/Extensions -A "$KC.venera-new" -z >/tmp/venera-kmutil.log 2>&1 &&
      mv -f "$KC.venera-new" "$KC" ||
      say "warning: kmutil failed (/tmp/venera-kmutil.log); the old Auxiliary KC still lists the driver's kexts, which
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
    while [ $i -ge 0 ]; do   # from the end: removing shifts the ones after
      [ "$(pl -extract Kernel.Add.$i.BundlePath raw -o - 2>/dev/null)" = VirtioGPU.kext ] && run pl -remove Kernel.Add.$i
      i=$((i - 1))
    done
    run rm -rf "$OC_ROOT/EFI/OC/Kexts/VirtioGPU.kext"
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
    say "OpenCore: VirtioGPU.kext removed, boot-args \"${NEW# }\" (backup: $BACKUP)"
    cleanup
  fi
fi

say ""
say "Venera removed. Reboot to finish: sudo shutdown -r now"
