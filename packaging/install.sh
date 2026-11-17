#!/bin/bash
# Venera installer: run inside the macOS guest, as root, from the unpacked release folder.
#
#   sudo ./install.sh [--level 4|2] [--video] [--no-app] [--oc /Volumes/EFI] [--no-opencore] [--set-security]
#                     [--no-system-volume] [--dry-run]
#
# What it does (each step says what it changed; nothing is downloaded):
#   1. checks the guest: x86_64 macOS 26, a virtio-gpu device, SIP and AMFI as the driver needs them
#   2. OpenCore: copies VirtioGPU.kext (the core, which must load from the Boot KC) into EFI/OC/Kexts, adds or enables
#      its Kernel > Add entry and sets vgpuaccel=LEVEL in OpenCore's boot-args (config.plist is backed up first); with
#      --video, VeneraVideo.kext too (hardware video decoding through the host: the host half is install-host.sh)
#   3. /Library/Extensions: VirtioGPUFramebuffer.kext and VirtioGPUAccel.kext, then rebuilds the Auxiliary KC
#   4. the Metal driver (over Venus): kept in /Library/GPUBundles/Venera, copied onto the system volume
#      (/System/Library/Extensions, a new blessed snapshot: sysvol.sh) where Safari's sandboxed graphics process can
#      load it, and /Library/GPUBundles/VirtioGPUMetal.bundle pointing at it; and the watcher (local.venera.watch),
#      which keeps it there across macOS updates, asking before it reinstalls
#   5. the Venera app (/Applications/Venera.app, started at login by local.venera.helper): it asks the watcher's
#      questions as notifications and shows what runs; --no-app leaves it out (the watcher then asks in dialogs)
# Then reboot. ./uninstall.sh undoes all of it; ./status.sh shows what runs.
#
# The system-volume copy needs SIP's authenticated root off (csr bit 0x800): --set-security sets it with the rest
# (0xA03). Without it the driver runs from the kept copy (every app but Safari's WebGL), and the watcher offers the
# system-volume copy once authenticated root is off. --no-system-volume skips it (and leaves authenticated root on).
#
# Levels (boot-arg vgpuaccel): 4 = WindowServer composites the desktop with Metal on the host GPU (default);
# 2 = the virtio-gpu framebuffer with the software compositor, Metal only for allow-listed test tools.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=$HERE/payload
LEVEL=4
OC_ROOT=
NO_OC=0
SET_SECURITY=0
NO_SYSVOL=0
DRY=0
FORCE=0
VIDEO=0
NO_APP=0
GUID=7C436110-AB2A-4BBB-A880-FE41995C9F82
MOUNTED=

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  cleanup
  exit 1
}
cleanup() { [ -n "$MOUNTED" ] && diskutil unmount "$MOUNTED" >/dev/null 2>&1; MOUNTED=; }
run() { # run CMD...: print it, and run it unless --dry-run
  say "  + $*"
  [ $DRY = 1 ] || "$@"
}

while [ $# -gt 0 ]; do
  case $1 in
  --level) LEVEL=$2; shift ;;
  --oc) OC_ROOT=$2; shift ;;
  --no-opencore) NO_OC=1 ;;
  --set-security) SET_SECURITY=1 ;;
  --no-system-volume) NO_SYSVOL=1 ;;
  --dry-run) DRY=1 ;;
  --force) FORCE=1 ;;
  --video) VIDEO=1 ;;
  --no-app) NO_APP=1 ;;
  -h | --help) sed -n '2,31p' "$0"; exit 0 ;;
  *) die "unknown option $1 (--help)" ;;
  esac
  shift
done
case $LEVEL in 2 | 4) ;; *) die "--level is 4 (Metal desktop) or 2 (software desktop)" ;; esac

