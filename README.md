# macos-virtio-gpu

A virtio-gpu driver for x86_64 macOS guests (Tahoe 26.x) on stock QEMU/KVM, aiming at accelerated
graphics through Venus (Vulkan) with no GPU passthrough. Home-lab project.

Target: macOS 26.7.3 (25G342) on Proxmox VE 9.2 / pve-qemu 11.1, host GPU an Alder Lake Iris Xe
(Mesa ANV). Test VM: 108 `macos-gpu-dev` on the Proxmox host (no network; kexts injected by OpenCore).

## Stages

0. **Probe** — a kext that claims `1af4:1050`, logs PCI config, BARs and the virtio capability
   list, and reads the device config (scanouts, capsets, feature bits). Touches nothing.
1. **virtio core** — modern virtio-pci transport (reset, features, split virtqueues, MSI-X) and
   the control queue answering `GET_DISPLAY_INFO` / `GET_EDID`.
2. **2D display** — an `IOFramebuffer`: `RESOURCE_CREATE_2D` + `ATTACH_BACKING`, `SET_SCANOUT`,
   transfer + flush, modes from the host, hardware cursor on the cursor queue.
3. **Vulkan** — Venus contexts (`CONTEXT_INIT`), blob resources mapped through `hostmem`,
   `SUBMIT_3D` + fences in the kext; Mesa's Venus built for macOS with a transport in place of
   `vn_renderer_virtgpu.c`.
4. **Metal** — an IOAccelerator kext (IOAcceleratorFamily2) and a Metal driver bundle over Vulkan.
   4.0 (the accelerator starts in the guest, unarmed), 4a (Metal lists the device, late arm, allow-list) and 4b
   (Metal compute kernels and blits run on the host GPU) done; see `notes/PLAN.md`.
5. **WindowServer** — IOSurface-backed accelerated compositing.

See `notes/PLAN.md` for the research behind this and what each stage needs.

## Layout

- `kext/VirtioGPU/` — the core kext (C++, built with the macOS SDK's Kernel.framework), OpenCore-injected.
- `kext/VirtioGPUFramebuffer/`, `kext/VirtioGPUAccel/` — the IOFramebuffer and the IOAccelerator (Auxiliary KC).
- `metal/VirtioGPUMetal/` — the Metal driver plugin (`/Library/GPUBundles/VirtioGPUMetal.bundle`).
- `vendor/nullmoth/` — nvidia-macos-driver's reconstructed IOAccel headers (PolyForm Noncommercial).
- `tools/` — build and deploy scripts (build here, inject into VM 108's OpenCore, read logs).
- `notes/` — plan, findings, device dumps.
