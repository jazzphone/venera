#!/bin/bash
# Build Mesa's Venus Vulkan driver (libvulkan_virtio.dylib) for x86_64 macOS
# from a clean Mesa 25.0.7 checkout plus the patches in ./patches.
# Cross-compiles on an Apple-silicon Mac (no Rosetta needed; nothing is run).
#
#   MESA_DIR   Mesa checkout (default ~/src/mesa), cloned if missing
#   MACOS_MIN  deployment target (default 26.0)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MESA_DIR="${MESA_DIR:-$HOME/src/mesa}"
MESA_TAG="mesa-25.0.7"
MACOS_MIN="${MACOS_MIN:-26.0}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$HERE/out"

# 1. Mesa source: clone/fetch the tag, fresh branch, apply the patch series.
if [ ! -d "$MESA_DIR/.git" ]; then
  git clone --depth 1 --branch "$MESA_TAG" \
    https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_DIR"
fi
cd "$MESA_DIR"
git rev-parse -q --verify "refs/tags/$MESA_TAG" >/dev/null || \
  git fetch --depth 1 origin tag "$MESA_TAG"
git checkout -q -f -B macos-venus "refs/tags/$MESA_TAG"
git -c user.name=build -c user.email=build@localhost \
  am --committer-date-is-author-date "$HERE"/patches/*.patch

# 2. Python venv (meson, ninja, mako, pyyaml, packaging).
if [ ! -x .venv/bin/meson ]; then
  PY="$(command -v python3.12 || command -v python3.11 || command -v python3)"
  "$PY" -m venv .venv
  .venv/bin/pip install -q meson ninja mako pyyaml packaging setuptools
fi
export PATH="$MESA_DIR/.venv/bin:$PATH"   # so meson finds the venv's python3

# 3. Cross file: clang -arch x86_64 against the macOS SDK.
CROSS="$MESA_DIR/x86_64-macos.cross"
FLAGS="'-mmacosx-version-min=$MACOS_MIN', '-isysroot', '$SDK'"
cat > "$CROSS" <<EOT
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
objc = ['clang', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'

[built-in options]
c_args = [$FLAGS]
cpp_args = [$FLAGS]
objc_args = [$FLAGS]
c_link_args = [$FLAGS]
cpp_link_args = [$FLAGS]
objc_link_args = [$FLAGS]

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOT

# 4. Configure and build.
rm -rf build
meson setup build --cross-file "$CROSS" --buildtype=release \
  -Dvulkan-drivers=virtio -Dgallium-drivers= -Dplatforms= \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled \
  -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dshared-glapi=disabled \
  -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dexpat=disabled \
  -Dvulkan-layers= -Dtools= -Dbuild-tests=false
ninja -C build

# 5. Sanity-check: every undefined symbol must come from a system library or
#    be a weak reference (the optional vn_/vk_/wsi_ entrypoints).
DYLIB=build/src/virtio/vulkan/libvulkan_virtio.dylib
BAD="$(nm -um "$DYLIB" | grep '(undefined)' | grep -v '(from ' | grep -v ' weak ' || true)"
if [ -n "$BAD" ]; then
  echo "unexpected unresolved strong symbols:" >&2; echo "$BAD" >&2; exit 1
fi

# 6. Collect.
mkdir -p "$OUT"
cp "$DYLIB" "$OUT/"
cp build/src/virtio/vulkan/virtio_icd.x86_64.json "$OUT/"
file "$OUT/libvulkan_virtio.dylib"
lipo -info "$OUT/libvulkan_virtio.dylib"
ls -l "$OUT"
