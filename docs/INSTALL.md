# Installing Venera

Venera gives an x86_64 macOS VM on QEMU/KVM accelerated graphics with no GPU passthrough. The guest's Metal runs on
the host's GPU through virtio-gpu's Venus (Vulkan) protocol, and the desktop's frames go to the screen straight
from the host GPU. It is experimental: read "Security" and "Recovery" before installing, and take a snapshot of the
VM first.

**A new VM on Proxmox:** `proxmox-macos-vm.sh`, in the host package, sets up everything below for you before macOS is
installed: the host's packages (on each cluster node the VM may run on), OpenCore with SIP and AMFI already relaxed, a
macOS Tahoe VM with the `virtio-gl` display, Venus, the address width, a sound device and the guest agent's virtio
port, and the Venera Tools CD with the guest package. After macOS is installed, open the package from that CD (it is on
the desktop), restart, and run the script again to Finish (video decoding on every node, the installer disks out). [vm/README.md](../vm/README.md) has the details (Venera's own OpenCore image, bringing your
own macOS disk or installer, moving an older VM to Venera's OpenCore). The rest of this page is for an existing VM,
or a host other than Proxmox.

**After a Proxmox update**, run `./install-host.sh --check` from the host package: it compares the host's QEMU,
virglrenderer, Venus render server, Mesa Vulkan and VA-API drivers with the versions the release was tested on
(`TESTED`), checks each piece, and prints the commands that go back to the tested versions if something changed.
`--hold` keeps those packages where they are through updates (their security fixes too) until `--unhold`.

## What you need

### Host

| | Tested | Needed |
|---|---|---|
| Hypervisor | Proxmox VE 9.2, pve-qemu 11.1.3 | QEMU with `virtio-vga-gl` (or `virtio-gpu-gl`) and Venus: QEMU 9.2 or later built with virglrenderer |
| virglrenderer | 1.1.0 | 1.0 or later with Venus enabled (`-Dvenus=true`) |
| Host GPU | Intel Iris Xe (Alder Lake), Mesa ANV | any GPU with a Vulkan 1.3 driver that can export dma-bufs (Mesa ANV or RADV; NVIDIA's driver is untested) |
| Display | Proxmox's `virtio-gl` display (egl-headless + noVNC) | an OpenGL display backend (`egl-headless`, `gtk,gl=on`, `sdl,gl=on`, `spice-app,gl=on`) |

On Proxmox (Debian 13), the host needs two packages beside its own: `apt install mesa-vulkan-drivers virgl-server`
(the GPU's Vulkan driver, and Venus's render server: without it the guest's Venus contexts are never really created).
In a cluster, every node the VM may run on needs them.

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

**Also limit the guest's physical address width to 40 bits** (`host-phys-bits-limit=40` in the `-cpu` option, e.g.
`-cpu host,host-phys-bits-limit=40,...` in the same `args:` line). Without it, the firmware can place the GPU's memory
window above 2^44, which macOS's kernel can't address, and the driver finds no GPU memory.

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
- falls back to the software desktop by itself when WindowServer fails twice, with the Metal driver loaded or before it
  gets that far (a missing or broken Metal driver).

## Install

### With the installer package

Copy `Install Venera VERSION.pkg` into the guest and open it, or, with no network or shared folder, attach the
**Venera Tools CD** (`Venera-Tools-VERSION.iso`, a release file with the package and a read-me): upload it to an ISO
storage in Proxmox (Datacenter > the storage > ISO Images > Upload), add it in the VM's Hardware as a CD/DVD drive,
and macOS shows "Venera Tools" on the desktop. Under **Customize**:

| Choice | Default | What it does |
|---|---|---|
| Graphics driver | always | everything below ("From the command line", steps 1-5) |
| Hardware video decoding | on | `VeneraVideo.kext` through OpenCore, for decoding and encoding; needs the host's half ("Hardware video decoding and encoding", below) |
| Venera app | on | `/Applications/Venera.app`, started at login (below, "The Venera app") |
| Proxmox guest agent | on | Venera's guest agent, so Proxmox works with the VM as with Linux and Windows guests (below, "The Proxmox guest agent") |
| Safari WebGL | off | turns off SIP's authenticated root in OpenCore and puts the Metal driver on the system volume; when authenticated root is already off, the driver goes there anyway |

The package runs `install.sh --set-security` with those choices as flags, keeps the release folder in
`/Library/Application Support/Venera/release`, writes what it did to `/Library/Application Support/Venera/install.log`,
and ends with **Restart**.

**When SIP has to change first** (a VM whose SIP doesn't yet allow unsigned kexts and an unrestricted file system), the
rest of the install can't run until SIP's new settings start at the restart. The package then changes only OpenCore's
security settings, and Venera finishes installing by itself after the restart (a minute or two, the one-time job
`local.venera.finish`), then restarts once more: right away at the login window, or after asking whoever is logged
in. `install.log` has both passes. A pass that fails tries again at the next boot, three boots at most.

The package isn't signed with a Developer ID yet, so macOS says it can't check it the first time you open it: in
**System Settings > Privacy & Security**, choose **Open Anyway** (once). A package copied into the VM without a web
browser or AirDrop (a shared disk, `scp`) carries no quarantine and opens without asking. `packaging/make-pkg.sh` signs
it when `SIGN_ID="Developer ID Installer: NAME (TEAM)"` names a certificate in the build Mac's keychain.

### From macOS Recovery

The Venera Tools CD also installs Venera from macOS Recovery's Terminal (OpenCore's picker > the macOS installer's
macOS Base System, or an installed macOS's Recovery; then Utilities > Terminal), with no desktop needed:

```bash
"/Volumes/Venera Tools/install-venera"            # or: install-venera remove
```

It lists the APFS volumes that are, or will be, macOS (whatever they're named), asks which, and asks the package's
choices. Then:

- **Before macOS is installed** (erase the disk in Disk Utility first: APFS): it starts macOS's installer itself
  (`startosinstall`, after showing Apple's license and asking whether you agree), with Venera added as installer
  packages (`Recovery/Venera Stage.pkg` and one small package per choice). The installer downloads macOS, as Reinstall
  macOS does, and restarts by itself; at macOS's first startup Venera installs and the VM restarts once, so Setup
  Assistant runs on the host's GPU. Files put onto the empty volume by hand wouldn't last: the installer clears it.
- **After it is installed**, with no package or network at hand: it unpacks the release onto that macOS's Data volume
  (`/Library/Application Support/Venera/release`) with the one-time startup job `local.venera.finish`, and macOS runs
  `install.sh` at its next startup with its own tools. When SIP isn't set for Venera yet, that pass sets OpenCore's
  security settings and restarts, and the next startup installs the rest and restarts once more, by itself
  (`install.log` has every pass).
- **As a rescue**: `install-venera` again puts this CD's release back (a broken or half-finished install), and
  `install-venera remove` runs `uninstall.sh --at-boot` at the next startup and restarts (a driver or a macOS update
  that left no usable desktop). A FileVault volume asks for a password of one of that Mac's users to unlock it.

Recovery keeps the firmware's display: Venera's core kext stands aside in a Recovery or installer boot (since core
0.5.9; before it, Recovery started with no picture once Venera was installed, and `-vgpuoff` in OpenCore's boot-args
was the way in).

### From the command line

In the guest, as an administrator:

```bash
tar -xzf Venera-0.1.5.tar.gz
cd Venera-0.1.5
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
6. installs the Venera app and its login item (`local.venera.helper`);
7. installs and starts the guest agent (`local.venera.agent`, below); this one runs in the first pass too, since it
   needs no restart. Its port's driver, `VeneraConsole.kext`, goes into OpenCore with step 1.

Options: `--level 2` installs everything with the software desktop (the framebuffer and the accelerator, Metal only
for allow-listed test tools); `--no-opencore` skips step 1 and 2 for people who manage `config.plist` themselves (add
`VirtioGPU.kext` with `ExecutablePath` `Contents/MacOS/VirtioGPU`, and `vgpuaccel=4` to boot-args);
`--no-system-volume` leaves the system volume (and authenticated root) alone; `--video` adds `VeneraVideo.kext` to
OpenCore (hardware video decoding); `--no-app` leaves out the Venera app; `--no-agent` leaves out the guest agent (or
takes it out); `--dry-run` prints every change without making it.

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

### The Proxmox guest agent

Venera's own guest agent (`/Library/Application Support/Venera/venera-agent`, the launch daemon `local.venera.agent`)
speaks the QEMU guest agent protocol that Proxmox uses with Linux and Windows guests. With it:

- **Shutdown** and **Reboot** on the Proxmox page (and `qm shutdown`, HA, a node's shutdown) shut macOS down cleanly,
  with no "quit the apps?" dialogs; without an agent Proxmox presses the virtual power button, which macOS answers with
  a dialog that nobody sees;
- the VM's **Summary** shows its IP addresses, and `qm agent VMID` answers `get-osinfo`, `get-host-name`, `get-users`,
  `get-fsinfo`, `get-time`, `get-vcpus` and the rest;
- the host can run commands and copy files in: `qm guest exec` (with `--pass-stdin`), the API's `agent/file-write` and
  `agent/file-read` (a Proxmox bug: `qm guest exec` sends only part of a command with a character past U+07FF in it,
  a check mark or an emoji, and times out; the agent drops what it left behind and answers the next request);
- `qm guest passwd VMID USER` sets a local account's password, as an administrator's reset does (the login keychain
  keeps the old password, and macOS offers to update it at the next login);
- a backup's `fs-freeze` syncs the disks (APFS can't be frozen from outside the kernel: macOS reports no file system
  frozen, and the backup goes on as crash-consistent), and `fstrim` says APFS trims by itself.

macOS VMs don't sleep or hibernate here, so the suspend commands answer "Unsupported", as do Linux's memory-block
commands.

**The clipboard.** With the same choice comes `venera-clipboard` (the LaunchAgent `local.venera.clipboard`, in each
logged-in user's session): copy in macOS and paste in the Proxmox console's clipboard panel, or the other way, as
spice-vdagent does for Linux guests. It speaks the SPICE agent protocol on QEMU's `com.redhat.spice.0` port
(through VeneraConsole.kext, which lets the logged-in user open that port and only root the agent's). In Proxmox,
set the VM's **Hardware > Display > Clipboard** to **VNC** (`vga: virtio-gl,clipboard=vnc`) and restart the VM: QEMU's
own vdagent then joins the noVNC console's clipboard to it (text, UTF-8). Left at the default, the port goes to a
SPICE client instead (remote-viewer), which also takes images (PNG). A VM pinned to a machine version below 10.1
can't live-migrate with the VNC clipboard; the VM script turns it on only where it can (new VMs, Ready, Finish).
Its messages are in the unified log: `log show --last 1h --predicate 'process == "venera-clipboard"'`.

**Turn it on in Proxmox**: the VM's **Options > QEMU Guest Agent**: on, with **Type** VirtIO (the default), then shut
the VM down and start it (QEMU adds the port when it starts). The agent also answers on the ISA serial port (Type ISA),
about ten times slower; a VM made by `proxmox-macos-vm.sh` before 0.1.6 has that one, and its Finish switches it. The
agent takes the place of `mac-guest-agent` if that is installed (its launch daemon is set aside in
`/Library/Application Support/Venera/replaced`; `uninstall.sh` puts it back).

It runs as root and answers only on the VM's agent port, which only the Proxmox host can reach: the host already
controls the whole VM, so it can do nothing through the agent that it couldn't do without it. Untick **Proxmox guest
agent** under Customize (or `install.sh --no-agent`) to go without it. Its log is `/var/log/venera-agent.log`.

**Its port's driver.** The virtio agent port is a port of QEMU's virtio-serial device, and Venera drives that device
itself with `VeneraConsole.kext` (through OpenCore, with this choice, from the next restart). macOS's own driver for
it (AppleVirtIOConsole, made for Apple's Virtualization framework) stops sending for good when the host hangs up while
an answer is on its way, and its tty then holds the agent's writes and even its exit; Proxmox hangs up on any answer
it waited 5 s for. VeneraConsole treats the host closing and opening the port as what QEMU says it is (QEMU discards a
closed port's output), so nothing waits: tested by hanging up mid-answer three times in a row, the next connection was
answered at once. Without it (an install without OpenCore, or before the restart) the agent works through macOS's
driver and gets out of a stall by dropping that answer and reopening the port.

Every answer is kept to about 2 s of the port, so Proxmox never has to hang up: `qm guest exec` output past ~1.1 MB
comes back cut and marked truncated (as QEMU's own agent does past 16 MB), and `agent/file-read` simply takes more
pieces (a 5 MB file in about 5 s).

## Hardware video decoding and encoding

Apps that decode with VideoToolbox (Safari, QuickTime, Photos, every AVFoundation player) decode H.264, HEVC (8 and
10-bit) and VP9 on the host's GPU, up to 4K. 4K 10-bit (HDR video, macOS's own wallpaper movies) needs VeneraVideo
0.2.1 in the guest and Venera 0.1.4's host or later; with either half older, those frames fail. Apps that encode
with it (QuickTime and AVFoundation exports, `avconvert`, screen recordings, anything with a `VTCompressionSession`)
encode H.264 and HEVC (8-bit) there too, when the host's GPU can (the host's installer says what it encodes). Measured
on an Iris Xe host (VM 108): H.264 720p ~295 fps, 1080p ~175 fps, 4K ~55 fps; HEVC 720p ~370 fps, 1080p ~200 fps, 4K
~60 fps, against Apple's software encoder in the VM at ~90 fps for H.264 720p and ~7 fps for HEVC 720p. Encoding needs
VeneraVideo 0.2 or later in the guest; with an older one the host offers no encoders and the guest encodes in software
as before. With Venera 0.1.2's and 0.1.3's host, a long export through the host ran macOS out of memory (each frame
was kept until the export ended: ~16,000 frames on an 8 GB VM); 0.1.4's fixes it. The guest's half is the
package's "Hardware video" choice (`install.sh --video`). The host's half is `Venera-host-VERSION.tar.gz`,
for a Proxmox host with an Intel GPU:

```bash
tar -xzf Venera-host-0.1.5.tar.gz
cd Venera-host-0.1.5
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

**In a cluster, run it on every node the VM may run on** (HA can start the VM on any of them, and a VM with the device
won't start where its socket is missing). On the node that holds the VM it also adds the device to the VM's config,
which the cluster shares; on the others it sets up only the socket and service (`--status` lists them as "ready for
when it runs here"). Each node needs Venus as well (`mesa-vulkan-drivers` and `virgl-server`, under "Host" above). A VM
with Venus or the video device can't live-migrate: HA moves it by shutting it down and starting it on the other node.

**A VM with the device needs `VeneraVideo.kext`.** Without it, Apple's VirtIO driver takes the device and hangs on
it, and the boot doesn't publish the partitions of disks found after it -- the OpenCore disk among them, so an
installer finds no OpenCore. So install the guest's half before the VM starts with the device; the installer adds
the kext whenever the device is there (even with "Hardware video" unticked), and the uninstaller keeps it
until the device is gone (`--remove-vm` on the host, start the VM again, run the uninstaller again).

### Which processes use the driver

WindowServer (the desktop), every app (a process running from an `.app` bundle, an app extension (`.appex`, such as the
Memoji editor), and the graphics process WebKit starts for Safari and other web views), and the background services that draw for the screen: `iconservicesagent`
(every icon Finder, the Dock and open panels show), `CursorUIViewService`, `avconferenced` (video calls) and
`mediaanalysisd` (the photo library's analysis), and the login window's `loginwindow` and `SecurityAgent` (since
0.1.10: they draw the login screen's user pictures and background). Other daemons don't. Each process on the driver
costs the host about 58 MB.
`/Library/GPUBundles/VirtioGPUMetal-allow.txt` changes that, one line each: a process name adds it, `-name` excludes
it, `*` adds every process, `apps-off` turns the apps (and services) default off, `services-off` the services alone.
If the login window ever misbehaves on the driver, `-loginwindow` and `-SecurityAgent` keep it off; from macOS's
Recovery the file is `/Volumes/Data/Library/GPUBundles/VirtioGPUMetal-allow.txt` (the Data volume's name may differ).

A Metal call the driver doesn't have yet is answered with nothing (an empty object or zero) rather than crashing the
app, and logged: `status.sh` lists the ones of the last day by app, under "Metal calls the driver lacks". An app that
draws wrong usually shows up there, and that list is the report that helps.

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

Most of that first wait was one shader: Core Animation's uber shader, which WindowServer asks for in a few dozen sets
of function constants, one after another. The driver carries the list of those sets (`warm.txt` in its Resources:
the function's name and the constants' values, nothing of Apple's shaders), and the first time WindowServer asks for
that function it translates the other listed sets in the background on the VM's other cores (`VGMTL_NOWARM=1` turns
it off for a process), so most of WindowServer's later requests find them ready.

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

- **The desktop falls back by itself**: when WindowServer fails twice with the Metal driver, or twice on the display
  pipe before it gets to Metal (a missing Metal driver), the accelerator withdraws it and the next WindowServer
  composites in software on the same framebuffer. `./status.sh` shows
  `VirtioGPUGuard` and why.
- **Software desktop, driver still installed**: set `vgpuaccel=2` in OpenCore's boot-args (or remove it), reboot.
- **No picture at all**: boot with the OpenCore picker, choose Reset NVRAM or edit `config.plist` from another OS
  (the VM's OpenCore disk can be mounted on the host while the VM is stopped) and disable the `VirtioGPU.kext` entry;
  without it macOS uses the firmware's framebuffer. A snapshot from before the install is the fastest way back.
- **From macOS Recovery**, with the Venera Tools CD attached: `install-venera remove` takes Venera out at the next
  startup, and `install-venera` puts it back ("From macOS Recovery", above).

## Tuning (optional)

Files in `/Library/GPUBundles` the Metal driver reads (root only; delete them to go back to the defaults):

- `VirtioGPUMetal-depth`: how many display command buffers may be in flight, 1-16 (default 6; lower is less lag,
  higher is smoother under load). Read again once a second.
- `VirtioGPUMetal-fetchmode`: `0` emulates Metal's framebuffer fetch with copies instead of sampling the
  attachment in place (the default since 0.1.0's last round; in place needs Venus' `VK_EXT_attachment_feedback_loop_layout`
  and falls back to copies without it). Read when WindowServer starts: reboot after changing it.
- `VirtioGPUMetal-perf`: log where WindowServer's frames spend their time every 5 s (to
  `/var/tmp/VirtioGPUMetal.log` and the system log; WindowServer notices the file within 5 s).
- `VirtioGPUMetal-gputime` adds GPU timings and the uncertainty of the GPU-to-guest clock calibration.
  Read when a process starts. With `perf`, compare the pre-submit, completion dispatch, predecessor wait and
  Venus fence probe counters. Timestamp queries add their own work, so use the same timing flags in both builds
  when comparing frame times.
- `VirtioGPUMetal-initperf` logs the time to load the Vulkan driver, create an instance, enumerate the GPU and
  its capabilities, create a logical device and set up its queue. Leave the file empty for all processes or list
  process names, one per line.
- `VirtioGPUMetal-skipsoftware` asks the bundled Venus driver to skip full capability queries for CPU Vulkan
  devices. Metal already selects a hardware GPU. Use with `initperf` to compare fresh launches. Read when a
  process starts. This experiment is off by default.
- `VirtioGPUMetal-eagerlib`: read every shader of a Metal library when it loads, as before 0.1.9 (the driver reads
  one when an app first asks for it). Read when a process starts.
- `VirtioGPUMetal-faildump`: save the text of each shader the translator can't take, to the process's cache folder
  (`faildump/NAME-STAGE.ll`, beside `spirv/`), to try the translator on. Its lines name the processes it's for, or
  it's empty for every process.
- `VirtioGPUMetal-shaderdump`: the functions it names (one a line) saved as each process translates them, to
  `/var/tmp/VirtioGPUMetal-shaderdump/NAME-STAGE.ll`, `.fc` (the function constants) and `.spv`, to try the translator
  on. A process with `VGMTL_NODISKCACHE=1` translates what its cache would have answered.
- `VirtioGPUMetal-novtfix`: leave VideoToolbox's reply wait as Apple ships it. Since 0.1.10 the driver corrects it in
  each process it loads into (Intel VideoToolbox turns a 10 s timeout into a 32-bit count of nanoseconds, which
  overflows), so a synchronous video decode gets its frame before the call returns, as on a Mac: the moving
  wallpaper's first still needs that. Only VideoToolbox's copy in that process's memory changes. Read when a process
  starts.
- `VirtioGPUMetal-nosibling`: keep a surface's images in other texel sizes in step through its CPU copy only, as in
  0.1.10 (since 0.1.13 the driver copies them from each other on the GPU; VideoToolbox's Metal transfer reads a
  picture's plane that way, for the login window's list of users and the Memoji picker). For comparing; with it, those
  pictures can come out stale. Read when a process starts.
- `VirtioGPUMetal-scanoutwriteback`: copy CoreDisplay's scanout surfaces back to CPU memory when the display hasn't
  shown them yet, as before 0.1.13 (since then only the display reads them, through their twins). Read when
  WindowServer starts.
- `VirtioGPUMetal-ringidle` holds a number of microseconds (100 to 100000): how long the host's Venus ring thread
  keeps polling after the last command before it sleeps and needs a wake-up (default 1000). For measuring; 20000
  made no difference to WindowServer. Read when a process starts.
- `VirtioGPUMetal-framesig` (WindowServer) logs a signature of what the display shows after each presented frame,
  with its time, whenever it changes: when the screen settles after a click, to time how long a window or a System
  Settings pane takes to be usable. Read when WindowServer starts.
- `VirtioGPUMetal-selectivewriteback`: copy SkyLight's "Selective Sharing" surface back to CPU memory and wait for
  it, as before 0.1.13. While the screen is shared it is written every frame and only read on the GPU (Screen
  Sharing reads the display stream's surfaces). Read when WindowServer starts.
- `VirtioGPUMetal-locknames`: a reader that waits (ScreensharingAgent) logs each surface it locks, once. Read when
  the process starts.
- `VirtioGPUMetal-nolockwait`: Screen Sharing's frames waited for by WindowServer again, as in 0.1.12. Since
  0.1.13 Screen Sharing's capture process (`ScreensharingAgent`) waits in its IOSurfaceLock for a frame's CPU copy,
  as on a Mac, and WindowServer doesn't: it keeps its frame rate while someone shares the screen. Read when a
  process starts (restart macOS after changing it).
- `VirtioGPUMetal-lockwait`: the reader processes that wait, one a line, in place of `ScreensharingAgent` (a screen
  recorder, say). With `VirtioGPUMetal-lockwaitmeasure` too, they only log the timing of the display stream's frames
  and locks every 5 s, without waiting. Read when a process starts.
- **A major macOS upgrade needs a Venera release that knows it first**: the VM's SMC is acidanthera's VirtualSMC
  (through Lilu), and it runs only on the macOS versions its release knows (Tahoe in Lilu 1.7.2 and VirtualSMC 1.3.8).
  On a newer macOS it stays off, and with no SMC macOS can't start its apps. Upgrade Venera before the macOS upgrade
  (Venera's kexts need that too); to try a newer macOS anyway, add `-lilubeta -vsmcbeta` to the boot-args.

- **A VM needs a sound device for YouTube and other streaming sites**: Safari's streaming playback (Media Source
  Extensions) won't start without a default audio output, and keeps retrying (CoreAudio logs `-66680 ...
  Default-Output`). macOS has no driver for QEMU's Intel HDA, but drives USB audio itself: add
  `-audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd` to the VM's `args:` (sound plays in Proxmox's SPICE
  console; `none` instead of `spice` drops it) and shut the VM down and start it again.
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
