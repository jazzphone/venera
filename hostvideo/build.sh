#!/bin/bash
# Builds Venera's host video programs (in the venera-hostvideo-build container) into out/bin, beside out/ffmpeg's libs.
#   docker run --rm --platform linux/amd64 -v ~/src:/src venera-hostvideo-build /src/macos-virtio-gpu/hostvideo/build.sh
set -e
H=/src/macos-virtio-gpu/hostvideo
F=$H/out/ffmpeg
mkdir -p $H/out/bin
for p in "$@"; do
  gcc -O2 -Wall -o $H/out/bin/$p $H/src/$p.c -I$F/include -L$F/lib -lavformat -lavcodec -lavutil -lva -lpthread \
    -Wl,-rpath,'$ORIGIN/../lib' $EXTRA
done
ls -la $H/out/bin
