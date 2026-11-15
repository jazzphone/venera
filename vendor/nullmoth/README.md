# Vendored from nullmoth/nvidia-macos-driver

Source: https://github.com/nullmoth/nvidia-macos-driver at `87e524a` (2026-11-13).
License: PolyForm Noncommercial 1.0.0 (`LICENSE`); noncommercial home-lab use only. If this repository is ever
published, these files and anything built from them stay under that license.

- `accel/re/*.h`, `accel/iofam/*.h`: NV's reconstructed IOAcceleratorFamily2 / IOGraphicsFamily class layouts
  (vtable order and class sizes read from Apple's binaries; macOS 15 layouts, unchanged on 26 per NV's KDK check).
  Copied unchanged.
- `accel/vg_tahoe_fwd.h`: NV's generated `kexts/NVRM/accel/tahoe_fwd.h` (macOS 26.7.1 KDK) with the class names
  renamed to ours (`NVResource` -> `VGResource`, ..., `NVAccel` -> `VirtioGPUAccel`) by a perl one-liner; nothing
  else changed. Each listed slot is an inherited method macOS 26 no longer exports; the override tail-jumps through
  Apple's exported base vtable. Valid only while our classes override the same set of methods NV's do.

Not vendored, built from the same checkout: the translator (`translator/`, metal2vulkan + NV's `wrapper/`,
LGPL-3.0-or-later). `tools/build-translator.sh` builds `libnvmtl_translate.dylib` for x86_64; the plugin bundle carries
it in Contents/Resources with its license (`libnvmtl_translate.LICENSE`) and loads it with dlopen, as NV's does.
- `accel/nv_iop_pixel.h` (stage 5a): NV's `kexts/NVRM/accel/nv_iop_pixel.h`, the display pipe's row converters (BGRA, l10r,
  RGhA into an 8-bit or 30-bit scanout). Copied unchanged.
- `agdc/AppleGraphicsDeviceControl_re.h` (stage 5a): NV's `kexts/NVRMAGDC/AppleGraphicsDeviceControl_re.h`, the
  reconstructed AppleGraphicsDeviceControl base class (0x110 bytes, one pure `vendor_doDeviceAttribute`). Copied unchanged.
- `plugin/nvmtl_fetch_copy.h` (stage 5b): NV's `plugin/nvmtl_fetch_copy.h`, the SPIR-V rewrite that turns `[[color(n)]]`
  subpass-input reads into texel fetches of a sampled image at the fragment's position (framebuffer fetch by copies).
  Copied unchanged.
- `accel/nvres_fields.h` (stage 5b): NV's `kexts/NVRM/accel/nvres_fields.h`, where the family's resource object keeps
  its width, height, pitches and face size per release (VGResource's level offsets and IOSurface video-memory size).
  Copied unchanged.
