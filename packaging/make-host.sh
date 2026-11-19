#!/bin/zsh
# make-host: dist/Venera-host-VERSION.tar.gz, the Proxmox host's half of video decoding: venera-videod, vaprofiles
# and the minimal LGPL FFmpeg they use (built for Debian amd64 in the venera-hostvideo-build container, Docker
# needed), install-host.sh and the service, and proxmox-macos-vm.sh with the guest package (a new macOS VM, ready for Venera).
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(cat VERSION)
NAME=Venera-host-$VERSION
D=dist/$NAME
docker image inspect venera-hostvideo-build >/dev/null 2>&1 ||
  docker build --platform linux/amd64 -t venera-hostvideo-build hostvideo >/dev/null
[[ -d hostvideo/out/ffmpeg/lib ]] || docker run --rm --platform linux/amd64 -v ~/src:/src venera-hostvideo-build \
  /src/macos-virtio-gpu/hostvideo/build-ffmpeg.sh
docker run --rm --platform linux/amd64 -v ~/src:/src venera-hostvideo-build /src/macos-virtio-gpu/hostvideo/build.sh \
  venera-videod >/dev/null
docker run --rm --platform linux/amd64 -e EXTRA="-lva-drm" -v ~/src:/src venera-hostvideo-build /src/macos-virtio-gpu/hostvideo/build.sh \
  vaprofiles >/dev/null
rm -rf $D && mkdir -p $D/bin $D/lib $D/licenses
cp hostvideo/out/bin/venera-videod hostvideo/out/bin/vaprofiles $D/bin/
cp -P hostvideo/out/ffmpeg/lib/*.so* $D/lib/
cp packaging/host/install-host.sh packaging/host/venera-videod@.service packaging/host/venera-videod@.socket VERSION LICENSE NOTICE.md $D/
# the macOS VM script (MIT, vm/README.md) and the guest package it puts on a new VM's Venera disk
cp vm/proxmox-macos-vm.sh $D/
cp vm/LICENSE $D/licenses/proxmox-macos-vm-MIT.txt
if [[ -f "dist/Install Venera $VERSION.pkg" ]]; then
  mkdir -p $D/guest && cp "dist/Install Venera $VERSION.pkg" $D/guest/
  [[ -f dist/Venera-Tools-$VERSION.iso ]] && cp dist/Venera-Tools-$VERSION.iso $D/guest/
else
  echo "make-host: no dist/Install Venera $VERSION.pkg (packaging/make-pkg.sh): the host package goes without it" >&2
fi
chmod 755 $D/install-host.sh $D/proxmox-macos-vm.sh $D/bin/*
FF=${FFSRC:-$HOME/src/vendor-src/ffmpeg/ffmpeg-7.1.1}
cp $FF/COPYING.LGPLv2.1 $D/licenses/FFmpeg-LGPL-2.1.txt
cat >$D/licenses/FFmpeg-SOURCE.txt <<TXT
The libraries in lib/ are FFmpeg 7.1.1 (https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz), unmodified, built as
shared LGPL libraries (no --enable-gpl, no --enable-nonfree) by hostvideo/build-ffmpeg.sh in Venera's repository:
$(sed -n '/configure/,/extra-ldflags/p' hostvideo/build-ffmpeg.sh)
TXT
(cd $D && find bin lib $([[ -d guest ]] && echo guest) -type f -exec shasum -a 256 {} + >SHA256SUMS)
COPYFILE_DISABLE=1 tar -czf dist/$NAME.tar.gz -C dist $NAME
shasum -a 256 dist/$NAME.tar.gz
ls -la dist/$NAME.tar.gz
