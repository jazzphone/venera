#!/bin/bash
# Venera host video fuzzing.  Runs in the venera-hostvideo-build image (linux/amd64); clang is installed into the
# throwaway container at run time.  Usage (from the Mac):
#   docker run --rm --platform linux/amd64 -v ~/src:/src venera-hostvideo-build /src/macos-virtio-gpu/hostvideo/fuzz/run.sh [build|all|NAME...] [seconds]
# NAMEs: msg parse ring h2g session fds.  "build" only compiles.  Findings land in fuzz/out/NAME/ (crash-*, leak-*, timeout-*).
# Re-run a finding: fuzz/out/bin/NAME FILE  (with LD_LIBRARY_PATH=hostvideo/out/ffmpeg/lib).
set -e
H=/src/macos-virtio-gpu/hostvideo
FZ=$H/fuzz
F=$H/out/ffmpeg
V=${VARIANT:-raw}   # the output folder's name (one variant now: the daemon as it is)
BIN=$FZ/out/bin-$V
SECS=${2:-300}
if ! command -v clang >/dev/null; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang libclang-rt-dev >/dev/null
fi
mkdir -p $BIN $FZ/gen
# fuzz a snapshot of the daemon (the source is being edited by others; FINDINGS.md cites this snapshot's sha256 and lines)
if [ ! -f $FZ/gen/venera-videod.c ] || [ -n "$RESNAP" ]; then   # RESNAP=1 takes a fresh snapshot
  cp $H/src/venera-videod.c $H/src/vv_bplist.h $H/src/vv_shm.h $H/src/vv_static.h $FZ/gen/
  sha256sum $FZ/gen/venera-videod.c | cut -c1-16 > $FZ/gen/SNAPSHOT.sha256
fi
SRC=$FZ/gen/venera-videod.c
# the software-decoder copy of the daemon (the original is never touched): no VA-API device, FFmpeg's own pixel formats
perl -0pe '
  s/\n\s*s->c->hw_device_ctx = av_buffer_ref\(hwdev\);//;
  s/\n\s*s->c->get_format = pick_vaapi;//;
  s/\n\s*s->c->extra_hw_frames = 16;[^\n]*//;
  s/AVHWFramesContext \*fc = \(AVHWFramesContext \*\)f->f->hw_frames_ctx->data;/enum AVPixelFormat swfmt = f->f->format;/;
  s/fc->sw_format == AV_PIX_FMT_P010/(swfmt == AV_PIX_FMT_P010 || swfmt == AV_PIX_FMT_YUV420P10LE)/;
  s/sw->format = fc->sw_format;/sw->format = swfmt;/;
  s/av_hwframe_transfer_data\(sw, f->f, 0\)/0/;
' $SRC > $FZ/gen/venera-videod-sw-$V.c
diff <(cat $SRC) $FZ/gen/venera-videod-sw-$V.c > $FZ/gen/sw.diff || true
FLAGS="$XF -g -O1 -fno-omit-frame-pointer -fsanitize=fuzzer,address,undefined -fno-sanitize=alignment -fno-sanitize-recover=undefined -I$F/include -w"
LIBS="-L$F/lib -lavformat -lavcodec -lavutil -lva -lpthread -Wl,-rpath,$F/lib"
build() { # name source videod
  clang $FLAGS -DVIDEOD_SRC="\"$3\"" -I$FZ $2 -o $BIN/$1 $LIBS
}
build msg     $FZ/fuzz_msg.c     $SRC
build parse   $FZ/fuzz_parse.c   $SRC
build ring    $FZ/fuzz_ring.c    $SRC
build h2g     $FZ/fuzz_h2g.c     $SRC
build session $FZ/fuzz_session.c $FZ/gen/venera-videod-sw-$V.c
build fds     $FZ/fuzz_fds.c     $FZ/gen/venera-videod-sw-$V.c
[ "$1" = build ] && exit 0
declare -A SEED=([msg]=msg [parse]=bplist [ring]=ring [h2g]="" [session]=session [fds]=fds)
declare -A MAXLEN=([msg]=8192 [parse]=4096 [ring]=65536 [h2g]=256 [session]=16384 [fds]=2048)
NAMES=${1:-all}
[ "$NAMES" = all ] && NAMES="msg parse ring h2g session fds"
export ASAN_OPTIONS=allocator_may_return_null=1:detect_leaks=1:abort_on_error=0
export UBSAN_OPTIONS=print_stacktrace=1
pids=()
for n in $NAMES; do
  mkdir -p $FZ/out/$V/$n/corpus $FZ/out/$V/$n/findings
  seeds=""
  [ -n "${SEED[$n]}" ] && seeds=$FZ/seeds/${SEED[$n]}
  ( cd $FZ/out/$V/$n/findings && $BIN/$n -fork=${FORK:-2} -max_total_time=$SECS -max_len=${MAXLEN[$n]} -timeout=20 -rss_limit_mb=3072 \
      -artifact_prefix=$FZ/out/$V/$n/findings/ -print_final_stats=1 -ignore_crashes=1 -ignore_timeouts=1 -ignore_ooms=1 \
      $FZ/out/$V/$n/corpus $seeds > $FZ/out/$V/$n/log.txt 2>&1 ) &
  pids+=($!)
done
wait "${pids[@]}" || true
for n in $NAMES; do echo "== $n"; tail -4 $FZ/out/$V/$n/log.txt; ls $FZ/out/$V/$n/findings; done
