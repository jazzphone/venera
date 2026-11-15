# Plan and findings

## What's already true (checked 2026-11-15)

- the Proxmox host: PVE 9.2.26, pve-qemu 11.1.3, virglrenderer 1.1.0 built with Venus, `/dev/udmabuf`
  and `renderD128` present. `virtio-gpu-gl-pci` takes `venus=`, `blob=`, `hostmem=`,
  `drm_native_context=`. `mesa-vulkan-drivers` (ANV) is NOT installed yet — needed from stage 3.
- Proxmox: `vga: virtio` = `virtio-vga` (2D); `vga: virtio-gl` = `virtio-vga-gl` +
  `-display egl-headless,gl=core`. Venus needs `args: -global virtio-vga-gl.venus=on
  -global virtio-vga-gl.blob=on -global virtio-vga-gl.hostmem=4G` (untested).
- Tahoe 26.7.3 x86: no virtio-gpu driver. `AppleVirtIO.kext` has `AppleVirtIOPCITransport`
  matching any `1af4` device (IOPCIPrimaryMatch `0x00001af4&0x0000FFFF`) plus block/net/input/
  sound/socket/fs/console/balloon/entropy/IOMMU function drivers. `AppleParavirtGPU.kext`
  matches `106b:eeee` (Apple's PV GPU) — not ours.
- Xcode 27.2 on the Mac builds x86_64 kexts for macOS 26 (`-arch x86_64 -mmacosx-version-min=26.0
  -mkernel -fapple-kext -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE`, link `-Xlinker -kext -lkmod
  -lkmodc++ -lcc_kext`). Public headers include IOFramebuffer and IOAccelerator; the private
  IOAccel* family classes come from nvidia-macos-driver's reverse-engineered headers.
- Mesa: Venus's kernel transport is one file, `src/virtio/vulkan/vn_renderer_virtgpu.c` (1,303
  lines, 10 DRM ioctls: GETPARAM, GET_CAPS, CONTEXT_INIT, RESOURCE_CREATE_BLOB, MAP, EXECBUFFER,
  RESOURCE_INFO, GEM_CLOSE, PRIME fd<->handle). Mesa's Vulkan runtime builds on macOS already
  (KosmicKrisp, `wsi_common_metal.c`).

## References

- Reims (steelbrain/reims-vgpu, GPL/LGPL): own device + guest kexts on Tahoe x86 in a VM — best
  reference for IOFramebuffer/WindowServer integration.
- nvidia-macos-driver (nullmoth, PolyForm NC — fine for home lab): `kexts/NVRM/accel/` (NVAccel :
  IOGraphicsAccelerator2), `accel/iofam/*.h` RE'd IOAccel headers, `plugin/` Metal-over-Vulkan.
- metal2vulkan (steelbrain): AIR -> SPIR-V, Metal device API on Vulkan.
- virtio 1.2 spec §4.1 (virtio-pci), §5.7 (GPU device).

## Test VM 108 notes

- Clone of 107, own SMBIOS identity, NO network (never add one), only user `dev` (blank password,
  autologin, NOPASSWD sudo, secure token). Snapshots: `fresh-clone`, `dev-created`, `clean-dev`.
- Shell = QEMU guest agent from the Proxmox host (`qm guest exec 108 -- ...`). Screen =
  `echo "screendump /tmp/x.png -f png" | qm monitor 108`.
- OpenCore: `PollAppleHotKeys` false — a Shift stuck in the noVNC console made every boot Safe
  Mode (`-x`), which can't boot this VM ("OCB: StartImage failed - Aborted"). File logging on
  (`Misc/Debug/Target 0x41`, `AppleDebug`).
- Serial console + `serial=3 debug=0x8` collides with the guest agent's ISA serial port and slows
  boot to a crawl; if a serial console is needed, point the agent at `/dev/cu.serial2`
  (`/etc/qemu/qemu-ga.conf`) first.
- No GPU: Setup Assistant's closing animation needs Metal and hangs; new users need
  `AccountInfo:FirstLogins:<user>` in `/Library/Preferences/com.apple.loginwindow.plist`.

## Stage 0 result (2026-11-15, VM 108, `vga: virtio`)

