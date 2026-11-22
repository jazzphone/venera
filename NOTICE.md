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

| OpenCore (acidanthera's OpenCorePkg release, unmodified) | the host package's `opencore/` image, made by `vm/opencore/build.sh` | BSD-3-Clause |
| `macrecovery.py` (OpenCorePkg) | the host package, for the VM script | BSD-3-Clause |

`kext/VeneraHide`, `kext/VeneraConsole`, `kext/VeneraBalloon` and the rest of Venera's own code are under Venera's
license above; `vm/` (the VM script, the OpenCore config and ACPI table) is MIT (`vm/LICENSE`). Each release's
`Venera-sources-VERSION.tar` (`tools/make-sources.sh`) carries the sources of everything above, and
`packaging/UPSTREAM` lists each with its checksum. A release carries these texts in `licenses/`.
