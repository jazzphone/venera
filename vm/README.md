# The macOS VM, for reference

`proxmox-macos-vm.sh` is the script that made the macOS VM these drivers are developed on and for: a Proxmox VE VM
running macOS through OpenCore, able to sign into an Apple Account. It comes from an earlier project (the home device timer reader,
an earlier macOS VM script), where it was written on 2026-11-12, and is kept here unchanged as a
record of what such a VM needs. It is not part of Venera's build or install.

**License:** this folder is MIT (an earlier project's license), not Venera's PolyForm Noncommercial. It contains Apple's SMC key
(the `OSK` string QEMU's `applesmc` needs), as every open-source macOS VM project publishes it.

## What it sets up

Run on the Proxmox host as root. It asks before each change and touches nothing else (beyond turning on KVM's
`ignore_msrs`). For a new VM it:

- downloads the OpenCore image (thenickdude/KVM-Opencore v21) and macOS Sequoia's recovery from Apple;
- creates a q35 / OVMF VM: the host's own CPU (`-cpu host`, on the performance cores), QEMU's `applesmc` with the SMC
  key, a VMware SVGA display (`--vga vmware`) at 1280x800, vmxnet3, a virtio disk with no TRIM, USB keyboard and
  tablet, and an ISA serial port for `mac-guest-agent`;
- adds Lilu 1.7.2 and VMHide to OpenCore, so the Apple Account sign-in doesn't see a VM;
- writes a real Mac's identity (model, serial, board serial, ROM) into OpenCore when given one; without it the VM keeps
  OpenCore's shared sample identity and must not be signed into iCloud.

For an existing VM it adds or changes that identity, or finishes the VM once macOS and its guest agent are in (the
clock, PerfPowerServices off, the installer disk). The comments at the top say what each piece is for and what broke
without it.

## How the VM differs today

- **macOS Tahoe 26.7.3,** upgraded inside the VM after a Sequoia install; Tahoe is the last macOS for Intel, so it
  stays there.
- **Code signing relaxed** for an earlier project's private entitlements: OpenCore boot-arg `amfi_get_out_of_my_way=1` and
  `csr-active-config` `01000000` (SIP `0x0001`), set by hand in OpenCore's `config.plist`; the script doesn't do it yet.
- **Venera's own test VM** uses a virtio-gpu display in place of `--vga vmware`; `docs/INSTALL.md` has what the host
  and the VM need for Venera.
