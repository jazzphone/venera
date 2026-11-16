#!/bin/bash
# Venera: the Metal driver on the system volume, for sandboxed graphics processes (stage 5d).
#
# Safari's graphics process (com.apple.WebKit.GPU) may map code only from the sealed system (/System/Library/Extensions,
# Frameworks, PrivateFrameworks, /usr/lib) and the cryptex grafts; /Library/GPUBundles is refused, so WebGL gets no
# Metal device. This puts a copy of VirtioGPUMetal.bundle in /System/Library/Extensions, the way OpenCore Legacy Patcher
# root-patches: authenticated root off (SIP bit 0x800, set in OpenCore), the live system volume mounted read-write,
# the bundle copied, a new system snapshot blessed. A macOS update replaces the system volume: run `install` again.
#
#   sudo ./sysvol.sh status              authenticated root, the copy, and which bundle Metal loads
#   sudo ./sysvol.sh csr [--oc DIR]      add 0x800 to OpenCore's csr-active-config (0x203 -> 0xA03); reboot after
#   sudo ./sysvol.sh install [BUNDLE]    copy BUNDLE (default /Library/GPUBundles/VirtioGPUMetal.bundle) into the
#                                        system volume, bless a new snapshot, and make /Library/GPUBundles' bundle a
#                                        symlink to the system copy; reboot after
#
# Metal looks in /Library/GPUBundles first and doesn't fall back when the sandbox refuses it, so that path stays, as a
# symlink: the sandbox judges the file mapped, which is the system copy. The flag files stay in /Library/GPUBundles.
#   sudo ./sysvol.sh remove              take the copy out again (new snapshot); reboot after
set -u
GUID=7C436110-AB2A-4BBB-A880-FE41995C9F82
NAME=VirtioGPUMetal.bundle
say() { echo "sysvol: $*"; }
die() { echo "sysvol: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
CMD=${1:-status}; shift || true

authroot() { csrutil authenticated-root status 2>/dev/null | grep -qi disabled && echo off || echo on; }

mount_esp() {   # prints the mount point of the EFI partition holding OpenCore
  for p in $(diskutil list | awk '/ EFI / {print $NF}'); do
    mp=$(diskutil info "$p" | awk -F': *' '/Mount Point/ {print $2}')
    [ -z "$mp" ] && diskutil mount "$p" >/dev/null 2>&1 && mp=$(diskutil info "$p" | awk -F': *' '/Mount Point/ {print $2}')
    [ -n "$mp" ] && [ -f "$mp/EFI/OC/config.plist" ] && { echo "$mp"; return 0; }
  done
  return 1
}

mount_system() {   # the live system volume (not its snapshot) read-write at $MNT
  SNAP=$(diskutil info / | awk -F': *' '/Device Node/ {print $2}')
  VOL=$(echo "$SNAP" | sed -E 's/s[0-9]+$//')       # disk3s1s1 (the booted snapshot) -> disk3s1
  [ "$VOL" != "$SNAP" ] || die "/ is $SNAP, not a snapshot: is authenticated root already off on an unsealed volume?"
  MNT=/System/Volumes/Update/mnt1
  mkdir -p "$MNT"
  mount | grep -q " on $MNT " || mount -o nobrowse -t apfs "$VOL" "$MNT" || die "mounting $VOL at $MNT failed (authenticated root still on?)"
  say "system volume $VOL mounted read-write at $MNT (booted snapshot $SNAP)"
}

bless_new() {
  bless --folder "$MNT/System/Library/CoreServices" --bootefi --create-snapshot || die "bless --create-snapshot failed"
  say "new system snapshot blessed: reboot to use it"
}

case $CMD in
status)
  say "authenticated root: $(authroot) (csr-active-config $(nvram csr-active-config 2>/dev/null | awk '{print $2}'))"
  if [ -d "/System/Library/Extensions/$NAME" ]; then
    say "copy: /System/Library/Extensions/$NAME ($(stat -f '%Sm' "/System/Library/Extensions/$NAME/Contents/MacOS/VirtioGPUMetal"))"
    cmp -s "/System/Library/Extensions/$NAME/Contents/MacOS/VirtioGPUMetal" "/Library/GPUBundles/$NAME/Contents/MacOS/VirtioGPUMetal" &&
      say "  same plugin binary as /Library/GPUBundles" || say "  DIFFERS from /Library/GPUBundles: run install again"
  else
    say "copy: none in /System/Library/Extensions"
  fi
  diskutil info / | grep -E 'Sealed|Device Node' | sed 's/^ */sysvol:   /'
  ;;
csr)
  OC=
  [ "${1:-}" = --oc ] && OC=$2
  [ -n "$OC" ] || OC=$(mount_esp) || die "no EFI partition with EFI/OC/config.plist: pass --oc"
  C=$OC/EFI/OC/config.plist
  cp "$C" "$C.venera-sysvol-$(date +%Y%m%d-%H%M%S)"
  plutil -replace "NVRAM.Add.$GUID.csr-active-config" -data AwoAAA== "$C"   # 0x00000A03, little-endian
  plutil -extract "NVRAM.Delete.$GUID" xml1 -o - "$C" 2>/dev/null | grep -q '<string>csr-active-config</string>' ||
    plutil -insert "NVRAM.Delete.$GUID.0" -string csr-active-config "$C"
  plutil -lint "$C" >/dev/null || die "$C no longer parses (backup beside it)"
  say "OpenCore csr-active-config 0xA03 (adds authenticated root off); reboot to apply"
  ;;
install)
  SRC=${1:-/Library/GPUBundles/$NAME}
  [ -x "$SRC/Contents/MacOS/VirtioGPUMetal" ] || die "$SRC is not the Metal driver bundle"
  [ "$(authroot)" = off ] || die "authenticated root is on: run '$0 csr' and reboot first"
  mount_system
  rm -rf "$MNT/System/Library/Extensions/$NAME"
  ditto "$SRC" "$MNT/System/Library/Extensions/$NAME" || die "copy failed"
  chown -R root:wheel "$MNT/System/Library/Extensions/$NAME"
  chmod -R go-w,a+rX "$MNT/System/Library/Extensions/$NAME"
  say "copied $SRC"
  bless_new
  G=/Library/GPUBundles/$NAME
  if [ ! -L "$G" ]; then
    mkdir -p "/Library/Application Support/Venera"
    rm -rf "/Library/Application Support/Venera/$NAME"
    [ -d "$G" ] && mv "$G" "/Library/Application Support/Venera/$NAME"   # kept for remove
    ln -s "/System/Library/Extensions/$NAME" "$G"
    say "$G -> /System/Library/Extensions/$NAME"
  fi
  ;;
remove)
  [ "$(authroot)" = off ] || die "authenticated root is on: nothing of ours can be on the system volume"
  mount_system
  G=/Library/GPUBundles/$NAME
  if [ -L "$G" ]; then
    K="/Library/Application Support/Venera/$NAME"
    [ -d "$K" ] || ditto "$MNT/System/Library/Extensions/$NAME" "$K"
    rm "$G" && mv "$K" "$G"
    say "$G is a folder again"
  fi
  rm -rf "$MNT/System/Library/Extensions/$NAME"
  say "removed the copy"
  bless_new
  ;;
*) die "unknown command $CMD (status, csr, install, remove)" ;;
esac
