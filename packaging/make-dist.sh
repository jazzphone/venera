#!/bin/zsh
# make-dist: build everything and assemble a release, dist/Venera-VERSION.tar.gz (on a Mac with Xcode; run
# tools/build-translator.sh once first). Unpacked in the guest, its install.sh puts each piece in place.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(cat VERSION)
NAME=Venera-$VERSION
D=dist/$NAME
[[ -f build/translator/libnvmtl_translate.dylib ]] || { echo "build the translator first: tools/build-translator.sh"; exit 1; }
tools/build.sh >/dev/null
tools/build-metal.sh >/dev/null
rm -rf $D && mkdir -p $D/payload/OpenCore $D/payload/Extensions $D/payload/GPUBundles $D/licenses
cp -R build/VirtioGPU.kext $D/payload/OpenCore/
cp -R build/VirtioGPUFramebuffer.kext build/VirtioGPUAccel.kext $D/payload/Extensions/
cp -R build/VirtioGPUMetal.bundle $D/payload/GPUBundles/
cp packaging/install.sh packaging/uninstall.sh packaging/status.sh $D/
chmod 755 $D/*.sh
cp docs/INSTALL.md VERSION LICENSE NOTICE.md $D/
cp vendor/nullmoth/LICENSE $D/licenses/NullMoth-PolyForm-Noncommercial-1.0.0.txt
cp ${NVSRC:-$HOME/src/vendor-src/nvidia-macos-driver}/translator/LICENSE $D/licenses/metal2vulkan-LGPL-3.0.txt
cp ${MESA:-$HOME/src/mesa}/docs/license.rst $D/licenses/Mesa-license.rst
# what's inside, for anyone checking a download
(cd $D && find payload -type f -perm +111 -exec shasum -a 256 {} + > SHA256SUMS)
COPYFILE_DISABLE=1 tar -czf dist/$NAME.tar.gz -C dist $NAME
shasum -a 256 dist/$NAME.tar.gz
ls -la dist/$NAME.tar.gz
