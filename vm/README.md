# A macOS VM on Proxmox, ready for Venera

`proxmox-macos-vm.sh` makes a macOS Tahoe VM on Proxmox VE that Venera can run in, and sets up the host for it. It
ships in the host package (`Venera-host-VERSION.tar.gz`) beside `install-host.sh` and the guest package; run it as root
on the Proxmox host from that unpacked folder:

```bash
tar -xzf Venera-host-VERSION.tar.gz
cd Venera-host-VERSION
./proxmox-macos-vm.sh
```

It checks the host, asks its questions, shows the plan, and changes nothing until you say yes. Saying no at the end is
a dry run.

## What it checks

- an Intel CPU (the VM runs as an Intel Mac on `-cpu host`) and KVM;
- the GPU: an Intel GPU gives Venera Metal, OpenGL and hardware video (decoding and encoding); an AMD GPU, Metal and OpenGL; with no GPU
  the host can render on (or one passed through to another VM), the VM gets a plain VMware display instead;
- QEMU 9.2 or later and virglrenderer 1.0 or later (Proxmox VE 9);
- in a cluster, each other node over the cluster's own SSH: its GPU and its packages. Only when the VM's disk is on
  shared storage (HA can start it on another node); a VM on a node's own storage stays there.

## A new VM

It asks for the name, Venera's choices (graphics, hardware video, Safari WebGL, a sound device), storage, network,
cores, memory, disk, the screen size at boot, where macOS comes from (below), and the VM's Mac identity (below). Then
it:

