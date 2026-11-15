#!/bin/zsh
# User-space tools for the VM (x86_64): build/vgputest
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
xcrun clang -arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall -framework IOKit -framework CoreFoundation \
  tools/vgputest.c -o build/vgputest
file build/vgputest
