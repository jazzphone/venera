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

### With the installer package

Copy `Install Venera VERSION.pkg` into the guest and open it. Under **Customize**:

| Choice | Default | What it does |
|---|---|---|
| Graphics driver | always | everything below ("From the command line", steps 1-5) |
| Hardware video decoding | on | `VeneraVideo.kext` through OpenCore; needs the host's half ("Hardware video decoding", below) |
| Venera app | on | `/Applications/Venera.app`, started at login (below, "The Venera app") |
| Safari WebGL | off | turns off SIP's authenticated root in OpenCore and puts the Metal driver on the system volume; when authenticated root is already off, the driver goes there anyway |

The package runs `install.sh --set-security` with those choices as flags, keeps the release folder in
`/Library/Application Support/Venera/release`, writes what it did to `/Library/Application Support/Venera/install.log`,
and ends with **Restart**.

The package isn't signed with a Developer ID yet, so macOS says it can't check it the first time you open it: in
**System Settings > Privacy & Security**, choose **Open Anyway** (once). A package copied into the VM without a web
browser or AirDrop (a shared disk, `scp`) carries no quarantine and opens without asking. `packaging/make-pkg.sh` signs
it when `SIGN_ID="Developer ID Installer: NAME (TEAM)"` names a certificate in the build Mac's keychain.

### From the command line

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
5. starts the watcher (`local.venera.watch`, below);
6. installs the Venera app and its login item (`local.venera.helper`).

Options: `--level 2` installs everything with the software desktop (the framebuffer and the accelerator, Metal only
for allow-listed test tools); `--no-opencore` skips step 1 and 2 for people who manage `config.plist` themselves (add
`VirtioGPU.kext` with `ExecutablePath` `Contents/MacOS/VirtioGPU`, and `vgpuaccel=4` to boot-args);
`--no-system-volume` leaves the system volume (and authenticated root) alone; `--video` adds `VeneraVideo.kext` to
OpenCore (hardware video decoding); `--no-app` leaves out the Venera app; `--dry-run` prints every change without
making it.

### The Venera app

A small app that starts at login, with no Dock icon and no menu bar icon unless you turn one on. It says when
something needs you, as a notification (macOS asks once whether Venera may send them):

- after a macOS update took the Metal driver off the system volume, "Reinstall?" with the buttons, in place of the
  watcher's dialog;
- the desktop fell back to the software compositor this boot (and why);
- video decoding is installed but the host's video service wasn't running when the VM started.

Open it from Applications to see what runs: the desktop (Metal on the host's GPU, or the software desktop), where the
Metal driver loads from, video decoding, the version, and a button for the watcher's log. With notifications off, a
question waits in its window. "Show Venera in the menu bar" puts the same in a menu bar item.

## Hardware video decoding

Apps that decode with VideoToolbox (Safari, QuickTime, Photos, every AVFoundation player) decode H.264, HEVC (8 and
10-bit) and VP9 on the host's GPU, up to 4K. The guest's half is the package's "Hardware video decoding" choice
(`install.sh --video`). The host's half is `Venera-host-VERSION.tar.gz`, for a Proxmox host with an Intel GPU:

```bash
tar -xzf Venera-host-0.1.0.tar.gz
cd Venera-host-0.1.0
./install-host.sh --vm 108          # as root on the Proxmox host; --dry-run first to see each step
qm shutdown 108 && qm start 108     # the VM picks up its new device when QEMU starts again
```

It installs `intel-media-va-driver` (and `libva-drm2`) from the host's apt sources when they're missing,
`venera-videod` with the FFmpeg it was built with in `/opt/venera/video`, a socket and a service per VM
(`venera-videod@VMID.socket` and `.service`), and adds the VM's video device to its `args:` line (the VM's config is
backed up to `/opt/venera/backup` first). `--status` shows what runs, `--remove-vm VMID` takes one VM's device out,
`--uninstall` takes everything out again (packages only if it installed them). Nothing else on the host changes. An
older hand-made setup (`venera-videod.service` and `/run/venera-video.sock` in the VM's args) is replaced.

**The service decodes what the VM sends it, so it runs with as little as it can**: a user made for each run
(systemd's `DynamicUser`), the GPU's render node and nothing else in `/dev`, no network, a read-only file system, no
privileges or capabilities, a system-call filter, 2 GB of memory at most. Everything it reads from the VM is copied out
of the shared memory before it is parsed, and the parsers were fuzzed (`hostvideo/fuzz`).

**Restarts don't cost the VM its device.** systemd holds the socket from boot (the VM finds it even while the service
is down) and keeps the service's shared memory and the VM's connection across a restart (its file descriptor store):
an update or a crash carries on with them, back within ~100 ms, and the video in a player picks up at its next key
frame (a second or two). A host with no usable GPU still serves the VM, answering that it decodes nothing, so the
guest decodes in software. Debugging: `systemctl kill -s USR1 venera-videod@VMID` toggles verbose logging (and message
dumps in `/var/lib/venera-video/VMID`), `-s USR2` logs its state.

**A VM with the device needs `VeneraVideo.kext`.** Without it, Apple's VirtIO driver takes the device and hangs on
it, and the boot doesn't publish the partitions of disks found after it -- the OpenCore disk among them, so an
installer finds no OpenCore. So install the guest's half before the VM starts with the device; the installer adds
the kext whenever the device is there (even with "Hardware video decoding" unticked), and the uninstaller keeps it
until the device is gone (`--remove-vm` on the host, start the VM again, run the uninstaller again).

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
sudo "/Library/Application Support/Venera/uninstall.sh"
sudo shutdown -r now
```

It removes the Venera app, the Metal driver, its shader cache, the kexts (rebuilding the Auxiliary KC from whatever else is in
`/Library/Extensions`), and the OpenCore entry, kext and `vgpuaccel` boot-arg (`config.plist` backed up first). SIP
and AMFI stay as they are; restore them from a `config.plist.venera-*` backup, or set `csr-active-config` back to
`00000000` and drop `amfi_get_out_of_my_way=1`. On the host, `./install-host.sh --uninstall`.

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
  stream it from inside the guest. Away from home, noVNC also has to fit every frame through the link as compressed
  tiles: Proxmox's SPICE console (already on for `virtio-gl`; a client such as virt-viewer opens the `.vv` file the
  console menu gives) sends changing areas as a video stream, which usually holds up better on a slow link.
- Apps: tested on VM 108 with Safari (WebGL, canvas, CSS effects at 60 fps), Preview and QuickTime (Core Image,
  video), Maps, Photos, Freeform, Calendar, Contacts, Notes, Music, TV, System Settings and others. OpenGL apps
  (Chess) draw through the driver too; Core Image's stitched kernels fall back to its source path (slower the first time).
- WindowServer draws window drags, scrolling, resizing and minimizing at 45-60 fps on the tested host (mean frame
  gap 17-20 ms); each flip costs QEMU ~2-4 ms (egl-headless reads the frame back for VNC).
- `screencapture` from a shell needs Screen Recording permission for the app that runs it (Terminal), as usual.
