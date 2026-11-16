#!/bin/bash
# Venera installer: run inside the macOS guest, as root, from the unpacked release folder.
#
#   sudo ./install.sh [--level 4|2] [--oc /Volumes/EFI] [--no-opencore] [--set-security] [--dry-run]
#
# What it does (each step says what it changed; nothing is downloaded):
#   1. checks the guest: x86_64 macOS 26, a virtio-gpu device, SIP and AMFI as the driver needs them
#   2. OpenCore: copies VirtioGPU.kext (the core, which must load from the Boot KC) into EFI/OC/Kexts, adds or enables
#      its Kernel > Add entry and sets vgpuaccel=LEVEL in OpenCore's boot-args (config.plist is backed up first)
#   3. /Library/Extensions: VirtioGPUFramebuffer.kext and VirtioGPUAccel.kext, then rebuilds the Auxiliary KC
#   4. /Library/GPUBundles: VirtioGPUMetal.bundle (the Metal driver over Venus)
# Then reboot. ./uninstall.sh undoes all of it; ./status.sh shows what runs.
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
DRY=0
FORCE=0
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
  --dry-run) DRY=1 ;;
  --force) FORCE=1 ;;
  -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
  *) die "unknown option $1 (--help)" ;;
  esac
  shift
done
case $LEVEL in 2 | 4) ;; *) die "--level is 4 (Metal desktop) or 2 (software desktop)" ;; esac

# ---- 1. the guest --------------------------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run as root: sudo $0"
for d in OpenCore/VirtioGPU.kext Extensions/VirtioGPUFramebuffer.kext Extensions/VirtioGPUAccel.kext \
  GPUBundles/VirtioGPUMetal.bundle; do
  [ -d "$PAYLOAD/$d" ] || die "payload/$d is missing: run this from the unpacked release folder"
done
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
if [ $SIP_OK = 0 ] || [ $AMFI_OK = 0 ]; then
  if [ $SET_SECURITY = 1 ]; then
    [ $NO_OC = 1 ] && die "--set-security writes OpenCore's config.plist; it can't go with --no-opencore"
    say "security: will set csr-active-config 0x203 and amfi_get_out_of_my_way=1 in OpenCore (effective at reboot)"
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
  run rm -rf "$OC_ROOT/EFI/OC/Kexts/VirtioGPU.kext"
  run cp -R "$PAYLOAD/OpenCore/VirtioGPU.kext" "$OC_ROOT/EFI/OC/Kexts/"
  N=$(pl -extract Kernel.Add raw -o -) || die "config.plist has no Kernel > Add"
  IDX=
  i=0
  while [ $i -lt "$N" ]; do
    [ "$(pl -extract Kernel.Add.$i.BundlePath raw -o - 2>/dev/null)" = VirtioGPU.kext ] && IDX=$i
    i=$((i + 1))
  done
  if [ -n "$IDX" ]; then
    run pl -replace Kernel.Add.$IDX.Enabled -bool YES
  else
    run pl -insert Kernel.Add.$N -json '{"Arch":"x86_64","BundlePath":"VirtioGPU.kext","Comment":"Venera core (virtio-gpu)","Enabled":true,"ExecutablePath":"Contents/MacOS/VirtioGPU","MaxKernel":"","MinKernel":"","PlistPath":"Contents/Info.plist"}'
  fi
  OCARGS=$(pl -extract "NVRAM.Add.$GUID.boot-args" raw -o - 2>/dev/null)
  NEW=
  for a in $OCARGS; do
    case $a in vgpuaccel=*) ;; *) NEW="$NEW $a" ;; esac
  done
  if [ $SET_SECURITY = 1 ]; then
    case " $NEW " in *" amfi_get_out_of_my_way=1 "*) ;; *) NEW="$NEW amfi_get_out_of_my_way=1" ;; esac
    run pl -replace "NVRAM.Add.$GUID.csr-active-config" -data AwIAAA==   # 0x00000203, little-endian
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
  say "OpenCore: VirtioGPU.kext enabled, boot-args \"${NEW# }\" (backup: $BACKUP)"
  cleanup
else
  say "OpenCore: skipped (--no-opencore). Add payload/OpenCore/VirtioGPU.kext to Kernel > Add and vgpuaccel=$LEVEL"
  say "  to boot-args yourself (INSTALL.md)."
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
run mkdir -p /Library/GPUBundles
run rm -rf /Library/GPUBundles/VirtioGPUMetal.bundle
run cp -R "$PAYLOAD/GPUBundles/VirtioGPUMetal.bundle" /Library/GPUBundles/
run chown -R root:wheel /Library/GPUBundles/VirtioGPUMetal.bundle
run chmod -R go-w,a+rX /Library/GPUBundles/VirtioGPUMetal.bundle
mkdir -p /Library/Application\ Support/Venera 2>/dev/null
[ $DRY = 1 ] || cp "$HERE/VERSION" /Library/Application\ Support/Venera/VERSION 2>/dev/null
say "Metal driver: /Library/GPUBundles/VirtioGPUMetal.bundle"

say ""
say "Installed Venera $(cat "$HERE/VERSION" 2>/dev/null) (level $LEVEL). Reboot to start it: sudo shutdown -r now"
say "If the desktop doesn't come back, the driver falls back to the software desktop by itself after two WindowServer"
say "failures; INSTALL.md, \"Recovery\", has the rest. ./status.sh shows what runs."