# ---- 1. the guest --------------------------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run as root: sudo $0"
for d in OpenCore/VirtioGPU.kext Extensions/VirtioGPUFramebuffer.kext Extensions/VirtioGPUAccel.kext \
  GPUBundles/VirtioGPUMetal.bundle Support/sysvol.sh Support/venera-watch.sh Support/local.venera.watch.plist; do
  [ -e "$PAYLOAD/$d" ] || die "payload/$d is missing: run this from the unpacked release folder"
done
[ $VIDEO = 0 ] || [ -e "$PAYLOAD/OpenCore/VeneraVideo.kext" ] || die "payload/OpenCore/VeneraVideo.kext is missing"
[ "$(uname -m)" = x86_64 ] || die "x86_64 macOS only (this is $(uname -m))"
VER=$(sw_vers -productVersion)
BUILD=$(sw_vers -buildVersion)
case $VER in
26.*) ;;
*) [ $FORCE = 1 ] || die "macOS 26 (Tahoe) only; this is $VER ($BUILD). --force to try anyway" ;;
esac
[ "$BUILD" = 25G342 ] || warn "tested on macOS 26.7.3 (25G342); this is $VER ($BUILD). The Metal desktop checks the parts of
  CoreDisplay it depends on and falls back to the software desktop when they differ."
if ! ioreg -rc IOPCIDevice -l | grep -q '"device-id" = <50100000>' ||
  ! ioreg -rc IOPCIDevice -l | grep -q '"vendor-id" = <f41a0000>'; then
  die "no virtio-gpu device (1af4:1050). The VM needs vga: virtio-gl (see INSTALL.md, host)"
fi
say "guest: macOS $VER ($BUILD), virtio-gpu present"

CSR=$(csrutil status 2>/dev/null)
SIP_OK=1
echo "$CSR" | grep -q 'Kext Signing: disabled' || SIP_OK=0
echo "$CSR" | grep -q 'Filesystem Protections: disabled' || SIP_OK=0
echo "$CSR" | grep -q 'System Integrity Protection status: disabled' && SIP_OK=1
ARGS=$(nvram boot-args 2>/dev/null | cut -f2-)
AMFI_OK=0
case " $ARGS " in *" amfi_get_out_of_my_way=1 "*) AMFI_OK=1 ;; esac
AUTHROOT_OFF=0
csrutil authenticated-root status 2>/dev/null | grep -qi disabled && AUTHROOT_OFF=1
if [ $SET_SECURITY = 1 ] && [ $NO_SYSVOL = 0 ] && [ $AUTHROOT_OFF = 0 ]; then
  SIP_OK=0   # write the csr value with the authenticated-root bit
fi
if [ $SIP_OK = 0 ] || [ $AMFI_OK = 0 ]; then
  if [ $SET_SECURITY = 1 ]; then
    [ $NO_OC = 1 ] && die "--set-security writes OpenCore's config.plist; it can't go with --no-opencore"
    say "security: will set csr-active-config $([ $NO_SYSVOL = 1 ] && echo 0x203 || echo 0xA03) and amfi_get_out_of_my_way=1 in OpenCore (effective at reboot)"
  else
    [ $SIP_OK = 0 ] && warn "SIP must allow unsigned kexts and an unrestricted file system (csr-active-config 0x203)"
    [ $AMFI_OK = 0 ] && warn "boot-args need amfi_get_out_of_my_way=1 (WindowServer loads the ad-hoc signed Metal bundle)"
    die "set them in OpenCore yourself, or run again with --set-security (INSTALL.md, \"Security\")"
  fi
fi

