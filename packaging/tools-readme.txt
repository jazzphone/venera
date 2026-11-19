Venera Tools @VERSION@

Venera for a macOS VM on Proxmox: Metal graphics on the host's GPU, hardware video, and the Proxmox guest agent.

1. Open "Install Venera @VERSION@.pkg". Customize has the choices: hardware video, the Venera app and the Proxmox
   guest agent (all on), and Safari WebGL (off: it changes a security setting).
2. Restart when it says so.
3. If the VM was made by proxmox-macos-vm.sh, run it again on the Proxmox host and choose Finish: it turns on hardware
   video and the faster guest agent port, takes out the installer disks (this one too) and restarts the VM.
   Otherwise, in Proxmox: the VM's Options > QEMU Guest Agent: on (type VirtIO), then shut the VM down and start it.

From macOS Recovery (before macOS is installed, after it, or as a rescue), in Terminal (Utilities > Terminal):

    "/Volumes/Venera Tools/install-venera"

   It asks which volume is (or will be) macOS and the choices above. On a volume with no macOS yet (erase the disk in
   Disk Utility first: APFS), it starts macOS's installer with Venera added: at macOS's first startup Venera installs
   and the VM restarts once, so Setup Assistant runs on the host's GPU. On an installed macOS it puts Venera in for
   its next startup. "install-venera remove" takes Venera out the same way (when a driver or a macOS update left no
   usable desktop). A FileVault volume asks for its password.

Extras (any macOS VM, with or without Venera): "Quieter macOS" turns off background services a VM doesn't need
(automatic macOS upgrades, photo and media analysis, Siri, Game Center, diagnostics uploads; Spotlight's indexing if
you want), and "Server Settings" keeps it always on (no sleep or hibernation file, no screen saver, restart after a
freeze; SSH and Screen Sharing if you want). Double-click one: it asks before each change, and
  sudo "/Volumes/Venera Tools/Extras/venera-tune.sh" undo
puts back everything it changed.

The install guide: https://github.com/jazzphone/venera/blob/main/docs/INSTALL.md
