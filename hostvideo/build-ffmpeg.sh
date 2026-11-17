#!/bin/bash
# Builds the minimal FFmpeg Venera's host video program uses (in the venera-hostvideo-build container):
# H.264, HEVC, AV1 and VP9 decoders with VA-API, shared libraries installed under out/ffmpeg.
#   docker run --rm --platform linux/amd64 -v ~/src:/src venera-hostvideo-build /src/macos-virtio-gpu/hostvideo/build-ffmpeg.sh
set -e
SRC=/src/vendor-src/ffmpeg/ffmpeg-7.1.1
OUT=/src/macos-virtio-gpu/hostvideo/out/ffmpeg
B=/tmp/ffbuild
mkdir -p $B && cd $B
$SRC/configure --prefix=$OUT --enable-shared --disable-static --disable-programs --disable-doc --disable-debug \
  --disable-everything --disable-autodetect --enable-vaapi --enable-libdrm \
  --disable-avdevice --disable-avfilter --disable-swresample --disable-postproc \
  --enable-decoder=h264,hevc,av1,vp9 --enable-parser=h264,hevc,av1,vp9 \
  --enable-hwaccel=h264_vaapi,hevc_vaapi,av1_vaapi,vp9_vaapi \
  --enable-demuxer=mov,matroska --enable-protocol=file --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe_split \
  --extra-ldflags='-Wl,-rpath,$$ORIGIN' >/tmp/configure.log 2>&1 || { tail -30 /tmp/configure.log; exit 1; }
grep -E "^(Enabled hwaccels|External libraries)" -A3 /tmp/configure.log | head -12
make -j$(nproc) >/tmp/make.log 2>&1 || { tail -40 /tmp/make.log; exit 1; }
make install >/dev/null
ls -la $OUT/lib/*.so.* | head