- installs what the host is missing, on this node and each node you choose: `mesa-vulkan-drivers` and
  `virgl-server` (Venus), `libgl1` and `libegl1` (QEMU's GL display), and `unzip`, `dmg2img`, `genisoimage` for its
  own work; and turns on KVM's `ignore_msrs`;
- copies **Venera's OpenCore image** from the host package (`opencore/OpenCore-Venera-VERSION.img`, below) and sets in
  it the screen size, a hardware UUID of the VM's own, and **SIP and AMFI already as Venera needs them**
  (`csr-active-config` 0x203, or 0xA03 with Safari WebGL; `amfi_get_out_of_my_way=1`). Venera's installer then runs
  in one pass, with no restart to change SIP first;
- downloads macOS Tahoe's recovery from Apple with OpenCorePkg's `macrecovery.py` (carried in the package, checked
  against Apple's chunklist), unless you brought your own macOS. That is the only download;
- creates a q35 / OVMF VM: the host's own CPU with `host-phys-bits-limit=40`, QEMU's `applesmc` with the SMC key, the
  `virtio-gl` display with Venus (blob resources, a 2 GB host memory window), a USB sound device (YouTube needs one),
  vmxnet3, a virtio disk (with TRIM on thin storage, asked: local-lvm, ZFS, Ceph or a disk file take freed space back;
  thick LVM and iSCSI can't, and a TRIM over iSCSI crawls), USB keyboard and tablet, and the guest agent's virtio port;
- attaches the **Venera Tools CD** (the release's `Venera-Tools-VERSION.iso`, or one made from the guest package) as a
  CD drive, from an ISO storage (a shared one when there is one, so HA can start the VM on any node). macOS shows it on
  the desktop.

Then, in the VM's console: install macOS from the recovery, open **Install Venera** on the Venera Tools CD (on the
desktop), and restart when it says so. Or, in the recovery, after erasing the disk: Utilities > Terminal,
`"/Volumes/Venera Tools/install-venera"`, which installs macOS with Venera already in. Its **Proxmox guest agent** choice (on by default) is what lets Proxmox shut
macOS down cleanly and show its addresses, and what Finish and Upgrade talk to. Run the script again and choose
**Finish**.

What to expect on the way, before Venera is in:

- **OpenCore's menu at each restart.** The installer restarts the VM three times, and Venera's OpenCore follows it by
  itself: the first time straight into the installer (no menu), then with Macintosh HD chosen in its menu (seen in a
  whole install, 2026-11-19). Nothing to pick. (KVM-Opencore's OpenCore 1.0.0 started on macOS Base System each time,
  which went back to the recovery.)
- **Setup Assistant can stop on its last screen.** Without a graphics driver macOS draws in software, and the last
  step into the desktop can sit there for good. If it hasn't moved in a few minutes, restart the VM from the Proxmox
  page (Reboot, or Stop and Start): the account is already made, and macOS starts at the login window. The desktop is
  plain (no wallpaper) and slow until Venera is installed.

### Where macOS comes from

By default, Apple's recovery for macOS Tahoe, which installs the newest Tahoe over the network. Or your own: the
script looks in every ISO storage's `template/iso` folder and its `import` folder (where Proxmox keeps disk images to
import) and offers what it finds:

- **a disk with macOS installed** (`.qcow2`, `.vmdk`, `.vhdx`, `.vdi`, or a raw `.img` / `.raw` of 20 GB or more):
  imported as the VM's disk, made as big as the disk size you gave if it is smaller. No install: the VM boots it. It
  must be an Intel (x86) macOS (from VMware Fusion, VirtualBox or Parallels on an Intel Mac, or another Proxmox VM);
  Apple Silicon VMs can't run here. Remove the old hypervisor's tools in macOS afterwards.
- **a macOS installer image** you made on a Mac (`createinstallmedia` onto a disk image, saved as `.img`, `.iso`,
  `.cdr` or `.dmg`): booted to install, offline, the version you chose (26.7.3, say, which Venera is tested on, where
  Apple's recovery gives the newest Tahoe).
- **a recovery image** you kept (`BaseSystem.dmg` or the `.img` an earlier run made): installs over the network, but
  doesn't depend on Apple still serving that recovery.

An `InstallAssistant.pkg` can't be used as it is: making a bootable installer from it needs macOS. On a Mac, install
it (it becomes "Install macOS Tahoe" in Applications), then `sudo /Applications/Install\ macOS\ Tahoe.app/Contents/Resources/createinstallmedia --volume /Volumes/Installer`
onto an 18 GB disk image made with Disk Utility, and copy the image to the ISO storage.

### Venera's OpenCore

`vm/opencore/build.sh` makes it at release time from acidanthera's OpenCorePkg release (1.0.8 now, BSD-3; the version
and checksum are in `packaging/UPSTREAM`) with three things of Venera's own: the config (`config.py`: OpenCore's
`Sample.plist` with what a QEMU q35 VM needs), one ACPI table (`SSDT-VENERA.dsl`: an EC device, the USB power
properties, the CPU's power-management plugin type) and **VeneraHide.kext**, which keeps `kern.hv_vmm_present` from
everything in macOS but software update, so the Apple Account sign-in doesn't turn the VM away. OpenCore's
`ocvalidate` checks the config, and the same sources always make the same image. There is no Lilu, no VMHide and
nothing from thenickdude's KVM-Opencore (which older VMs used: its last release, v21, has OpenCore 1.0.0 from 2024).
The menu is OpenCore's text one, 5 seconds, and lists only macOS volumes.

**The Mac identity** (the model, serial, board serial and Wi-Fi MAC address OpenCore gives macOS), for the model you
choose (iMac20,1 by default, one macOS Tahoe supports):
- **generate** (the default): a serial and board serial made for that model and for each other by OpenCorePkg's
  `macserial` (in the host package's `opencore/`, from the same pinned release): the serial's model code is the model's,
  the board serial's board code fits its board-id, both from the same factory and week, the board serial's checksum
  holds; and a Wi-Fi MAC address with one of Apple's prefixes. Each VM gets its own (the script adds the randomness:
  `macserial` for Linux has no random source of its own). Valid in form and unique, but registered with Apple for no
  Mac: macOS takes it, iCloud and iMessage may refuse it.
- **your Mac's**, to sign into iCloud: its serial, board serial and Wi-Fi MAC address (System Information on that Mac).
  The script decodes the serial's model and offers to make the VM that model when they differ (a MacBook's serial on
  an iMac20,1 doesn't match).
- **skip**: OpenCore's shared sample serial; never sign into iCloud with it.

The script's third choice for an existing VM changes it later (to yours, for iCloud, or a generated one).

## An existing VM

Run it again with the VM's name:

1. **Finish**, once macOS and Venera are installed. It reads Venera's status in macOS through the guest agent, then:
   - turns on hardware video (decoding and encoding): `install-host.sh --vm VMID` on each node the VM may run on, the others first,
     so the VM finds its socket wherever HA starts it;
   - takes out the recovery disk (deleted) and the Venera Tools CD (its ISO stays in the storage, for the next VM);
   - moves the guest agent to its virtio port, when Venera's agent is in and the VM still has the ISA one (made
     before 0.1.6): about ten times faster;
   - turns on the Proxmox console's clipboard (`vga: ...,clipboard=vnc`), which Venera's clipboard agent answers,
     unless the VM is pinned to a machine version below 10.1 (it couldn't live-migrate then). New VMs have it from
     the start;
   - sets the clock once and turns off Apple's power logging, which held a core at ~90% in the VM;
   - shuts the VM down and starts it again, since QEMU picks up a new device only when it starts.

   The video device waits until Finish because macOS hangs on it without `VeneraVideo.kext`.
2. **Ready for Venera**, for an older macOS VM (stopped). It installs the host's packages, switches the display to
   `virtio-gl`, adds Venus, the address width and the sound device to its `args:`, and attaches the Venera Tools CD. The
   VM's config is backed up first. Venera's installer then sets SIP and AMFI itself and finishes after a restart.
3. **Its model and Mac identity**: writes a model and Mac identity into OpenCore, yours or a generated one (above),
   starting from the model the VM has now. The old OpenCore disk is saved first.
4. **Upgrade Venera**, to the release the script came with, on a running VM that has Venera and the guest agent:
   - this release's host half: `install-host.sh --vm VMID` on each node the VM may run on, the others first (running
     VMs keep their video connections);
   - the guest package from a USB disk it plugs into the running VM, installed through the guest agent with the
     choices macOS has now (hardware video, the Venera app, the system-volume copy for Safari WebGL);
   - the disk unplugged, then macOS restarted. Whoever is logged in loses unsaved work: the plan says who that is.
5. **OpenCore**: moves the VM (stopped) to Venera's OpenCore image from this package: its EFI folder and config are
   replaced, and what was the VM's own is carried over (Venera's kexts and their entries, boot-args and SIP, the Mac
   identity, the screen size, the menu's timeout). What the old image brought that Venera doesn't need goes (Lilu,
   VMHide, WhateverGreen, AppleALC, the Broadcom Bluetooth kexts, OpenCanopy). The old OpenCore disk is saved to
   `/root` first; writing it back undoes the change.
6. **Startup settings**, the ones people change most, without editing `config.plist`:
   - **Screen size**: the size macOS's desktop starts at, up to 1920x1200 (QEMU's display reports it to Venera's
     framebuffer, as `-global virtio-vga-gl.xres/yres` in the VM's `args:`), and OpenCore's menu's and Recovery's;
   - **Verbose startup** (`-v`): the kernel's messages instead of the Apple logo;
   - **OpenCore's menu**: its seconds (1-30), to pick another disk or Recovery;
   - **Venera at startup**: off adds `-vgpuoff`, and macOS starts on the basic display (for a broken desktop);
   - **Other boot-args** (`keepsyms=1`, `debug=0x100`, ...). Venera's own (`amfi_get_out_of_my_way=1`,
     `vgpuaccel=N`) are kept;
   - **Model and Mac identity**: choice 3's questions;
   - **TRIM**: the space macOS frees goes back to the storage (the disk's `discard` and OpenCore's APFS TRIM),
     on thin storage only (local-lvm, ZFS, Ceph, a disk file).

   It shows the settings the VM has, changes them one at a time, then shows the plan. A running VM is shut down first
   (asked), and started again after (asked). The OpenCore disk is saved to `/root` and the VM's config to
   `/root/macos-vm-backup` first. Anything else in OpenCore: mount its EFI partition in macOS (the small OpenCore
   disk's, not the macOS disk's) and edit `EFI/OC/config.plist`.

   Choices 3, 5 and 6 work on a stopped VM; when it's running, the script offers to shut it down.

