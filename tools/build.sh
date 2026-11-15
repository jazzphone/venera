#!/bin/zsh
# Build kext/VirtioGPU into build/VirtioGPU.kext (x86_64, macOS 26 target).
set -euo pipefail
cd "${0:A:h}/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
SRC=kext/VirtioGPU
OUT=build/VirtioGPU.kext
CFLAGS=(-arch x86_64 -mmacosx-version-min=26.0 -std=gnu++17 -O2 -Wall -Wno-unused-parameter -Wno-deprecated-declarations
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
  -fno-rtti -fno-exceptions -fno-builtin -fno-common -fapple-kext -mkernel -nostdinc -nostdlib
  -isysroot "$SDK" -I"$SDK/System/Library/Frameworks/Kernel.framework/Headers")

rm -rf build && mkdir -p build/obj "$OUT/Contents/MacOS"
for f in $SRC/*.cpp; do
  xcrun clang++ "${CFLAGS[@]}" -c "$f" -o "build/obj/${f:t:r}.o"
done
CCFLAGS=(${CFLAGS:#-std=gnu++17}); CCFLAGS=(${CCFLAGS:#-fno-rtti}); CCFLAGS=(${CCFLAGS:#-fno-exceptions})
CCFLAGS=(${CCFLAGS:#-fapple-kext})
for f in $SRC/*.c; do
  xcrun clang -x c -std=gnu11 "${CCFLAGS[@]}" -c "$f" -o "build/obj/${f:t:r}.o"
done
xcrun clang++ -arch x86_64 -mmacosx-version-min=26.0 -isysroot "$SDK" -nostdlib \
  -Xlinker -kext -Xlinker -no_data_const -lkmod -lkmodc++ -lcc_kext build/obj/*.o \
  -o "$OUT/Contents/MacOS/VirtioGPU"
cp $SRC/Info.plist "$OUT/Contents/Info.plist"
plutil -lint "$OUT/Contents/Info.plist" >/dev/null
codesign -s - --force "$OUT" 2>/dev/null || true
file "$OUT/Contents/MacOS/VirtioGPU"
