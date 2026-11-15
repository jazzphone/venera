#!/bin/zsh
# User-space tools for the VM (x86_64): build/vgputest, build/vkprobe
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
CC=(xcrun clang -arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall)
$CC -framework IOKit -framework CoreFoundation tools/vgputest.c -o build/vgputest
$CC -I"$HOME/src/mesa/include" tools/vkprobe.c -o build/vkprobe
$CC -I"$HOME/src/mesa/include" tools/vkexec.c -o build/vkexec
file build/vgputest build/vkprobe build/vkexec