The probe kext (OpenCore-injected) takes `S08@1` from `AppleVirtIOPCITransport` (score 20000 >
10000, default match category); `.Display_boot` (IONDRVFramebuffer, BAR0) keeps the screen.

```
pci 1af4:1050 sub 1af4:1100 rev 01 class 030000 cmd 0007
BAR0 mem32 0x80000000 len 8 MB   (VGA framebuffer)
BAR2 mem64 0x80c00000 len 16 KB  (virtio modern regions)
BAR4 mem32 0x81c1b000 len 4 KB   (MSI-X table @0, PBA @0x800)
msi-x 3 vectors (disabled)
virtio common  bar 2 off 0x1000 len 0x800
virtio isr     bar 2 off 0x1800 len 0x800
virtio device  bar 2 off 0x2000 len 0x1000
virtio notify  bar 2 off 0x3000 len 0x1000 multiplier 4
features 0x0000010130000002: EDID, INDIRECT_DESC, EVENT_IDX, VERSION_1
num_queues 2 (control, cursor)   num_scanouts 1   num_capsets 0
```

No VIRGL / RESOURCE_BLOB / CONTEXT_INIT: expected with plain `virtio-vga`; they appear with
`virtio-vga-gl` + venus/blob (stage 3).

Lessons: a hand-built kext needs `kmod_info` (kmod_info.c) or OpenCore says "Prelinked injection
... Invalid Parameter"; IOLog from an injected kext doesn't reach dmesg/unified log on Tahoe, so
the kext publishes a `ProbeLog` registry property (`tools/deploy.sh logs`). OpenCore `ShowPicker`
is off on 108 (`oc_kext.py CONFIG - picker` turns it back on).

## Stage 1 result (2026-11-15)

Polling virtio core works on the first deploy; the screen stays on the VGA framebuffer.

```
features offered 0x10130000002 accepted 0x100000002 (VERSION_1, EDID)
queue 0 (control): 64 entries (device max 64), notify_off 0
queue 1 (cursor):  16 entries (device max 16), notify_off 1
status after DRIVER_OK 0x0f
GET_DISPLAY_INFO -> OK_DISPLAY_INFO in 78 us: scanout 0 1280x800 enabled
GET_EDID         -> OK_EDID in 50 us: RHT 0x1234 "QEMU Monitor", preferred 1280x800 @ 107.3 MHz
```

Registry: `ProbeLog`, `DisplayModes`, `EDID`. Kill switch: boot-arg `-vgpuoff`.
Next (stage 2): MSI-X interrupts instead of polling, then the IOFramebuffer
(RESOURCE_CREATE_2D, ATTACH_BACKING, SET_SCANOUT, TRANSFER_TO_HOST_2D, RESOURCE_FLUSH, cursor).

## Stage 2a/2b result (2026-11-15)

- MSI-X: IOPCIDevice interrupt index 0 = INTx, 1..3 = message signaled (type 0x30000); index 1
  = vector 0 for config + both queues. 1,182 of 1,190 commands completed by interrupt (8 fell to
  the 5 ms poll).
- 2D pipeline (test 45 s after the kext starts, then scanout off + reset gives the screen back to
  the VGA framebuffer):
  RESOURCE_CREATE_2D (B8G8R8X8 1280x800), ATTACH_BACKING (4,096,000 bytes, one contiguous
  segment), SET_SCANOUT, TRANSFER_TO_HOST_2D + RESOURCE_FLUSH: all OK_NODATA.
  Full frame transfer + flush 4.2 ms; 172x160 damage updates avg 232 us, worst 2.8 ms
  (590 frames in 10 s with a 16 ms sleep between).
- Screenshots (`tools/deploy.sh shots`) started too late to catch the test; the desktop was back
  afterward.

## Stage 2c result (2026-11-15): the desktop runs on our framebuffer

Two kexts, because IOGraphicsFamily and IONDRVSupport are in the System KC and OpenCore only
injects into (and links against) the Boot KC:

