#!/bin/zsh
# build.sh: Venera's OpenCore image for a new macOS VM (on a Mac with Docker; tools/build.sh first, for VeneraHide):
#   build/opencore/OpenCore-Venera-OCVERSION.img   a raw GPT disk with one EFI partition (FAT32), as the VM script
#                                                 imports it; and its .sha256
# From acidanthera's OpenCorePkg release (BSD-3; checksum-pinned below, kept in ~/src/vendor-src/opencore and in the
# release mirror), with config.py's settings over its Sample.plist, Venera's SSDT-VENERA.dsl (compiled with iasl)
# and VeneraHide.kext. OpenCore's own ocvalidate checks the config. No KVM-Opencore, no Lilu.
set -euo pipefail
cd "${0:A:h}/../.."
. packaging/UPSTREAM   # the version, address and checksum of OpenCorePkg, and the Debian image
OCVER=$OPENCORE_VERSION OCSHA=$OPENCORE_SHA256 DEBIAN=$DEBIAN_IMAGE
OCZIP=${VENERA_VENDOR_SRC:-$HOME/src/vendor-src}/opencore/OpenCore-$OCVER-RELEASE.zip
[[ -d build/VeneraHide.kext ]] || { echo "no build/VeneraHide.kext: run tools/build.sh"; exit 1; }
if [[ ! -f $OCZIP ]]; then
  mkdir -p ${OCZIP:h}
  curl -fsSL -o $OCZIP $OPENCORE_URL
fi
echo "$OCSHA  $OCZIP" | shasum -a 256 -c --quiet || { echo "$OCZIP doesn't match its checksum"; exit 1; }
# a fresh work folder each run (Docker Desktop's file sharing can show a just-deleted folder's old contents)
B=build/opencore-work-$$
OUT=build/opencore
rm -rf $B && mkdir -p $B/oc $B/EFI/BOOT $B/EFI/OC/ACPI $B/EFI/OC/Drivers $B/EFI/OC/Kexts
(cd $B/oc && unzip -q $OCZIP)
cp $B/oc/X64/EFI/BOOT/BOOTx64.efi $B/EFI/BOOT/
cp $B/oc/X64/EFI/OC/OpenCore.efi $B/EFI/OC/
for d in OpenRuntime OpenHfsPlus OpenPartitionDxe ResetNvramEntry; do cp $B/oc/X64/EFI/OC/Drivers/$d.efi $B/EFI/OC/Drivers/; done
cp -R build/VeneraHide.kext $B/EFI/OC/Kexts/
cp vm/opencore/SSDT-VENERA.dsl $B/
python3 vm/opencore/config.py $B/oc/Docs/Sample.plist $B/EFI/OC/config.plist
IMG=OpenCore-Venera-$OCVER.img
docker run --rm --platform linux/amd64 -v "$PWD/$B:/b" $DEBIAN sh -ec '
  apt-get update -qq >/dev/null && apt-get install -y -qq acpica-tools mtools gdisk >/dev/null 2>&1
  cd /b && iasl -vs -p EFI/OC/ACPI/SSDT-VENERA SSDT-VENERA.dsl >/dev/null
  chmod +x oc/Utilities/ocvalidate/ocvalidate.linux
  oc/Utilities/ocvalidate/ocvalidate.linux EFI/OC/config.plist > ocvalidate.log 2>&1 || true
  grep -q "Found 0 issues\|No issues found" ocvalidate.log || { cat ocvalidate.log; exit 1; }
  tail -1 ocvalidate.log
  # the same sources make the same image: fixed disk and partition GUIDs, volume serial and times
  export SOURCE_DATE_EPOCH=1767225600 TZ=UTC
  find EFI -exec touch -h -d @$SOURCE_DATE_EPOCH {} +
  truncate -s 48M '$IMG'
  # (not sgdisk -q: quiet, it writes no partition table and still says it succeeded)
  sgdisk -o -U 56454E45-5241-4F43-0000-000000000001 -n 1:2048:0 -t 1:EF00 -c 1:EFI \
    -u 1:56454E45-5241-4F43-0000-000000000002 '$IMG' >/dev/null
  END=$(sgdisk -i 1 '$IMG' | sed -n "s/^Last sector: \([0-9]*\).*/\1/p")
  mformat -i '$IMG'@@1M -T $((END - 2048 + 1)) -F -N 56454E52 -v OPENCORE ::   # the FAT ends where the partition does
  mcopy -i '$IMG'@@1M -s -m EFI ::
  mdir -i '$IMG'@@1M -/ ::EFI | grep -c -E "efi|aml|plist|VeneraHide"
  sgdisk -v '$IMG' | grep -q "No problems found" && sgdisk -p '$IMG' | grep -q "EF00  EFI" || { sgdisk -p '$IMG'; echo "the partition table is wrong"; exit 1; } '
rm -rf $OUT && mkdir -p $OUT && mv $B/$IMG $OUT/ && rm -rf $B
(cd $OUT && shasum -a 256 $IMG | tee $IMG.sha256)
