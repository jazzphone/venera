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
cores, memory, disk, the screen size at boot, and optionally your Mac's identity for iCloud. Then it:

- installs what the host is missing, on this node and each node you choose: `mesa-vulkan-drivers` and
  `virgl-server` (Venus), `libgl1` and `libegl1` (QEMU's GL display), and `unzip`, `dmg2img`, `genisoimage` for its
  own work; and turns on KVM's `ignore_msrs`;
- downloads the OpenCore image (thenickdude/KVM-Opencore v21) and macOS Tahoe's recovery from Apple (OpenCorePkg's
  `macrecovery.py`), each checked against its checksum or Apple's chunklist;
- prepares OpenCore: Lilu 1.7.2 and VMHide (so the Apple Account sign-in doesn't see a VM), the screen size, and
  **SIP and AMFI already as Venera needs them** (`csr-active-config` 0x203, or 0xA03 with Safari WebGL;
  `amfi_get_out_of_my_way=1`). Venera's installer then runs in one pass, with no restart to change SIP first;
- creates a q35 / OVMF VM: the host's own CPU with `host-phys-bits-limit=40`, QEMU's `applesmc` with the SMC key, the
  `virtio-gl` display with Venus (blob resources, a 2 GB host memory window), a USB sound device (YouTube needs one),
  vmxnet3, a virtio disk with no TRIM, USB keyboard and tablet, and the guest agent's virtio port;
- attaches the **Venera Tools CD** (the release's `Venera-Tools-VERSION.iso`, or one made from the guest package) as a
  CD drive, from an ISO storage (a shared one when there is one, so HA can start the VM on any node). macOS shows it on
  the desktop.

Then, in the VM's console: install macOS from the recovery, open **Install Venera** on the Venera Tools CD (on the
desktop), and restart when it says so. Its **Proxmox guest agent** choice (on by default) is what lets Proxmox shut
macOS down cleanly and show its addresses, and what Finish and Upgrade talk to. Run the script again and choose
**Finish**.

What to expect on the way, before Venera is in:

- **OpenCore's menu at each restart.** The installer restarts the VM a few times, and OpenCore's menu starts on macOS
  Base System each time, not where the install is going: press an arrow key within 5 seconds to stop it, then pick
  macOS Installer while it installs, and Macintosh HD once it has (macOS Base System again goes back to the recovery).
- **Setup Assistant can stop on its last screen.** Without a graphics driver macOS draws in software, and the last
  step into the desktop can sit there for good. If it hasn't moved in a few minutes, restart the VM from the Proxmox
  page (Reboot, or Stop and Start): the account is already made, and macOS starts at the login window. The desktop is
  plain (no wallpaper) and slow until Venera is installed.

Without your Mac's identity the VM keeps OpenCore's shared sample serial, as an iMac20,1 (a model Tahoe supports), and
must not be signed into iCloud until you add yours (the script's third choice for an existing VM).

## An existing VM

Run it again with the VM's name:

1. **Finish**, once macOS and Venera are installed. It reads Venera's status in macOS through the guest agent, then:
   - turns on hardware video (decoding and encoding): `install-host.sh --vm VMID` on each node the VM may run on, the others first,
     so the VM finds its socket wherever HA starts it;
   - takes out the recovery disk (deleted) and the Venera Tools CD (its ISO stays in the storage, for the next VM);
   - moves the guest agent to its virtio port, when Venera's agent is in and the VM still has the ISA one (made
     before 0.1.6): about ten times faster;
   - sets the clock once and turns off Apple's power logging, which held a core at ~90% in the VM;
   - shuts the VM down and starts it again, since QEMU picks up a new device only when it starts.

   The video device waits until Finish because macOS hangs on it without `VeneraVideo.kext`.
2. **Ready for Venera**, for an older macOS VM (stopped). It installs the host's packages, switches the display to
   `virtio-gl`, adds Venus, the address width and the sound device to its `args:`, and attaches the Venera Tools CD. The
   VM's config is backed up first. Venera's installer then sets SIP and AMFI itself and finishes after a restart.
3. **Its Mac identity**: writes your Mac's model, serial, board serial and ROM into OpenCore. The old OpenCore disk is
   saved first.
4. **Upgrade Venera**, to the release the script came with, on a running VM that has Venera and the guest agent:
   - this release's host half: `install-host.sh --vm VMID` on each node the VM may run on, the others first (running
     VMs keep their video connections);
   - the guest package from a USB disk it plugs into the running VM, installed through the guest agent with the
     choices macOS has now (hardware video, the Venera app, the system-volume copy for Safari WebGL);
   - the disk unplugged, then macOS restarted. Whoever is logged in loses unsaved work: the plan says who that is.

## Where it came from

It began as an earlier project's VM script (an earlier macOS VM script,
2026-11-12), which made the VM these drivers were developed in. The comments at the top say what each piece is for and
what broke without it. `vm/test.sh` tests its pieces that need no Proxmox host: the args, a cluster node's address,
and the OpenCore edits against KVM-Opencore's own `config.plist`.

**License:** this folder is MIT (`vm/LICENSE`, an earlier project's license), not Venera's PolyForm Noncommercial. It contains
Apple's SMC key (the `OSK` string QEMU's `applesmc` needs), as every open-source macOS VM project publishes it.
