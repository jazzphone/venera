# Licenses

Venera's own code (`kext/`, `metal/`, `tools/`, `packaging/`, `docs/`) is under the **PolyForm Noncommercial License
1.0.0** (`LICENSE`): free for personal, home-lab, research and other noncommercial use. It is that license, not a
more permissive one, because the accelerator kext is built with NullMoth's reconstructed IOAcceleratorFamily2
headers, which are PolyForm Noncommercial; anything built from them, including every release, stays under it.

Third-party parts:

| Part | Where | License |
|---|---|---|
| NullMoth's reconstructed IOAccel/AGDC headers (nvidia-macos-driver `87e524a`) | `vendor/nullmoth/`, built into `VirtioGPUAccel.kext` | PolyForm Noncommercial 1.0.0, Copyright (c) 2026 NullMoth Systems |
| Mesa's Venus Vulkan driver, with Venera's macOS patches | `mesa/patches/`, built as `libvulkan_virtio.dylib` in the Metal bundle | MIT (Mesa's `docs/license.rst`) |
| metal2vulkan translator with NullMoth's wrapper (`translator/`, same commit) | built as `libnvmtl_translate.dylib` in the Metal bundle, loaded at run time | LGPL-3.0-or-later; source at the commit above, built unmodified by `tools/build-translator.sh` |

A release carries these texts in `licenses/`.
