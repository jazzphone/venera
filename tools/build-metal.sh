#!/bin/zsh
# Build build/VirtioGPUMetal.bundle (x86_64, macOS 26): the Metal plugin, Mesa's Venus ICD and the translator in
# its Resources. Run tools/build-translator.sh once first.
set -euo pipefail
cd "${0:A:h}/.."
B=build/VirtioGPUMetal.bundle
rm -rf $B && mkdir -p $B/Contents/MacOS $B/Contents/Resources
xcrun clang -arch x86_64 -mmacosx-version-min=26.0 -O1 -Wall -Wno-protocol -Wno-incomplete-implementation -Wno-objc-protocol-property-synthesis -bundle -fobjc-arc -I"$HOME/src/mesa/include" -Ivendor/nullmoth/plugin \
  metal/VirtioGPUMetal/*.m -framework Foundation -framework Metal -framework IOKit -framework IOSurface \
  -o $B/Contents/MacOS/VirtioGPUMetal
cp metal/VirtioGPUMetal/Info.plist $B/Contents/Info.plist
cp mesa/out/libvulkan_virtio.dylib $B/Contents/Resources/
# NV's metal2vulkan wrapper (LGPL-3.0-or-later), built for x86_64 by tools/build-translator.sh
cp build/translator/libnvmtl_translate.dylib $B/Contents/Resources/
cp ${NVSRC:-$HOME/src/vendor-src/nvidia-macos-driver}/translator/LICENSE $B/Contents/Resources/libnvmtl_translate.LICENSE
for d in $B/Contents/Resources/*.dylib; do codesign -f -s - $d 2>/dev/null; done
codesign -f -s - $B 2>/dev/null
file $B/Contents/MacOS/VirtioGPUMetal
