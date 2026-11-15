#!/bin/zsh
# Build build/VirtioGPUMetal.bundle (x86_64, macOS 26): the Metal plugin + Mesa's Venus ICD in its Resources.
set -euo pipefail
cd "${0:A:h}/.."
B=build/VirtioGPUMetal.bundle
rm -rf $B && mkdir -p $B/Contents/MacOS $B/Contents/Resources
xcrun clang -arch x86_64 -mmacosx-version-min=26.0 -O1 -Wall -Wno-protocol -Wno-incomplete-implementation -Wno-objc-protocol-property-synthesis -bundle -fobjc-arc -I"$HOME/src/mesa/include" \
  metal/VirtioGPUMetal/VGMTLDevice.m -framework Foundation -framework Metal -framework IOKit \
  -o $B/Contents/MacOS/VirtioGPUMetal
cp metal/VirtioGPUMetal/Info.plist $B/Contents/Info.plist
cp mesa/out/libvulkan_virtio.dylib $B/Contents/Resources/
codesign -f -s - $B/Contents/Resources/libvulkan_virtio.dylib 2>/dev/null
codesign -f -s - $B 2>/dev/null
file $B/Contents/MacOS/VirtioGPUMetal
