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

## Stage 4a result (2026-11-15): Metal lists the device

**`MTLCopyAllDevices` in VM 108 returns one device, "Virtio-GPU Venus (Intel(R) Iris(R) Xe Graphics (ADL GT2))
(VirtioGPUMetal)", and `MTLCreateSystemDefaultDevice` returns it** (tools/mtlprobe.m, run as dev after the late arm).
Apple's own `-[MTLIOAccelDevice initWithAcceleratorPort:]` succeeds against VirtioGPUAccel (it opens the family's
user clients itself), the plugin brings up a Venus VkDevice on the Iris Xe in the same process, and
`-[_MTLDevice initLimits]` completes.

Pieces:

- **Late arm** (VirtioGPUAccel 0.4.1, `setProperties`): a root process sets `{"VirtioGPUArm": {MetalPluginName,
  MetalPluginClassName}}` or `{"VirtioGPUDisarm": true}` on the accelerator (`acceltest arm|disarm`;
  `tools/deploy.sh mtl arm|disarm`). Non-root is refused. Boots unarmed every time.
- **`metal/VirtioGPUMetal/VGMTLDevice.m`** -> `/Library/GPUBundles/VirtioGPUMetal.bundle` (built by
  `tools/build-metal.sh`, Mesa's Venus ICD in its Resources; `tools/deploy.sh metal` installs it root-owned,
  readable by `_windowserver`). Class `VGMTLDevice : MTLIOAccelDevice <MTLDevice>`; `MTLDeviceSPI` adopted at
  `+load` from the runtime (`objc_getProtocol`, no header). MetalPluginName is the bare `VirtioGPUMetal`: Metal
  found `/Library/GPUBundles/VirtioGPUMetal.bundle` by it (Reims' form; NV's relative path wasn't needed).
- **Allow-list**: WindowServer always refused (until 5a); `mtlprobe` always allowed; others need
  `/Library/GPUBundles/VirtioGPUMetal-allow.txt` (names, `*`) or `VGMTL_ENABLE=1`. A refusal before super's init
  keeps the object (NV's lesson). Tested: the same binary under another name loads the plugin, gets no device,
  exits normally.
- Log: os_log subsystem `local.homelab.VirtioGPUMetal`, `/var/tmp/VirtioGPUMetal.log`, stderr with `VGMTL_LOG=1`.
  Unanswered selectors are logged by name (`-doesNotRecognizeSelector:`). `tools/deploy.sh mtl probe|refused|health`;
  `tools/deploy.sh pull 'GLOB'` copies guest files (crash reports) out through the transfer disk.

What Metal demanded, in order (each was a crash until answered):
1. `-[_MTLDevice initLimits]` sends vendor selectors: `featureProfile` (10002, NV's value) and the rest of NV's
   contract set (FP configs, timestamp frequency, depth24stencil8, assertions, texture buffer alignment, ...).
2. `MTLAddDevice` asserts `conformsToProtocol:@protocol(MTLDevice)`, then `@protocol(MTLDeviceSPI)`.
3. `maxThreadsPerThreadgroup` (now from Vulkan's limits: 1024 x 1024 x 1024).

What the base class answers on its own: registryID 4294968177 (the accelerator), location 0 / number 1, not
headless / low power / removable, hasUnifiedMemory 0, recommendedMaxWorkingSetSize 2,863,312,896,
maxBufferLength 2 GiB, supportsFamily Mac2 / Common3 / Metal3 all YES (from featureProfile; may claim more than
we'll deliver, revisit in 4b/4c).

Checks: Venus contexts all closed when mtlprobe exits (core ProbeLog "uc: ctx N closed", 0 VirtioGPUUserClient
left); after disarm a new mtlprobe lists 0 devices; WindowServer kept its boot pid (no restart, no new crash
report); only mtlprobe processes logged plugin activity while armed.

Probe 3 (Venus features, `vkprobe ICD --features`): every hard requirement of the plugin is there (Vulkan 1.3,
graphics+compute queue, bufferDeviceAddress, descriptor indexing incl. update-after-bind and variable count,
dynamicRendering, synchronization2, maintenance4, shaderFloat16/Int8/Int16/Int64, 8/16-bit storage, timeline
semaphores, scalar block layout, BC compression, geometry + tessellation; no shaderFloat64). Of its 17 optional
extensions: yes = extended_dynamic_state3, depth_clip_enable, image_drm_format_modifier, external_memory_fd,
mutable_descriptor_type, calibrated_timestamps, provoking_vertex (and VALVE_mutable_descriptor_type); no =
memory_budget, acceleration_structure, ray_query, deferred_host_operations, external_memory_host,
cooperative_matrix, sample_locations, pipeline_executable_properties, vertex_attribute_divisor,
pipeline_robustness. So no ray tracing, no host-pointer import (newBufferWithBytesNoCopy copies), estimated
working set.

Next (4b): command queue, buffers on Venus host-visible memory, a host-built metallib through the translator
(the guest's GPUCompiler libLLVM reads AIR), compute pipeline, dispatch, blit; `mtlcompute` checks results.

## Stage 4b result (2026-11-15): Metal compute runs on the host GPU

**`tools/mtlcompute.m`, plain Metal API in VM 108, PASS on the first full run**: Apple's metal compiler (on the Mac)
-> `compute.metallib` -> our plugin -> Venus -> Iris Xe:

```
library compute.metallib: loaded (235.4 ms) functions: vadd, reduce_sum
pipelines: vadd ok, reduce_sum ok (15.0 ms)
  vadd 16777216 floats, threadgroup 256           54.61 ms   all right (first run)
  vadd 16777216 floats, threadgroup 256           12.22 ms   all right (cached pipeline)
  vadd 1000003 floats, threadgroup 64              9.49 ms   all right (partial last threadgroup)
  reduce_sum 16M uints (threadgroup memory)       71.67 ms   sum 50331645 right (atomics, barriers, setBytes)
  fill 64 MB + copy 64 MB                         29.13 ms   all right, completion handler ran
```

Times are commit-to-completion seen from the app, including the Venus round trips (vkexec's raw Vulkan fill+copy of
64 MB was 23 ms).

The path (all in `metal/VirtioGPUMetal/`):

- **Library** (`VGMTLLibrary.m`): bitcode blobs found in the metallib by the wrapper magic (NV's method); each blob
  -> LLVM IR text with **the guest's own LLVM** (`GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib`,
  dlopen from the dyld cache; it read Xcode 27.2's AIR fine); entry name and stage from `!air.kernel` metadata.
- **Translator**: NV's metal2vulkan wrapper (`libnvmtl_translate.dylib`, LGPL, in the bundle's Resources with its
  license; `tools/build-translator.sh`). Homebrew's Rust has no x86_64 std, but `RUSTC_BOOTSTRAP=1 cargo build
  -Z build-std=std,panic_abort --target x86_64-apple-darwin` builds it from the shipped std source; no rustup.
  The translator's CLI needs spirv-val; the wrapper's in-process path (what the plugin calls) doesn't.
  `nvmtl_reflect` gives the binding map and dispatch contract as JSON; translation waits until dispatch, because
  threadgroup-memory lengths (`setThreadgroupMemoryLength`) are baked into the SPIR-V
  (`nvmtl_translate_set_threadgroup_lengths`). vadd translated in 18.7 ms, reduce_sum in 12.3 ms.
- **Pipelines** (`VGMTLCompute.m`): one translation per threadgroup-length set; descriptor layout read from the
  SPIR-V itself (set 0, storage vs uniform buffer); local size via spec constants 0..2; one VkPipeline per local
  size. Dispatch is the translator's `KernelDispatch::plan` (full groups, then each dimension's tail with its own
  local size) with the 48-byte ThreadsDynamic push-constant block (thread grid, thread base, threadgroup base,
  threadgroup grid).
- **Buffers**: every MTLBuffer is a VkBuffer in host-visible coherent cached memory (type 2), mapped for life
  (`contents`). setBytes goes to a per-command-buffer upload arena.
- **Command buffers**: one VkCommandBuffer each, a full memory barrier after every command, submit with a fence at
  commit, completion (handlers, status, freeing descriptor pools/arenas/retained resources) on a background queue;
  `waitUntilCompleted` waits on it. Blit: copyFromBuffer, fillBuffer (4-byte-aligned ranges only).
- `vg.h` + `VGVulkan.m`: the process's one Venus VkDevice, queue, command pool and a function table.

Checks after the run: every Venus context closed (ctx 6..11 "closed"), no user clients left, WindowServer kept its
boot pid; disarmed again afterwards.

Known gaps (later stages): no textures, samplers or render pipelines (4c); kernels whose reflection has anything but
buffers and threadgroup memory are refused with a message (argument buffers, textures, the BufferAddressTable of
pointer-chasing kernels); no function constants; no MTLHeap, events, indirect dispatch; unaligned fillBuffer;
private storage still in host memory; one queue, serialized submits. Each MTLBuffer is its own Venus blob
(hostmem range cap 2048 per VM, `VirtioGPU.hpp`), so a buffer pool is needed before real apps.

Next (4c): textures (VkImage + views, samplers), render pipelines (vertex + fragment translation), render passes,
`replaceRegion`/`getBytes`, a triangle and a textured quad read back and compared.

## Stage 4c result (2026-11-15): Metal renders to textures on the host GPU

**`tools/mtlrender.m` (plain Metal API, offscreen RGBA8 64x64 targets read back with getBytes) PASS in VM 108**,
and mtlcompute still passes:

```
  clear                                            ok
  pipeline tri_vertex + color_fragment: ok (40.7 ms)
  triangle: top half, clockwise front face kept    ok   (y up as in Metal; back faces culled, it stays)
  triangle: culled as a front face                 ok
  indexed quad: bottom-right quarter               ok   (uint16 indices, setVertexBytes)
  pipeline tri_vertex + texture_fragment: ok (7.9 ms)
  replaceRegion + getBytes round trip              ok
  textured quad: texel (0,0) at the top left       ok   (sampled texture + nearest sampler)
  pipeline tri_vertex + color_fragment (blend): ok (5.0 ms)
  blending: 50% red over gray                      ok
  pipeline attr_vertex + color_fragment: ok (10.0 ms)
  vertex descriptor: blue triangle, bottom half    ok   ([[stage_in]] attributes from an MTLVertexDescriptor)
  pipeline pattern (compute, texture write): ok
  compute: texture write pattern                   ok   (storage image, formatless write)
PASS (0 failures)
```

New in the plugin (`metal/VirtioGPUMetal/`): `objects.h` (shared object interfaces), `VGMTLTexture.m` (textures,
samplers, depth-stencil states, pixel formats, one-shot submits), `VGMTLRender.m` (render pipelines, render
encoder, `renderCommandEncoderWithDescriptor:`); compute encoders take textures and samplers; one SPIR-V binding
scanner and one descriptor writer serve both.

How it maps:

- **Textures**: VkImage, optimal tiling, device-local memory, kept in VK_IMAGE_LAYOUT_GENERAL for life (set once
  at creation), so sampling, storage writes, rendering and copies need no layout tracking. replaceRegion /
  getBytes are synchronous (staging buffer + one-shot command buffer), as Metal's are. 26 pixel formats mapped.
- **Translation contract for graphics**: vertex and fragment functions are translated at pipeline creation; both
  stages' resources come out in set 0 (buffer n -> n, texture n -> 32+n, sampler n -> 160+n, storage texture n
  -> 480+n), so the fragment module is moved to set 1 (NV's `nvmtl_spirv_retarget_set`). Varyings and render
  targets are matched by location; vertex attribute n -> location n, vertex buffer n -> binding n.
- **Rendering**: Vulkan 1.3 dynamic rendering (no render-pass objects), attachments in GENERAL. Metal's +y-up clip
  space / top-left framebuffer = a negative-height viewport (NV's choice); with it Metal's winding maps 1:1
  (MTLWindingClockwise -> VK_FRONT_FACE_CLOCKWISE, verified by the cull test). Topology, cull, winding, depth
  test/write/compare, primitive restart, viewport, scissor and blend color are dynamic state; one VkPipeline per
  topology class, the triangle one built at creation so a bad combination fails there.
- **Device features**: the VkDevice now enables every feature Venus reports except robustBufferAccess /
  robustImageAccess (translated shaders declare descriptor indexing, Int8, the memory model, formatless storage
  images...). The translator is told the device reads/writes storage images without a format
  (`nvmtl_translate_set_caps(3)`), so a Metal texture's storage image is declared Unknown, not R32f.

The bug that cost the most: **the translator's in-process path emits NV's bindless texture model by default**
(textures from a heap of images at set 2 binding 0, indexed through a table buffer at binding 640), while
`nvmtl_reflect` reports per-slot bindings (texture at 32). With no set 2 in our pipeline layout,
**ANV segfaulted in the host's render server** (`vkr-ring-N: segfault at 0 ... in libvulkan_intel.so`, journal
on the Proxmox host) and the guest process aborted with "MESA-VIRTIO: ... aborting on expired ring alive status". Only
that context died; QEMU and the VM were fine. Fix: `NVMTL_NO_BINDLESS_ALL=1` (the translator's switch, read once)
is set before the translator loads, and the binding scanner now refuses, with a message, any module that reaches
outside its own set or uses the 640+ address table. Debug aid: `VGMTL_TRACE=1` logs each step and forces a host
round trip (`vkDeviceWaitIdle`) after pipeline builds, since Venus runs most calls asynchronously and a host crash
otherwise surfaces at a later call.

Known gaps: MSAA and resolve, stencil, depth bias, line fill mode, render to mip levels / array slices / 3D
planes, combined image-samplers and texture arrays, cube textures, texture views and swizzles, render stages with
their own push constants, argument buffers, function constants; every draw writes fresh descriptor sets (no
caching); pipelines and translation aren't cached across processes. Depth attachments are wired but not tested.

Next (4d): IOSurface-backed textures (`newTextureWithDescriptor:iosurface:plane:`, copy in / out with seeds), a
CAMetalLayer / MTKView app that animates in a window through the software compositor.

## Stage 4d result (2026-11-15): a Metal app animates in a window

**`tools/mtlwindow.m`, a plain Cocoa app with a CAMetalLayer, renders a spinning triangle on our Metal device in a
real window in VM 108, and WindowServer (still the software compositor) shows it**: the owner saw the spinning
triangle on the console. Over 12.6 s: 337 frames completed, 335 presented by Core Animation, **~27 fps** (25-30 over
three runs; a 60 Hz timer, three drawables). Frame 30's drawable IOSurface holds exactly that frame's clear color;
the frame as handed to WindowServer is `notes/img/stage4d-frame30.png`.

`tools/mtlsurface.m` (CLI) PASS: `newTextureWithDescriptor:iosurface:plane:`; a GPU clear lands in the IOSurface's
own memory; a CPU write to the surface is seen by `getBytes` and by a GPU sampling pass; a 1280x800 surface frame
(clear + copy-out) takes 3.3 ms. mtlrender and mtlcompute still pass.

How (plugin):

- **IOSurface textures = NV's headless copy path**: Venus can't put a guest IOSurface's pages under a host image, so
  a surface texture is a private VkImage plus a staging buffer laid out like the surface plane. The surface seed
  tells when the CPU (or another process) changed it: before the GPU reads it (bound for sampling or storage, or a
  Load attachment) a changed surface is pulled in (synchronous one-shot copy); a command buffer that writes it
  (stored attachment, writable storage texture) records image -> staging at its end, and at completion the plugin
  copies staging into the surface under IOSurfaceLock and remembers the resulting seed as its own.
- **presentDrawable**: drawables are presented (`-[MTLDrawable present]`) at completion, after the copy-out, so
  WindowServer never reads a surface before its pixels are in it.
- **CAMetalLayer needed nothing else**: with `layer.device` = our device it made its three drawables through
  `newTextureWithDescriptor:iosurface:plane:` and no unanswered selector was logged.
- `screencapture` can't read this display ("could not create image from display", as dev or root), like QEMU's
  screendump with the GL display; the app saves its own frame instead.

Seen in passing: other processes that ask Metal for devices while armed load the plugin and are refused by the
allow-list (e.g. `universalAccessAuthWarn`, started by the screenshot attempt), with no crash.

Known gaps: the copy path costs two CPU copies per frame (surface <-> staging) plus a GPU copy; two command buffers in
flight that write the same surface share one staging buffer; no planar / YUV surfaces; nothing waits for
WindowServer to finish reading a surface before the next write (CAMetalLayer's drawable pool covers that today).
Frame rate isn't tuned (25-30 fps for a trivial frame): measure where the time goes before 5a.

Stage 4 is done: an app-only Metal device on Venus (compute, render, IOSurfaces, CAMetalLayer). Next is 5a
(WindowServer picks the device: AGDC, display pipe, framebuffer registration, VBL, the arming moved into the kext).

## Stage 5a result (2026-11-15): WindowServer picks our Metal device ("Metal compositor activated"); no frames through the pipe yet

**Checkpoint met except frames on screen.** With `vgpuaccel=4` the armed WindowServer loads VirtioGPUMetal, brings up
Venus through the accelerator, builds CoreDisplay's pipelines and logs **"Metal compositor activated"** (instead of
"Software compositor activated"). The registry shows our AppleGraphicsDeviceControl (`VGDeviceControl`) and display
pipe (`VGDisplayPipe`) on the PCI device. No sandbox denial touched IOKit. `system_profiler SPDisplaysDataType` says
**"Metal: Supported"** (vendor 0x1af4, device 0x1050). The screen does not show the desktop yet: the first
WindowServer aborts inside Core Animation once it draws real UI, because CA's pipelines use **framebuffer fetch**,
and composited frames never reach our display pipe (see "What's left" below). The guard then gives the next
WindowServer a software desktop. VM 108 is left on `vgpuaccel=2` (software compositor, all the new code loaded,
WindowServer never armed). `vgpuaccel=4` reproduces everything below. Snapshot before 5a: `pre-5a`.

### What was built

Kernel (VirtioGPUAccel 0.5.2, VirtioGPUFramebuffer 0.5.0, VirtioGPU core 0.5.0):

- **Framebuffer** (`VirtioGPUFramebuffer.cpp`): `IOFBDependentID`/`IOFBDependentIndex 0` before `IOFramebuffer::start`;
  **a 60 Hz timer VBL** (`registerForInterruptType(kIOFBVBLInterruptType)` with 4 handler slots, `setInterruptState`,
  own work loop; IOFramebuffer registers its handler at open); `callPlatformFunction` answers `vgpu.fb.scanoutInfo` (kva,
  pitch, size of the scanout RAM) and `vgpu.fb.present` for the display pipe (`kext/VirtioGPUAPI.h`).
- **Display machine registration** (`VirtioGPUAccel.cpp`): first-publish notification on `VirtioGPUFramebuffer`, then from
  our own arm work loop `found_framebuffer` (pipe count at dm+0x108, pipes at dm+0x88, a pipe's framebuffer at +0x98, NV's
  26.7.1 offsets, all held on 26.7.3), `display_mode_will_change/did_change`, enable bit stays set. The family called
  our `newDisplayPipe` and the pipe's framebuffer is ours.
- **`VGDisplayPipe`**: `initFramebufferResource` returns NULL (CPU-only scanout); `performTransaction` copies the plane-0
  IOSurface (BGRA / l10r / RGhA through NV's `nv_iop_pixel.h`, vendored) into the scanout RAM, keeps 4 sources mapped,
  copies the overlap if sizes differ; refused (0xe00002c7) until `IOAccelDisplayPipeCapabilities` is published.
  Counters in `VirtioGPUPipeFrames` on the accelerator. IOSurface and transaction accessors linked by name (kmutil
  resolved them on 26.7.3).
- **AGDC** (`VGDeviceControl.cpp`, `com.apple.AppleGraphicsDeviceControl` library, NV's reconstructed base class in
  `vendor/nullmoth/agdc`): created, attached and started by hand on the PCI device. Answers 0x1 (description: version
  0x30000, "VirtioGPU", vendor half-word 0x106b as Reims measured, device 0x1050, kind 2; `vgpuagdcvendor=` /
  `vgpuagdcversion=` override), 0x3 (get: framebuffers|accelerator; set: InitFlags), 0x980 (one port, one framebuffer,
  the PCI device), 0x921 (NV's K5 link config from the current mode's timing), 0x711 type 0x10 (plane scaler), 0x925
  (connected). Seen asked and unanswered: 0x941 (48 B), 0x988 (36 B), 0x2001 (4 B in), 0x711 types other than 0x10.
  WindowServer accepts it as is.
- **Venus through the accelerator** (WindowServer's sandbox): private user-client type `kVGUCAccelType` 0x56470001 on
  `VirtioGPUAccel` asks the core for an unattached `VirtioGPUUserClient` (`vgpu.newClient`) and attaches it under one
  of 8 `IOAccelVirtioCarrier`s. Mesa patch 0005 opens the accelerator first, the core as fallback. Apps use it too now.
- **Arming moved into the kext**, levels by boot-arg: `vgpuaccel=2` as before (late arm only); `=3` registers the
  framebuffer, pipe, AGDC and capabilities but publishes no MetalPluginName; `=4` also publishes MetalPluginName and
  `VirtioGPUWindowServer = true` (the plugin's permission for WindowServer; the late arm never sets it). A boot hold
  (`adjustBusy`, 20 s cap, `-vgpunohold`) keeps the registry busy until armed; armed in ~0.1 s after the framebuffer
  published. `-vgpunoagdc` skips the AGDC.
- **Guard**: a third WindowServer (counted by pid on the Venus client) since the last arm withdraws MetalPluginName,
  `VirtioGPUWindowServer` and the pipe capabilities. The next WindowServer finds no display pipe and composites in
  software (measured twice). Root re-arms or withdraws at run time, no reboot: `tools/deploy.sh mtl wsarm|withdraw`
  (then `killall -9 WindowServer`); `tools/deploy.sh mtl ws` prints WindowServer's state. AGDC can't be terminated
  (`terminate` -> 0), so it stays.

Plugin (VirtioGPUMetal):

- Allow-list: WindowServer only when the accelerator says `VirtioGPUWindowServer` and the list has no `-WindowServer`;
  `-name` lines deny any process.
- **Every `NSError **` is written** (nil on success). CoreDisplay, C++ without ARC, passes an uninitialized `NSError *`
  and sends it `-description` if non-nil: that was the first armed crash (`GetGPUPassRenderPipelineState`).
- **Function constants**: `newFunctionWithName:constantValues:error:` reads `MTLFunctionConstantValues` (indexed:
  `_index/_dataType/_data`; named: `_name`, index from the module's `MTL_FC_INIT` metadata, NV's method) and the
  translator specializes with `nvmtl_translate_fc` / `nvmtl_reflect_fc`. CoreDisplay's GPUPass (2 constants) and CA's
  `fixed_*` (60 + 5 named) specialize.
- `MTLHeap` (`VGMTLHeap.m`): no sub-allocation, resources are plain device allocations; heap size queries on the device.
- **Lenient mode** (`VGMTLLenient.m`, WindowServer or `VGMTL_LENIENT=1`): a message none of our objects answers is
  logged once ("LENIENT: -[Class selector]") and answered with nil/0 by a sink, instead of aborting. Seen so far:
  `-[VGMTLCommandQueue setCompletionQueue:/setSubmissionQueue:/setGPUPriority:]`,
  `-[VGMTLTexture setResponsibleProcess:/protectionOptions]`, `-[VGMTLCommandBuffer protectionOptions]`,
  `-[VGMTLDevice newBufferWithBytesNoCopy:length:options:deallocator:]` (needs a real implementation).

Tools: `tools/codepeek.c` reads a function out of a loaded system library in the guest (no developer tools there) and
resolves its selector refs and call targets; the bytes disassemble on the Mac (wrap them in `.byte` lines, assemble,
`llvm-objdump -d`). `vm-remote.sh aux` takes several kexts in one AuxKC rebuild; `deploy.sh stage5` = bundle + AuxKC +
core in one reboot. `tools/build.sh` no longer deletes all of `build/` (it took the translator with it).

### What happened, in order (each a boot or a WindowServer restart)

1. `vgpuaccel=2` with the new code: desktop unchanged (software), VBL registered, Metal tests pass through the
   accelerator-routed Venus client.
2. `vgpuaccel=3`: AGDC up, WindowServer asks it 0x1/0x980/0x921/0x925/0x711, opens the display pipe user client, then
   **asserts "Failed to create MetalDevice"** every 10 s: a display pipe without a Metal device is an abort loop (the
   owner saw a black screen). Level 3 is only a probe, never a state to boot.
3. `vgpuaccel=4`: the plugin loads in WindowServer, Venus up, no sandbox denial; SIGSEGV in CoreDisplay
   (`[error description]` on an uninitialized error, after `newFunctionWithName:constantValues:error:`). Found with
   codepeek. Fixed (error out-params, function constants).
4. `-[MTLDevice newHeapWithDescriptor:]` -> abort. Added the heap. The guard (first version) withdrew after 3 and
   WindowServer came back in software.
5. Run-time re-arm: `-[VGMTLCommandQueue setCompletionQueue:]` abort inside `CompositorMetal::new_compositor`. Added lenient
   mode. Next start: **"Metal compositor activated."** WindowServer stays up; CoreDisplay loads its shader libraries
   (180 + 31 entry points). The console shows the login window mostly black, with only the regions redrawn since the
   start visible (the owner's screenshot): CoreDisplay's legacy display-surface path (`CGXAccessDisplayDeviceSurface`,
   `IOAccelSetSurfaceFramebufferShape`, `copy_forward_region` failing 0xe00002bc against our stub `VGSurface`) copied
   damaged regions to the framebuffer on the CPU; nothing went through `performTransaction` (0 calls).
6. When the UI drew (typing at the login window, or the desktop after autologin): Core Animation inside WindowServer
   (`CA::OGL::MetalContext::create_pipeline_state`) aborted, because `fixed_vert_lpf_spc+fixed_frag_lpf_cpf` was refused:
   its fragment shader reads set 3 binding 192, the translator's `[[color(n)]]` framebuffer-fetch input. Named constants
   (added) didn't fold it away. Another start died with an assertion in `CA::OGL::Context::push_surface` (likely a
   follow-on of a refused pipeline).

### What's left (5b), in order

1. **Framebuffer fetch** in render pipelines: bind the current color attachment's contents at set 3 binding 192 + n.
   NV's `fetch_copy` copies the attachment to a texture before a draw that reads it; with dynamic rendering, a
   `VK_EXT_rasterization_order_attachment_access`-free version is "end rendering, copy, begin rendering". Venus/ANV
   exposes `dynamicRenderingLocalRead`? Check with vkprobe first. Then CA's pipelines build.
2. **Why no transactions**: WindowServer opens the display pipe user client and AGDC is accepted, yet presents via
   the legacy surface path. Candidates: the pipe's "active" byte (+0x298) and wsaa defer (+0x282) NV logs in
   `reportPipeGates`; `framebuffer_did_power_on` never delivered; the 0x941/0x988/0x2001 AGDC attributes; legacy surface
   type 0 opens (`VGSurface` stubs) taking precedence. Log the pipe gates after arm and at each WindowServer start, then
   compare with NV's working log.
3. Real `newBufferWithBytesNoCopy:...deallocator:` (copy + deallocator call), stencil, the queue/texture SPI the lenient
   log lists.
4. Then 5b proper: surface pending/ready marks, pixel formats, pacing.

Recommendation for 5b: start with (2) because it decides the whole present path, and it's kernel-side and cheap to
probe at run time (`wsarm` + WindowServer restart, no reboot), then (1), which unblocks Core Animation. Keep lenient
mode on in WindowServer while bringing up, and keep the guard.

## Stage 5b progress (2026-11-15): Core Animation's pipelines build in WindowServer; it still aborts on a lost transient surface

With `vgpuaccel=4` (and `-vgpulegacy`), the armed WindowServer now builds Core Animation's real pipelines on our
device. That includes `fixed_vert_*+fixed_frag_lpf_cpf` (60 named function constants, framebuffer fetch, ~690 KB of
SPIR-V each), CoreDisplay's GPUPass and the MPS kernels of the desktop window effects. The first WindowServer of each
boot still aborts ~20 s in, on `Assertion failed: (found != slist->end ()), function push_surface, file
ogl-context.cpp, line 1186`, which Core Animation logs as "context(2) transient surface … not found". The second
WindowServer stays up on the Metal compositor. Nothing reaches the display pipe yet. VM 108 is back on `vgpuaccel=2`.

### Built (plugin; all of it checked by mtlrender / mtlcompute / mtlsurface in the guest)

- **Framebuffer fetch by copies** (`VGMTLRender.m`, NV's `nvmtl_fetch_copy.h` vendored). A fragment module that reads
  `[[color(n)]]` (set 3, binding 192+n) is rewritten to texel-fetch a sampled image at FragCoord. Before such a draw the
  encoder ends rendering, copies each read color attachment into a scratch image (one per attachment per encoder),
  resumes with load, and binds the copies at set 3 (set 2 is an empty layout). Attachments always store, so a pass
  can be split. New mtlrender case: two fetch draws in one pass (swap, then halve) give the expected pixel.
- **Translation cache**: (module text, stage, constants, threadgroup lengths) -> SPIR-V, so CA's ~4 s translations
  happen once per variant.
- **Unbound slots** read placeholders (a zeroed 64 KB buffer, a 1x1 texture, a linear clamp sampler) instead of
  failing the command buffer: CA's specialized shaders keep declarations their constants folded away.
- `commitAndWaitUntilSubmitted` (CA commits this way; lenient mode had swallowed it, so those frames were never
  submitted), `userDictionary`, `globalTraceObjectID`, `newBufferWithBytesNoCopy:...deallocator:` and the private
  `-[MTLBuffer initStandinWithDevice:bytesNoCopy:length:deallocator:]` (copied into the buffer at each bind),
  blit texture<->buffer and texture<->texture copies, `A8Unorm` (R8 with an alpha swizzle), resources made by a heap
  report it (`heap`, `heapOffset`, `makeAliasable`).

Kernel (VirtioGPUAccel 0.5.3): `VGDisplayPipe` logs the family entry points (`newDisplayPipeTransaction`,
`submitTransaction`, `beginTransaction`, VBL / transaction interrupt enables, `framebuffer_did_power_on`, wsaa defer)
and the pipe's gate bytes (NV's +0x298 active, +0x282 defer). Legacy `IOAccelSurface` user clients (type 0) are
refused to an armed WindowServer unless `-vgpulegacy` or `acceltest legacy on`.

### What the probes showed

- **Display-pipe transactions: none.** WindowServer opens the pipe's user client, but the family never calls any
  pipe transaction entry point, never enables the pipe's VBL interrupt, and the active byte stays 0, whether or not
  legacy surfaces are allowed. CoreDisplay logs `isAcc=YES` and presents through its legacy display-surface path:
  `CGXAccessDisplayDeviceSurface` composites into the display IOSurface, then `CGXReleaseDisplayDeviceSurface` copies to
  the framebuffer on the CPU (`vRotate`), and `copy_forward_region` fails 0xe00002bc against our stub `VGSurface`.
  With legacy surfaces refused, WindowServer aborts sooner. Open question: what makes CoreDisplay pick IOPresentment
  transactions over the legacy path on 26 (NV's notes say 10.13/10.14 decided by the framebuffer's class name).
- **The first armed WindowServer** always runs the same sequence: CA's first textured quad, ~6 s with no GPU work
  ("timed out fence (pid<<32 | n)", "synchronize timed out"), MPS's wallpaper-average compute, then the transient
  surface assertion. Neither the heap fix nor the texture copies changed it, so the likely root is a wait that never
  completes: something CA synchronizes on (an `MTLSharedEvent`, a fence or a scheduled handler on our command buffers)
  that the plugin doesn't signal. The plugin has no `MTLSharedEvent`/`MTLEvent` code at all; `newSharedEvent` is left to
  `MTLIOAccelDevice`, and our command buffers don't implement `encodeSignalEvent:` / `encodeWaitForEvent:` (lenient mode
  would log them if they were sent; none were logged, so CA may wait through another mechanism).
- Lenient mode also lists `-[VGMTLTexture setResponsibleProcess:/protectionOptions]`,
  `-[VGMTLCommandBuffer protectionOptions]`, and `-[VGMTLCommandQueue setCompletionQueue:/setSubmissionQueue:/setGPUPriority:]`.
- WindowServer crash reports are throttled after the first few. ReportCrash's own log keeps the assertion text:
  `log show --predicate 'process == "ReportCrash" AND eventMessage CONTAINS "ASI found [lib"'`.

### Next

1. Find the wait. Read `CA::OGL::MetalContext` (fence and synchronize code) with codepeek, as for CoreDisplay. Look for
   what it creates on the device (`newSharedEvent`, `newFence`) and what it sends our command buffers. Then implement
   that: shared events signaled at completion, `encodeSignalEvent:value:`, `addScheduledHandler:` timing.
2. Then the present path: why CoreDisplay doesn't use IOPresentment transactions, or make the legacy path work
   (`VGSurface` shape/copy-forward backed by the framebuffer RAM).

### 5b, round 2 (2026-11-15): Core Animation surveyed; completion order fixed; the abort narrowed to `calculate_average_luma`

- **`tools/codepeek` reads Apple code by name now**: `codepeek LIB find SUBSTRING` lists a cached library's functions
  (dladdr over `__text`), `codepeek LIB sels SUBSTRING` lists every selector those functions send. Selector stubs
  (`objc_msgSend$sel` in `__objc_stubs`) and `__stubs` jumps are decoded. 16 s for QuartzCore in the guest.
  `/var/tmp/ca-sels.txt` in VM 108 holds what `CA::OGL::MetalContext` sends (213 selectors); `tools/mtlcaps.m` prints
  what our device answers to the capability questions `CA::OGL::new_metal_context` asks (tile shaders, memoryless,
  framebuffer read, raster order groups, SIMD group/reduction: all as a non-Apple Mac2/Metal3 GPU, no Apple families).
- **"timed out fence" is normal on this VM**: it shows on the plain software-compositor boot too. Not the cause.
- **Completion order** (plugin): command buffers of a queue whose caller set `-setCompletionQueue:` (Core Animation does)
  now complete in commit order on a serial queue, and their completed handlers run on that completion queue. Before,
  they ran on a global concurrent queue, concurrently and out of order. `addScheduledHandler:` used to run the block at
  once, even before commit; now it runs after submission. `setSubmissionQueue:`/`setGPUPriority:` are no-ops.
- **The abort, narrowed**: the first armed WindowServer (login stage) always dies in
  `CA::OGL::MetalContext::calculate_average_luma`. Its compute path (`sum_rgba_columns`/`rows`, then a blit) runs, then a
  branch falls back to the render/tile path, which calls `push_surface` with a transient surface CA never tracked
  (the assertion). The fallback is taken when `start_compute_encoder` fails, a `MetalBufferPool::create_external_buffer`
  returns null (heap with `setProtectionOptions:` + `newHeapWithDescriptor:` + `newBufferWithLength:options:`), or the
  context's command buffer (ctx+0xf00) is null after a block-taking message. Static reading didn't settle which.
  The WindowServer started after autologin (dev has Reduce Transparency on) survives but draws nothing at all.
- **Next**: reproduce CA's Metal renderer outside WindowServer, so one run takes seconds instead of a boot.
  `CARenderer` (`+rendererWithMTLTexture:options:`) runs `CA::OGL::MetalContext` in-process; a test app with a
  vibrancy/material layer over an image should reach `calculate_average_luma`. Then log every message our objects
  receive there (an `instrumentObjcMessageSends`-style trace works outside the sandbox) and find the failing branch.

### 5b, round 3 (2026-11-15): a Core Animation test app; the abort isn't the luma pass alone

- **`tools/carender.m`**: Core Animation's own Metal renderer (`CARenderer`, i.e. `CA::OGL::MetalContext`) in an ordinary
  process on our device: a gradient image, a translucent rounded panel and a luma-tracking `CABackdropLayer`, rendered
  into a texture and read back (`VGMTL_ENABLE=1 carender [FRAMES] [notrack]`). It renders correctly with framebuffer
  fetch by copies and no lenient fallbacks. It does not reach `calculate_average_luma` (`update_backdrop_luma` needs
  WindowServer's backdrop groups), so it doesn't reproduce the abort. It is the quick check for CA rendering from now on.
- **`codepeek LIB callers OFFSET`** lists direct callers of a function.
- **Call trace** (plugin): with `/Library/GPUBundles/VirtioGPUMetal-calls` present (WindowServer can read it), the
  plugin logs command buffers, encoders, dispatches, commits, completions, heap buffers and texture views as `CALL …`,
  and `STACK …` lines (caller frames) for blit-encoder creation, `endEncoding` and `commit`. Remove the file afterwards.
  Under load os_log drops some of it.
- Plugin additions: buffer-backed textures (`newTextureWithDescriptor:offset:bytesPerRow:` and CA's tiled/linear SPI,
  refreshed from the buffer at each bind), texture views (`newTextureViewWithPixelFormat:…`, images made with
  MUTABLE_FORMAT), protection options / responsible process kept per object, explicit capability answers (no tile
  shaders, memoryless targets, framebuffer reads, raster order groups; logged when asked).
- **What the trace showed in WindowServer's luma pass**: compute encoder, `sum_rgba_columns` and `sum_rgba_rows` dispatched,
  `endEncoding`, a blit encoder created and at once ended and the command buffer committed. CA's context then has no
  command buffer, takes the fallback, and the fallback's `push_surface` asserts. In `new_metal_context`, bit 1 of
  ctx+0xe37 (the luma fallback's tile branch) is `supportsTileShaders`. We now answer NO explicitly, and WindowServer
  asks and gets NO, yet it still aborts on "transient surface … not found".
- **The abort isn't the luma pass alone**: the post-autologin WindowServer of the previous boot, which looked
  stable, also aborted on it after 284 s from CA's normal end-of-frame flush (`MetalContext::Flush` via `EndUpdate`).
  So Core Animation loses track of one of its transient surfaces in ordinary rendering on our device.
- **Next**: transient surfaces are created by `CA::OGL::MetalContext::create_surface_with_properties` and tracked by
  `CA::OGL::Context` (`slist`). Read `create_surface_with_properties` and the surface release/volatile paths
  (`set_surface_volatile` -> `setPurgeableState:`, `purge_iosurface_cache`, heap aliasing) with codepeek, and make
  carender exercise transient surfaces (blur filter, shadow, masks) so the loss reproduces outside WindowServer.

### 5b, round 4 (2026-11-15): root cause of the WindowServer abort -- the display still goes through the software compositor

**Found, with probes inside WindowServer.** The "transient surface … not found" abort comes from WindowServer's
*software* compositor, not from Core Animation's Metal context. The failing stack (logged by the probe just before
the assertion):

```
CA::OGL::FlattenNode::retain_surface -> push_surface         (CA "context(2)", not the MetalContext)
CA::OGL::ImagingNode::render / render_layers / LayerNode::apply ...
CA::OGL::Renderer::render  <- CARenderOGLRender
SkyLight CGLayerKitFetch <- layer_blit_byte <- layer_blit_entry
SkyLight CompositorSW::CompositeLayersToDestination <- WS::Displays::CDDisplay::render_update
```

So with "Metal compositor activated", WindowServer still renders the display with `CompositorSW` (Core Animation's
software OGL context), while other work runs on our Metal device: SkyLight's `desktop_window_effects_update` (its own
`MetalContext`, the `sum_rgba` compute + blit + Finish, which completes normally) and CA's MetalContext. A flattened
layer's cached surface is then looked up in a context that doesn't own it, and CA asserts. The plugin bugs fixed on
the way (rounds 2-4) were real, but this mixed state is the cause. **It is the same open question as 5a: the display
isn't on the IOPresentment / display-pipe path** (no transactions reach `VGDisplayPipe`; CoreDisplay presents through
the legacy display surface, `CGXAccessDisplayDeviceSurface` / `vRotate` copies), so `CDDisplay` gets `CompositorSW`.
Refusing legacy surfaces (`-vgpulegacy` absent) ends the same way.

Also learned this round:
- The `sum_rgba_*` compute pass is SkyLight's own (`desktop_window_effects_update`), not CA's `calculate_average_luma`;
  it runs and completes correctly on our device.
- In-process Core Animation rendering on our device is correct with effects: `carender N fx` renders a Gaussian-blurred
  layer, a backdrop material, a shadow, a mask and group opacity (picture checked).
- Plugin: purgeable state kept per resource (previous state returned, as Metal's contract says); scheduled handlers run
  asynchronously (they used to run inline on the committing thread, where CA releases surfaces from them).

**Probes for next time** (plugin, WindowServer only, each behind a file in /Library/GPUBundles, all removed now):
- `VirtioGPUMetal-calls`: CALL/STACK trace of command buffers, encoders, commits.
- `VirtioGPUMetal-cahook`: wraps 14 `CA::OGL::MetalContext` vtable slots and inline-hooks 5 non-virtual
  `CA::OGL::Context` functions (release_surface, release_surface_async, add_transient_render_texture, push_surface,
  FlattenNode::retain_surface), logging surface pointers and flags; `push_surface` repeats CA's list lookup first and
  logs a miss with the full call stack. Offsets are 25G342's and every slot/prologue is checked before patching.
  Inline patching works because AMFI is off in this VM.
- `tools/codepeek`: `find`, `sels`, `callers`, `vtable OFFSET [all]`, `xref STRING`.

**Next (5b, the present path)**: find what makes `WS::Displays::CDDisplay` render with `CompositorMetal` and present
through IOPresentment. With the probes this is now directly observable: hook or trace SkyLight's display setup
(`WS::Displays::CDDisplay` construction, `CompositorMetal::new_compositor`, CoreDisplay's choice between
`CGXAccessDisplayDeviceSurface` (legacy) and the IOPresentment surface), and IOPresentment's interface creation
("Interface creation error: 0x2002" seen with the software WindowServer). The kernel side (pipe, AGDC, capabilities)
is in place and waiting for transactions.

### 5b, round 5 (2026-11-15): the desktop is composited with Metal and shown through the display pipe

**Checkpoint met.** At `vgpuaccel=4` the first WindowServer of the boot stays up on the Metal compositor (our
`VGMTLDevice` over Venus), CoreDisplay presents every frame as a display pipe transaction, and `VGDisplayPipe`'s
`performTransaction` copies it into the scanout: `VirtioGPUPipeFrames` "calls 61 ok 61 fail 0" a minute after login,
77 presents to the host. The tester on VM 108's console: "Desktop looks great! But it is slow". Five things stood between
round 4 and this, found in this order:

1. **CoreDisplay's IOPresentment switch is a GPU-vendor check on the framebuffer's class name.**
   `CoreDisplay::UseIOPresentment()` (+0xb6f0) is true only when a once-computed vendor mask (+0x3e790c84) is non-zero
   and covered by four allow flags (all 1). `__GetSystemGPUVendors_block_invoke` ORs `GetGPUVendorForFramebufferService`
   over every `IOFramebuffer`: `IOObjectCopyClass` contains (case-insensitive) "Intel" -> 2, "AMD" -> 4, "NVDA" -> 8,
   "AppleParavirt" -> 0x10, else 1, and bit 1 is dropped. "VirtioGPUFramebuffer" gave 0, so every display took the
   legacy display surface and `CompositorSW` (round 4's mixed state). The framebuffer kext now has a subclass
   `VirtioGPUFramebufferAppleParavirt` (IOProbeScore 2000) that only matches at `vgpuaccel>=4` without
   `-vgpunovendor`; below that the plain class matches and the software desktop is as before. Found with the new
   `codepeek dref` (RIP-relative references to a data address).
2. **Plugin gaps the IOPresentment path uses**: CoreDisplay's display pipe (`RunFullDisplayPipe`) asserted on
   `m_combinedLUTTexture` because `MTLTextureType1DArray` wasn't supported; it renders its LUTs into slices of that
   array, so color attachments now take a level or slice (a one-level, one-slice view); `RG16Unorm/Snorm/Uint` added
   (a WindowServer surface). The refused attachments had been failing command buffers (SkyLight: "Detected command
   buffer completion failure. Error code = 0x1", "Flushing display space to aid GPU restart recovery").
3. **The pipe was never active.** A kernel probe (accel 0.5.5, off with `-vgpunopipeprobe`) wraps
   `IOAccelDisplayPipeUserClient2::externalMethod` (vtable copy, one slot replaced) and logs each selector. Selector 8
   (`transaction_end`, 280-byte args) answered `kIOReturnNotReady`. Reading the family out of the guest's
   `SystemKernelExtensions.kc` (new `tools/kcsyms.py` / `tools/kcdis.py`): `transactionEnd` requires accel+0xc78 bit 2,
   pipe+0x282 == 0 and `IOAccelDisplayPipe::isActive()` (+0x298), which only `init_framebuffer_resource` sets, and only
   when the pipe's `initFramebufferResource` returns memory and the resource then `prepare()`s. Ours returned NULL
   ("frames are copied", NV's choice for another GPU's panel). Now it returns the framebuffer's VRAM wrapped by the
   family's exported `IOAccelSysMemory::withMemoryDescriptor`; the pipe goes active at the first mode set.
4. **Transactions then failed with `kIOReturnNoResources`** in `IOAccelDisplayPipeTransaction2::prepare()`: the planes'
   resources (CoreDisplay's display surfaces) live in video memory and `VGVidMemory::allocPhysical` refused. It now
   backs each allocation with contiguous kernel RAM (phys at +0xc8, length at +0x40, the family's own
   `getPhysicalSegment`); `-vgpunovidmem` refuses again. Nothing GPU-side reads it; frames still reach the screen by
   copies from the IOSurfaces.
5. **The video memory was 0 bytes**: `VGResource::calculateIOSurfaceDeviceCacheVRAMBytes` answered 0. It and the level
   offsets now read the resource's pitch and face size as NV does (`vendor/nullmoth/accel/nvres_fields.h`, vendored).

Also: `vg_coredisplay_report` (plugin, WindowServer) only reads CoreDisplay's switch now; calling
`CoreDisplay_UseIOPresentment()` itself computed the mask early and cleared the switch for good.

**Known issues, for 5c**
- **Slow.** Every frame is a full 1280x800 CPU copy in `performTransaction` plus the plugin's IOSurface sync (CPU copies
  between the IOSurface and its Venus image on each pull and write-back), and CA's first pipelines translate in ~4 s.
- **The guard at `vgpuaccel=4` no longer gives a software desktop.** With the AppleParavirt class name the vendor mask
  is set whatever the arm state, so a withdrawn WindowServer finds "System set to use IOP but no display pipes are
  present" and sets the main display offline (seen once this round, before the 1D-array fix). A withdraw should also
  stop the framebuffer naming a vendor, or the guard should leave the pipe capabilities in place.
- CoreDisplay still logs "Attempting to get capabilities from plane with no gamma" per frame and its first few
  transactions fail before the pipe is active; several AGDC attributes are still answered unsupported (0xe00002c7).
- First boot after an install: the first ~6 transactions are refused (pipe not yet active).

**Recommendation for 5c**: speed. Measure first (per-frame time in `performTransaction`, plugin pull/write-back
counts and bytes per frame), then: present through a host-side blit instead of a CPU copy (the scanout as a Venus
image, or the virtio-gpu resource the IOSurface already is), and keep IOSurfaces resident on the Venus side so a frame
isn't pulled from and written back to guest RAM. Fix the withdraw path before anything that could crash WindowServer
in a loop.

## Stage 5c, round 1 (2026-11-15): the Metal desktop, faster and clean

Measured first (new: `VGMTLPerf.m` logs "perf 5 s: ..." from WindowServer, or any process with `VGMTL_PERF=1`;
`VGMTL_PERF=2` / `/Library/GPUBundles/VirtioGPUMetal-gputime` add GPU timestamps; the kext publishes
`VirtioGPUPipeTiming`; `tools/mtllat` times command-buffer round trips), then fixed in this order. Benchmark:
`mtlwindow` (a spinning Metal triangle in a window) while WindowServer composites it at `vgpuaccel=4`.

| Step | `mtlwindow` | What it was |
|---|---|---|
| 5b as committed | 15.7 fps | WindowServer spent 3.7-4.1 s of every 5 s in ~800 synchronous one-shot submits (~5 ms each) |
| deferred work | 15 fps | one-shots ~0; the remaining waits are elsewhere |
| PerfPowerServices off | ~10 fps (noisy) | a system daemon spun a whole vCPU on the emulated SMC |
| staging pool for setBytes arenas | 27.2 fps | every command buffer created and destroyed Venus buffers |
| one image per IOSurface | 42.5 fps | redundant pulls gone; also fixes most stale pieces |
| wait for write-back in commitAndWaitUntilSubmitted | 29.6 fps | the display pipe no longer shows a surface before its frame is in it |

The tester on VM 108 after the last step: dragging a Finder window is **clean** (before: old window pieces left behind and
flicker), smoother than the first Metal desktop, still not smooth.

What changed:
- **Deferred GPU work** (`vg_pending_*` in `VGMTLTexture.m`): a new image's layout transition, `replaceRegion`
  uploads, buffer-backed texture refreshes and IOSurface pulls no longer submit and wait. They queue and are recorded
  in a command buffer submitted just ahead of the next commit (same `vkQueueSubmit`), or at the start of the next
  one-shot (readbacks still wait, as `getBytes` must). An image going away drops its queued work.
- **Staging pool** (`vg_staging_get/put`): uploads, pulls, readbacks and command buffers' `setBytes` arenas reuse
  host-visible buffers (48 buffers / 192 MB at most). Creating one through Venus is several round trips plus a host
  fault on each first-touched page; this was the biggest single cost.
- **One GPU image per IOSurface plane** in a process: later wrappers of the same surface are views of the first.
  With a private image per wrapper, synced only through the surface's CPU memory, WindowServer's copy-forward read
  stale pixels once frames overlapped.
- **`commitAndWaitUntilSubmitted` waits** for the write-back when the command buffer wrote IOSurfaces (Core Animation
  commits its display frames this way, then hands the surface to the display pipe, which copies its CPU memory; the
  family thinks our GPU work is already done). `VGMTL_NOWAIT_SUBMIT=1` turns it off (faster, with leftovers).
- **Fence waits through the kernel** (`VN_PERF=no_fence_feedback`, set by the plugin unless the process set
  `VN_PERF`): Venus' fence feedback polls with short sleeps that macOS stretches under load (median small submit
  under load 8.3 -> 5.8 ms).
- Framebuffer fetch copies only the scissor's pixels (Core Animation's scissors are mostly near-full-screen, so a
  modest gain). Core Animation's `fixed_frag_*_cpf` shaders really read all three `[[color(n)]]` inputs (the plugin now
  logs declared vs read per pipeline; declared-only inputs get no copies).
- **Guard fallback fixed** (accel 0.5.9): a withdraw keeps `MetalPluginName`, so the plugin still loads into the next
  WindowServer, turns CoreDisplay's IOPresentment switch off there (`vg_coredisplay_off`, the byte
  `UseIOPresentment()` reads first, 25G342 layout checked) and refuses the device: software desktop (the tester saw the
  login window). `mtl withdraw` + `killall -9 WindowServer` and `mtl wsarm` + `killall -9 WindowServer` switch both
  ways without a reboot (the guard still counts WindowServers since the last arm).
- VM 108: `launchctl disable system/com.apple.PerfPowerServices` (it spun on QEMU's SMC in
  `PLSMCMetricsAgent getAllKeys`); `launchctl enable` + reboot undoes it.

Where the time goes now (WindowServer, a busy desktop): ~60 command buffers/s, ~10 ms commit -> done, of which GPU
time is a few ms; ~400 framebuffer-fetch pass splits/s (~22 per frame); every frame read back to the CPU (4 MB) for the
pipe's copy; the pipe copy itself ~0.8 ms. The app's own tiny frames took ~15 ms commit -> done under load with 0.17
ms of GPU time: latency between the host GPU finishing and the guest seeing it is the largest remaining cost.

**Next (5c round 2)**: (1) present without the CPU: let the display pipe flip to (or the host blit from) the GPU image
of the frame, so the write-back, the wait in `commitAndWaitUntilSubmitted` and the pipe's copy go away; (2) the
framebuffer-fetch splits: native input attachments (dynamic rendering local read, if Venus can pass it) instead of
end-copy-resume; (3) find the guest/host latency on fence completion (QEMU's fence handling, the kext's interrupt
path, guest scheduling).

## Stage 5c, round 2 (2026-11-15): frames go to the screen straight from the host GPU

**Zero-copy present works.** WindowServer's display frames reach VM 108's console without any CPU copy: the
plugin copies each display surface, on the GPU, into a *twin* (a linear host-visible Venus buffer, i.e. a virtio-gpu
blob resource), and the display pipe points scanout 0 at that blob with `SET_SCANOUT_BLOB` + `RESOURCE_FLUSH`; QEMU
(11.1.3, virglrenderer 1.1.0, `egl-headless`) imports it as a dmabuf. Proven first with `tools/blobtest` (a color-bar
pattern from a Metal buffer; the tester saw it), then end to end: `VirtioGPUPipeFrames` "ok N (from a twin N)".

Pieces:
- Mesa patch 0006: `vn_macos_device_memory_res_id()` returns the blob resource behind a mappable allocation (the
  plugin finds it with dlsym; `-[VGMTLBuffer vgResId]` for tools).
- Core 0.5.2: `setScanoutBlob()` (a blob on scanout 0, or the framebuffer's 2D resource again; the framebuffer's own
  flushes are skipped while a blob is shown), a twin table (IOSurface id -> blob) filled by `kVGUCSetTwin` (WindowServer
  only, and only for a blob one of its own clients created), `kVGUCScanoutBlob` (root, for blobtest). A destroyed
  resource drops its twin and takes it off the screen (WindowServer exiting is safe). Links `com.apple.kpi.bsd`.
- Accelerator 0.6.x: `performTransaction` looks the frame's surface up (`vgpu.twinFor`) and queues a flip instead of
  copying; flips run on a work loop of their own (QEMU answers a flip only after drawing it and reading it back for
  VNC, 4-7 ms, up to ~26 ms) and are paced at least 16 ms apart, newest frame wins (`vgpuflipms` boot-arg,
  `acceltest flipms N` at run time; the tester: paced flips judder less). No twin, or a size mismatch: the CPU copy as
  before, with the framebuffer put back on screen first. A withdraw puts the framebuffer back too.
- Plugin: a twin per screen-sized BGRA IOSurface WindowServer presents (`commitAndWaitUntilSubmitted`), copied in the
  same command buffer; that call then waits for the GPU only. Twinned surfaces get **no CPU write-back** any more
  (nothing reads them on the CPU; `VGMTL_TWIN_WRITEBACK=1` keeps it). `VGMTL_TWIN=0` turns twins off.

Also this round:
- **Surface roots kept 2 s** after their last wrapper: Core Animation makes a new texture for an app's drawable every
  frame, so with only the weak map each frame built a new host image (369 times in 5 min for one window).
- **Translated shaders on disk** (`VGMTLLibrary.m`), in the process's Darwin cache directory, SHA-256 keyed (translator
  content, stage, constants, threadgroup sizes, module text), for SPIR-V and reflection. Core Animation keeps asking for
  new variants as the desktop does new things (~4 s each on WindowServer's thread), so the cache fills with use; the
  key is stable across boots (2 of 83 files shared content). `VGMTL_NODISKCACHE=1` off.
- **Transparency crash fixed**: with transparency on, Core Animation's luma pass asks for its compute pipeline with the
  private two-argument `newComputePipelineStateWithDescriptor:error:`, which only `MTLIOAccelDevice` answered (nil, no
  error): WindowServer aborted ("function=compute_average_luma") and the guard withdrew to software after two
  restarts. The plugin now answers it and the completion-handler forms.

Numbers (`mtlwindow` while WindowServer composites it): ~26-31 fps; WindowServer ~100 command buffers/s at ~6.4 ms
when dragging, no write-backs, pulls 0.2 ms; transaction 10 us. The tester: smoother than before with paced flips, but it
**still judders**.

**What's left (judder)**: the framebuffer-fetch splits (~700/s while dragging, ~1 GB/s of GPU copies plus a pass
restart each) are now the heaviest GPU work per frame and vary with the scene; QEMU's flip time varies (4-26 ms);
new Core Animation variants still translate for ~4 s on WindowServer's thread until the disk cache has them; and the
console itself (VNC/noVNC encoding full-screen changes) may add its own uneven pacing. Next: native input attachments
or a cheaper fetch (e.g. copy once per pass and only re-copy when a draw writes what a later fetch reads), a look at
the console path (SPICE vs VNC, egl-headless readback), and translating faster or ahead of time (warm the cache from
Core Animation's library at install).

## Stage 5c, round 3 (2026-11-15): the judder found and gone; the desktop keeps up

Measured first: the kext now histograms the gaps between WindowServer's frames (transactions), between flips, and
how long flips take (`VirtioGPUPacing`; `acceltest pacereset` / `acceltest pace`), and the plugin's perf counters log
one line per kind (the unified log cut the long lines). Recorded while the tester dragged and scrolled.

1. **The judder came from WindowServer, not the display**: 91 of 116 frame gaps were 50-100 ms and the flips followed
   them exactly. WindowServer sat in `commitAndWaitUntilSubmitted` 666 times in a 40 s scroll, 18.5 ms each (12.3 s),
   for ~5 ms of GPU work: round 2's wait for the twin copy, Venus' completion latency on top.
2. **No wait, frames numbered** (core 0.5.3 `kVGUCTwinMark`, accelerator 0.6.5): the plugin numbers each twin copy,
   marks it submitted at commit and ready after the fence; a transaction asks for the frame last submitted into that
   twin and the flip loop flips once it is ready (1 ms polls, at most 100 ms, then anyway: "flipped unready").
   the tester: "the judder seems gone, but things are slower and jerky".
3. **Completions at USER_INTERACTIVE** (the completion queue and the fallback global queues): Venus waits for fences
   in short sleeps that macOS stretches at lower classes. `mtlwindow` ~30 -> ~47 fps; completions in line 32 -> ~2 ms.
   Fence feedback on or off measured the same (~12 ms fence wait for ~3 ms of GPU time); it stays off, and
   `/Library/GPUBundles/VirtioGPUMetal-fencefeedback` turns it back on.
4. **Two display frames in flight** (`VGMTL_PRESENT_DEPTH`, default 2): with no wait at all WindowServer ran ahead of
   the GPU and a dragged window trailed far behind the pointer. Now a display frame waits for the one before it.
   the tester: "way better, probably better than it's been".
5. **Twins only at the screen's size** (core 0.5.4 refuses others; the plugin then keeps the CPU write-back): a window
   snapshot drawn in a display frame had become a twin and lost its write-back, so the Dock's minimize preview was
   blank. The tester: preview shows, still good.

State: `mtlwindow` ~48 fps while WindowServer composites it. GPU timestamps and fence feedback are off again (flag
files removed).

**Next**: the ~12 ms between the GPU finishing and the guest seeing it (Venus host side: ring thread, fence
signaling) is now the floor under every frame; the framebuffer-fetch splits (~40 per command buffer); shader
translation stalls for new variants; and "flipped unready" (27 in one boot, likely startup translations: check it
stays 0 in normal use).

## Stage 5c, round 4 (2026-11-15): where completion latency comes from

Measured with GPU timestamps mapped onto the guest's clock (`VK_EXT_calibrated_timestamps`, now enabled; with
`VGMTL_PERF=2` or `/Library/GPUBundles/VirtioGPUMetal-gputime` the plugin logs "latency: commit -> GPU starts it" and
"latency: GPU done -> guest sees it"). A WindowServer command buffer under `mtlwindow` load:

| commit -> GPU starts | GPU work | GPU done -> guest sees it |
|---|---|---|
| 7.2-7.6 ms | 2.6 ms | 0.6 ms |

- The completion side is fine now (round 3's USER_INTERACTIVE queues): a small submit round-trips in ~1 ms even under
  load (`mtllat`; it was 6-12 ms).
- The time before the GPU starts is mostly **queueing behind the same frame's earlier command buffers** (2-4 arrive
  together, ~2.7 ms of GPU each); Venus' host ring thread for WindowServer runs at ~40 % of a core (bursty), not
  saturated. So the floor under a frame is its GPU time, not Venus.
- Command reductions (kept; correct and cheaper for the host): the render encoder sends pipeline, set binds, vertex
  buffers and dynamic state only when they change (~5 skipped per command buffer here); descriptor sets are remembered
  per command buffer by their exact contents (few reuses: `setBytes` data moves every draw, 24 189 written vs 1 937
  reused); descriptor pools are reset and recycled instead of created per command buffer. No measurable fps change.

**Tried and dropped: pre-specializing Core Animation's uber shaders with Apple's LLVM** (to cut the ~4 s translation
stalls). LLVM's C API is all there (`LLVMParseIRInContext`, `LLVMRunPasses`, builder), but AIR copies each function
constant into an internal global inside an initializer function, so folding the constants' own loads reaches little
without `globalopt`, and the translator recognizes specific AIR shapes (the initializer, the static-init struct
fields): pre-optimized modules fail in its native emitter ("getelementptr value requires instruction-local
materialization"). The translator is already a `--release` build. Translation stalls stay mitigated by the disk cache.

Also noted: Venus offers `VK_EXT_attachment_feedback_loop_layout` (a possible native path for framebuffer fetch, but
barriers inside dynamic rendering need `dynamicRenderingLocalRead`, which it doesn't list).

**Next**: GPU time per frame is now the lever (Core Animation's fetch splits, ~40 per command buffer in busy scenes;
the size of the translated uber shaders), and the translation stalls (faster translation inside the translator, or
building Core Animation's common variants ahead of time).

## Stage 5c, round 5 (2026-11-15): what framebuffer fetch costs

Four boots, WindowServer under `mtlwindow`, GPU timestamps on, the fetch emulation switched by
`/Library/GPUBundles/VirtioGPUMetal-fetchmode` (kept for measurements; default 0):

| mode | GPU per command buffer | mtlwindow |
|---|---|---|
| 0 full barriers (default) | 2.55 ms | 50.0 fps |
| 1 no copies (wrong pixels) | 1.85 ms | 47.5 fps |
| 2 no split at all (wrong pixels) | 1.77 ms | 47.8 fps |
| 3 targeted barriers | 2.52 ms | 43.9 fps |

The copies are ~27 % of WindowServer's GPU time; ending/resuming the pass and the barriers cost almost nothing, and
narrower barriers save nothing. Sampling the attachment in place (VK_EXT_attachment_feedback_loop_layout) would remove
the copies, but **the frame rate doesn't move even with no fetch work at all**: GPU time doesn't limit it here, so
that rewrite is not worth its risk now. What limits the benchmark is the presentation chain (16 ms flip pacing, two
frames in flight, QEMU's ~3-4 ms per flip), not the guest GPU or Venus.

## Stage 5c, round 6 (2026-11-15, overnight): 40-60 fps for every gesture; screenshots; Venera 0.1.0

Measured with injected input (`tools/qmpinput.py` through VM 108's own QMP socket: a window drag in circles, a live
resize from the corner; `tools/dragtest` animates scrolling and minimizing itself), the kext's pacing histograms
and the plugin's counters (`tools/gesture-bench.sh`, `tools/drag-perf.sh GESTURE`), WindowServer sampled during each
(`tools/gesture-sample.sh`, `tools/sample-top.py`). Most frame gaps, before -> after:

| gesture | start of the round | end of the round |
|---|---|---|
| drag | 25-50 ms | 10-25 ms |
| live resize | 50-200 ms | 17-34 ms |
| scroll | 34-100 ms | 10-25 ms |
| minimize | 50-100 ms | 17-25 ms |

(WindowServer paces to the 60 Hz VBL, so 16.7 ms is the floor; flips land 17-25 ms apart.)

1. **The present throttle counted the wrong thing.** WindowServer calls `commitAndWaitUntilSubmitted` ~3 times per
   display frame (its composite flush, then CoreDisplay's), so "depth 1" made each call wait ~10 ms for the call
   before it: ~30 ms a frame, WindowServer's main thread mostly in `_dispatch_group_wait_slow`. The depth now counts
   command buffers (default 6; 1/2/4/6/8 measured: 4-8 alike, 6 the best resize and scroll), waits for the fence only
   (`_fenced`, not the handlers), and `/Library/GPUBundles/VirtioGPUMetal-depth` is read again once a second.
2. **The flip loop starved** (accelerator 0.6.8): it waited for the *newest* frame to be ready, and while frames kept
   coming the newest never was (flips 25-200 ms apart while WindowServer made one every ~16 ms). It now keeps the last
   8 requested frames and flips the newest one that is ready.
3. **Buffers from the pool**: while an app scrolled, ~35 % of WindowServer's thread was creating and mapping
   host-visible buffers (`vn_MapMemory`) for Core Animation's per-frame buffers and new surface textures. Buffers and
   surface write-back staging now come from the staging pool (160 buffers / 256 MB; small sizes in powers of two from
   4 KB; staging taken only when a command buffer first writes the surface; pooled memory zeroed for new buffers).
4. **Screenshots were blank** (core 0.5.5): Cmd-Shift-3 renders the screen into new screen-sized surfaces in display
   command buffers; they got twins, and twins skipped the CPU write-back. The core's twin table now marks a surface
   shown when a display transaction asks for it, `kVGUCTwinMark` returns that, and only shown surfaces skip the
   write-back. Others (screenshots, and one GPU-only intermediate per frame) keep it, before the completion handlers
   as Metal requires, without `commitAndWaitUntilSubmitted` waiting for it. `screencapture` from the guest agent is
   refused by TCC (no Screen Recording permission for mac-guest-agent), not by the driver.
5. Checked: display sleep and wake (`pmset displaysleepnow`, a click), the Dock's minimize preview, no crash reports,
   2-4 "flipped unready" per boot (startup only).

Still open: the GPU work per frame (~2.5 ms per command buffer, ~27 % of it framebuffer-fetch copies) and commit ->
GPU start latency (~10 ms, the frame's own earlier command buffers queued ahead of it); a live resize is also paced
by the app's own layout. Next would be sampling the attachment in place (`VK_EXT_attachment_feedback_loop_layout`,
needs render-pass objects) and app Metal (the allow-list).

**Packaging: Venera 0.1.0** (`packaging/`, `docs/INSTALL.md`). `packaging/make-dist.sh` builds
`dist/Venera-VERSION.tar.gz`; in the guest `sudo ./install.sh [--set-security]` checks the guest (macOS 26 x86_64, the
virtio-gpu device, SIP 0x203, `amfi_get_out_of_my_way=1`), finds OpenCore's EFI partition, backs up `config.plist`,
adds/enables the `VirtioGPU.kext` entry and `vgpuaccel=4`, installs the Auxiliary KC kexts (kmutil, checked) and the
Metal bundle; `uninstall.sh` removes all of it; `status.sh` shows what runs. Tested on VM 108: uninstall + reboot
(firmware framebuffer, no driver), install + reboot (Metal desktop). Host requirements and recovery: INSTALL.md.

**GitHub**: https://github.com/jazzphone/venera (private). Before the push the history was rewritten to drop the
host's addresses, name and SSH key name and first names (the original history is the local branch
`private-history-2026-11-15`; commit ids in this file before this section are from it). The host now comes from
`tools/local.env` (ignored). License: PolyForm Noncommercial 1.0.0 (the accelerator is built with NullMoth's
noncommercial headers); `NOTICE.md`. No release is published.

### Round 6, after midnight: flip pacing, the VNC ceiling, repeated screenshots, fetch in place

- **Flips at most every 12 ms** (accelerator 0.6.10, was 16): with the newest-ready loop, WindowServer makes ~56
  frames a second during a drag (mean gap 17.7 ms); a 16 ms floor dropped a quarter of them (flips 22 ms apart on
  average), 12 follows it (18.5 ms), 8 too but less evenly. Fewer flips (33 ms) didn't lower latency. Pacing
  histograms now have bins around 60 Hz and print the mean.
- **The console is capped at ~33 fps by QEMU**: its VNC server (Proxmox's noVNC console) sends at most one update per
  30 ms (`VNC_REFRESH_INTERVAL_BASE` = `GUI_REFRESH_INTERVAL_DEFAULT` = 30, checked in QEMU's source), however fast
  the guest flips. 60 fps is only visible through a non-VNC display (gtk/sdl with gl, local SPICE gl) or streaming
  from the guest. INSTALL.md says so.
- **Repeated screenshots**: one in three still came out blank: WindowServer reads a capture surface on the CPU right
  after `commitAndWaitUntilSubmitted`, which no longer waited for unshown surfaces' write-back. It waits again,
  except for a surface written by 10 display command buffers in a row (the per-frame GPU-only intermediate): 8 of 8
  correct, pacing unchanged.
- **Framebuffer fetch in place, now the default** (mode 4): with `VK_EXT_attachment_feedback_loop_layout` the split
  still ends and resumes the pass, but the draw samples the attachment itself in the feedback loop layout (render
  targets get the feedback loop usage, fetch pipelines the flag, encoders put the layout back to GENERAL) instead of
  a scratch copy. Against copies (tools/pngdiff on Cmd-Shift-3 screenshots of the same desktop): alike to the eye
  (34 k pixels differ slightly at glass edges), deterministic, gesture snapshots clean; WindowServer's command
  buffers complete in ~12 ms instead of ~20 (commit -> GPU start 7.9 vs 11.8 ms; the copies were host CPU work for
  Venus' ring thread as well as GPU time), ~70 MB less memory. `VirtioGPUMetal-fetchmode` = 0 goes back to copies.
- **Soak** (`tools/soak.sh`): 16 min with copies and 10 min in place, drags/resizes/scrolls/minimizes in a loop:
  same WindowServer throughout, no crash reports, memory flat after the pool filled. Display modes (1024x768 to
  1920x1080) switch with the Metal desktop running (`tools/modetest`). Display sleep/wake fine.
- Host observation (read-only `top`): Venus' ring thread for WindowServer (`vkr-ring` in virgl_render_server) ran
  at ~68 % of a host core under load; decoding WindowServer's commands there is what queues each command buffer, so
  fewer commands per frame is the next latency lever (push descriptors instead of allocate/update/bind per draw).

## Stage 5c, round 7 (2026-11-16): push descriptors, measured and set aside

The idea from round 6: Venus' host ring thread for WindowServer (`vkr-ring`) ran at ~68% of a host core, so fewer
commands per draw (push descriptors instead of allocate + update + bind) might shorten the wait before the GPU starts
a command buffer.

- Built on branch `experiment/push-descriptors` (not on main): `VK_KHR_push_descriptor` (Venus has it, max 32 on the
  Iris Xe), one render set pushed per draw, chosen by `/Library/GPUBundles/VirtioGPUMetal-push` (1 vertex, 2
  fragment); a push is skipped when its contents match the last one. Half of WindowServer's descriptor sets became
  pushes (~14 k of ~29 k per 5 s during a drag).
- Measured (snapshot `pre-push-r7` first): six boots alternating off / fragment / vertex, 2 min after login, three
  8 s drags from a fresh `dragtest` each, frame gaps from the kext and the ring thread from the host's `top`
  (read-only). **No gain**: mean drag frame gap off 18.1 ms, fragment 19.1 ms, vertex 19.2 ms; the ring thread ~60%
  of a core off, ~55% with pushes. (A first run of this A/B was thrown out: the session was locked, below, so its
  drags moved a window behind the lock screen.)
- Why: the ring thread's CPU is mostly not decoding. From `/proc` (read-only) during a drag, 46 user ticks against
  343 system ticks: ~88% of its time is in the kernel, ~7 k voluntary context switches a second, sampled mostly in
  `clock_nanosleep` / `sched_yield` / futex: virglrenderer's ring polling (`vkr_ring_relax`: yields, then short
  sleeps) and the GPU driver's ioctls, not command decoding. Command count isn't the lever; the earlier "~68% of a
  core" never meant the thread was saturated. (Sampled on the locked screen; the split is the thread's, not the
  scene's.)
- **The session was locked** from the night before: loginwindow re-locks an auto-login session that was locked at
  shutdown ("loginUserIsAutoLoginUser ... locking screenWasLocked", kLWLockFromCookieFile), so every reboot came back
  locked, and the lock screen plays the Aerial video (`VTDecoderXPCService` ~110% of a guest core, software HEVC
  through `VCPHEVC.bundle`: no video decoder for this GPU). Return at the lock screen unlocks it (no password on VM
  108); measurement scripts now run `caffeinate -dimu` in the session after each boot and print the lock state
  (`ioreg -n Root -d1 | grep ScreenIsLocked`).
- Video decode on the GPU (looked into, not built): NullMoth's NVIDIA driver registers its own VideoToolbox decoders
  (`VTRegisterVideoDecoderWithInfo`, WebKit's published VTVideoDecoder SPI) from its Metal plugin in every process,
  VTDecoderXPCService included; Apple's AppleGVA bundle route is unmapped. For Venera the decoder would need an
  engine: Venus has no Vulkan Video (Mesa main, 2026-11-15) and the host's virglrenderer 1.1.0 none either; vrend's
  VA-API video exists in the library but QEMU never sets `VIRGL_RENDERER_USE_VIDEO` and the host has no VA driver.
  Every route needs host changes; set aside for app Metal.

VM 108 is back on main's driver (0.1.0 + round 6), no flag files.

**Next**: what remains under a frame is GPU time per command buffer (~2.7 ms each, ~3 per frame, queued behind each
other) and the host's flip (egl-headless reads the frame back for VNC, 2-9 ms). Fewer or cheaper command buffers per
frame (the ~40 framebuffer-fetch splits) is the guest-side lever; a non-VNC display removes the readback.

## Stage 5d, round 8 (2026-11-16): app Metal, first look

Snapshot `pre-appmetal`. `tools/apptest.sh APP [PROCESS...]` writes the allow-list, launches the app as the console
user (`OPEN=` a file for it), takes a Cmd-Shift-3 screenshot through QMP and prints the driver's log for it and any
crash report; `tools/apptest/gpu-page.html` is a local WebGL / canvas / CSS page (VM 108 has no network).

- **Lenient mode in every process** (`VGMTL_LENIENT=0` turns it off): an app that sends a message we don't implement
  logs `LENIENT: -[class selector]` and gets nil/0 instead of aborting. It was WindowServer-only.
- **Chess**: draws correctly, but not through us: it is OpenGL, and with no `IOGLBundleName` on the accelerator macOS
  gives it the software renderer (`GLRendererFloat.bundle`). NullMoth sets `IOGLBundleName = AppleMetalOpenGLRenderer`
  (Apple's OpenGL over Metal, present on this guest) and lowers the renderer's shaders through Apple's
  `libGLDPlugin` (`plugin/NVMTLGL.m`, ~500 lines): the way to OpenGL apps.
- **Safari**: without app Metal, WebGL gets no context (renderer null) and canvas / CSS run at 30 fps. Allow-listing
  `com.apple.WebKit.GPU` does nothing: its sandbox denies `file-map-executable` for `/Library/GPUBundles`. It maps code
  only from the sealed system (`/System/Library/Extensions`, `Frameworks`, `PrivateFrameworks`, `/usr/lib`) and the
  cryptex folders, which on this guest are read-only grafts (`EROFS` even with Preboot mounted read-write). Opening
  our device is allowed (`iokit-connection "IOAccelerator"`, Venus already goes through the accelerator's client) and
  `/Library/GPUBundles` is readable. So WebGL in Safari needs the bundle in `/System/Library/Extensions`: authenticated
  root off (csr 0x800), a root patch and a new blessed snapshot, as OpenCore Legacy Patcher does. Not done (owner's
  call). NullMoth's Preboot copy (`safari_gpu_copy.sh`) can't work here for the same reason.
- **Preview / QuickTime** (Core Image): `-[VGMTLCommandQueue setBackgroundGPUPriority:]` (now answered by lenient
  mode), then Preview crashes in `CIKernelReflection::consolidate` (null) from `+[CIColorKernel kernelWithString:]`:
  Core Image reads function reflection we don't give. NullMoth answers it with CI binding classes and bridges
  `newLibraryWithStitchedDescriptor:` through Apple's own stitcher (NVMTLObjects.m, NVMTLDevice.m): the Core Image
  milestone.
- **Maps**: `-[VGRenderEncoder updateFence:afterStages:]` (fences; no-ops are safe here: every encoder ends with a full
  barrier and all queues submit to the one Vulkan queue in order), library functions in namespaces not found
  (`Clear::clear_vertex`), pipelines from them refused, `texture: type 4` (2D multisample).
- Freeform, Photos: no driver activity in 15 s (nothing drawn with Metal yet, or not reached).

Scale: NullMoth's plugin has ~100 classes (events, fences, argument encoders, indirect command buffers, reflection,
stitching, Metal 4); ours 14, sized for WindowServer. Milestones: (1) the simple missing calls (fences, events,
priorities, namespaced functions, MSAA textures); (2) Core Image (reflection + stitching); (3) OpenGL over Metal;
(4) Safari WebGL once the system-volume install is decided.

### Round 8, part 2: Safari on Venera (system-volume install)

- `newLibraryWithSource:` (ANGLE writes MSL at run time): Apple's base class compiles it, the library's container
  (`libraryDataContents`) goes through our loader (after NullMoth's `nvmtlBridgeAppleLibrary`). `tools/mtlsource`:
  compute (4096/4096 right) and render (exact pixel) from source.
- Authenticated root off on VM 108 (`packaging/sysvol.sh csr`: OpenCore csr 0x203 -> 0xA03; snapshot `pre-authroot`
  first), the bundle copied into `/System/Library/Extensions` on the live system volume and a new snapshot blessed
  (`sysvol.sh install`; `Sealed: Broken` after the reboot, as expected). Metal looks in `/Library/GPUBundles` first and
  doesn't fall back when the sandbox refuses it, so that path is now a symlink to the system copy: the sandbox judges
  the file mapped. `tools/deploy.sh metal` installs through `sysvol.sh` once the symlink is there (a reboot per
  deploy).
- **Safari's test page on Venera** (allow-list `com.apple.WebKit.GPU`): WebGL draws (renderer "Apple GPU"), canvas
  and CSS transforms + backdrop blur at 60 fps; without app Metal: no WebGL context, canvas and CSS at 30 fps.
- Open: (1) the animated canvas looks dim (balls ~ one fade behind); static colors (`tools/apptest/canvas-colors.html`)
  match software exactly, fetch mode 0 changes nothing, so it's timing: the compositor sometimes shows the canvas
  surface between its fade and its redraw (cross-process IOSurface write-back?). (2) WebKit's canvas pipeline
  `fixed_vert_lpf_spc+fixed_frag_lpf_cpf` has 60 function constants and each new combination is translated afresh,
  ~5.5 s and 685 KB of SPIR-V each, several in the first minute: specialization constants instead of a translation per
  combination. (3) Missing: `generateMipmapsForTexture`, `setBackgroundGPUPriority:`, a fragment-stage setter and a
  command-buffer encode call (lenient mode answers them).
- The owner's direction (2026-11-16): every app through the driver, installed in `/System/Library/Extensions`, with a
  helper that notices a macOS update removed or changed the copy, asks before reinstalling, and says why when it can't.

### Round 8, part 3: every app on the driver

Measured on VM 108 (snapshots `pre-authroot`, `pre-watcher`, `pre-gl`), each fix with a test:

- **Safari**: events signaled at completion (the dim, half-drawn canvas), fences, mipmaps, the staging pool evicting
  its oldest (14 -> 56-59 fps), the translation cache writing without fsync (Safari's GPU process may not; each launch
  re-translated), one-module function constants kept opt-in (`VirtioGPUMetal-fcspec` = 1: WebKit drew wrong with it).
- **Core Image** (Preview, QuickTime): libraries without entry points (ci_stdlib), dynamic libraries and extern
  linking, externFunctionNames; `tools/citest` 7 of 7 against the CPU renderer. Core Image's stitchable kernels
  (`clampToEdges`, `fishEye`...) aren't functions of ours yet: it falls back to compiling source, slower the first time.
- **Maps**: quoted (namespaced) entry names, default libraries, several viewports/scissors.
- **Multisampling** and **stencil** (`tools/mtlsource`: 4x resolve, a stencil mask), binary archives of our own
  (SwiftUI's RenderBox crashed in Apple's), priorities, viewports.
- **The default**: every app (`.app` bundles) and WebKit's GPU process get the device; daemons don't; never
  loginwindow or SecurityAgent. 22 system apps swept: no crashes; gestures unchanged (drag 19.7, resize 22.2, scroll
  18.3, minimize 23.0 ms mean frame gap); 9 Venus contexts on the host, ~520 MB.
- **Packaging**: kept copy in `/Library/GPUBundles/Venera` (WindowServer's sandbox refuses `/Library/Application
  Support`: a first try left no desktop after a simulated update), system-volume copy, the watcher
  (`local.venera.watch`) tested through a simulated update: kept copy at boot, dialog, reinstall, restart, system copy.
- **OpenGL** (`vgpugl=1`, off): the renderer loads and its shaders translate, Chess's window stays white. Next:
  what the renderer reads from reflection (bindings), as NullMoth's NVMTLGLBinding classes answer.
- Safari's test page uses WindowServer ~150% and its GPU process ~120% of a guest core at 59 fps: app surfaces cross
  processes through CPU memory (write-back, then upload). Sharing them on the host GPU (blob resources across Venus
  contexts) is the big remaining performance lever for apps.

### Round 8, part 4: OpenGL, SwiftUI effects, surfaces across processes (2026-11-16)

Measured on VM 108 (snapshots `pre-gl`, `pre-share`, `pre-accel0612`):

- **OpenGL** is on by default (accelerator 0.6.12 publishes `IOGLBundleName`; the `vgpugl` boot-arg is gone). Chess
  draws fully: real pipeline reflection, swizzles, vendor name from the host GPU, the renderer's private calls. It takes
  ~18 s to show its window here: Game Center waits for a network the VM doesn't have.
- **SwiftUI/RenderBox effects** (the Dock's Calendar icon, which had gone blank and then vanished a second after
  launch): linked visible functions (`nvmtl_visible_refs` + `nvmtl_link_visible`, under `specializedName`
  "custom_fn"), render-target barriers (`memoryBarrierWithScope:`: end the Vulkan rendering, flush, resume; RenderBox
  binds its coverage attachment as texture(5) between them), constexpr samplers (the translator's StaticSampler
  bindings get a normalized VkSampler of their own), and function constants folded (constant-space loads and stores
  spelled with opaque pointers, which the translator's static-initializer evaluator reads; `VirtioGPUMetal-typedconst`
  turns that off). `com.apple.dock.extra` is on the driver by default; Core Image 7 of 7 still.
- **Open**: Spotlight's result icons (Calendar, Shortcuts) still come out empty on the driver, so Spotlight stays off
  by default (allow-list "Spotlight" to try it). Their image draws read an atlas that holds the icon and get zeros;
  the Dock helper has one surface of this kind too, unseen. Debug flag files for it: `passlog`, `dumpsurf`, `dumplink`
  (one process name a line).
- **Surfaces shared across processes** (core 0.5.6, Mesa patch 0007, opt-in with `VirtioGPUMetal-share`): an
  IOSurface's image lives on exportable memory, offered at its first GPU write-back and imported by the other process
  (WindowServer), which then skips the pull of frames already in it (the surface is tagged with seed and resource).
  It works and draws right (mtlwindow, Safari's page), but it saves little here: WindowServer's pull copies for a
  640x480 window drawing every frame went from 37 to 6.5 ms per 5 s, under 1% of a core, inside run-to-run noise of
  20 points. Correction to 384eaed's message: its "122% -> 29%" compared against a baseline in which my first version
  (registered at creation, synchronous uploads) was still running in WindowServer; not a real gain. WindowServer's
  CPU goes to Core Animation and Venus encoding, not the copies. Kept off by default because a first version lost
  Safari's page background (fixed: an image offered before its first layout transition ran).
- **Seen once, not reproduced**: right after a reboot that invalidated every translation cache, parts of Safari's page
  stayed black (twice in the first minutes, never with warm caches). Watch for it after an update.
- tools/vm-remote.sh injecting the core now keeps csr-active-config 0xA03: 0x203 turned authenticated root back on and
  the next boot came up without the system-volume copy.

### Round 8, part 5: Spotlight, the translation pool, small buffers, the cold-start band (2026-11-16)

Measured on VM 108 (snapshots `pre-core057` and earlier):

- **Spotlight's icons and the Dock's icon shadow** draw (9829b94). RenderBox's path coverage vertex shader
  binary-searches its segment array by moving a device pointer around a loop; NV's translator, given typed-pointer IR
  (what the guest's LLVM prints), turned that pointer into a null private variable, so every coverage read was 0.
  `vg_opaque_ir.h` rewrites the module's text with opaque pointers first (what LLVM 23 prints for the same bitcode;
  checked against it and `llvm-as` on the RenderBox corpus). `tools/mtlptr` (six pointer patterns; the loop phi is the
  one that failed) and `tools/mtlpath` (RenderBox's own shader on recorded inputs) reproduce it. Spotlight is on the
  driver by default. Also: FPFastMathMode NotNaN|NotInf cleared from translated SPIR-V (`VirtioGPUMetal-fastinf` keeps
  them), `setDepthClipMode:` clamp is a real pipeline variant.
- **One translation pool** (d5f8a43): the watcher gathers every process's translated shaders into
  `/Library/GPUBundles/Venera/cache` (256 MB cap) and copies them back into each process's own cache; the driver falls
  back to the pool on a miss. Safari's GPU process with its own cache deleted draws the test page at 58-59 fps from the
  start (25 fps translating cold).
- **Small buffers** (5743b8c): every MTLBuffer was its own mapped Venus allocation, each holding one of the core's
  2048 host-memory ranges for the whole machine; with WindowServer, Safari and a few apps open they ran out (Grapher's
  3D surface: 233 map failures). Buffers up to 256 KB are cut from 4 MB chunks; core 0.5.7 has 16384 ranges.
- **Venus ring abort** (Mesa patch 0008): eight missed alive checks in a row (~30 s) before `vn_relax` aborts, each
  logged; a host stall of a few seconds no longer takes down every waiting app (Chess aborted once).
- **App and WindowServer CPU** (316111b): profiled on Safari's GPU test page, the driver's own share is ~5% (surface
  copies, Venus encoding); the rest is Core Animation's own work. Two wastes fixed on the way (surface roots found by
  IOSurface ID, kept roots evicted least recently used first); no measurable change.
- **Safari's cold-start black band** (5405fb0; part 4's "seen once"): reproduced with caches cleared (2 of 2 boots).
  A GPU pass drew the page's animated cells into WebKit's page surface while WebKit painted the rest on the CPU; the
  write-back at completion copied the whole image back over the CPU's part and marked the surface in sync, so neither
  side had it. Now each command buffer keeps a written rectangle per surface (cleared attachments: the pass's area;
  loaded ones: their draws' scissors; blits: the destination; compute: all) and copies only that; a surface someone
  else wrote since our pull stays out of sync. 3 of 3 cold boots clean.
- **VM 108's snapshots**: 21 deleted with the owner's OK (thin pool 62.5% -> 53.7%); kept `clean-dev`,
  `venera-010-r6` and `pre-pkgtest`.
- **GPU video decode** is not started: it needs a video path in Venus (none in Mesa's guest driver; the host's
  virglrenderer 1.1.0 decodes only for virgl contexts, over VA-API, and reports "Video disabled due to missing
  get_drm_fd"), host package changes, and a decoder plugin for macOS's private AppleGVA/VideoToolbox interface.
  What software decode costs today (Safari, one tab, synthetic 30 fps clips, 4 vCPUs): 1080p H.264 plays with 0 of
  601 frames dropped, WebKit.GPU ~33% of a core and WindowServer ~16% over idle; 1080p HEVC 0 dropped,
  VTDecoderXPCService 18% + WebKit.GPU 11% + WindowServer ~16%; 4K H.264 drops 552 of 601 frames with little CPU
  in use. Checked: not the driver -- with Venera off for Safari's GPU process it drops the same (~4 frames shown a second against ~6 with it on), and while it plays WindowServer's render thread, its main thread and Safari's four JVTlib decoder threads all sit waiting. The media pipeline skips frames before decoding them (about 30 decoded in 5 s, ~11% of a core), so it is macOS's own choice for 4K software H.264 on this machine; host decode is the only lever there. Host decode
  would save roughly half a core at 1080p. (The transfer disk's `com.apple.fskit.msdos` takes a core whenever the
  tools touch it: leave it out of CPU numbers.)

### GPU video decode: what it would take (2026-11-16, read-only survey)

- **Host today**: the Iris Xe's Vulkan driver (ANV, Mesa 25.0.7) decodes H.264/H.265/AV1 only with
  `ANV_DEBUG=video-decode`; no VA-API driver is installed (`libva2` only, no `intel-media-va-driver`); virglrenderer
  1.1.0's video is for virgl contexts only and QEMU doesn't hand it a DRM fd; Mesa's Venus has no video commands at
  all. Only VM 108 uses virgl on this host. QEMU 11.1 has generic devices served by a separate process
  (`vhost-user-test-device-pci`, `vhost-user-vsock-pci`), so a decoder could be a program of ours with no package
  replaced.
- **macOS's own paravirtual decoder**: `AppleVideoToolboxParavirtualization.kext` (virtio PCI 106b:1a03, over
  AppleVirtIO) is on Intel Tahoe as a plist only -- its code is in neither kernel collection (Apple silicon only) --
  but the user-space half, `VideoToolboxParavirtualizationSupport.framework` (project AppleParavirtGPU), IS in the
  x86 dyld cache: it opens `AppleVideoToolboxParavirtualizationDriver` and has a host-to-guest queue. A kext of ours
  providing that service (protocol learned from Apple silicon's driver and the framework) plus a host program speaking
  the device side would let VideoToolbox, Safari and QuickTime decode on the host. Unverified: whether Intel
  VideoToolbox picks that path for H.264/HEVC.
- **Intel's route**: GPU kexts advertise `IOGVACodec` (Gen95, Gen11), `IOVARendererID`, `IOGVAHEVCDecode`; AppleGVA
  then loads Apple's Intel decoder bundles, which drive Intel hardware directly: no way in without reverse engineering
  AppleGVA's private plugin interface.

### GPU video decode: the guest side works (2026-11-16)

Checked without changing the host or installing anything in VM 108 (tools/vtprobe.m, tools/pvshim.c, tools/pvhost.m):

- Intel Tahoe's VideoToolbox has Apple's whole paravirtualized-video stack (decoder and encoder). It reaches its driver
  only through VideoToolboxParavirtualizationSupport.framework, which opens `AppleVideoToolboxParavirtualizationDriver`
  (user client: scalar 0 = buffer size in, 3 values out; struct 1/2 = register/deregister a 16-byte guest UUID; a send
  of iovecs; scalar 4 after each host message; host-to-guest messages in an IODataQueue with a notification port,
  handed to three blocks: alloc(capacity, &msg, &buf), deliver(msg, len), release(msg)).
- pvshim interposes those four functions in one process. VideoToolbox then says it runs in a guest, registers a UUID
  and asks the host for its decoders (`vtpv` `decs`, 68 bytes). Apple's own host side -- in this Mac's VideoToolbox
  (VTParavirtualizationHostSessionCreate / DeliverMessageFromGuest; messages are CMBlockBuffers of boxes and binary
  plists) -- answers it (1399 bytes); given that answer, the guest lists paravirtualized hardware decoders for H.264,
  HEVC, AV1, VP9, ProRes and JPEG, and every session, the default one included, asks for the paravirtualized H.264
  decoder first (`+dec`, codec avc1, decoder id avd.avc, guest build) and falls back to software only when nobody
  answers. The Mac's host session accepts that request too (a real decoder session; `-dec` closes it).
- So a kext of ours providing that service, plus something answering on the host, gives every app (Safari, if its GPU
  process's sandbox lets it open the user client -- unverified) hardware decoding through Apple's own code. There is
  no route to the host GPU's decoder without a host change: the host's virglrenderer has no Vulkan video, its Intel
  Vulkan driver decodes only with ANV_DEBUG=video-decode, and QEMU leaves virgl's VA-API path off.

### GPU video decode: the design (2026-11-17, owner's OK for the host part)

The owner approved: `intel-media-va-driver` installed on the host (done: 25.2.3 + libigdgmm12, nothing else changed),
our program under /root, VM 108's config. Proxmox's own packages stay as shipped.

- **Guest kext** (new, injected like the others): provides the IOService class `AppleVideoToolboxParavirtualizationDriver`
  that Intel macOS ships no code for, with the user client VideoToolboxParavirtualizationSupport expects -- scalar 0
  (send-buffer size in; 3 values out), struct 1/2 (guest UUID), scalar 3 (send: length + up to 5 IOSurface IDs, one
  value out), scalar 4 (host message consumed), host messages through an IODataQueue + notification port. IOSurface
  IDs become surfaces with `IOSurfaceRoot::lookupSurface(id, task)` (exported by com.apple.iokit.IOSurface); decoded
  frames are copied into them.
- **Transport**: `ivshmem-doorbell` (in the host's QEMU 11.1): a shared memory region plus interrupts both ways,
  served by our host program over a UNIX socket. VM 108's memory setup stays as it is; its config gains one chardev
  and one device.
- **Host program** (/root/vgpu): the ivshmem server, the host side of Apple's protocol (the Mac's VideoToolbox host
  session is the reference: tools/pvhost.m), and decoding with FFmpeg over VA-API on the Iris Xe, frames written to
  the shared region. Runtime needs only what the host has (libva2, libva-drm2, libdrm2, glibc 2.41). Built on the Mac
  in a Debian amd64 container with its own minimal FFmpeg (H.264, HEVC, AV1, VP9 decoders + VA-API), shipped beside it.
