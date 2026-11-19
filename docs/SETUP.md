# Setting up a macOS VM with Venera

From nothing to a macOS Tahoe VM whose desktop, Metal and video run on the Proxmox host's GPU: one command on the
host, a few questions, then one command in macOS Recovery. About an hour, most of it macOS installing itself.

This guide is the short path. [vm/README.md](../vm/README.md) has everything the VM script does and its other choices;
[INSTALL.md](INSTALL.md) has Venera itself in depth (installing by hand, security, hardware video, recovery).

> **Experimental, home-lab.** Tested on macOS Tahoe 26.7.3 in Proxmox VE 9 on an Intel Iris Xe host. Take a backup or
> snapshot before changing a VM you care about.

## What you need

- A **Proxmox VE 9** node with an **Intel GPU** (an iGPU: Iris Xe was tested). The script checks the GPU and says what
  it finds.
- Internet access on the host and for the VM (Apple's recovery and macOS itself download during the install).
- About 70 GB of storage for the VM.

## 1. Run the setup command on the Proxmox host

Open the node's shell (in the Proxmox web page: **Datacenter > your node > Shell**, or `ssh root@your-node`) and paste:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jazzphone/venera/main/get-venera.sh)"
```

It downloads the newest Venera release's host package into `/root/venera`, checks it, and starts the VM script. The
script asks its questions, shows a plan, and changes nothing until you say **y** at "Go ahead?".

The questions (Enter keeps the answer in brackets):

| Question | Usually |
|---|---|
| VM name | anything, e.g. `macos` |
| Set it up for Venera | **Y** |
| Hardware video | **Y** (the host's GPU decodes and encodes video for the VM) |
| Safari WebGL | N, unless you need WebGL in Safari (it turns off one more security setting) |
| A sound device | Y (YouTube needs one) |
| Storage, bridge, VLAN, VM number, cores, memory, disk, screen size (up to 1920x1200) | the defaults, or yours |
| Set up node … too | Y for each node if the VM is in an HA group, so it can run on any of them |
| Where macOS comes from | **1**, macOS Tahoe's recovery from Apple |
| Model identifier | Enter (iMac20,1) |
| Mac identity: generate, your Mac's, or skip | **g** generates one just for this VM (see the note below) |

When it's done it tells you the next steps; they're the ones below.

**The Mac identity.** Every Mac has a serial number, a board serial and a Wi-Fi address. **g** makes a matching set
for this VM alone: fine for everything macOS does, but it isn't registered with Apple, so iCloud and iMessage may
refuse it. To sign into iCloud, use **m** and enter your own Mac's (from **System Information** on that Mac), now or
later (run the script again and choose **Its model and Mac identity**).

## 2. Start the VM and open its console

In the Proxmox web page: select the VM, **Start**, then **Console**. You'll see OpenCore's boot menu (white text on
black) for 5 seconds; it starts **macOS Base System**, Apple's recovery, by itself.

## 3. In the recovery: erase the disk, then install macOS with Venera

1. When the recovery's window appears (choose a language first if it asks), select **Disk Utility** and **Continue**.
2. In Disk Utility: **View > Show All Devices**. Select the empty disk of the size you chose (64 GB by default; not
   the small recovery or OpenCore disks), then **Erase**:
   - Name: `Macintosh HD` (or any name)
   - Format: **APFS**
   - Scheme: **GUID Partition Map**

   Then **Done**, and quit Disk Utility (**Disk Utility > Quit Disk Utility**) to get back to the recovery's window.
3. Open **Utilities > Terminal** (in the menu bar at the top), type this and press Return:

   ```bash
   "/Volumes/Venera Tools/install-venera"
   ```

4. It finds the disk you erased and asks Venera's choices. Enter keeps each default:
   hardware video (yes), the Venera app (yes), the Proxmox guest agent and shared clipboard (yes), Safari WebGL (no).
5. It shows Apple's macOS license (Space for the next page, `q` at the end) and asks whether you agree. Type **y**,
   then press Return to install.

macOS's installer now downloads macOS (several GB) and installs it. **Leave it alone:** the VM restarts by itself a
few times over 30-45 minutes, and OpenCore picks the right disk at each restart. At macOS's first startup Venera
installs itself and the VM restarts **once more**. Then Setup Assistant appears, already drawn by the host's GPU.

*If you'd rather install macOS first:* skip the Terminal step, choose **Reinstall macOS Tahoe** in the recovery, and
after setup open **Install Venera** on the **Venera Tools** disc on the desktop. Either way ends in the same place.

## 4. Setup Assistant

Go through it as on any Mac: country, account, and so on. If the VM has a generated identity, choose **Set Up Later**
for the Apple Account.

Then open the **Venera Tools** disc on the desktop, its **Extras** folder, and double-click:
- **Quieter macOS**: no automatic macOS upgrades (Venera is tested on each macOS release before it's supported; a
  newer macOS can fall back to the slower software desktop until then), and fewer background services using the CPU
  (photo and media analysis, Siri, Game Center, diagnostics uploads);
- **Server Settings**, if the VM should stay on: never sleep, no hibernation file, no screen saver, restart after a
  freeze, the clock from the network; SSH and Screen Sharing if you want.

Each asks before every change (Enter takes the suggestion) and can be undone; [extras/README.md](../extras/README.md)
has the list. To do it by hand instead, in **System Settings**: **General > Software Update > Automatic Updates**
(turn off installing macOS updates), **Energy** (never sleep) and **General > Date & Time** (set time automatically).

## 5. Finish, on the host

Back in the Proxmox node's shell, run the same command again (or `/root/venera/Venera-host-*/proxmox-macos-vm.sh`),
type the VM's name, and choose **1 Finish**. It turns on hardware video on the host (on each node the VM may run on),
switches the guest agent to its faster port, takes out the installer disks, and restarts the VM.

That's it. In macOS, **System Information > Graphics/Displays** shows the Virtio GPU with Metal; the Venera app in
the menu bar tells you if something needs you. Proxmox's **Summary** page shows the VM's IP addresses, **Shutdown**
shuts macOS down cleanly, and the console's clipboard is shared with macOS.

## Later

Run the setup command again and name the VM:
- **Upgrade Venera**: a newer release, host and macOS together.
- **Its model and Mac identity**: another model, your own Mac's identity for iCloud, or a newly generated one.
- **Startup settings**: the screen size (up to 1920x1200), verbose startup, OpenCore's menu, Venera on or off at
  startup, and other boot-args.
- **OpenCore**: move an older VM to Venera's OpenCore.

## When something goes wrong

- **The desktop is black or broken after an update**: start the VM, and at OpenCore's menu (press an arrow key in the
  first 5 seconds) choose the **Recovery** entry. In its **Utilities > Terminal**:

  ```bash
  "/Volumes/Venera Tools/install-venera" remove
  ```

  Venera comes out at the next startup and macOS starts on the basic display; `install-venera` (without `remove`)
  puts it back. The Venera Tools disc must be attached (the VM's **Hardware > CD/DVD Drive**:
  `Venera-Tools-VERSION.iso` from the ISO storage).
- **A hang or a crash you want to report**: `tools/serial-log.sh` in the repository keeps the VM's kernel log on the
  host, one file per boot (see the script's header).
- More: [INSTALL.md](INSTALL.md), "Recovery" and "Uninstall".