- `VirtioGPU.kext` (OpenCore, Boot KC): the core; `VirtioGPUFramebufferSlot` holds the
  IOFramebuffer category on the PCI device (score 30000 > IONDRVFramebuffer's 20000), so no
  firmware framebuffer appears; publishes a `VirtioGPUDisplay` nub; serves `../VirtioGPUAPI.h`
  over callPlatformFunction.
- `VirtioGPUFramebuffer.kext` (/Library/Extensions, Auxiliary KC): IOFramebuffer on the nub;
  9.2 MB contiguous VRAM; modes 1024x768, 1280x800 (host preferred), 1440x900, 1680x1050,
  1920x1080; full-frame transfer + flush at 30 Hz on its own work loop; EDID via getDDCBlock;
  software cursor.

Result: the only IOFramebuffer in the system; WindowServer draws the desktop through the virtio
scanout; System Information shows "QEMU Monitor" 1280x800 @ 60 Hz, 8 MB VRAM, 0x1af4/0x1050.
~30 flushes/s, 4,213 of 4,214 commands completed by interrupt.

Getting the AuxKC in (each cost a round):
- kmutil wants IOGraphicsFamily >= its OSBundleCompatibleVersion `1.0.0b1` (`1.0.0d1` sorts lower).
- `thread_call_*` aren't exported to AuxKC kexts: use IOTimerEventSource; `kernel_task` needs
  `com.apple.kpi.unsupported`.
- `kmutil load` says "not approved" even with consent off; build the KC like nvidia-macos-driver:
  `kmutil create -n aux --volume-root / --allow-missing-kdk --kernel /System/Library/Kernels/kernel
  -B .../BootKernelExtensions.kc -S .../SystemKernelExtensions.kc --repository /Library/Extensions
  -A <new> -z`, then move it to /Library/KernelCollections/AuxiliaryKernelExtensions.kc.
- That move needs SIP filesystem protection off: VM 108 runs SIP 0x203 (kext signing,
  unrestricted fs, unapproved kexts), set by `vm-remote.sh` through OpenCore.
- File transfer without network: mac-guest-agent takes neither `--pass-stdin` nor file-write
  (file-write crashed it); the deploy pushes base64 in 1 KB exec arguments (4 KB hangs it).
- Right after boot the agent drops out; the deploy waits 45 s and the aux step retries.

Next: hardware cursor (cursor queue), measure flush cost at idle, then smarter updates (dirty
tiles, or zero-copy blob scanout) before stage 3.

## Stage 3 so far (2026-11-15)

- the Proxmox host: `mesa-vulkan-drivers` + `vulkan-tools` installed; ANV sees "Intel Iris Xe Graphics (ADL GT2)",
  Vulkan 1.4.305 (Mesa 25.0.7). VM 108: `vga: virtio-gl` + `args: ... -global virtio-vga-gl.venus=on
  -global virtio-vga-gl.blob=on -global virtio-vga-gl.hostmem=4G` (Proxmox adds egl-headless).
  QEMU's screendump captures nothing with the GL display.
- Device: features VIRGL, EDID, RESOURCE_BLOB, CONTEXT_INIT accepted; capsets virgl (1), virgl2 (2),
  venus (4, max size 160); shared memory id 1 = BAR4, 4 GiB at 0x384000000000; control queue max 256.
- Venus capset: wire format 1, vk.xml 1.3.269, command serialization spec 1, Mesa Venus protocol
  spec 2, supports blob id 0 (fields after that don't match our struct; check venus_hw.h).
- CTX_CREATE (context_init = 4) and CTX_DESTROY answered OK_NODATA: a Venus context exists on the
  host from the macOS guest.
- Hardware cursor (0.3.0): 64x64 B8G8R8A8 resource, UPDATE/MOVE_CURSOR on the cursor queue,
  convertCursorImage in the framebuffer; the owner: "smooth and accurate". No drops.
- Without a GPU, WindowServer composites on the CPU: the Genie minimize ran at 234% CPU and
  looked frozen. dev now has Dock mineffect=scale, reduceMotion, reduceTransparency.

Next: a user client in the core (context, blob create/map in hostmem, SUBMIT_3D with ring_idx,
fences/wait) and Mesa's Venus for x86_64 macOS with `vn_renderer_macos.c`; goal: `vulkaninfo` in
the VM listing the Iris Xe.
