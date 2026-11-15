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

## Stage 3: the user client works (2026-11-15)

`tools/deploy.sh test` (tools/vgputest.c, run as dev in the VM): getInfo, Venus capset, contextInit
(ctx 2), createBlob HOST3D 1 MB blob id 0, mapBlob (cached), IOConnectMapMemory64 + 1 MB write/read
in 1.6 ms with 0 mismatches, fenced empty submit on ring 0 signaled in 4.1 ms, destroy: PASS.

What it took:
- **virgl-server** on the Proxmox host (`/usr/libexec/virgl_render_server`). Without it virglrenderer
  still advertises the Venus capset and QEMU still answers CTX_CREATE with OK_NODATA (it ignores
  `virgl_renderer_context_create_with_flags`'s result), but the context doesn't exist and blob
  creation fails with EINVAL.
- QEMU's `qemu_log_mask` output is lost when daemonized: `qm monitor 108` -> `logfile /tmp/qemu108.log`,
  `log guest_errors,unimp`.
- **XNU can't address physical memory >= 2^44** (32-bit ppnum_t): OVMF put the hostmem BAR at
  0x3840_0000_0000 (top of 46-bit space) and no IOMemoryDescriptor could be made for it. VM 108's
  args now have `-cpu host,host-phys-bits-limit=40,...`: BAR4 lands at 0xe0_0000_0000.
- IOPCIFamily mis-parses 64-bit BARs above 4 GB (lists BAR4 as an IOSubMemoryDescriptor with
  address = upper dword, length 4); the core reads BAR4 from config space and makes an
  IODeviceMemory per mapping.
- hostmem is 2 GB now (`hostmem=2G`); 4 GB wasn't the problem but 2 GB is plenty for now.
- The control queue is asynchronous: requests indexed by descriptor head, drained in the
  interrupt action; fenced SUBMIT_3D completes when the host signals the fence.

Next: `vn_renderer_macos.c` on this API (mesa/NOTES.md lists the ops; sim-syncobj logic with
kVGUCWaitFence in place of sync_file fds), install the dylib + ICD json in the VM, Vulkan loader,
`vulkaninfo`.

## Vulkan inside macOS (2026-11-15)

`tools/deploy.sh vk` (Mesa's Venus ICD from mesa/out + tools/vkprobe.c, no Vulkan loader), in VM 108:

```
using VirtioGPU: 2048 MB host memory, pci 1af4:1050; venus capset 160 bytes; connected to renderer
wire format 1, vk.xml 1.3.269, command serialization 1, Venus protocol 2, renderer instance 1.3.309
vkCreateInstance 0; vkEnumeratePhysicalDevices 0, 2 devices
[0] Virtio-GPU Venus (Intel(R) Iris(R) Xe Graphics (ADL GT2)): integrated GPU, API 1.3.269,
    vendor 0x8086 device 0x46a6, heap 32013 MB device-local, 7 memory types (host-visible
    coherent / cached), queue family 0: graphics compute transfer
[1] Virtio-GPU Venus (llvmpipe): the host's CPU device
```

Path: vkprobe -> libvulkan_virtio.dylib (Mesa 25.0.7 + 4 patches, vn_renderer_macos.c) ->
VirtioGPUUserClient -> VirtioGPU.kext -> virtio-gpu (QEMU 11.1, venus/blob/hostmem=2G) ->
virglrenderer 1.1.0 render server -> ANV (Mesa 25.0.7) -> Iris Xe.

Files reach the VM over a transfer disk (virtio1, 1 GB FAT "VGPU" at /Volumes/VGPU;
`vm-remote.sh xfer`): virtiofs hung OpenCore at startup (with or without ScanPolicy), so it's off.

Next: real GPU work (buffer copy + compute dispatch, check results and timing), Khronos loader +
vulkaninfo, then stage 4 (Metal over Vulkan).

## The GPU executes work (2026-11-15)

`VKTOOL=vkexec tools/deploy.sh vk` (tools/vkexec.c, no shaders): on the Iris Xe through Venus,
vkCreateDevice 7.3 ms; two 64 MB buffers in memory type 2 (host-visible coherent cached),
allocate+map ~2 ms each; vkCmdFillBuffer 64 MB + vkCmdCopyBuffer 64 MB + fence wait: 23 ms
(2.9 GB/s); CPU check of all 16.7 M words in both buffers: 0 wrong. PASS.

Nothing in macOS's UI is accelerated yet: WindowServer uses Metal, which needs an IOAccelerator
(stage 5) and a Metal driver bundle (stage 4). notes/STAGE4-5.md has the plan.

## Stage 4.0 result (2026-11-15): YES, IOAcceleratorFamily2 starts in the guest and our subclass attaches

**Answer to STAGE4-5.md risk 1: the family starts, our `IOGraphicsAccelerator2` subclass starts, registers and serves
every family user client, with no panic, and WindowServer keeps running (software compositor) beside it.** The
Reims concern ("IOAccel2 cannot start where IOGPU runs") doesn't apply here: IOGPUFamily is on disk but nothing in
this guest loads it (AppleParavirtGPU matches only Apple's `106b:eeee`). The plan's route (NV-style IOAccel2 kext
in the AuxKC, Metal plugin over Venus) stands; go to 4a.

`kext/VirtioGPUAccel/` (`VirtioGPUAccel.kext` 0.4.0, Auxiliary KC beside the framebuffer): class `VirtioGPUAccel :
IOGraphicsAccelerator2` on the `IOPCIDevice` (`IOPCIPrimaryMatch 0x10501af4`, category `IOAccelerator`, score 100),
stubs for all 17 pure virtuals and the helper classes (event machine, legacy display machine, task with a bump VA
allocator, memory map, resource, sys/vid memory with no VRAM, legacy surface, display pipe (unused), GL/2D/CL/video
contexts), NV's `populateAccelConfig` values renamed ("VirtioGPUAccelerator", one framebuffer).
**Unarmed: no `MetalPluginName`** anywhere. Headers: NV's reconstructed `re/` and `iofam/` (vendored unchanged in
`vendor/nullmoth/`, PolyForm NC) and NV's 26.7.1 `tahoe_fwd.h` renamed to our classes (`vg_tahoe_fwd.h`: 68 slots
forwarded through Apple's exported vtables, built with `-DNM_TAHOE`).

Gates (boot-args, set with `tools/deploy.sh bootarg set|del|show`, which edits OpenCore's config offline):
`vgpuaccel` absent = kext + family load, start refuses; `vgpuaccel=1` = family start, not registered;
`vgpuaccel=2` = also `registerService()`; `-vgpuaccoff` = probe refuses. Log: `VirtioGPUAccelLog` on the PCI device
and the core's ProbeLog; `tools/deploy.sh accel-logs`. Install: `tools/deploy.sh accel` (AuxKC rebuild + reboot).
VM 108 now runs with `vgpuaccel=2`. Snapshot before any of this: `pre-accel-4-0`.

Evidence, VM 108 (26.7.3 25G342):

- Probes (section 9, probe 1): SIP 0x203 (kext signing + FS protections off, NVRAM protections on), boot-args
  `keepsyms=1 amfi_get_out_of_my_way=1 -v msgbuf=1048576`, Lilu 1.7.2 loaded. System KC has
  `IOAcceleratorFamily2` 487.4.4, `IOGPUFamily` 130.16.5, `AppleParavirtGPU` 15.0.0,
  `AppleGraphicsDeviceControl` 8.1.12 (loaded), Intel ICL/KBL and AMD drivers; before 4.0 no IOAccelerator
  existed and IOAccelerator2/IOGPU weren't loaded. Kext executables aren't on disk (only in the KCs).
- Link: `kmutil create` resolved all 801 imports of VirtioGPUAccel against 26.7.3's System KC on the first try
  (dry run into /tmp first): NV's 26.7.1 forwarding list holds on 26.7.3 for this class set.
- Boot, gate off: `com.apple.iokit.IOAcceleratorFamily2 (487.4.4)` loaded as our dependency; probe ran.
- Boot, `vgpuaccel=1`: `IOGraphicsAccelerator2::start -> 1`. The family called, in order: configureDevice,
  populateAccelConfig (pre-filled `cfg+0x28 = 0x0000000100000001`, `+0x30 = 0x0000400010001000`),
  newEventMachine, newDisplayMachine, createKernelGPUTask. It published AccelCaps 15, AGCInfo,
  PerformanceStatistics, IOReportLegend, IOCFPlugInTypes (IOAccelerator2D.plugin).
- `enableAccelerator()` from start: flags dword at ivar +0xc78 went 0x0 -> 0x2 (the bit
  `acceleratorWaitEnabled` waits on), so family allocations won't hang.
- Boot, `vgpuaccel=2`: `registered, matched, active`. `tools/acceltest.c` (root) opens each user-client type;
  the family makes:

  | type | user client |
  |---|---|
  | 0 | unsupported (legacy IOAccelSurface; its surfaceStart fails "failed to get the vram descriptors") |
  | 1 | VGGLContext (our class) |
  | 2 | unsupported (2D context) |
  | 3 | VGVideoContext |
  | 4 | IOAccelDisplayPipeUserClient2 |
  | 5 | IOAccelDevice2: get_config 0 -> 64 bytes, get_name -> "VirtioGPUAccelerator" |
  | 6 | IOAccelSharedUserClient2 |
  | 7 | VGCLContext |
  | 8 | IOAccelCommandQueue |
  | 9 | IOAccelGLDrawableUserClient |
  | 10-12 | unsupported |

  Opening them made the family call getStampMemory (16 KB, 4096 stamps), createUserGPUTask and our context
  factories. `get_config` bytes: `00 43 00 00 ...; +0x18 01; +0x20 00 b0 aa aa; +0x28 00 00 00 80`.
- WindowServer: one pid all boot (no restart loop). It opens legacy surfaces on the accelerator once at
  start (12 x `IOAccelSurface::surfaceStart(): failed to get the vram descriptors`, our newSurface x3), then
  "Software compositor activated". CoreDisplay's "Unable to find display pipe for IOFB service" was already
  logged before the accelerator existed (no AGDC/pipe yet, as expected; 5a's job).
- IOAcceleratorFamily2's own kernel messages do reach the unified log (`log show --predicate 'sender ==
  "IOAcceleratorFamily2"'`), unlike IOLog from our kexts.
- Venus user client still passes beside it (`tools/deploy.sh test`: PASS).

Other section-9 probes:

- Probe 2 (KDK): Apple's KDK for 26.7.3 **25G342 exists** (dortania/KdkSupportPkg release `25G342`,
  `Kernel_Debug_Kit_26.7.3_build_25G342.dmg`). Not downloaded: kmutil's link in the guest already checks every
  import. Get it when 4a/5a needs vtable verification for a class NV's list doesn't cover.
- Probe 4: the guest's `GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib` (dyld shared cache, no file
  on disk) dlopens and exports `LLVMParseBitcodeInContext2`, `LLVMPrintModuleToString`, `LLVMContextCreate`,
  `LLVMCreateMemoryBufferWithMemoryRange` (`tools/llvmprobe.c`): the AIR reader can use Apple's own LLVM, no
  LLVM build needed (whether it parses every AIR module is 4b's test).
- Probe 5: the build Mac has the Metal toolchain (`xcrun metal`: metal 32023.922, MobileAsset MetalToolchain
  v27.2); it targets darwin27 by default, so pass a macOS 26 AIR target.
- Probes 3 (Venus feature dump) and 6 (QEMU SET_SCANOUT_BLOB) are 4a/5c work, not run.

Recommendation: proceed to **4a** as planned. Changes to the plan from what 4.0 showed:
- The ordering worry about a registered accelerator aborting WindowServer is gone for the unarmed case:
  registered without `MetalPluginName`, WindowServer starts once and composites in software. Keep late-arm
  for MetalPluginName (4a) exactly as planned; that's the remaining WindowServer hazard.
- User-client type map above replaces guesses; Metal's `MTLIOAccelDevice` will open 5/6/8 (device, shared,
  command queue) itself.
- First 4a step: the `debug.vgpuaccel` late-arm sysctl that sets MetalPluginName/MetalPluginClassName on the
  registered accelerator, then the bundle and `mtlprobe` with the allow-list.
- Legacy surfaces (type 0) need VRAM descriptors (a framebuffer registered with the display machine); that is
  5a's `found_framebuffer` work and doesn't affect Metal on IOSurfaces.
