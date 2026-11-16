# Installing Venera

Venera gives an x86_64 macOS VM on QEMU/KVM accelerated graphics with no GPU passthrough. The guest's Metal runs on
the host's GPU through virtio-gpu's Venus (Vulkan) protocol, and the desktop's frames go to the screen straight
from the host GPU. It is experimental: read "Security" and "Recovery" before installing, and take a snapshot of the
VM first.

## What you need

### Host

| | Tested | Needed |
|---|---|---|
| Hypervisor | Proxmox VE 9.2, pve-qemu 11.1.3 | QEMU with `virtio-vga-gl` (or `virtio-gpu-gl`) and Venus: QEMU 9.2 or later built with virglrenderer |
| virglrenderer | 1.1.0 | 1.0 or later with Venus enabled (`-Dvenus=true`) |
| Host GPU | Intel Iris Xe (Alder Lake), Mesa ANV | any GPU with a Vulkan 1.3 driver that can export dma-bufs (Mesa ANV or RADV; NVIDIA's driver is untested) |
| Display | Proxmox's `virtio-gl` display (egl-headless + noVNC) | an OpenGL display backend (`egl-headless`, `gtk,gl=on`, `sdl,gl=on`, `spice-app,gl=on`) |

On Proxmox, the VM's config needs (`qm set` or `/etc/pve/qemu-server/VMID.conf`):

```
vga: virtio-gl
args: ... -global virtio-vga-gl.venus=on -global virtio-vga-gl.blob=on -global virtio-vga-gl.hostmem=2G
```

On plain QEMU:

```
-device virtio-vga-gl,venus=on,blob=on,hostmem=2G -display egl-headless,rendernode=/dev/dri/renderD128
-object memory-backend-memfd,id=mem,size=8G,share=on -machine memory-backend=mem
```

`hostmem` is the window the guest maps GPU memory through; 2 GB is plenty for a desktop. Venus needs the guest's
memory to be shareable with the host renderer (memfd on plain QEMU; Proxmox does it for you).

### Guest

- macOS 26 (Tahoe) on x86_64, booted by OpenCore. Tested on 26.7.3 (25G342). The Metal desktop depends on one
  internal of CoreDisplay; on a build where it differs, the driver detects it and keeps the software desktop.
- At least 4 cores and 8 GB of memory.
- **SIP** relaxed to allow unsigned kexts and an unrestricted file system: `csr-active-config` = `03020000`
  (0x203: kext signing off, file system protections off, unapproved kexts allowed).
- **AMFI** relaxed: `amfi_get_out_of_my_way=1` in boot-args (WindowServer loads the driver's ad-hoc signed Metal
  bundle).

`install.sh --set-security` writes both into OpenCore's `config.plist` for you.

## Security

The two settings above turn off protections macOS normally relies on: any kext and any code library can then load.
That is how every unsigned GPU driver for macOS works (Apple signs only its own), and it is why Venera is meant for
VMs you use for testing and development, not for a VM that holds anything you need to protect. The driver itself:

- runs Venus in the guest (Mesa's Venus driver as a library inside each Metal process); on the host it is
  virglrenderer inside QEMU, so a guest that can reach Venus can reach the host's Vulkan driver;
- lets only WindowServer register display surfaces with the kernel, and only surfaces the caller created;
- falls back to the software desktop by itself when WindowServer fails twice with the Metal driver loaded.

## Install

In the guest, as an administrator:

```bash
tar -xzf Venera-0.1.0.tar.gz
cd Venera-0.1.0
sudo ./install.sh --set-security      # or without --set-security when SIP and AMFI are already relaxed
sudo shutdown -r now
```

`install.sh` finds OpenCore's EFI partition (or `--oc /Volumes/EFI` when it can't decide), backs up `config.plist`
next to it (`config.plist.venera-DATE`), and then:

1. copies `VirtioGPU.kext` (the core: virtio transport, display, cursor, Venus contexts) into `EFI/OC/Kexts` and
   adds it to `Kernel > Add` (it must load from the Boot kernel collection, which only OpenCore can add to);
2. sets `vgpuaccel=4` in OpenCore's boot-args;
3. puts `VirtioGPUFramebuffer.kext` and `VirtioGPUAccel.kext` in `/Library/Extensions` and rebuilds the Auxiliary
   kernel collection (no approval prompt with SIP as above);
4. installs the Metal driver: a copy kept in `/Library/GPUBundles/Venera`, a copy on the system volume
   (`/System/Library/Extensions`, with a new blessed system snapshot) when authenticated root is off, and
   `/Library/GPUBundles/VirtioGPUMetal.bundle` pointing at it;
5. starts the watcher (`local.venera.watch`, below).

Options: `--level 2` installs everything with the software desktop (the framebuffer and the accelerator, Metal only
for allow-listed test tools); `--no-opencore` skips step 1 and 2 for people who manage `config.plist` themselves (add
`VirtioGPU.kext` with `ExecutablePath` `Contents/MacOS/VirtioGPU`, and `vgpuaccel=4` to boot-args);
`--no-system-volume` leaves the system volume (and authenticated root) alone; `--dry-run` prints every change without
making it.

### Which processes use the driver

WindowServer (the desktop) and every app: a process running from an `.app` bundle, and the graphics process WebKit
starts for Safari and other web views. Background daemons (Spotlight's indexers, photo and media analysis...) don't,
and neither do `loginwindow` and `SecurityAgent`, the processes that let you log in. `/Library/GPUBundles/VirtioGPUMetal-allow.txt`
changes that, one line each: a process name adds it, `-name` excludes it, `*` adds every process, `apps-off` turns
the apps default off.

### Why the system volume, and the watcher

Safari's graphics process is sandboxed: it may only load code from the sealed system volume, so WebGL (and Safari's
GPU-drawn canvas and page effects) can use the driver only when a copy is in `/System/Library/Extensions`. Writing
there needs SIP's authenticated root off (csr bit `0x800`; `--set-security` sets `0xA03`, which includes it), and a
new system snapshot, as OpenCore Legacy Patcher does for its root patches.

A macOS update replaces the system volume and takes that copy with it. The watcher (a LaunchDaemon, at boot, every
30 minutes and when its folders change) notices, points `/Library/GPUBundles` at the kept copy at once so the desktop
and every app keep Metal (only Safari's WebGL waits), and asks the logged-in user whether to reinstall the system
copy; on yes it does, and offers to restart. If it can't (authenticated root is on again), it says why and what to
run. "Not now" is remembered until the macOS build changes; `sudo "/Library/Application Support/Venera/venera-watch.sh" --ask`
asks again. Its log is `/Library/Application Support/Venera/watch.log`; `./status.sh` shows where the driver is loaded from.

After the reboot the desktop looks the same, but `sudo ./status.sh` should show the three kexts loaded,
`MetalPluginName` `VirtioGPUMetal`, a growing flip count (`VirtioGPUBlobFlips`) and the driver's location.

The first minutes after the first boot are slower: the driver translates each new shader the first time it is needed
(a few seconds for large ones) and keeps it on disk. The watcher also gathers every process's translations into one
pool, `/Library/GPUBundles/Venera/cache` (under 256 MB), which every process reads on a miss, so a shader is translated
once for the whole machine, not once per app: a new app, or Safari's GPU process after an update, starts with what
WindowServer and the Dock already translated.

## Uninstall

```bash
sudo ./uninstall.sh
sudo shutdown -r now
```

It removes the Metal driver, its shader cache, both kexts (rebuilding the Auxiliary KC from whatever else is in
`/Library/Extensions`), and the OpenCore entry, kext and `vgpuaccel` boot-arg (`config.plist` backed up first). SIP
and AMFI stay as they are; restore them from a `config.plist.venera-*` backup, or set `csr-active-config` back to
`00000000` and drop `amfi_get_out_of_my_way=1`.

## Recovery

- **The desktop falls back by itself**: when WindowServer fails twice with the Metal driver, the accelerator withdraws
  it and the next WindowServer composites in software on the same framebuffer. `./status.sh` shows
  `VirtioGPUGuard` and why.
- **Software desktop, driver still installed**: set `vgpuaccel=2` in OpenCore's boot-args (or remove it), reboot.
- **No picture at all**: boot with the OpenCore picker, choose Reset NVRAM or edit `config.plist` from another OS
  (the VM's OpenCore disk can be mounted on the host while the VM is stopped) and disable the `VirtioGPU.kext` entry;
  without it macOS uses the firmware's framebuffer. A snapshot from before the install is the fastest way back.

## Tuning (optional)

Files in `/Library/GPUBundles` the Metal driver reads (root only; delete them to go back to the defaults):

- `VirtioGPUMetal-depth`: how many display command buffers may be in flight, 1-16 (default 6; lower is less lag,
  higher is smoother under load). Read again once a second.
- `VirtioGPUMetal-fetchmode`: `0` emulates Metal's framebuffer fetch with copies instead of sampling the
  attachment in place (the default since 0.1.0's last round; in place needs Venus' `VK_EXT_attachment_feedback_loop_layout`
  and falls back to copies without it). Read when WindowServer starts: reboot after changing it.
- `VirtioGPUMetal-gputime`: log GPU timings every 5 s (costs a little).

The accelerator flips at most once per 12 ms by default (`vgpuflipms=N` boot-arg, 0 = no limit).

## Known limits

- One display, in the modes the host offers (1024x768 to 1920x1080 on Proxmox; switching works with the Metal
  desktop running); no HDR, no multiple displays yet.
- **Proxmox's noVNC console shows at most ~33 fps**: QEMU's VNC server sends an update at most every 30 ms
  (`VNC_REFRESH_INTERVAL_BASE`), however fast the guest draws. The guest runs 50-60 fps; to see that, view the VM
  through a display that isn't VNC (QEMU's `gtk,gl=on` or `sdl,gl=on` on the host, or local SPICE with `gl=on`) or
  stream it from inside the guest.
- Apps: tested on VM 108 with Safari (WebGL, canvas, CSS effects at 60 fps), Preview and QuickTime (Core Image,
  video), Maps, Photos, Freeform, Calendar, Contacts, Notes, Music, TV, System Settings and others. OpenGL apps
  (Chess) still draw with macOS's software OpenGL; Core Image's stitched kernels fall back to its source path.
- WindowServer draws window drags, scrolling, resizing and minimizing at 45-60 fps on the tested host (mean frame
  gap 17-20 ms); each flip costs QEMU ~2-4 ms (egl-headless reads the frame back for VNC).
- `screencapture` from a shell needs Screen Recording permission for the app that runs it (Terminal), as usual.
