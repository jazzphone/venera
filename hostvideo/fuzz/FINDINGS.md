# venera-videod fuzzing (round 11, 2026-11-17)

Six libFuzzer + ASan + UBSan harnesses over the daemon's guest-facing code, run in the venera-hostvideo-build image
(`run.sh`; clang is installed into the throwaway container). No GPU there: `session` and `fds` fuzz a copy of the
daemon with FFmpeg's software decoders (`gen/venera-videod-sw-raw.c`, made by `run.sh`).

| Harness | Target |
|---|---|
| `msg` | `engine_msg` for every message type with no GPU, `msg_parse` / `msg_field` / `field_int` / `sample_data` |
| `parse` | the leaf parsers (`bp_read_string`, the sbuf and sample-description box walks) on exact-size blocks |
| `ring` | `drain_g2h` with guard pages around the guest-to-host ring |
| `h2g` | `ring_put` / `h2g` / `flush_outbox` against a hostile tail and head |
| `session` | whole decode sessions (dsta, dfrm, dfin, Dbuf answers) on the software-decoder copy |
| `fds` | `open_decoder`'s MP4 box walk |

## Found and fixed (inputs in `repro/`)

1. **High** -- `bp_read_string` (`vv_bplist.h`): an 8-byte string length of all ones wrapped both bounds checks and
   `memcpy` ran 2^64-1 bytes into a 128-byte stack buffer (`bp_len_wrap.msg`).
2. **Medium** -- the same function read the length's int object with no bound, up to 32 KB past the message
   (`bp_int_oob.msg`).
3. **Low** -- `(top + 1) * osz` wrapped, so the offset-table read landed before the buffer (`msg_fuzz_found_table_wrap.msg`).
   1-3: offset sizes 1..8 only, every offset checked against the table, lengths checked by subtraction.
4. **High** -- `pump` called `avcodec_flush_buffers(NULL)`: a dfin, then a failing dsta (which freed the decoder), then
   the guest's Dbuf answer (`pump_null_flush.session`). Fixed: nothing to replay without a decoder.
5. **Medium** -- the packets kept for a replay since the last key frame grew without bound (a guest that never sends
   one: 1 MB packets, 311 MB). Capped at 1024 packets / 64 MB.
6. **Medium** -- `open_decoder` leaked the extradata of every repeated configuration box (`extradata_leak.fds`).
7. **Low** -- after a restart the ring counters came from guest-writable memory unaligned; an unaligned head made
   `ring_put`'s pad record write past the ring's end (`h2g_unaligned_head.ops`). Rounded down to a record.

Also from reading, fixed: a second dsta reopens the decoder cleanly; the outbox (host messages waiting for room) is
capped at 64 MB; each guest record is copied out of shared memory before it is parsed (no double fetches); the
host's own ring counters are kept privately; the restart store is written once per message, its sample descriptions
copied once.

## Runs

Before the fixes: about 5 minutes per harness, two workers each (30 M execs of `msg`, 83 M of `parse`). After them, on
the daemon as committed: 4 minutes per harness, no new findings (`h2g` 3 more minutes after its restart emulation
was made to round the counter as `serve()` does).

Not covered: the VA-API paths, memory errors inside libavcodec and libva (not instrumented), the systemd and
restart-store code (tested on the host by restarting and crashing the service mid-video instead).

Run again: `docker run --rm --platform linux/amd64 -e RESNAP=1 -v ~/src:/src venera-hostvideo-build
/src/macos-virtio-gpu/hostvideo/fuzz/run.sh all 300`

Re-run on the fixed daemon (2026-11-17, all six, 240 s each, about 0.1 to 106 million inputs): no crashes, leaks or
timeouts. One `msg` job then froze in the leak check at the end (its tracer and the job stopped each other, which
happens under x86 emulation on a Mac), so `run.sh` now stops each fuzzer 5 minutes after its time is up.
