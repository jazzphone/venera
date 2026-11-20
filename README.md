# Venera

**Accelerated graphics for macOS virtual machines on Proxmox and QEMU/KVM, with no GPU passthrough.**

Venera is a virtio-gpu driver for macOS. The guest's Metal runs on the host's GPU through virtio-gpu's Venus (Vulkan)
protocol: WindowServer composites the desktop with Metal, every app gets Metal and OpenGL, video decodes and encodes
on the host GPU, and finished frames go to the screen straight from the host GPU. The host GPU isn't handed to the
VM: it stays the host's, and several VMs can share it.

Named after the Soviet Venera probes, the first to reach Venus, the protocol it speaks.

## What it does

- **A GPU-accelerated macOS desktop.** WindowServer composites with Metal on the host GPU: window drags, scrolling,
  live resize and minimizing at 45-60 fps, with the Liquid Glass look, translucency and animations intact.
- **Metal and OpenGL for every app.** Safari (with WebGL, optionally), Preview, QuickTime, Maps, Photos, Freeform and
  the rest run their graphics on the host GPU; Core Image, Core Animation and games' OpenGL go through the driver.
- **Hardware video.** VideoToolbox decodes H.264, HEVC (up to 4K, 10-bit) and VP9 and encodes H.264 and HEVC on the
  host's GPU (Intel VA-API on the host), so YouTube, video calls and exports don't load the VM's CPU.
- **A first-class Proxmox guest.** Venera's guest agent gives Proxmox clean shutdowns, the VM's IP addresses on its
  Summary page and `qm guest` commands, like its Linux and Windows guests; the console's clipboard is shared with macOS.
- **A macOS VM in one command.** The setup script creates a macOS Tahoe VM ready for Venera: Venera's own OpenCore
  build, macOS downloaded from Apple, a Mac identity (serial, board serial, Wi-Fi address) generated for the VM's
  model, and HA clusters handled (every node set up).
- **Venera from macOS Recovery.** One command in Recovery installs macOS with Venera already in, so Setup Assistant
  runs on the host's GPU; the same command repairs or removes Venera when a desktop is broken.
- **Safe by default.** If anything goes wrong, the desktop falls back to software compositing by itself; a watcher
  keeps the driver in place across macOS updates and asks before it acts; the Venera app (menu bar) says when
  something needs you; `uninstall.sh` takes everything out again.

## Quick start

