# Venera video: hardware video decoding for VM 108

macOS's VideoToolbox decodes on the Proxmox host's GPU through Apple's own paravirtualized-video protocol, which
Intel macOS ships whole except its kernel driver.

- `kext/VeneraVideo/` (the guest): provides `AppleVideoToolboxParavirtualizationDriver` and its user client on QEMU's
  `ivshmem-doorbell` device, loaded by OpenCore (`tools/deploy.sh video-kext`).
- `hostvideo/src/venera-videod.c` (the host): the ivshmem server and the host side of the protocol, decoding with
  FFmpeg over VA-API (`intel-media-va-driver` on the host) and copying frames into shared memory on the GPU
  (VA-API video processing into user-pointer surfaces). `hostvideo/src/vv_shm.h` is the shared layout.
- VM 108's `args` gain `-chardev socket,path=/run/venera-video.sock,id=vvideo -device ivshmem-doorbell,chardev=vvideo,vectors=1`;
  `venera-videod.service` starts before the guests.

Build and deploy: `tools/deploy.sh video-host` (a Debian amd64 container on the Mac builds FFmpeg 7.1.1 and the
program; nothing is compiled on the host), then `tools/redeploy.sh --no-build`.

Debugging: `kill -USR1` the service toggles verbose logging (and saves the messages it gets to
/root/vgpu/video/dump/, for `tools/pvdump.py`); `kill -USR2` logs every session's state. `venera-videod -replay MSG...`
plays recorded guest messages against the engine. `tools/vtprobe.m` (in the VM) lists VideoToolbox's decoders and
decodes a file; `tools/pvshim.c` stands in for the guest driver in one process; `tools/pvhost.m` runs Apple's host side
on a Mac as the reference.