# ---- 2. OpenCore ---------------------------------------------------------------------------------------------------
pl() { plutil "$@" "$CONFIG"; }
if [ $NO_OC = 0 ]; then
  if [ -z "$OC_ROOT" ]; then
    FOUND=
    for p in $(diskutil list | awk '/ EFI / {print $NF}'); do
      mp=$(diskutil info "$p" | awk -F': *' '/Mount Point/ {print $2}')
      fresh=
      if [ -z "$mp" ]; then
        diskutil mount "$p" >/dev/null 2>&1 || continue
        mp=$(diskutil info "$p" | awk -F': *' '/Mount Point/ {print $2}')
        fresh=$p
      fi
      if [ -n "$mp" ] && [ -f "$mp/EFI/OC/config.plist" ]; then
        [ -n "$FOUND" ] && die "OpenCore on more than one EFI partition ($FOUND and $mp): say which with --oc"
        FOUND=$mp
        MOUNTED=$fresh
      elif [ -n "$fresh" ]; then
        diskutil unmount "$fresh" >/dev/null 2>&1
      fi
    done
    [ -n "$FOUND" ] || die "no EFI partition with EFI/OC/config.plist: mount OpenCore's and pass --oc, or --no-opencore"
    OC_ROOT=$FOUND
  fi
  CONFIG=$OC_ROOT/EFI/OC/config.plist
  [ -f "$CONFIG" ] || die "$CONFIG not found"
  plutil -lint "$CONFIG" >/dev/null || die "$CONFIG doesn't parse"
  say "OpenCore: $CONFIG"
  BACKUP=$CONFIG.venera-$(date +%Y%m%d-%H%M%S)
  run cp "$CONFIG" "$BACKUP"
  # oc_kext NAME COMMENT: NAME.kext copied into EFI/OC/Kexts, its Kernel > Add entry added or enabled
  oc_kext() {
    run rm -rf "$OC_ROOT/EFI/OC/Kexts/$1.kext"
    run cp -R "$PAYLOAD/OpenCore/$1.kext" "$OC_ROOT/EFI/OC/Kexts/"
    N=$(pl -extract Kernel.Add raw -o -) || die "config.plist has no Kernel > Add"
    IDX=
    i=0
    while [ $i -lt "$N" ]; do
      [ "$(pl -extract Kernel.Add.$i.BundlePath raw -o - 2>/dev/null)" = "$1.kext" ] && IDX=$i
      i=$((i + 1))
    done
    if [ -n "$IDX" ]; then
      run pl -replace Kernel.Add.$IDX.Enabled -bool YES
    else
      run pl -insert Kernel.Add.$N -json "{\"Arch\":\"x86_64\",\"BundlePath\":\"$1.kext\",\"Comment\":\"$2\",\"Enabled\":true,\"ExecutablePath\":\"Contents/MacOS/$1\",\"MaxKernel\":\"\",\"MinKernel\":\"\",\"PlistPath\":\"Contents/Info.plist\"}"
    fi
  }
  oc_kext VirtioGPU "Venera core (virtio-gpu)"
  [ $VIDEO = 1 ] && oc_kext VeneraVideo "Venera video decoding (through the host)"
  OCARGS=$(pl -extract "NVRAM.Add.$GUID.boot-args" raw -o - 2>/dev/null)
  NEW=
  for a in $OCARGS; do
    case $a in vgpuaccel=*) ;; *) NEW="$NEW $a" ;; esac
  done
  if [ $SET_SECURITY = 1 ]; then
    case " $NEW " in *" amfi_get_out_of_my_way=1 "*) ;; *) NEW="$NEW amfi_get_out_of_my_way=1" ;; esac
    if [ $NO_SYSVOL = 1 ]; then
      run pl -replace "NVRAM.Add.$GUID.csr-active-config" -data AwIAAA==   # 0x00000203, little-endian
    else
      run pl -replace "NVRAM.Add.$GUID.csr-active-config" -data AwoAAA==   # 0x00000A03: and authenticated root off
    fi
  fi
  NEW="${NEW# } vgpuaccel=$LEVEL"
  run pl -replace "NVRAM.Add.$GUID.boot-args" -string "${NEW# }"
  # OpenCore writes NVRAM.Add only over variables NVRAM.Delete lists (or that don't exist yet)
  for k in boot-args csr-active-config; do
    [ $k = csr-active-config ] && [ $SET_SECURITY = 0 ] && continue
    if ! pl -extract "NVRAM.Delete.$GUID" raw -o - >/dev/null 2>&1; then
      run pl -insert "NVRAM.Delete.$GUID" -json "[\"$k\"]"
    elif ! pl -extract "NVRAM.Delete.$GUID" xml1 -o - | grep -q "<string>$k</string>"; then
      run pl -insert "NVRAM.Delete.$GUID.0" -string $k
    fi
  done
  [ $DRY = 1 ] || plutil -lint "$CONFIG" >/dev/null || {
    cp "$BACKUP" "$CONFIG"
    die "config.plist didn't validate after the edit; restored the backup"
  }
  say "OpenCore: VirtioGPU.kext$([ $VIDEO = 1 ] && echo " and VeneraVideo.kext") enabled, boot-args \"${NEW# }\" (backup: $BACKUP)"
  cleanup