### When Proxmox updates

Venera's host side depends on packages Proxmox ships and updates: QEMU, virglrenderer and its render server, Mesa's
Vulkan driver, Intel's VA-API driver. The host package's `TESTED` lists the versions a release was tested on, and the
script warns when the host has moved on. After a Proxmox update, `install-host.sh --check` compares them, checks each
piece (the render server's libraries, the GPU's render node, the Vulkan and VA-API drivers), and if something changed
prints the `apt install PACKAGE=VERSION` lines that go back to the tested ones (Proxmox keeps older versions in its
repository). `install-host.sh --hold` keeps those packages where they are through updates until `--unhold` (their
security fixes wait too, so it's off unless you ask).

## Where it came from

It began as the author's script for a macOS VM in an earlier project (2026-11-12), which made the VM these drivers
were developed in. The comments at the top say what each piece is for and
what broke without it. `vm/test.sh` tests its pieces that need no Proxmox host: the args, a cluster node's address,
Venera's OpenCore config and the script's edits to it, and moving an older VM's config (KVM-Opencore's) onto it.

**License:** this folder is MIT (`vm/LICENSE`, the earlier project's license), not Venera's PolyForm Noncommercial. It contains
Apple's SMC key (the `OSK` string QEMU's `applesmc` needs), as every open-source macOS VM project publishes it.
