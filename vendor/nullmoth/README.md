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