else
  say "OpenCore: skipped (--no-opencore). Add payload/OpenCore/VirtioGPU.kext to Kernel > Add and vgpuaccel=$LEVEL"
  say "  to boot-args yourself (INSTALL.md)."
  [ $VIDEO = 1 ] && say "  And payload/OpenCore/VeneraVideo.kext, for video decoding."
fi

# ---- 3. the Auxiliary KC -------------------------------------------------------------------------------------------
for k in VirtioGPUFramebuffer VirtioGPUAccel; do
  run rm -rf "/Library/Extensions/$k.kext"
  run cp -R "$PAYLOAD/Extensions/$k.kext" /Library/Extensions/
  run chown -R root:wheel "/Library/Extensions/$k.kext"
  run chmod -R 755 "/Library/Extensions/$k.kext"
done
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
say "Auxiliary KC: rebuilding (a minute or two)"
if [ $DRY = 0 ]; then
  kmutil create -n aux --volume-root / --allow-missing-kdk --kernel /System/Library/Kernels/kernel \
    -B /System/Library/KernelCollections/BootKernelExtensions.kc \
    -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
    --repository /Library/Extensions -A "$KC.venera-new" -z >/tmp/venera-kmutil.log 2>&1 ||
    { tail -20 /tmp/venera-kmutil.log; die "kmutil failed (log: /tmp/venera-kmutil.log)"; }
  for k in VirtioGPUFramebuffer VirtioGPUAccel; do
    kmutil inspect -a x86_64 -A "$KC.venera-new" 2>/dev/null | grep -q "homelab\.$k[^A-Za-z]" ||
      { tail -20 /tmp/venera-kmutil.log; rm -f "$KC.venera-new"; die "kmutil left $k out (log: /tmp/venera-kmutil.log)"; }
  done
  mv -f "$KC.venera-new" "$KC" || die "couldn't replace $KC (SIP file system protection still on?)"
fi
say "Auxiliary KC: VirtioGPUFramebuffer and VirtioGPUAccel in"