On a Proxmox VE node's shell (Datacenter > your node > **Shell**), paste:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jazzphone/venera/main/get-venera.sh)"
```

It downloads the newest release's host package, checks it, and starts the setup script, which asks a few questions
and shows its plan before it changes anything. Then start the VM, and in macOS Recovery erase the disk and run one
command. **[docs/SETUP.md](docs/SETUP.md) walks through it, screen by screen.**

## Requirements

| | |
|---|---|
| Host | Proxmox VE 9 (tested: 9.2), or QEMU 9.2+ built with virglrenderer 1.0+ (Venus) on Linux |
| Host CPU | Intel (tested); AMD **experimental, untested** (the VM gets an Intel CPU model, Haswell) |
| Host GPU | a GPU with a Vulkan 1.3 driver that exports dma-bufs: Intel (tested: Iris Xe, Mesa ANV) or AMD (Mesa RADV, untested); hardware video needs an Intel GPU (VA-API) |
| Guest | macOS Tahoe (tested: 26.7.3), x86_64, booted through OpenCore |

## Status

**Experimental, home-lab.** Tested on macOS Tahoe 26.7.3 (25G342) in Proxmox VE 9.2 (pve-qemu 11.1.3,
virglrenderer 1.1.0) on an Intel Iris Xe host, in daily use there. Known limits:

- One display, 1024x768 to 4K, with Retina modes from 2560x1440 ("looks like" half that); no HDR.
- Proxmox's noVNC console shows at most ~33 fps (QEMU's VNC refresh); the guest draws at 50-60. SPICE, or a display
  that isn't VNC, shows the rest.
- A newer macOS than the tested one can fall back to the software desktop until Venera is tested on it: turn off
  automatic macOS updates in the VM.
- NVIDIA host GPUs are untested; Apple silicon hosts and arm64 macOS are out of scope.
- A generated Mac identity is unique but not registered with Apple: iCloud and iMessage may refuse it. Use your own
  Mac's identity for those.

Take a VM snapshot or backup before installing. Bugs and questions: GitHub issues.

## Documentation

- [docs/SETUP.md](docs/SETUP.md): a new macOS VM with Venera, step by step.
- [docs/INSTALL.md](docs/INSTALL.md): Venera in depth: installing by hand or from Recovery, security settings,
  hardware video, recovery, uninstalling, tuning.
- [vm/README.md](vm/README.md): everything the VM script does, and its choices for an existing VM (Finish, Upgrade,
  the Mac identity, moving to Venera's OpenCore, startup settings).
- [extras/README.md](extras/README.md): a quieter macOS (fewer background services using the CPU) and server settings
  (always on), for any macOS VM; each change can be undone.
- [notes/PLAN.md](notes/PLAN.md): the research and build log, round by round, with the measurements behind each
  decision.

**What it depends on.** Everything Venera is built from outside this repository (OpenCorePkg, Mesa, FFmpeg, NullMoth's
translator, the build image) is listed with its checksum in `packaging/UPSTREAM`, and each release has a
`Venera-sources-VERSION.tar` with all of it, so it can be rebuilt offline if an upstream project goes away. On the
host it depends on Proxmox's QEMU, virglrenderer and Mesa: `install-host.sh --check` compares them with the versions a
release was tested on (`TESTED`) and says how to go back after an update that breaks something.

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
| `venera-clipboard` | launch agent | the clipboard: the SPICE agent protocol on `com.redhat.spice.0`, in step with the Mac's pasteboard (Proxmox's noVNC console, or a SPICE client) |

A display frame never touches the guest's CPU: Core Animation renders it on the host GPU, the driver copies it into a
host-visible "twin" buffer in the same command buffer, and the accelerator points the scanout at that buffer
(`SET_SCANOUT_BLOB`) once its GPU work is done. [notes/PLAN.md](notes/PLAN.md) is the full research and build log,
stage by stage, with the measurements behind each decision.

## Build

On a Mac with Xcode 26 (x86_64 target), Rust (for the translator) and a Mesa checkout:

```bash
tools/build-translator.sh     # once: the Metal-to-SPIR-V translator (LGPL), from nvidia-macos-driver's translator/
mesa/build-mesa.sh            # once: Mesa's Venus for macOS with mesa/patches/
packaging/make-dist.sh        # everything below, into dist/
```

A release is these files, each attached to its GitHub release:

| File | What |
|---|---|
| `Venera-VERSION.tar.gz` | the guest's files and `install.sh` |
| `Install Venera VERSION.pkg` | the same as an installer package |
| `Venera-Tools-VERSION.iso` | the package on a CD image, for a VM with no network, and for macOS Recovery `install-venera` with `Recovery/` (the release's tarball, `Venera Stage.pkg` and the choice packages), all built by `make-pkg.sh` from the same release |
| `Venera-host-VERSION.tar.gz` | the Proxmox host's half: hardware video, `install-host.sh` (with `TESTED`), the VM script with Venera's OpenCore image and `macrecovery.py`, the guest package and Tools CD |
| `Venera-sources-VERSION.tar` | everything it was built from, to rebuild it offline (`tools/make-sources.sh`) |

Before a release: `install-host.sh --record` on the test host into `packaging/host/TESTED`, and any new upstream
version with its checksum in `packaging/UPSTREAM`. And the release's Tools CD from macOS Recovery on a test VM (never
the build or daily VMs): `install-venera` before macOS is installed (erase, then it installs macOS with Venera; the
VM comes back at Setup Assistant on the host's GPU with the app and the guest agent), onto an installed macOS, and
`install-venera remove`; and both recoveries (the installer's macOS Base System and an installed macOS's Recovery)
come up with a picture while Venera is installed.

For development against a test VM, `tools/deploy.sh` builds and installs pieces over the Proxmox host's guest agent
(set the host in `tools/local.env`, from `tools/local.env.example`); `tools/gesture-bench.sh` and
`tools/drag-perf.sh` measure frame pacing with injected input.

`tools/check-vtables.py` checks the kexts' vtables against a macOS release, before a macOS update can shift a slot
under us: it compiles each kext as `tools/build.sh` does and compares, slot by slot, the layout clang computes for
each of our classes (from NullMoth's headers and the SDK's) with its base's real vtable in the kernel collections
given, and checks that every forwarder in `vendor/nullmoth/accel/vg_tahoe_fwd.h` jumps through the slot of the method
it forwards. Copy the guest's `/System/Library/KernelCollections/BootKernelExtensions.kc` and
`SystemKernelExtensions.kc` out first (the IOAccel classes are in the System KC):

```bash
tools/check-vtables.py --kc BootKernelExtensions.kc --kc SystemKernelExtensions.kc   # exit 1 on a mismatch
tools/check-vtables.py --kext VirtioGPUAccel --show VGResource --kc ...               # one kext, every slot of a class
```

Without `--kc` it runs only the forwarder check; a class whose base isn't in the KCs given is checked against its
nearest ancestor that is (PARTIAL).

`tools/serial-log.sh VMID on|record|off` (on the Proxmox node) keeps a VM's kernel log on the host, a file per boot:
macOS's own log loses the last seconds before a hang or panic, the serial port doesn't. `tools/vbltest.m` measures
what apps see of the display's VBLs (CVDisplayLink, a view's display link, Metal's presented times).

## Layout

- `kext/VirtioGPU/` — the core kext (C++, the macOS SDK's Kernel.framework), injected by OpenCore.
- `kext/VirtioGPUFramebuffer/`, `kext/VirtioGPUAccel/` — the IOFramebuffer and the IOAccelerator (Auxiliary KC).
- `metal/VirtioGPUMetal/` — the Metal driver bundle.
- `mesa/` — the Venus patches and build script (`mesa/build-mesa.sh` builds `mesa/out/libvulkan_virtio.dylib`).
- `vendor/nullmoth/` — nvidia-macos-driver's reconstructed IOAccel headers.
- `packaging/` — the release builder, installer, uninstaller and status script; `docs/` — the install guide.
- `tools/` — build, deploy and measurement scripts; `notes/` — plan, findings, device dumps.
- `vm/` — the script that makes a macOS VM on Proxmox ready for Venera (MIT).
- `get-venera.sh` — the one-line setup: downloads the newest release's host package and starts the VM script.

## License

PolyForm Noncommercial 1.0.0 (`LICENSE`): free for personal, research and other noncommercial use. Mesa's parts are
MIT and the translator is LGPL-3.0-or-later; [NOTICE.md](NOTICE.md) has the details.

Venera is not affiliated with or endorsed by Apple. Apple's macOS license permits running macOS only on
Apple-branded hardware: whether and how you run macOS in a VM is your responsibility.

Venera stands on [nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver) (NullMoth Systems), whose
reconstructed IOAcceleratorFamily2 headers, Metal plugin approach and translator made a third-party Metal driver
for macOS possible, on [Mesa](https://mesa3d.org)'s Venus, and on QEMU's and virglrenderer's virtio-gpu work.
