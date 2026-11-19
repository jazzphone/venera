#!/bin/zsh
# build.sh: Venera's OpenCore image for a new macOS VM (on a Mac with Docker; tools/build.sh first, for VeneraHide):
#   build/opencore/OpenCore-Venera-OCVERSION.img   a raw GPT disk with one EFI partition (FAT32), as the VM script
#                                                 imports it; and its .sha256
# From acidanthera's OpenCorePkg release (BSD-3; checksum-pinned below, kept in ~/src/vendor-src/opencore and in the
# release mirror), with config.py's settings over its Sample.plist, Venera's SSDT-VENERA.dsl (compiled with iasl)
# and VeneraHide.kext. OpenCore's own ocvalidate checks the config. No KVM-Opencore, no Lilu.
set -euo pipefail
cd "${0:A:h}/../.."
OCVER=1.0.8
OCSHA=2011e8b7216ecb2645d97ea710df965947edd406846e92050b9bc4190be6d27b
OCZIP=${VENERA_VENDOR_SRC:-$HOME/src/vendor-src}/opencore/OpenCore-$OCVER-RELEASE.zip
DEBIAN=debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6
[[ -d build/VeneraHide.kext ]] || { echo "no build/VeneraHide.kext: run tools/build.sh"; exit 1; }
if [[ ! -f $OCZIP ]]; then
  mkdir -p ${OCZIP:h}
  curl -fsSL -o $OCZIP https://github.com/acidanthera/OpenCorePkg/releases/download/$OCVER/OpenCore-$OCVER-RELEASE.zip
fi
echo "$OCSHA  $OCZIP" | shasum -a 256 -c --quiet || { echo "$OCZIP doesn't match its checksum"; exit 1; }
B=build/opencore
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
  truncate -s 48M '$IMG'
  sgdisk -q -n 1:2048:0 -t 1:EF00 -c 1:EFI '$IMG'
  mformat -i '$IMG'@@1M -F -v OPENCORE ::
  mcopy -i '$IMG'@@1M -s EFI ::
  mdir -i '$IMG'@@1M -/ ::EFI | grep -c -E "efi|aml|plist|VeneraHide" '
mv $B/$IMG build/opencore-$IMG.tmp && rm -rf $B && mkdir -p $B && mv build/opencore-$IMG.tmp $B/$IMG
(cd $B && shasum -a 256 $IMG | tee $IMG.sha256)
