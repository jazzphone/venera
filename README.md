# Venera

Accelerated graphics for x86_64 macOS virtual machines on QEMU/KVM, with no GPU passthrough. Venera is a
virtio-gpu driver for macOS: the guest's Metal runs on the host's GPU through virtio-gpu's Venus (Vulkan) protocol,
WindowServer composites the desktop with it, and finished frames go to the screen straight from the host GPU.

Named after the Soviet Venera probes, the first to reach Venus, the protocol it speaks.

**Status: experimental, home-lab.** Tested on macOS Tahoe 26.7.3 (25G342) in a Proxmox VE 9.2 VM (pve-qemu 11.1.3,
virglrenderer 1.1.0) on an Intel Iris Xe host. Window drags, scrolling, live resize and minimizing run at 40-60 fps;
screenshots, display sleep and the Dock's window previews work; when anything goes wrong the desktop falls back to
software compositing by itself. Every app gets Metal and OpenGL from the host GPU (Safari's WebGL included), and
VideoToolbox decodes H.264, HEVC and VP9 and encodes H.264 and HEVC on the host's GPU with the host half installed.
Its guest agent lets Proxmox treat macOS like its Linux and Windows guests: clean shutdowns from the Proxmox page, the
VM's addresses on its Summary, and `qm guest` commands.

## Install

Download a release (or build one, below), then follow [docs/INSTALL.md](docs/INSTALL.md): the host needs
`virtio-vga-gl` with Venus and blob resources, the guest OpenCore with SIP and AMFI relaxed, and `install.sh` does
the rest. `uninstall.sh` removes everything again.

For a new VM on Proxmox, `proxmox-macos-vm.sh` in the host package does all of that before macOS is installed: it
checks the host's GPU, installs what the host needs (on each cluster node), creates a macOS Tahoe VM with OpenCore,
SIP and AMFI already set, and attaches the Venera Tools CD with the installer package ([vm/README.md](vm/README.md)).
Each release also has the Venera Tools CD on its own (`Venera-Tools-VERSION.iso`), for installing with no network.

## How it works

| Piece | Where it runs | What it does |
|---|---|---|
| `VirtioGPU.kext` | Boot KC (OpenCore) | virtio-pci transport, control and cursor queues, 2D scanout, Venus contexts, blob resources, fences, the display-surface table |
| `VirtioGPUFramebuffer.kext` | Auxiliary KC | the IOFramebuffer macOS's display stack drives: modes, EDID, cursor |
| `VirtioGPUAccel.kext` | Auxiliary KC | an IOAcceleratorFamily2 accelerator: Metal's device, the display pipe WindowServer presents through, VBL, paced flips to the host GPU's frames |
| `VirtioGPUMetal.bundle` | /Library/GPUBundles | the Metal driver: Metal's API over Vulkan (Mesa's Venus, patched for macOS), Metal shaders translated to SPIR-V, IOSurfaces as host GPU images |
| `VeneraVideo.kext` | Boot KC (OpenCore) | hardware video decoding and encoding: VideoToolbox's paravirtual decoder and encoder, over a shared-memory device to `venera-videod` on the host |
| `VeneraConsole.kext` | Boot KC (OpenCore) | QEMU's virtio-serial device (the guest agent's port, SPICE's agent channel) in place of Apple's console driver, which stalls when the host hangs up mid-answer |
| `venera-agent` | launch daemon | the guest agent: the QEMU guest agent protocol Proxmox speaks (shutdown, addresses, `qm guest exec`, files, passwords) over the VM's agent port |

A display frame never touches the guest's CPU: Core Animation renders it on the host GPU, the driver copies it into a
host-visible "twin" buffer in the same command buffer, and the accelerator points the scanout at that buffer
(`SET_SCANOUT_BLOB`) once its GPU work is done. [notes/PLAN.md](notes/PLAN.md) is the full research and build log,
stage by stage, with the measurements behind each decision.

## Build

On a Mac with Xcode 26 (x86_64 target), Rust (for the translator) and a Mesa checkout:

```bash
tools/build-translator.sh     # once: the Metal-to-SPIR-V translator (LGPL), from nvidia-macos-driver's translator/
mesa/build-mesa.sh            # once: Mesa's Venus for macOS with mesa/patches/
packaging/make-dist.sh        # the kexts, the Metal bundle and dist/Venera-VERSION.tar.gz
```

For development against a test VM, `tools/deploy.sh` builds and installs pieces over the Proxmox host's guest agent
(set the host in `tools/local.env`, from `tools/local.env.example`); `tools/gesture-bench.sh` and
`tools/drag-perf.sh` measure frame pacing with injected input.

## Layout

- `kext/VirtioGPU/` — the core kext (C++, the macOS SDK's Kernel.framework), injected by OpenCore.
- `kext/VirtioGPUFramebuffer/`, `kext/VirtioGPUAccel/` — the IOFramebuffer and the IOAccelerator (Auxiliary KC).
- `metal/VirtioGPUMetal/` — the Metal driver bundle.
- `mesa/` — the Venus patches and build script (`mesa/out/` holds a prebuilt `libvulkan_virtio.dylib`).
- `vendor/nullmoth/` — nvidia-macos-driver's reconstructed IOAccel headers.
- `packaging/` — the release builder, installer, uninstaller and status script; `docs/` — the install guide.
- `tools/` — build, deploy and measurement scripts; `notes/` — plan, findings, device dumps.
- `vm/` — the script that makes a macOS VM on Proxmox ready for Venera (MIT).

## License

PolyForm Noncommercial 1.0.0 (`LICENSE`): free for personal, research and other noncommercial use. Mesa's parts are
MIT and the translator is LGPL-3.0-or-later; [NOTICE.md](NOTICE.md) has the details.

Venera stands on [nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver) (NullMoth Systems), whose
reconstructed IOAcceleratorFamily2 headers, Metal plugin approach and translator made a third-party Metal driver
for macOS possible, on [Mesa](https://mesa3d.org)'s Venus, and on QEMU's and virglrenderer's virtio-gpu work.
