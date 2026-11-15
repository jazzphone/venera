#!/bin/zsh
# Build the kexts into build/<Name>.kext (x86_64, macOS 26 target):
#   VirtioGPU.kext            - the core, injected by OpenCore (Boot kernel collection)
#   VirtioGPUFramebuffer.kext - the IOFramebuffer, loaded from /Library/Extensions (Auxiliary KC)
#   VirtioGPUAccel.kext       - the IOAccelerator (stage 4), Auxiliary KC; NV's reconstructed IOAccel headers
set -euo pipefail
cd "${0:A:h}/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
COMMON=(-arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall -Wno-unused-parameter -Wno-deprecated-declarations
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
  -fno-builtin -fno-common -mkernel -nostdinc -nostdlib
  -isysroot "$SDK" -I"$SDK/System/Library/Frameworks/Kernel.framework/Headers")
CXXFLAGS=($COMMON -std=gnu++17 -fno-rtti -fno-exceptions -fapple-kext)
CFLAGS=($COMMON -std=gnu11)

rm -rf build && mkdir -p build
for NAME in VirtioGPU VirtioGPUFramebuffer VirtioGPUAccel; do
  SRC=kext/$NAME
  EXTRA=()
  [[ $NAME == VirtioGPUAccel ]] && EXTRA=(-DNM_TAHOE -Ivendor/nullmoth/accel -Ivendor/nullmoth/accel/re -Ivendor/nullmoth/accel/iofam)
  OUT=build/$NAME.kext
  OBJ=build/obj/$NAME
  mkdir -p $OBJ "$OUT/Contents/MacOS"
  for f in $SRC/*.cpp; do
    xcrun clang++ "${CXXFLAGS[@]}" "${EXTRA[@]}" -c "$f" -o "$OBJ/${f:t:r}.o"
  done
  for f in $SRC/*.c; do
    xcrun clang -x c "${CFLAGS[@]}" -c "$f" -o "$OBJ/${f:t:r}.o"
  done
  xcrun clang++ -arch x86_64 -mmacosx-version-min=26.0 -isysroot "$SDK" -nostdlib \
    -Xlinker -kext -Xlinker -no_data_const -lkmod -lkmodc++ -lcc_kext $OBJ/*.o \
    -o "$OUT/Contents/MacOS/$NAME" 2> >(grep -v "was built for newer" >&2)
  cp $SRC/Info.plist "$OUT/Contents/Info.plist"
  plutil -lint "$OUT/Contents/Info.plist" >/dev/null
  codesign -s - --force "$OUT" 2>/dev/null || true
  file "$OUT/Contents/MacOS/$NAME"
done