# ---- 4. the Metal driver -------------------------------------------------------------------------------------------
V="/Library/Application Support/Venera"
# the kept copy lives under /Library/GPUBundles: WindowServer's sandbox maps code from there, not from $V
K=/Library/GPUBundles/Venera
run mkdir -p "$V" "$K"
run rm -rf "$K/VirtioGPUMetal.bundle"
run cp -R "$PAYLOAD/GPUBundles/VirtioGPUMetal.bundle" "$K/"
run chown -R root:wheel "$K/VirtioGPUMetal.bundle"
run chmod -R go-w,a+rX "$K/VirtioGPUMetal.bundle"
for f in sysvol.sh venera-watch.sh; do run cp "$PAYLOAD/Support/$f" "$V/" && run chmod 755 "$V/$f"; done
for f in uninstall.sh status.sh; do [ "$HERE/$f" -ef "$V/$f" ] || { run cp "$HERE/$f" "$V/" && run chmod 755 "$V/$f"; }; done
[ $DRY = 1 ] || { cp "$HERE/VERSION" "$V/VERSION" 2>/dev/null; echo 25G342 >"$V/TESTED_BUILD"; }
if [ $VIDEO = 1 ]; then run touch "$V/VIDEO"; else run rm -f "$V/VIDEO"; fi   # what the app checks video against
# /Library/GPUBundles' bundle is a symlink from now on: to the kept copy until the system-volume copy is in
[ -L /Library/GPUBundles/VirtioGPUMetal.bundle ] || run rm -rf /Library/GPUBundles/VirtioGPUMetal.bundle
run ln -sfn "$K/VirtioGPUMetal.bundle" /Library/GPUBundles/VirtioGPUMetal.bundle
SYSVOL="kept copy only (--no-system-volume)"
if [ $NO_SYSVOL = 0 ]; then
  if [ $AUTHROOT_OFF = 1 ]; then
    say "system volume: copying the driver into /System/Library/Extensions and blessing a new snapshot"
    run "$V/sysvol.sh" install "$K/VirtioGPUMetal.bundle" || die "the system-volume copy failed (sysvol.sh above)"
    run ln -sfn "$K/VirtioGPUMetal.bundle" /Library/GPUBundles/VirtioGPUMetal.bundle   # the system copy is there after the reboot; the watcher switches
    SYSVOL="on the system volume after the reboot"
  else
    SYSVOL="kept copy until authenticated root is off (then the watcher offers the system-volume copy; Safari's WebGL needs it)"
  fi
fi
# the watcher
run cp "$PAYLOAD/Support/local.venera.watch.plist" /Library/LaunchDaemons/
run chown root:wheel /Library/LaunchDaemons/local.venera.watch.plist
run chmod 644 /Library/LaunchDaemons/local.venera.watch.plist
[ $DRY = 1 ] || launchctl bootout system/local.venera.watch 2>/dev/null
run launchctl bootstrap system /Library/LaunchDaemons/local.venera.watch.plist
say "Metal driver: kept in $K; $SYSVOL; watcher local.venera.watch running"

# ---- 5. the Venera app ---------------------------------------------------------------------------------------------
CUID=$(stat -f %u /dev/console)
if [ -f /Library/LaunchAgents/local.venera.helper.plist ] && [ "$CUID" != 0 ] && [ $DRY = 0 ]; then
  launchctl bootout "gui/$CUID/local.venera.helper" 2>/dev/null
fi
[ $DRY = 1 ] || pkill -x Venera 2>/dev/null
if [ $NO_APP = 0 ] && [ -d "$PAYLOAD/Apps/Venera.app" ]; then
  run rm -rf /Applications/Venera.app
  run cp -R "$PAYLOAD/Apps/Venera.app" /Applications/
  run chown -R root:wheel /Applications/Venera.app
  run cp "$PAYLOAD/Support/local.venera.helper.plist" /Library/LaunchAgents/
  run chown root:wheel /Library/LaunchAgents/local.venera.helper.plist
  run chmod 644 /Library/LaunchAgents/local.venera.helper.plist
  [ "$CUID" != 0 ] && run launchctl bootstrap "gui/$CUID" /Library/LaunchAgents/local.venera.helper.plist
  say "Venera app: /Applications/Venera.app, started at login (local.venera.helper)"
else
  run rm -rf /Applications/Venera.app /Library/LaunchAgents/local.venera.helper.plist
  say "Venera app: not installed$([ $NO_APP = 1 ] && echo " (--no-app)")"
fi

say ""
say "Installed Venera $(cat "$HERE/VERSION" 2>/dev/null) (level $LEVEL$([ $VIDEO = 1 ] && echo ", video decoding")). Reboot to start it: sudo shutdown -r now"
say "If the desktop doesn't come back, the driver falls back to the software desktop by itself after two WindowServer"
say "failures; INSTALL.md, \"Recovery\", has the rest. ./status.sh shows what runs."
