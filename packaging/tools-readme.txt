Venera Tools @VERSION@

Venera for a macOS VM on Proxmox: Metal graphics on the host's GPU, hardware video, and the Proxmox guest agent.

1. Open "Install Venera @VERSION@.pkg". Customize has the choices: hardware video, the Venera app and the Proxmox
   guest agent (all on), and Safari WebGL (off: it changes a security setting).
2. Restart when it says so.
3. If the VM was made by proxmox-macos-vm.sh, run it again on the Proxmox host and choose Finish: it turns on hardware
   video and the faster guest agent port, takes out the installer disks (this one too) and restarts the VM.
   Otherwise, in Proxmox: the VM's Options > QEMU Guest Agent: on (type VirtIO), then shut the VM down and start it.

The install guide: https://github.com/jazzphone/venera/blob/main/docs/INSTALL.md
