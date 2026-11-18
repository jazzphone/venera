#!/bin/zsh
# make-dist: build everything and assemble a release (on a Mac with Xcode; run tools/build-translator.sh once first):
#   dist/Venera-VERSION.tar.gz       the guest's files; unpacked in the guest, its install.sh puts each piece in place
#   dist/Install Venera VERSION.pkg  the same as an installer package (packaging/make-pkg.sh)
#   dist/Venera-host-VERSION.tar.gz  the Proxmox host's half of video decoding (packaging/make-host.sh, needs Docker)
# SIGN_ID="Developer ID Installer: ..." signs the package; without it the package is unsigned.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(cat VERSION)
NAME=Venera-$VERSION
D=dist/$NAME
[[ -f build/translator/libnvmtl_translate.dylib ]] || { echo "build the translator first: tools/build-translator.sh"; exit 1; }
tools/build.sh >/dev/null
tools/build-metal.sh >/dev/null
tools/build-helper.sh >/dev/null
rm -rf $D && mkdir -p $D/payload/OpenCore $D/payload/Extensions $D/payload/GPUBundles $D/payload/Support $D/payload/Apps $D/licenses
cp -R build/VirtioGPU.kext build/VeneraVideo.kext $D/payload/OpenCore/
cp -R build/VirtioGPUFramebuffer.kext build/VirtioGPUAccel.kext $D/payload/Extensions/
cp -R build/VirtioGPUMetal.bundle $D/payload/GPUBundles/
cp packaging/install.sh packaging/uninstall.sh packaging/status.sh $D/
cp packaging/sysvol.sh packaging/venera-watch.sh packaging/local.venera.watch.plist helper/local.venera.helper.plist $D/payload/Support/
cp -R build/Venera.app $D/payload/Apps/
# the translation pool's seed (tools/seed-pool.sh): only one made with this translator
TR=$(shasum -a 256 build/translator/libnvmtl_translate.dylib | cut -c1-12)
SEED=$(ls packaging/seed/pool-*-$TR.tar.gz 2>/dev/null | head -1 || true)
if [[ -n $SEED ]]; then
  cp $SEED $D/payload/Support/pool.tar.gz
  echo ${${SEED:t}#pool-} | cut -d- -f1 >$D/payload/Support/pool.build
else
  echo "make-dist: no translation seed for translator $TR (tools/seed-pool.sh): the first boot translates everything" >&2
fi
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
packaging/make-pkg.sh
[[ -n "${NO_HOST:-}" ]] || packaging/make-host.sh
