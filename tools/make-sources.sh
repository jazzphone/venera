#!/bin/zsh
# make-sources: dist/Venera-sources-VERSION.tar, everything a release is built from, so it can be built again with
# no network and no upstream project still online (packaging/UPSTREAM lists each one, with its checksum):
#   venera-VERSION.tar.gz                Venera's own source (git archive of HEAD)
#   upstream/OpenCore-*-RELEASE.zip      acidanthera's OpenCorePkg release (BSD-3)
#   upstream/mesa-*.tar.xz               Mesa's release tarball (MIT); mesa/patches is in Venera's source
#   upstream/ffmpeg-*.tar.xz (+ .asc)    FFmpeg's release tarball and its signature (LGPL-2.1)
#   upstream/translator-COMMIT.tar.gz    NullMoth's translator/ (LGPL-3.0-or-later) at the pinned commit, its licenses
#   upstream/cargo-home.tar.gz           the Rust crates the translator and -Z build-std use (CARGO_HOME, offline)
#   upstream/python-wheels/              meson, ninja and the rest at mesa/requirements.txt's versions
#   SHA256SUMS, README.txt
set -euo pipefail
cd "${0:A:h}/.."
. packaging/UPSTREAM
VERSION=$(cat VERSION)
V=${VENERA_VENDOR_SRC:-$HOME/src/vendor-src}
NVSRC=${NVSRC:-$V/nvidia-macos-driver}
D=dist/Venera-sources-$VERSION
rm -rf $D && mkdir -p $D/upstream/python-wheels
grep -q "FROM --platform=linux/amd64 $DEBIAN_IMAGE" hostvideo/Dockerfile || { echo "hostvideo/Dockerfile's FROM isn't DEBIAN_IMAGE"; exit 1; }
fetch() {   # fetch FILE URL SHA256: the cached copy (downloaded once), checked
  [[ -f $1 ]] || { mkdir -p ${1:h}; curl -fsSL -o $1 $2; }
  echo "$3  $1" | shasum -a 256 -c --quiet || { echo "$1 doesn't match packaging/UPSTREAM"; exit 1; }
  cp $1 $D/upstream/
}
git archive --format=tar.gz --prefix=venera-$VERSION/ -o $D/venera-$VERSION.tar.gz HEAD
[[ -z $(git status --porcelain --untracked-files=no) ]] || echo "make-sources: uncommitted changes aren't in venera-$VERSION.tar.gz (it is HEAD)" >&2
fetch $V/opencore/OpenCore-$OPENCORE_VERSION-RELEASE.zip $OPENCORE_URL $OPENCORE_SHA256
fetch $V/mesa-tarball/mesa-$MESA_VERSION.tar.xz $MESA_URL $MESA_SHA256
fetch $V/ffmpeg/ffmpeg-$FFMPEG_VERSION.tar.xz $FFMPEG_URL $FFMPEG_SHA256
[[ -f $V/ffmpeg/ffmpeg-$FFMPEG_VERSION.tar.xz.asc ]] && cp $V/ffmpeg/ffmpeg-$FFMPEG_VERSION.tar.xz.asc $D/upstream/
[[ $(git -C $NVSRC rev-parse --short=7 HEAD) == $TRANSLATOR_COMMIT ]] || { echo "$NVSRC isn't at $TRANSLATOR_COMMIT"; exit 1; }
git -C $NVSRC archive --format=tar.gz --prefix=nvidia-macos-driver/ -o $PWD/$D/upstream/translator-$TRANSLATOR_COMMIT.tar.gz \
  $TRANSLATOR_COMMIT translator LICENSE NOTICE licenses
# the crates: what the translator and std (-Z build-std) were built with, from build-translator.sh's CARGO_HOME
tar -czf $D/upstream/cargo-home.tar.gz -C ${CARGO_HOME:-$V/cargo-home} registry
PY=$(command -v python3.12 || command -v python3.11 || command -v python3)   # the one mesa/build-mesa.sh picks
$PY -m pip download -q --disable-pip-version-check -d $D/upstream/python-wheels -r mesa/requirements.txt --no-deps
cat >$D/README.txt <<TXT
Venera $VERSION, the sources it was built from (tools/make-sources.sh). Every file is checked against SHA256SUMS,
and each upstream one against packaging/UPSTREAM inside venera-$VERSION.tar.gz.

To build it again without the network, on a Mac with Xcode, Homebrew's Rust ($TRANSLATOR_RUSTC) and Docker:
  tar -xzf venera-$VERSION.tar.gz && cd venera-$VERSION
  mkdir -p ~/src/vendor-src/opencore ~/src/vendor-src/mesa-tarball ~/src/vendor-src/ffmpeg ~/src/vendor-src/cargo-home
  cp ../upstream/OpenCore-*-RELEASE.zip ~/src/vendor-src/opencore/
  cp ../upstream/ffmpeg-* ~/src/vendor-src/ffmpeg/
  tar -xzf ../upstream/translator-$TRANSLATOR_COMMIT.tar.gz -C ~/src/vendor-src
  tar -xzf ../upstream/cargo-home.tar.gz -C ~/src/vendor-src/cargo-home
  CARGO_OFFLINE=1 tools/build-translator.sh
  MESA_TARBALL=../upstream/mesa-$MESA_VERSION.tar.xz PIP_WHEELS=../upstream/python-wheels mesa/build-mesa.sh
  packaging/make-dist.sh
(The Debian image the host half builds in is $DEBIAN_IMAGE; docker save it next to this if that must be offline too.)
TXT
(cd $D && find . -type f ! -name SHA256SUMS | sort | xargs shasum -a 256 >SHA256SUMS)
tar -cf dist/Venera-sources-$VERSION.tar -C dist Venera-sources-$VERSION
ls -la dist/Venera-sources-$VERSION.tar; du -sh $D/upstream/* | sort -h | tail -8
