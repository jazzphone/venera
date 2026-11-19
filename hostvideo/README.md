# Venera video: hardware video decoding and encoding through the host

macOS's VideoToolbox decodes and encodes on the Proxmox host's GPU through Apple's own paravirtualized-video protocol,
which Intel macOS ships whole except its kernel driver.

- `kext/VeneraVideo/` (the guest): provides `AppleVideoToolboxParavirtualizationDriver` and its user client on QEMU's
  `ivshmem-doorbell` device, loaded by OpenCore (`tools/deploy.sh video-kext`).
- `hostvideo/src/venera-videod.c` (the host): the ivshmem server and the host side of the protocol, decoding with
  FFmpeg over VA-API (`intel-media-va-driver` on the host) and copying frames into shared memory on the GPU (vaCopy
  into user-pointer surfaces); `vv_encode.h` is the encoder; `hostvideo/src/vv_shm.h` is the shared layout.
- A VM's `args` gain `-chardev socket,path=/run/venera-video-VMID.sock,id=vvideo -device
  ivshmem-doorbell,chardev=vvideo,vectors=1`; `venera-videod@VMID.socket` (systemd) starts the service when QEMU
  connects. `packaging/host/install-host.sh --vm VMID` sets both up (`docs/INSTALL.md`).

Build and deploy: `tools/deploy.sh video-host` (a Debian amd64 container on the Mac builds FFmpeg 7.1.1 and the
program; nothing is compiled on the host) puts a new venera-videod over the installed host half
(`/opt/venera/video`, from `packaging/host/install-host.sh`) and restarts VM 108's service; the VM keeps its device.

Debugging: `systemctl kill -s USR1 venera-videod@VMID` toggles verbose logging (and saves the messages it gets to
/var/lib/venera-video/VMID/, the service's state folder, for `tools/pvdump.py`); `-s USR2` logs every session's
state. `venera-videod -replay MSG...` plays recorded guest messages against the engine. `tools/vtprobe.m` (in the VM)
lists VideoToolbox's decoders and decodes a file; `tools/vtenc.m` (in the VM) encodes and counts frames;
`tools/pvshim.c` stands in for the guest driver in one process; `tools/pvhost.m` runs Apple's host side on a Mac as
the reference.
