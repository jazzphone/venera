#!/bin/zsh
# make-host: dist/Venera-host-VERSION.tar.gz, the Proxmox host's half of video decoding: venera-videod, vaprofiles
# and the minimal LGPL FFmpeg they use (built for Debian amd64 in the venera-hostvideo-build container, Docker
# needed), install-host.sh and the service, and proxmox-macos-vm.sh with what it needs, so making a VM downloads
# nothing but macOS itself: the guest package and the Venera Tools CD (guest/), Venera's OpenCore image (opencore/,
# vm/opencore/build.sh) and OpenCorePkg's macrecovery.py (vm/macrecovery.py).
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(cat VERSION)
NAME=Venera-host-$VERSION
D=dist/$NAME
docker image inspect venera-hostvideo-build >/dev/null 2>&1 ||
  docker build --platform linux/amd64 -t venera-hostvideo-build hostvideo >/dev/null
. packaging/UPSTREAM   # FFmpeg's version and checksum
FFTAR=${VENERA_VENDOR_SRC:-$HOME/src/vendor-src}/ffmpeg/ffmpeg-$FFMPEG_VERSION.tar.xz
[[ -f $FFTAR ]] || { mkdir -p ${FFTAR:h} && curl -fsSL -o $FFTAR $FFMPEG_URL; }
echo "$FFMPEG_SHA256  $FFTAR" | shasum -a 256 -c --quiet || { echo "$FFTAR doesn't match its checksum (packaging/UPSTREAM)"; exit 1; }
[[ -d ${FFTAR%.tar.xz} ]] || tar -xJf $FFTAR -C ${FFTAR:h}
[[ -d hostvideo/out/ffmpeg/lib ]] || docker run --rm --platform linux/amd64 -v ~/src:/src venera-hostvideo-build \
  /src/macos-virtio-gpu/hostvideo/build-ffmpeg.sh
docker run --rm --platform linux/amd64 -v ~/src:/src venera-hostvideo-build /src/macos-virtio-gpu/hostvideo/build.sh \
  venera-videod >/dev/null
docker run --rm --platform linux/amd64 -e EXTRA="-lva-drm" -v ~/src:/src venera-hostvideo-build /src/macos-virtio-gpu/hostvideo/build.sh \
  vaprofiles >/dev/null
rm -rf $D && mkdir -p $D/bin $D/lib $D/licenses
cp hostvideo/out/bin/venera-videod hostvideo/out/bin/vaprofiles $D/bin/
cp -P hostvideo/out/ffmpeg/lib/*.so* $D/lib/
cp packaging/host/install-host.sh packaging/host/apt-check packaging/host/TESTED packaging/host/venera-videod@.service packaging/host/venera-videod@.socket VERSION LICENSE NOTICE.md $D/
# the macOS VM script (MIT, vm/README.md), the OpenCore image and macrecovery.py it uses, and the guest package
cp vm/proxmox-macos-vm.sh vm/macrecovery.py $D/
ls build/opencore/OpenCore-Venera-*.img >/dev/null 2>&1 || vm/opencore/build.sh >/dev/null
mkdir -p $D/opencore && cp build/opencore/OpenCore-Venera-*.img $D/opencore/
cp vm/opencore/OpenCorePkg-LICENSE.txt $D/licenses/OpenCorePkg-BSD-3.txt
cp vm/opencore/NOTICE.txt $D/opencore/
# OpenCorePkg's macserial (Linux), from the same pinned release: the VM script generates a Mac identity with it (a
# serial and board serial that match each other and the model)
OCZIP=${VENERA_VENDOR_SRC:-$HOME/src/vendor-src}/opencore/OpenCore-$OPENCORE_VERSION-RELEASE.zip
echo "$OPENCORE_SHA256  $OCZIP" | shasum -a 256 -c --quiet || { echo "$OCZIP doesn't match its checksum (vm/opencore/build.sh fetches it)"; exit 1; }
unzip -p $OCZIP Utilities/macserial/macserial.linux >$D/opencore/macserial && chmod 755 $D/opencore/macserial
cp vm/LICENSE $D/licenses/proxmox-macos-vm-MIT.txt
if [[ -f "dist/Install Venera $VERSION.pkg" ]]; then
  mkdir -p $D/guest && cp "dist/Install Venera $VERSION.pkg" $D/guest/
  [[ -f dist/Venera-Tools-$VERSION.iso ]] && cp dist/Venera-Tools-$VERSION.iso $D/guest/
else
  echo "make-host: no dist/Install Venera $VERSION.pkg (packaging/make-pkg.sh): the host package goes without it" >&2
fi
chmod 755 $D/install-host.sh $D/apt-check $D/proxmox-macos-vm.sh $D/bin/*
FF=${FFSRC:-$HOME/src/vendor-src/ffmpeg/ffmpeg-7.1.1}
cp $FF/COPYING.LGPLv2.1 $D/licenses/FFmpeg-LGPL-2.1.txt
cat >$D/licenses/FFmpeg-SOURCE.txt <<TXT
The libraries in lib/ are FFmpeg 7.1.1 (https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz), unmodified, built as
shared LGPL libraries (no --enable-gpl, no --enable-nonfree) by hostvideo/build-ffmpeg.sh in Venera's repository:
$(sed -n '/configure/,/extra-ldflags/p' hostvideo/build-ffmpeg.sh)
TXT
(cd $D && find bin lib opencore $([[ -d guest ]] && echo guest) -type f -exec shasum -a 256 {} + >SHA256SUMS)
COPYFILE_DISABLE=1 tar -czf dist/$NAME.tar.gz -C dist $NAME
shasum -a 256 dist/$NAME.tar.gz
ls -la dist/$NAME.tar.gz
