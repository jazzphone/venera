#!/bin/zsh
# User-space tools for the VM (x86_64): build/vgputest, build/vkprobe, build/vkexec, build/acceltest, build/llvmprobe, build/mtlprobe, build/mtlcompute, build/mtlrender (+ metallibs)
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
CC=(xcrun clang -arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall)
$CC -framework IOKit -framework CoreFoundation tools/vgputest.c -o build/vgputest
$CC -I"$HOME/src/mesa/include" tools/vkprobe.c -o build/vkprobe
$CC -I"$HOME/src/mesa/include" tools/vkexec.c -o build/vkexec
$CC -framework IOKit -framework CoreFoundation tools/acceltest.c -o build/acceltest
$CC tools/llvmprobe.c -o build/llvmprobe
$CC -fobjc-arc -framework Foundation -framework Metal tools/mtlprobe.m -o build/mtlprobe
$CC -fobjc-arc -framework Foundation -framework Metal tools/mtlcompute.m -o build/mtlcompute
$CC -fobjc-arc -framework Foundation -framework Metal tools/mtlrender.m -o build/mtlrender
$CC -fobjc-arc -framework Foundation -framework Metal -framework IOSurface tools/mtlsurface.m -o build/mtlsurface
$CC -fobjc-arc -framework Foundation -framework Metal tools/mtlcaps.m -o build/mtlcaps
$CC -fobjc-arc -framework Foundation -framework Metal -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers tools/carender.m -o build/carender
$CC -fobjc-arc -framework Cocoa -framework Metal -framework QuartzCore -framework IOSurface -framework ImageIO -framework UniformTypeIdentifiers tools/mtlwindow.m -o build/mtlwindow
for s in compute render; do
  xcrun metal -target air64-apple-macos26.0 -c tools/shaders/$s.metal -o build/$s.air && xcrun metallib build/$s.air -o build/$s.metallib
done
file build/vgputest build/vkprobe build/vkexec build/acceltest build/llvmprobe build/mtlprobe build/mtlcompute
