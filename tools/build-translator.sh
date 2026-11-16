#!/bin/zsh
# Build NV's metal2vulkan wrapper (libnvmtl_translate.dylib, AIR-derived LLVM IR -> SPIR-V + reflection) for x86_64
# macOS 26 into build/translator/. Source: nullmoth/nvidia-macos-driver translator/ (LGPL-3.0-or-later), checked out
# at $NVSRC (default ~/src/vendor-src/nvidia-macos-driver, commit 87e524a).
# Homebrew's Rust has no x86_64 std, but ships its source: -Z build-std builds it (RUSTC_BOOTSTRAP enables -Z on a
# stable compiler). Crates go to an isolated CARGO_HOME.
set -euo pipefail
cd "${0:A:h}/.."
NVSRC=${NVSRC:-$HOME/src/vendor-src/nvidia-macos-driver}
export CARGO_HOME=${CARGO_HOME:-$HOME/src/vendor-src/cargo-home} CARGO_TARGET_DIR=$PWD/build/translator-target
export RUSTC_BOOTSTRAP=1 MACOSX_DEPLOYMENT_TARGET=26.0
# no build machine paths in the binary (panic locations): home and the sources become fixed prefixes
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$NVSRC=/src/nvidia-macos-driver --remap-path-prefix=$CARGO_HOME=/cargo --remap-path-prefix=$HOME=/home"
(cd $NVSRC/translator/wrapper && cargo build --release -Z build-std=std,panic_abort --target x86_64-apple-darwin)
mkdir -p build/translator
cp $CARGO_TARGET_DIR/x86_64-apple-darwin/release/libnvmtl_translate.dylib build/translator/
install_name_tool -id @rpath/libnvmtl_translate.dylib build/translator/libnvmtl_translate.dylib
file build/translator/libnvmtl_translate.dylib
