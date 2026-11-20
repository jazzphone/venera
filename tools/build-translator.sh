#!/bin/zsh
# Build NV's metal2vulkan wrapper (libnvmtl_translate.dylib, AIR-derived LLVM IR -> SPIR-V + reflection) for x86_64
# macOS 26 into build/translator/. Source: nullmoth/nvidia-macos-driver translator/ (LGPL-3.0-or-later), checked out
# at $NVSRC (default ~/src/vendor-src/nvidia-macos-driver, commit 87e524a).
# Homebrew's Rust has no x86_64 std, but ships its source: -Z build-std builds it (RUSTC_BOOTSTRAP enables -Z on a
# stable compiler). Crates go to an isolated CARGO_HOME.
# Venera's changes to it are packaging/translator/*.patch (patch -p1, in order): the build is from a copy of the
# checkout's translator/ in build/translator-src with them applied, so the checkout stays as upstream has it.
set -euo pipefail
cd "${0:A:h}/.."
NVSRC=${NVSRC:-$HOME/src/vendor-src/nvidia-macos-driver}
. packaging/UPSTREAM   # TRANSLATOR_COMMIT, TRANSLATOR_RUSTC
if git -C $NVSRC rev-parse HEAD >/dev/null 2>&1; then
  [[ $(git -C $NVSRC rev-parse --short=7 HEAD) == $TRANSLATOR_COMMIT ]] || { echo "$NVSRC isn't at $TRANSLATOR_COMMIT (packaging/UPSTREAM)"; exit 1; }
  git -C $NVSRC diff --quiet -- translator/wrapper || { echo "$NVSRC has changes in translator/wrapper: the build is from $TRANSLATOR_COMMIT as it is"; exit 1; }
fi
[[ $(rustc --version) == "rustc $TRANSLATOR_RUSTC "* ]] || echo "build-translator: built with rustc $TRANSLATOR_RUSTC, this is $(rustc --version) (it may still build)" >&2
export CARGO_HOME=${CARGO_HOME:-$HOME/src/vendor-src/cargo-home} CARGO_TARGET_DIR=$PWD/build/translator-target
export RUSTC_BOOTSTRAP=1 MACOSX_DEPLOYMENT_TARGET=26.0
# the copy, patched: it is made again each time, so a patch that changed (or was removed) is what is built
SRC=$PWD/build/translator-src
mkdir -p $SRC
rsync -a --delete --exclude target $NVSRC/translator/ $SRC/translator/
for p in packaging/translator/*.patch(N); do
  (cd $SRC && patch -p1 --no-backup-if-mismatch -s < $OLDPWD/$p) || { echo "build-translator: $p doesn't apply to $TRANSLATOR_COMMIT"; exit 1; }
  echo "build-translator: applied $p"
done
# no build machine paths in the binary (panic locations): home and the sources become fixed prefixes
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$SRC=/src/nvidia-macos-driver --remap-path-prefix=$NVSRC=/src/nvidia-macos-driver --remap-path-prefix=$CARGO_HOME=/cargo --remap-path-prefix=$HOME=/home"
(cd $SRC/translator/wrapper && cargo build --release --locked ${CARGO_OFFLINE:+--offline} -Z build-std=std,panic_abort --target x86_64-apple-darwin)
mkdir -p build/translator
cp $CARGO_TARGET_DIR/x86_64-apple-darwin/release/libnvmtl_translate.dylib build/translator/
install_name_tool -id @rpath/libnvmtl_translate.dylib build/translator/libnvmtl_translate.dylib
file build/translator/libnvmtl_translate.dylib
