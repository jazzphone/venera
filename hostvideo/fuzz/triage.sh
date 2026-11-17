#!/bin/bash
# triage.sh VARIANT NAME : re-runs every artifact of a harness and buckets them by the sanitizer's SUMMARY line.
H=/src/macos-virtio-gpu/hostvideo/fuzz
export LD_LIBRARY_PATH=/src/macos-virtio-gpu/hostvideo/out/ffmpeg/lib ASAN_OPTIONS=allocator_may_return_null=1:detect_leaks=1 UBSAN_OPTIONS=print_stacktrace=1
V=$1; N=$2
for f in $H/out/$V/$N/findings/*; do
  case $f in *crash-*|*leak-*|*timeout-*|*oom-*) ;; *) continue;; esac
  s=$(timeout 60 $H/out/bin-$V/$N $f 2>&1 | grep -E "^SUMMARY|libFuzzer: (timeout|out-of-memory)|ERROR: LeakSanitizer" | head -1 | sed 's/(BuildId.*//')
  echo "$s | $(basename $f)"
done | sort | awk -F' \\| ' '{c[$1]++; ex[$1]=$2} END {for (k in c) print c[k], k, "  e.g.", ex[k]}'
