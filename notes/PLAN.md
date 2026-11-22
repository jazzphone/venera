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
  20 points. Correction to 2ec1f8b's message: its "122% -> 29%" compared against a baseline in which my first version
  (registered at creation, synchronous uploads) was still running in WindowServer; not a real gain. WindowServer's
  CPU goes to Core Animation and Venus encoding, not the copies. Kept off by default because a first version lost
  Safari's page background (fixed: an image offered before its first layout transition ran).
- **Seen once, not reproduced**: right after a reboot that invalidated every translation cache, parts of Safari's page
  stayed black (twice in the first minutes, never with warm caches). Watch for it after an update.
- tools/vm-remote.sh injecting the core now keeps csr-active-config 0xA03: 0x203 turned authenticated root back on and
  the next boot came up without the system-volume copy.

### Round 8, part 5: Spotlight, the translation pool, small buffers, the cold-start band (2026-11-16)

Measured on VM 108 (snapshots `pre-core057` and earlier):

- **Spotlight's icons and the Dock's icon shadow** draw (8de1ed2). RenderBox's path coverage vertex shader
  binary-searches its segment array by moving a device pointer around a loop; NV's translator, given typed-pointer IR
  (what the guest's LLVM prints), turned that pointer into a null private variable, so every coverage read was 0.
  `vg_opaque_ir.h` rewrites the module's text with opaque pointers first (what LLVM 23 prints for the same bitcode;
  checked against it and `llvm-as` on the RenderBox corpus). `tools/mtlptr` (six pointer patterns; the loop phi is the
  one that failed) and `tools/mtlpath` (RenderBox's own shader on recorded inputs) reproduce it. Spotlight is on the
  driver by default. Also: FPFastMathMode NotNaN|NotInf cleared from translated SPIR-V (`VirtioGPUMetal-fastinf` keeps
  them), `setDepthClipMode:` clamp is a real pipeline variant.
- **One translation pool** (504f1b0): the watcher gathers every process's translated shaders into
  `/Library/GPUBundles/Venera/cache` (256 MB cap) and copies them back into each process's own cache; the driver falls
  back to the pool on a miss. Safari's GPU process with its own cache deleted draws the test page at 58-59 fps from the
  start (25 fps translating cold).
- **Small buffers** (d563df8): every MTLBuffer was its own mapped Venus allocation, each holding one of the core's
  2048 host-memory ranges for the whole machine; with WindowServer, Safari and a few apps open they ran out (Grapher's
  3D surface: 233 map failures). Buffers up to 256 KB are cut from 4 MB chunks; core 0.5.7 has 16384 ranges.
- **Venus ring abort** (Mesa patch 0008): eight missed alive checks in a row (~30 s) before `vn_relax` aborts, each
  logged; a host stall of a few seconds no longer takes down every waiting app (Chess aborted once).
- **App and WindowServer CPU** (16e1599): profiled on Safari's GPU test page, the driver's own share is ~5% (surface
  copies, Venus encoding); the rest is Core Animation's own work. Two wastes fixed on the way (surface roots found by
  IOSurface ID, kept roots evicted least recently used first); no measurable change.
- **Safari's cold-start black band** (70bcd75; part 4's "seen once"): reproduced with caches cleared (2 of 2 boots).
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

## Round 9 (2026-11-17): hardware video decoding through the host

The owner approved the host part: `intel-media-va-driver` installed (with libigdgmm12; nothing else changed), our
program in /root/vgpu/video, VM 108's `args` (+ ivshmem-doorbell), a `venera-videod` service. Proxmox's own packages
are untouched. hostvideo/README.md says how it fits together and deploys.

- **The guest**: kext/VeneraVideo provides Apple's missing `AppleVideoToolboxParavirtualizationDriver` (Intel macOS has
  the rest of paravirtualized VideoToolbox) on the ivshmem device. It loads from OpenCore, not the AuxKC: AppleVirtIO's
  PCI transport matches every 1af4 device, ivshmem's too, and hangs on it, so a driver loaded later never gets it.
  IOSurface IDs become surfaces with `IOSurfaceRoot::lookupSurface` (returns retained).
- **The host**: venera-videod answers the protocol (decs, +dec, dsta -> Dpba, dsup, dcop, dset, dfrm -> Dbuf/Demt, dfin,
  dinv, -dec; learned with tools/pvshim.c in the guest and Apple's host session on a Mac, tools/pvhost.m), decodes with
  FFmpeg 7.1.1 over VA-API, and has the GPU copy each frame into a shared slot (VA-API video processing into
  user-pointer surfaces: data_size must be whole pages): 4.9 ms a 4K frame against 21.5 ms reading it with the CPU.
- **Fixed on the way**: packets were dropped on EAGAIN when GPU surfaces ran out (frames now leave them at once);
  `dfin` lost references (AVPlayer prerolls "frame 1, finish, the rest": the packets since the last key frame are
  replayed after the drain); `Demt` lost its buffer UUID once frames left the GPU early (VideoToolbox emitted empty
  frames); 10-bit streams (HEVC Main10, AV1, VP9) get 'x420' buffers.
- **Measured in VM 108** (tools/vtprobe.m): 1080p H.264 ~230 fps, 4K H.264 141 fps, 1080p HEVC 456 fps, 10-bit HEVC
  203 fps, pixels matching the reference decodes. Safari: 1080p and 4K H.264 play with no drops after the start (4K
  dropped 92% in software); at 1080p the VM's CPU went from ~33% (Safari's GPU process) + ~25% (WindowServer) to
  ~0% + 8% (+4% kernel copies); 4K: WindowServer 21%, kernel 9%, Safari's GPU process 7%; the host program ~1.5%.
- **Safari's codec checks** (later the same morning): with paravirtualized decoders listed, Safari validates HEVC
  against VideoToolbox's HEVC capabilities, which a guest asks the host for (`dcap`, codec in `cod`; the reply's `dca`
  is a dictionary: VTSupportedProfiles, VTPerProfileSupport per profile, VTIsHDRAllowedOnDevice). Answered now for
  HEVC (Main, Main 10, Main Still Picture, level 6.2) and H.264 (Constrained Baseline, Main, High, level 5.2), as the
  host decodes them; VP9 empty, as Apple's host answers. HEVC plays in Safari (8- and 10-bit). AV1 is no longer
  listed: Debian's intel-media-va-driver 25.2 has no AV1 decoding on this Iris Xe (hostvideo/src/vaprofiles.c lists
  what it has), and listing it made Safari report AV1 as hardware-decoded. Publishing IOGVAHEVCDecode* on the
  accelerator did nothing for this (reverted).
- **Measured in Safari at the end**: 1080p H.264, Core Media's own counts: 180 frames enqueued and 180 displayed per
  6 s, none dropped or late.
- **Limits**: restarting venera-videod needs VM 108 restarted (QEMU's ivshmem has no reconnect). With Venera's Metal
  off for Safari's GPU process the picture froze (not the default). A kernel panic seen at one shutdown (06:40, a
  shutdown-stall `heap` sample faulting in `mach_vm_page_range_query`) happened before the video device existed.
  H.264 High 10 is assumed 8-bit. Snapshot `pre-video` is the state before all this.

## Round 10 (2026-11-17): the Dock's menus, slow icons, and an installer for both halves

- **Dock right-click menus were striped** (6424c3c): DockHelper's RenderBox fills paths by adding +1 or -1 by
  `[[front_facing]]` into an RG16Float target; the host's Mesa 25.0.7 Intel compiler gets a select on that boolean
  between 16-bit values wrong (alternate columns 0x0000 / 0xBF80, the halves of a float -1.0). The translator's SPIR-V
  is right. `vg_frontface_ir.h` makes each such select a 32-bit integer select of the bits (VirtioGPUMetal-nofrontface
  turns it off); tools/mtlmrt.m fd/fg pass, the menu draws clean. Kept with it: attachments bound as fragment textures
  go to the feedback loop layout (Dock, DockHelper and Spotlight do it; undefined in GENERAL).
- **Slow icons are not storage**: VM 108's disk is local-lvm. iconservicesagent draws icons on the CPU the first time
  (a background daemon: not allow-listed for the device), ~7 s of CPU for one Finder folder, then 0.05 s from its
  cache. Giving it the device was slower (10+ s and climbing), so it stays on the CPU. Many reboots and system-volume
  snapshots this week kept the cache cold; it warms as folders are opened.
- **Install Venera VERSION.pkg** (packaging/make-pkg.sh; make-dist.sh builds it): productbuild with Customize choices
  (Graphics, required; Hardware video decoding, on; Venera app, on; Safari WebGL, off -- turns off authenticated root;
  kept automatically when already off). Hidden prep/core packages around empty choice packages that leave markers;
  core's postinstall runs the release's install.sh with them as flags, logs to Support/Venera/install.log, asks for the
  restart. Bundles non-relocatable. Unsigned: SIGN_ID signs it. Files copied in over the transfer disk carry no
  quarantine, so Gatekeeper doesn't ask.
- **install.sh / uninstall.sh**: `--video` (VeneraVideo.kext through OpenCore), `--no-app`; uninstall removes both
  OpenCore entries, the app and its login item, the package receipts.
- **Venera.app** (helper/Venera, tools/build-helper.sh; LaunchAgent local.venera.helper, `--background` at login):
  the watcher's questions as notifications with buttons, or in its window while notifications are off (protocol:
  Support/Venera/ask/{id,text,buttons,answer}); once-a-boot notices for the software desktop and a missing host video
  service; a status window; menu bar item off by default. Reads only.
- **install-host.sh** (Venera-host-VERSION.tar.gz, packaging/make-host.sh): intel-media-va-driver and libva-drm2 when
  missing (removed on uninstall only if it installed them), /opt/venera/video, `venera-videod@VMID` per VM (one VM per
  socket: the daemon serves one client), each VM's args line gains its device (config backed up), every VM checked
  before anything changes; `--status`, `--remove-vm`, `--uninstall`, `--dry-run`. tools/test-install-host.sh runs it in
  a Debian container against stand-in qm/systemctl/apt: 18 checks pass. **Not run on node 2**: VM 108 still uses the
  dev layout (/root/vgpu/video, venera-videod.service, /run/venera-video.sock); moving it is a host change for the owner
  to OK.
- **Tested on VM 108** (snapshot pre-pkg, rolled back after): the package with defaults installed everything (Metal
  desktop, VeneraVideo attached, app at login, watcher moved the link to the system copy); the app's window answered a
  watcher question (answer file `test-1 / Not now`); the menu bar item; uninstall.sh removed everything and the next
  boot was the software framebuffer. **Open**: in the two boots after that uninstall (230 s each, against 30-40 s),
  macOS didn't publish the OpenCore disk's partition (AHCI QEMU HARDDISK, GPT with its backup header not at the end of
  the 152 MB volume), so a reinstall from inside the guest found no OpenCore and the package failed. After the
  rollback it shows again (disk3s1). Cause not found.

## Round 11 (2026-11-17): checking it all -- the host service locked down, restarts survived, and the bugs that turned up

- **venera-videod sandboxed** (packaging/host/venera-videod@.service + .socket): DynamicUser, only `char-drm` devices,
  PrivateNetwork, ProtectSystem=strict, no capabilities, @system-service syscall filter, MemoryMax=2G. Socket
  activation: systemd holds `/run/venera-video-VMID.sock` from boot. The daemon keeps its memfd, both eventfds, QEMU's
  connection and a session store in systemd's fd store (FileDescriptorStorePreserve), so a restart or a crash carries
  on with the same connection: sessions are reopened from their saved sample descriptions, frames the old process held
  are reported dropped, numbers skipped while it died likewise, and decoding resumes at the next key frame. Request
  numbers continue (reusing them wedged the guest: a Dbuf never answered). A Dbuf unanswered for 2 s drops its frame.
  RestartSec=100ms: a gap of a second or more puts VideoToolbox's reply clerk into 1 s timeouts (below). No GPU: it
  still serves, refusing +dec, and the guest decodes in software. install-host.sh installs both units, migrates the
  hand-made dev layout (done on node 2 for VM 108: /opt/venera, venera-videod@108), restarts keeping connections;
  tools/test-install-host.sh 21 checks.
- **Guest input copied before parsing** (drain_g2h), host-owned ring counters private, outbox capped. Fuzzing
  (hostvideo/fuzz, FINDINGS.md): 7 bugs, two High (bp_read_string length wrap -> stack overflow; avcodec_flush_buffers
  on a freed decoder), all fixed; re-run clean.
- **VeneraVideo: the process is told of every message** (VeneraVideoDataQueue: sendDataAvailableNotification on each
  enqueue, again on method 4 "drained" when data is left). IODataQueue only notifies empty -> non-empty; the support
  framework drains once per notification, so a message landing mid-drain waited for VTParavirtualizationReplyClerk's
  1 s timeout -- after a burst, every frame did (a frame a second). Seen only after host outages, but latent always.
- **Safari's software-decoded video drew wrong colors and stale blocks** (found by running the service with no GPU):
  framebuffer fetch in place in com.apple.WebKit.GPU (Core Animation's fixed_frag_lph_cph). In place is only right when
  each pixel is drawn once per draw; Vulkan on the Iris Xe has no raster-order guarantee. Fetch mode is now 4 in
  WindowServer only, copies elsewhere (same frame rate); the fetchmode file takes "NAME DIGIT" lines. The feedback-loop
  extension is enabled in every mode (RenderBox's attachment-as-texture needs it); images of unknown usage get the
  feedback usage bit; in-place reads of an image without it fall back to copies.
- **Front-facing rewrite widened**: the inverse (`xor i1 %ff, true`), every vector width, i16. 16-bit phis under a
  branch on a bool parameter (in modules with air.front_facing) are logged: only RenderBox/CA helpers with ordinary
  bool flags showed up, and the A/B sweep found nothing.
- **A/B screenshot sweep** (16 apps, driver vs `-APP` in the allow-list, pngdiff): Contacts, Notes, Photos, Reminders,
  Books identical; the rest differ only in the clock, the Dock, a window behind, Font Book's random preview style, and
  Chess's edge rounding (max 50).
- **WindowServer's 54x54 mipmapped buffer texture** (6 levels) was refused, so it never drew; now accepted (level 0
  from the buffer).
- **The OpenCore disk after an uninstall**: reproduced -- with the host's ivshmem device present and VeneraVideo
  disabled, IOGUIDPartitionScheme on the OpenCore disk stays !registered (no disk3s1); with VeneraVideo, it publishes.
  Apple's VirtIO driver takes 1af4:1110 when nothing else does. install.sh adds VeneraVideo whenever the device is
  there; uninstall.sh keeps it until the device is gone. (The backup-GPT oddity is not the cause.)
- **Package checks** on VM 108 (snapshot pre-pkg-r11): upgrade over the dev install worked; a simulated macOS update
  (sysvol.sh remove, reboot) -> question in the app's window (notifications off) -> Reinstall -> Restart -> back on the
  system volume. Fixed on the way: the watcher asked before the reboot of a fresh install (install.sh now sets
  pending), gave up when nobody was logged in at boot (now waits up to 10 min), left a stale question behind (cleared
  at start). Root scripts hardened (notes/root-scripts-review.md): pool copies as the cache folder's owner, no fixed
  /tmp names. Not run: an install with nobody logged in (the agent dropped out on logout).
- **Frame pacing**: drag 17.9 ms, scroll 18.1, resize 23.3, minimize 25.8 -- as round 7 -- with only the usual apps;
  with the sweep's 16 apps open, 26-57 ms. Remote slowness is mostly the console: QEMU's VNC 30 ms floor, and noVNC's
  tiles over the link; SPICE (already on for virtio-gl) streams changing areas.
- Codecs: H.264, HEVC 8/10-bit and VP9 decode on the host (HEVC 10 colors right).

## Round 12 (2026-11-18): the first install on a second VM, and 0.1.1

Installing 0.1.0 on a second VM (VM 107: the same macOS build, its own OpenCore, SIP 0x001, on a two-node
Proxmox cluster with HA) found what VM 108 never could:

- **The first install failed when SIP wasn't relaxed yet.** `--set-security` writes SIP's new value into OpenCore, which
  starts at the restart, but the install went straight on to rebuild the Auxiliary KC, which needs it now (`kmutil`:
  "Operation not permitted"). It stopped with the two kexts already in /Library/Extensions; at the restart macOS added
  them to the KC by itself, so the accelerator offered Metal with no Metal bundle installed. **Fixed** by two passes:
  the first changes only OpenCore's security settings (and VeneraVideo.kext) and leaves a one-time job
  (`local.venera.finish`, `install.sh --finish` with the same options), which finishes at the next boot and restarts
  once more (by itself at the login window, else after a dialog). The job waits up to two minutes for the OpenCore
  partition (at its first try it ran before the disk was published: "no EFI partition") and stays until the install
  succeeds, three boots at most. A failed KC rebuild on a first install now takes its kexts out again. Tested on VM
  108 from SIP 0x001 through the package: both passes, the dialog, the Metal desktop after.
- **A missing Metal driver left a black screen.** WindowServer asserted in `CoreDisplay_CreateDisplayForCGXDisplayDevice`
  250 ms after each start, and the guard never fired: it counted WindowServers that opened the Venus client, which
  only the Metal driver does. **Fixed** in the accelerator (0.6.13): a third WindowServer that opens the display pipe
  since the arm withdraws too. Tested on VM 108 with the driver moved aside: WindowServers 1 and 2 died, the third
  withdrew, the fourth ran the software desktop (about 25 s after the login window would have shown).
- **The watcher warned "no longer on the system volume" on every install without Safari WebGL** (the package's
  default): it couldn't tell a choice from a macOS update. The installer now records `--no-system-volume`
  (`NO_SYSVOL`), and the watcher keeps quiet then.
- **YouTube didn't play: VM 107 had no sound device.** Safari's streaming playback (MSE) won't start without a default
  output (`-66680 ... Default-Output`, then AVFoundation -11800) and YouTube retried format after format; the video
  decoder was fine throughout (VP9 on the host GPU). macOS has no driver for QEMU's HDA; USB audio works:
  `-audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd`. In the install guide's limits.
- **A cluster.** HA started VM 107 on the other node, which lacked Venus's packages (`mesa-vulkan-drivers`,
  `virgl-server`, missing from the guide too) and the video socket. `install-host.sh` read VMs with `qm`, which only
  sees the local node's: on a node that doesn't hold the VM it now sets up only the socket and service (3233d6c). VM
  107 starts on either node with graphics, video and sound. Venus and ivshmem block live migration: HA moves it by
  restarting it.
- The guide also lacked `host-phys-bits-limit=40` (both VMs needed it).

## Round 13 (2026-11-18): a new VM, ready for Venera before macOS is in

- VM 107 upgraded to 0.1.1 (one pass: SIP was already relaxed). The guest agent's ISA serial port timed out on even 20
  KB of stdin, and VM 107's VLAN can't reach the Mac, so the release went in on a USB drive hot-added through QEMU's
  monitor (an ISO, `usb-storage` on `ehci.0`: macOS ignored it on the xhci's hub), ejected and detached after.
- `vm/proxmox-macos-vm.sh` (the author's earlier macOS VM script, MIT) is now Venera's VM maker, shipped in the host package with the
  guest package. It checks the host (Intel CPU, the GPU through sysfs: Intel for everything, AMD without video; QEMU
  9.2+, virglrenderer 1.0+), installs the Venus packages on each node the VM may run on (only when its storage is
  shared), and makes a macOS Tahoe VM (macrecovery's Mac-CFF7D910A743CAAF, `-os latest`). OpenCore gets SIP 0x203 (0xA03
  for WebGL) and AMFI off before macOS is installed, so the guest package installs in one pass. A Venera disk (an ISO
  imported as ide1) carries the package. Finish adds the video device on every node (others first), drops the
  installer disks and restarts the VM. The device waits for Finish because it hangs a macOS without VeneraVideo.kext.
  Without an identity the sample serial runs as an iMac20,1, which Tahoe supports; VM 107's iMac19,2 isn't on Tahoe's
  list, so it may have relied on the installer letting VMs through.
- Tested: `vm/test.sh` (args, corosync, OpenCore edits on KVM-Opencore v21's config.plist), the questions and plans on
  node 2 (create with node 1, create with WebGL, Finish on VM 108, Ready refused while running), the Venera disk's
  contents. Not tested: a whole run, from the Tahoe download through macOS's install to Finish.

## Round 14 (2026-11-18): first boot, background services, missing calls, and hardware encoding

The owner's list after 0.1.1: clean up (done: old branches, VM 108 snapshots pruned to clean-dev / video-decode /
r12-installed / pre-r14, VM 107's detached Sequoia disk, the NAS's Sequoia image, stale host files), the slow first boot,
hardware video encoding, a way to fix what apps ask for that the driver lacks, and background services on the driver.

- **The log.** WindowServer wrote 12 "perf 5 s" lines every 5 s to /var/tmp/VirtioGPUMetal.log (6.9 MB in VM 107's
  first 7 hours, never rotated). The counters are now off unless `/Library/GPUBundles/VirtioGPUMetal-perf` exists
  (WindowServer checks it every tick) or VGMTL_PERF is set; the file rolls over at 4 MB (.log.1).
- **OpenCore can't inject the framebuffer or the accelerator** (the owner asked): Kernel > Add links into the Boot
  KC, and IOGraphicsFamily, IOAcceleratorFamily2 and AppleGraphicsDeviceControl are System KC (checked on VM 108 with
  kmutil inspect; IOSurface and IOPCIFamily are Boot KC, which is why the core and VeneraVideo can be). And the Metal
  driver is a user-space bundle on macOS's disk. So a new VM gets SIP/AMFI in OpenCore and the package on a disk.
- **First boot.** With every cache empty (a fresh install), VM 108's first minutes translated 167 shaders, 125 s of
  CPU (WindowServer 104 s: Core Animation's ogl_metal_uber fragment shader, 700 KB of LLVM text, ~46 sets of
  function constants a boot, ~2 s each in the VM, 0.44 s natively on an M-series Mac).
  - The one-module path (translate once, fix values per set) is wrong as it stands, measured with a check mode
    (`VirtioGPUMetal-fccheck`: every per-set translation also built the one-module way and the interfaces compared):
    besides harmless dead declarations, sets read bindings the one-module SPIR-V lacks (UberComposite: texture 162
    and buffer 1 per set, binding 36 one-module), and the uber shader is 706 KB one-module against ~25 KB a set. That
    is the "WebKit drew wrong" of round 8.
  - Where a translation's time goes (tools: the fcdump flag writes each function's text and sets; a Rust bench over
    the translator crate): AIR specialization 24 ms, translation 390 ms. The specialized text is still 693 of 699 KB:
    the translator works through the whole uber shader and drops most of it after. Folding the constants' branches
    in the IR before translation is the real speed-up (not done).
  - Done instead: **the package ships a seed of the pool** (tools/seed-pool.sh -> packaging/seed/
    pool-BUILD-TRANSLATOR.tar.gz, 796 translations, 2.8 MB, made on VM 108 from a cleared cache through restarts,
    19 system apps, window gestures and the desktop's own windows; never VM 107's, whose pool holds the owner's own and
    third-party apps' shaders). make-dist ships it only with the translator it was made with; install.sh unpacks it
    into the pool only on that macOS build. Measured on VM 108, every cache cleared and the seed put in as install.sh
    does: WindowServer's first boot 104 s of translation -> 1.3 s at the lock screen, 55 s (21 shaders) with the
    desktop and restored windows up against the 720-translation seed; the 796 one adds those.
- **Background services.** In a day of VM 107 only six processes asked for Metal and were turned away:
  iconservicesagent, CursorUIViewService, avconferenced, mediaanalysisd, loginwindow (kept off), SafeEjectGPUService.
  The first four are on by default now (kServices; `services-off` in the allow-list turns them off). Icons draw
  right on the driver (Finder's Applications folder, the sidebar, the Dock: screenshot checked); iconservicesagent's
  first run translated ~700 small shaders (52 s), which the seed now carries.
- **Missing calls.** Lenient mode answers an unimplemented call with nil/0 and logs it once a process; VM 107 logged
  none in 6 h of use. status.sh now lists the last day's by app ("Metal calls the driver lacks").
- **Hardware encoding: done.** Tahoe's VideoToolbox has a paravirtualized encoder beside the decoder; venera-videod
  now answers it with VA-API (FFmpeg's h264_vaapi / hevc_vaapi, no B-frames, one frame in flight). The protocol, as
  this host speaks it, is at the top of hostvideo/src/vv_encode.h; how it was learned: Apple's own host session run on
  the Mac (an XPC LaunchAgent wrapping it, its messages replayed), and VideoToolbox's code read where it builds and
  checks each message.
  - The frame: `efrm` carries the frame's IOSurface; the host orders a **pull** (VV_H_PULL: the kext copies the
    surface into a slot, VV_G_PULLDONE), uploads it and encodes. The sample goes back as `Eemt`: CoreMedia's
    serialized sample buffer (sbuf: opts, stia, sdat with 4-byte lengths, nsmp, ssiz, sary attachments; fdsc, the
    format description with avcC / hvcC, on the first sample), checked against VideoToolbox's own serializer and
    reader run on the Mac. `Efds` before the first sample gives the guest the format description.
  - **Intel VideoToolbox's reply wait is broken** (26.7.3): it turns the timeout into nanoseconds in a 32-bit int
    (`cvttsd2si`), so efrm's and ecfr's 10 s become a deadline in the past, and the wait succeeds only if the answer
    is already in. Every frame failed at once (-19092). VeneraVideo 0.2 holds such a send in the kernel until the
    answer is queued and the process has drained it (2 s at most). A synchronous decode's `dfrm` waits the same way:
    synchronous decoding through the host failed every frame since 0.1.0 (Safari decodes asynchronously, so nothing
    showed) and works now.
  - The guest's receive buffer is 16384 bytes: a bigger message never leaves the queue. Eemt is split as Apple's host
    splits it (0x10, "more", on all but the last).
  - **The last frame.** AVFoundation's exports came out one frame short (299 of 300). The guest sends one message at
    a time (VideoToolboxParavirtualizationSupport holds a lock across the kext call), and the encoder runs in
    VideoToolbox's encoder service (VTEncoderXPCService), whose paravirtualization queue hands each Eemt's frame to the
    app and then answers it. While a send is held, that answer waits for the lock, and the queue with it. So the
    host now sends each frame's Eemt before it answers that frame's efrm, and sends Eemt as a plain message (Apple's
    host makes it a request; the kext holds requests back until a held send's answer is in, so a request would
    arrive after the answer). Every frame is out when CompleteFrames returns (vtenc counts them; 8 of 8 exports have
    every frame). The cost: the guest waits for each frame's encode, so 1080p went from ~160 fps to ~100 fps and 4K
    from ~47 to ~30. A 100 ms wait before answering ecfr fixed 5 of 6 and was dropped.
  - **Decoding was softening every frame** (since 0.1.0): the slot copy used VA-API video processing, which runs the
    scaler even at 1:1 (a row's 255 beside 0 came out 56; small changes everywhere). Found by decoding the
    encoder's output back (vtenc VTENC_VERIFY: 2 frames of 300 wrong at a sharp edge) and comparing with vatest's
    VATEST_LUMA. vaCopy copies exactly and is a little faster (1.05 ms a 1080p frame against 1.28); video processing
    stays as the fallback.
  - **Old guests.** VeneraVideo 0.2 says VV_GF_ENCODE in its hello and writes it into the control block; a host
    offers encoders only to a guest that says so (0.1.1's driver says 0: it would fail every frame).
  - Measured on VM 108 (Iris Xe): H.264 720p ~175 fps, 1080p ~100, HEVC 1080p ~105, 4K ~30 either; Apple's software
    encoder in the VM: H.264 720p 91 fps, HEVC 720p 6.9. Decoded back (sync and async, through the host and in
    software), every frame matches to the encoder's loss. avconvert 1080p exports (H.264, HEVC) and a 10-bit HEVC
    source decoded by the host and re-encoded: PSNR 44-50 dB against the source.
  - Left: the efrm wait could overlap again (answer early unless the frame might be the last: no signal for that
    yet); 10-bit encoding (Main10); encoder messages in the fuzz seeds (the session harness only has decode's);
    `kVTCompressionPropertyKey_Quality` is taken as constant quality without a level.

## Venera 0.1.5 (2026-11-18)

Rounds 16 and 17 packaged: two twins a display surface (core 0.5.8, accelerator 0.6.14, Metal driver 0.4.3: no frame
copied into the one on screen), CompleteFrames answered 20 ms after the last frame, the translation seed on any macOS
build, and the VM script's recovery download and install instructions fixed. Tested by upgrading VM 108 from the
0.1.5-dev test build with the release's VM script: 0 of 3,584 drag frames into the twin on screen, vtenc 1080p 20 of
20 complete at CompleteFrames.

## Venera 0.1.4 (2026-11-18)

Round 15 packaged: 4K 10-bit decoding through the host (VeneraVideo 0.2.1, frames spanning two slots) and the host
encoder's leak fixed (Eemt names the frame's uui; long exports no longer run macOS out of memory, and encoding is
~1.7-2x faster). The leak fix is host-only; 4K 10-bit needs both halves. Tested by upgrading VM 108 from 0.1.3 with
the release's script: 15 s of Tahoe Day decoded on the host (3,601 frames, IOSurfaces flat at ~150), vtenc 1080p 300
of 300 out in every run; in 1 of 12 the last frame came just after CompleteFrames returned (seen with 0.1.3 too).

## Venera 0.1.3 (2026-11-18)

The VM script's **Upgrade Venera** (choice 4) and the host decoder's H.264 fix (the second frame no longer dropped),
both from after 0.1.2. No guest code changed: the package is 0.1.2's with the new version (Metal driver 0.4.2,
VeneraVideo 0.2.0). 4K 10-bit decoding is still the next step. Tested by upgrading VM 108 with the script from the
release's host archive, which found that macOS turns a USB disk away (loginwindow dissents and ejects it) while its
screen is locked or nobody is logged in: VM 107 was unlocked when it was upgraded. The upgrade now waits for an unlocked
session before plugging the disk in (it asks), and vm/test.sh checks how it reads the console's state.

## Venera 0.1.2 (2026-11-18)

Round 14 packaged: hardware encoding (VeneraVideo 0.2.0, venera-videod with FFmpeg's VA-API encoders), the
translation pool's seed, background services and the quieter log (Metal driver 0.4.2), and the synchronous-decode and
softened-frame fixes. The package's "Hardware video decoding" choice is now "Hardware video". Tested from the release
archives: install-host.sh on node 2 (reports "encodes H.264 HEVC"), the package over VM 108's dev install (snapshot
pre-012; the seed added 0, VM 108 already held them), then H.264 and HEVC 1080p at 100-110 fps with all 300 frames
decoding back (sync and async), and two avconvert re-encodes of 300 frames each. VM 107 and node 1 stay on 0.1.1.

After the release, the same day:
- **VM 107 on 0.1.2**, through the VM script's new **Upgrade Venera** (choice 4): this release's host half on every node
  the VM may run on (others first), then the guest package from a USB disk hot-plugged on the EHCI bus, installed
  through the guest agent with the choices macOS has (Installer's -applyChoiceChangesXML: video, app, webgl read from
  VIDEO, /Applications/Venera.app, authenticated root and NO_SYSVOL), the disk unplugged, macOS restarted. Its plan
  names who is logged in. VM 107 came back on Metal with VeneraVideo 0.2.0, and an export encoded on the host.
- **Found: the host decoder dropped the second frame of H.264 with B-frames and no bitstream_restriction** (the
  Notification Center's mac_widgets movie: 554 of 555 frames in VM 108's exports to ProRes and to HEVC, 555 on a
  Mac). FFmpeg guesses the reorder depth for such a stream, starts at none and grows it at the first B-frame, handing
  out one frame out of order, which AVFoundation drops. Since 0.1.0. **Fixed** (strict compliance for H.264: the depth
  from the level). Both exports 555 now; encoding checks unchanged. On node 2 as a dev build (release copy
  /root/vgpu/venera-videod.0.1.2); node 1 runs 0.1.2's.
- **Found, not fixed: 4K 10-bit doesn't decode through the host.** A frame slot is 16 MB; a 3840x2160 P010 frame is
  25 MB (the comment said 16 MB held one). Tahoe's and Sonoma's wallpaper movies (HEVC 10-bit 4K) fail to export
  ("Cannot Decode", -11821/-16977) and Safari's 4K HDR would fail the same way. 10-bit 1080p and 8-bit 4K work. The fix
  needs bigger slots (fewer, or a bigger shared region), which the kext and the host must agree on: a VeneraVideo and
  host change together, with the hello saying which layout.

## Round 15 (2026-11-18): 4K 10-bit decoding, and the encoder's leak

- **4K 10-bit decodes through the host.** A frame bigger than a slot (P010 3840x2160: 25 MB; slots are 16 MB) now
  fills the next slot too: the host takes n free slots side by side, starting at a multiple of n so a stream keeps to
  the same spans (and VA surfaces, which never overlap: a span's surface replaces those of the slots it covers), and
  orders a fill naming the first; the guest's copy may run past its slot up to the last. Same shared memory, same
  layout: VeneraVideo 0.2.1 says VV_GF_SPAN in its hello, and a host sends spans only to a guest that does (an older
  guest's 4K 10-bit frames fail, as before). Tahoe Day (HEVC 10-bit 4K, 240 fps, 120 s): every one of 28,801 frames
  decoded on the host; against the Mac's own decode at full size (a ProRes export), 62 dB luma, 57 dB chroma, SSIM
  0.9992, so the chroma that starts in the second slot is right. Sonoma's Graphic Dark: all 21,600 to ProRes.
- **The encoder leaked a frame's IOSurface per frame** (since 0.1.2's hardware encoding). The guest's encoder keeps
  each frame's pixel buffer until both its efrm is answered and an Eemt names its uui
  (paravirtualizedVideoEncoder_forgetPendingFramePixelBufferByUUID sets one flag each; VideoToolbox's own host side,
  VTParavirtualizationHostEncoderSession, is in the same binary, which is how it was read). Our Eemt didn't carry the
  frame's uui, so nothing was let go until the session ended: IOSurfaces grew one a frame (16,332 at 16,000 frames),
  macOS compressed and swapped, and avconvert failed (-11801 / kCVReturnAllocationFailed -6662) at ~16,000 frames on
  VM 108's 8 GB. The Eemt now says the frame's uui: IOSurfaces stay at ~150 through the whole Tahoe Day export
  (28,801 frames to HEVC 1080p on the host, every one out). And encoding is faster, since the app's pool no longer
  makes a new buffer each frame: 1080p H.264 101-105 -> 175-181 fps, HEVC 104 -> 203-205 (A/B against 0.1.3's
  daemon); 720p 295 / 372, 4K 55 / 60. vtenc: 300 of 300 when CompleteFrames returned, every run (0.1.3's missed one
  in four).
- Found on the way: a full Tahoe Day export to ProRes at 4K is ~75 GB (5 GB for 8 s): VM 108's first attempt filled its
  disk. Apple's host also sends a top-level "rels" box of 64-bit surface mapping ids
  (VTParavirtualizationRelinquishMappedGuestSurfacesNoLongerInUse), most likely for Apple's guest driver, which
  VeneraVideo replaces; nothing in VideoToolbox reads it, and VeneraVideo's own table (96 surfaces) needs none.
- Checks: the session and ring fuzzers on the new slot code (1.4 M and 212 k runs, nothing found); the widget movie's
  555 frames to ProRes and HEVC; vtenc's small exports, 8 of 8 complete.

## Round 16 (2026-11-18): cleanup, and items 5-8 looked into

- **Cleanup.** node 2's local-lvm (VM 108 alone) was 93% full: VM 108's 8 snapshots held ~67 GB of old blocks (the
  4K exports of round 15 wrote tens of GB). Kept clean-dev and a new rel-014 (0.1.4 installed); the other 7 deleted:
  76%. Old kits (0.1.2, 0.1.3) gone from both nodes, node 2's /root/vgpu test output (~450 MB, and the pre-0.1.1
  /root/vgpu/video install) gone, dist/ keeps 0.1.4. deploy.sh video-host now installs over /opt/venera/video.
- **5, encoding one frame at a time.** Apple's host (VTParavirtualizationHostEncoderSession, in VideoToolbox) answers
  efrm as soon as the frame is in its encoder, Asynchronous, sends Eemt as a request, and answers CompleteFrames after
  VTCompressionSessionCompleteFrames, which waits for the guest's answers. Tried here (efrm at once, inf 1): 206-220
  fps against 178-181 at 1080p, but the last frame came after CompleteFrames in 20 of 20 runs (exports drop it). The
  guest can't answer a request while VeneraVideo holds its send (the workaround for Intel VideoToolbox's 32-bit reply
  timeout; VideoToolboxParavirtualizationSupport keeps its lock across the call), so it stays one frame at a time.
  The old 1-in-20 late last frame is fixed: CompleteFrames is answered 20 ms after the last frame (150 of 150 runs).
  Overlap needs another answer to the reply timeout: a send that returns at once with the answer delivered before
  the process waits, or patching the 32-bit conversion in the guest.
- **6, translation per function-constant set.** tools/fcfold: folding the specialized text (literal comparisons at the
  type's width, branches, dead blocks and phi entries, single-entry phis, uncalled functions) before translation makes
  WindowServer's uber shader 2.7-9.5x faster to translate (~400 ms -> 41-289 ms on the Mac, 12 sets), the SPIR-V
  computing the same (opcode counts equal but for unused loads). Two bugs found on the way (an unlabeled entry
  block's number; i8 255 is -1) show why the check matters. The real pass belongs in the translator after
  fc_air_specialize; a new translator means a new seed (its hash is in every key).
- **7, the seed on other builds.** Keys are the translator's hash and the shader's text, so the seed is right on any
  build; install.sh now always puts it in, and seed-pool.sh merges builds into one seed. Not measured on another build:
  VM 109's recovery was 26.6.2 but the installer put on 26.7.3 (Apple's latest), the build VM 108 has.
- **8, the new-VM path end to end (VM 109, node 2, NAS storage, vmbr0).** Found and fixed: the recovery
  lookup failed under pipefail after the download (Apple sends BaseSystem.dmg alone). Recovery, Disk Utility, the
  installer and Setup Assistant run on Venus graphics before any driver. Found, not fixed: at each of the install's
  restarts OpenCore's menu defaults to macOS Base System (its first entry), not the installer or the disk macOS chose
  (RequestBootVarRouting and WriteFlash are on), so someone has to pick at the menu three times; the script now says so
  instead of "it picks by itself". Setup Assistant needs an account password, and the guest agent is still a manual
  build: the rest is a person's. The owner made the account (2026-11-19): Setup Assistant then sat on its last screen
  (software drawing, no driver yet) until a restart, after which the login window and the desktop came up. The VM
  README and the script's closing steps now say so; a fix would mean Venera in before Setup Assistant.

## Round 17 (2026-11-18): window pieces left behind in a fast drag

The owner sees pieces of a window left behind while dragging it fast, in Proxmox's console and in VNC, gone once the
drag stops. Looked into on VM 108:
- tools/vncgrab.py records the screen as QEMU's VNC server shows it (Proxmox's console: egl-headless reading the GL
  scanout), through `qm vncproxy` with a one-time ticket; ~15 frames a second. QEMU's screendump has no surface with
  a blob scanout, and screencapture in the VM needs Screen Recording.
- tools/teartest.m: a full-screen window turning black and white every frame (no frame of 115 was mixed), and a
  magenta backdrop to drag the drag test window over: in 116 frames of fast circles the only thing not magenta was one
  window-sized region (the window and its shadow), never a piece elsewhere.
- Found: during drags, 12-20% of display frames are copied into the twin on screen at that moment (the core now counts
  it: VirtioGPUTwinRewrites). Flips run on the accelerator's loop, 12 ms apart at least and ~3-4 ms each, behind
  WindowServer's frames, and Core Animation comes back around to the surface still shown. A viewer reading the twin
  during that copy would get a torn frame. None was caught at 15 frames a second, so it isn't shown to be what the
  owner sees; the fix would be two twins a surface (the copy into the one not on screen).
- What remains likeliest: VNC viewers draw an update rectangle by rectangle, and drag frames come every 34-60 ms here,
  so a slower client shows old window pieces until the next update clears them.
- **Fixed (the owner: "fix the race now"): two twins a surface** (core 0.5.8, accelerator 0.6.14, Metal driver 0.4.3).
  The plugin makes a second blob for each display surface and passes it as kVGUCSetTwin's sixth scalar; at each
  frame kVGUCTwinMark (submitted) answers which twin to copy into: the other one than last time, unless that one is
  on screen. The transaction shows the twin the latest frame went into (twinFor), and the flip loop no longer flips
  to a queued frame whose twin a newer frame of its surface is being copied into. An older plugin or core keeps one
  twin. `/Library/GPUBundles/VirtioGPUMetal-onetwin` keeps one for comparing. On VM 108 (the release-to-be through the
  VM script's Upgrade): 0 of 11,584 frames into the twin on screen (one twin: ~15%), fast drags over the magenta
  backdrop 188 frames, nothing left behind. Drags as fast once warm: frames 17.8 ms apart (one twin 17.7-18.3); the
  first drags after a restart are slower (twice the blobs for QEMU to take in the first time each is shown).
- **VM 107's mouse died after 0.1.5's upgrade** (the owner: "non-responsive"): macOS ran and took keys, but no pointer
  events arrived (HIDIdleTime kept climbing). VM 107 has two USB tablets, Proxmox's (`tablet: 1`, EHCI, mouse #3 in
  `info mice`) and the args' (XHCI, #5); QEMU sends the console's mouse to the active one, which was #3, and macOS
  wasn't reading it (VM 108, working, had #5). `mouse_set 5` in the monitor brought the mouse back at once. Likely the
  upgrade's USB disk on and off the EHCI reset Proxmox's tablet, which took the active slot, not proven. New VMs from
  the script now get only the args' tablet (`--tablet 0`). The trails the owner saw in Proxmox's console remain with
  two twins; they go a second later. The owner sees them in a plain VNC client too, from away from home.
- **The trails are the link's speed, not the frames** (2026-11-19). The same circle drag on VM 108 over the magenta
  backdrop, read through `qm vncproxy` with each row drawn as it arrives (as a viewer draws an update): at full speed no
  frame holds anything but the window (~55 frames); with the read capped at 150 Mbit/s of raw pixels (a few times less
  once a real client's encoding compresses it), a frame holds pieces of two window positions, old edges and shadow
  left behind until the rest of the update arrives. A viewer on a slow link draws half of an update before the
  other half arrives. Nothing in the guest can change that; a faster link, or a viewer that sends less (macOS Screen
  Sharing from the guest itself), does. The capped grabber is a scratch variant of tools/vncgrab.py (rows drawn as
  read, a snapshot every 100 ms, reads paced to N Mbit/s). Care when driving VM 108 by QMP: aim drags at the test
  window's title bar from a fresh grab (a press too soon after a click is a double click and zooms it; a drag into the
  menu bar tiles it), and check what is in front first (an earlier drag made Calendar events, since deleted).

## Round 18 (2026-11-19): Venera's own guest agent, the Venera Tools CD

The owner: build our own guest agent rather than lean on mac-guest-agent, make macOS a first-class Proxmox guest
(everything Linux and Windows guests get), a Customize choice on by default, and an offline "Venera Tools" CD.

- **agent/venera-agent.m** (Objective-C, Foundation + OpenDirectory, ~800 lines; `tools/build-agent.sh`): the QEMU
  guest agent protocol on the virtio port `org.qemu.guest_agent.0` (preferred) or the ISA serial port. Commands:
  sync/sync-delimited, ping, info, get-osinfo, get-host-name, get-timezone, get-time, set-time, get-vcpus,
  network-get-interfaces, get-fsinfo, get-users, get-load, shutdown, exec/exec-status (stdin, separate or merged
  output, PATH lookup, 16 MB per stream), file-open/read/write/seek/flush/close, fsfreeze-* (sync only: APFS can't be
  frozen from user space), fstrim (says APFS trims at mount), set-user-password (OpenDirectory's reset: the login
  keychain keeps the old password), suspend-* and memory blocks as Unsupported. `agent/test-agent.py` checks the
  protocol through `--stdio` (23 checks; build it for the Mac you run it on).
- On VM 108, through Proxmox: ping, osinfo, exec with stdin (`--pass-stdin`), file-write/file-read via the API,
  fsinfo, users, freeze/thaw, fstrim, passwd (on a throwaway account: the new password authenticates, the old one
  doesn't; deleted after), `qm shutdown` in 10 s with no dialogs, `qm reboot` in 9 s, agent up ~22 s after start.
- **Speed**: the ISA serial port moves ~100 KB/s each way, which is why mac-guest-agent "hung" on 4 KB arguments and
  big outputs (Proxmox gives up on an answer after a few seconds). The virtio port moves ~1 MB/s. New VMs get
  `agent: type=virtio`; Finish moves an older VM to it when Venera's agent is in. `vm-remote.sh push` now goes through
  `--pass-stdin` in 512 KB pieces: 3 MB in 14 s (the 66 KB agent took 2.5 minutes the old way).
- **The virtio port stalls** when Proxmox closes its end while an answer is on its way (a 5 MB exec output timed out):
  macOS's virtio console then takes no more output, a blocking write waits for good, and even the close at exit waits
  on the tty's drain (launchd showed the exited agent as still running). Reading the host socket, and reconnecting
  QEMU's chardev, don't free it; the guest closing and reopening the port does. So the port is non-blocking; a write
  with no progress for 5 s flushes the queue (tcflush), drops the rest of that answer, and the agent reopens the
  port: answering again ~6 s after the timeout. A watchdog (20 s stuck) flushes and exits as a last resort.
- Learned on the way: QEMU's `chardev-change` to the same socket path deletes the socket (the old backend unlinks it
  after the new one listens): change to a temporary path and back. launchd stops retrying a job whose program wasn't
  executable when it tried (EX_CONFIG, "spawn scheduled" for good): install.sh makes the binary executable before the
  rename. `send-key` through QMP lost a key-up (a key repeated); `input-send-event` with explicit downs and ups
  doesn't.
- **Installer**: a "Proxmox guest agent" choice (on; `install.sh --no-agent`, remembered as NO_AGENT for the script's
  Upgrade), installed in the first pass too. It sets mac-guest-agent's daemon aside (uninstall.sh puts it back). The
  agent can be carrying the install itself (Upgrade runs through it), and launchd stops a job's whole process group,
  so the switch is a one-time job (local.venera.agent-swap) that waits until no install.sh runs; the agent's commands
  run in their own process group and its job has AbandonProcessGroup. Tested on VM 108 as the Upgrade does it: a test
  0.1.6 package from the Tools CD as a USB disk, `installer` through the agent: rc=0 read by Proxmox, the new agent up
  3 s later, then a reboot through the agent onto the Metal desktop.
- **Venera Tools CD**: make-pkg.sh also makes `dist/Venera-Tools-VERSION.iso` (the package and a read-me,
  `packaging/tools-readme.txt`), carried in the host package's guest/ folder. The VM script attaches it as a CD drive
  from an ISO storage (a shared one first: a NAS share), so macOS shows it on the desktop; Finish takes
  the drive out and leaves the ISO. vm/test.sh: 18 checks.
- Not done: VM 108 runs that test 0.1.6 build (agent from this round; the rest is 0.1.5's). No release yet. VM 107
  still has mac-guest-agent on the ISA port: an Upgrade to the release puts Venera's agent in, and Finish (or the
  Options page plus a restart) moves it to virtio.
- **Both fixes for the stall** (the owner: "seems like a band aid", then "let's do both"). Why it stalls: QEMU's
  virtio-console resets cleanly when the host hangs up (read hw/char/virtio-console.c and virtio-serial-bus.c:
  `virtio_serial_close` clears the throttle and discards the queued output, and output while the host is away is
  discarded); Apple's AppleVirtIOConsole doesn't come back from it (Virtualization.framework's host never goes away).
  1. **Answers sized to Proxmox's wait** (62ea44a): QMPClient's default timeout is 5 s; answers hold ~2 s of the port
     (1.5 MB virtio, 200 KB ISA): exec output cut and marked truncated (5 MB: 1.1 MB back in 2.7 s), file-read
     returns less than asked (a 5 MB file whole in 3.3 s).
  2. **VeneraConsole.kext**: our own virtio-serial (multiport) driver, through OpenCore, reusing VirtioGPU's
     VirtioPCI transport (its notify table grown to 64 queues). Control queue: DEVICE_READY, DEVICE_ADD -> PORT_READY,
     PORT_NAME, PORT_OPEN both ways; 16 x 16 KB receive and send buffers a port; a root-only user client (ports, open
     by name, read and write with timeouts; VeneraConsoleAPI.h), no tty. The agent uses it first, the tty after.
     Apple's AppleVirtIOPCITransport matches every 1af4 device with no IOProbeScore and still beat ours at 5000 (its
     probe raises the score): ours sets 1000000 in probe. Two boots hung while getting there: a property set on
     IOResources from probe, and the shared log array published as a live registry property while being appended to
     (the hang sat between probe and start); the log is now copied onto the service. On VM 108: the agent on
     VeneraConsole, 1 and 5 MB outputs, a 5 MB file read (4.9 s, checksum equal), 900 KB stdin, three hang-ups
     mid-answer with the next connection answered in 0.01 s (no drop, no reopen), two reboots through the agent
     (~10 s down, ~21 s to the agent). Snapshot pre-console on VM 108 is the state before the driver.
- **The clipboard** (the owner: "clipboard sharing wasn't implemented? We should implement it"). Proxmox gives a
  virtio-gl VM the port com.redhat.spice.0 on a second virtio-serial device: spicevmc by default (a SPICE client), or
  with `vga: ...,clipboard=vnc` QEMU's own vdagent (ui/vdagent.c), which joins the VNC (noVNC) clipboard to it. Both
  speak the SPICE agent protocol (vd_agent.h): chunks (port, size) carrying messages; capabilities asked for when the
  guest opens the port; on demand: GRAB (types) -> REQUEST (type) -> CLIPBOARD (data). `agent/venera-clipboard.m`, a
  LaunchAgent in each user's session, does that against NSPasteboard (the change count polled twice a second; a grab
  from the host requested at once; text UTF-8, PNG for SPICE clients; Latin-1 fallback, since QEMU passes a VNC
  client's plain cut text on as it is). VeneraConsole lets the console user open ports other than the guest agent's.
  QEMU sends the guest's clipboard only to VNC clients with the extended clipboard (noVNC has it); the test client
  (scratch vncclip.py) speaks it. On VM 108 through `qm vncproxy`: console -> macOS 1, 3, 12 KB and UTF-8; macOS ->
  console 9.6 KB UTF-8 across many chunks. Live migration with clipboard=vnc needs machine 10.1+ (VM 107 runs 11.1);
  the VM script turns it on for new VMs, Ready and Finish where that holds.
- **A Proxmox bug found on the way**: `qm guest exec` with a character past U+07FF (a check mark) in the command sends
  only part of the request and times out; Proxmox never sends the 0xFF that resets an agent's parser, so every later
  request landed inside that unfinished string ("QEMU guest agent is not running" until something sent 0xFF). The
  agent now drops an unfinished request that has sat with nothing more for 4 s when new bytes come (the next ping was
  answered 1 s after Proxmox gave up). VENERA_AGENT_TRACE=1 in the agent's environment logs every request.

## Round 19 (2026-11-19): what Venera depends on

The owner: how fragile are the dependencies (OpenCore, unmaintained projects), and fix it: our own OpenCore, a
VMHide of our own, copies of everything in our releases, bundle what can be, pin the build, and ideas for Proxmox's
packages; plus bringing your own macOS. Found: KVM-Opencore's last release (v21, OpenCore 1.0.0) is from March 2024;
VMHide has no license (can't be mirrored) and one release; NullMoth's translator is one person's (LGPL: mirrorable);
the Mesa build pulled unpinned Python packages; the Debian build image and FFmpeg's tarball weren't pinned.

- **Venera's OpenCore** (6110445): vm/opencore/build.sh, OpenCorePkg 1.0.8 (BSD-3, pinned) with config.py over its
  Sample.plist, SSDT-VENERA.dsl (EC, USBX, plugin-type on QEMU's C000: KVM-Opencore's tables, rewritten) and
  VeneraHide; ocvalidate clean; 48 MB; reproducible (fixed GUIDs, serial, times). Read off KVM-Opencore v21's config:
  its five kernel patches all stop at Darwin 23, its EHCI table names 00:07.x (q35's EHCI is 00:1d.7: no effect on
  VM 108) and its LPC property a PciRoot(0x1) path (no effect either), and its Broadcom, audio, graphics and USB-map
  kexts do nothing in a VM. Two bugs on the way: `sgdisk -q` writes no partition table and still exits 0 (the first
  images had no partition; VM 108's move worked only because it rewrote files in its old partition), and ScanPolicy 0
  listed OpenCore's own FAT disk first and booted it at the timeout (now APFS and HFS+ only, KVM-Opencore's devices
  plus USB). A fresh VM (110) boots Apple's recovery on it; VMs 108 and 109 moved with the new choice 5 (VM 108: all
  six Venera kexts, the Metal desktop; VM 109: its login window). Not tested: a full install's restarts (accepting
  Apple's license on a new VM needs the owner's OK), so the note about OpenCore's menu at those restarts stays, made
  conditional.
- **VeneraHide** (kext/VeneraHide): kern.hv_vmm_present 0 for every process but the four software-update ones,
  as VMHide; no Lilu: the kern sysctl node is exported (sysctl__kern_children), the oid's handler swapped with CR0.WP
  cleared and interrupts off for the one store. VM 108: sysctl reads 0, a copy named softwareupdated reads 1.
- **Pins and sources** (aa7d408): packaging/UPSTREAM (OpenCorePkg, Mesa's tarball, FFmpeg, the translator commit and
  rustc, the Debian digest) read by the builds; mesa/requirements.txt; tools/make-sources.sh makes
  Venera-sources-VERSION.tar (83 MB; the translator built offline from it in 34 s with the network off for cargo).
  The mirror: private prerelease upstream-2026-11-19 (8 files, 75 MB, MIRROR-SHA256SUMS).
- **Bring your own macOS**: the script lists ISO storages' template/iso and import files that could be a macOS disk
  (qcow2, vmdk, vhdx, vdi, or an image of 20 GB or more: imported as the VM's disk) or an installer or recovery
  (.dmg through dmg2img, or a smaller image: booted to install). VM 111 from VM 109's disk as a qcow2 in the NFS
  import folder: OpenCore listed Macintosh HD and its recovery, macOS reached the login window. VM 110 from the kept
  Tahoe-recovery.img as "your installer": the recovery. Also: the OpenCore mount waits for the loop device's
  partition node (it came late and the mount failed), and every OpenCore step dies on failure (one run went on and
  made a VM with an unedited image).
- **Proxmox's packages**: install-host.sh --check (versions against TESTED, the render server's libraries, the GPU's
  render node, the Vulkan and VA-API drivers; when something changed, the `apt install PACKAGE=VERSION` lines that go
  back), --record (TESTED for a release; node 2's is in packaging/host/TESTED), --hold/--unhold (QEMU, virglrenderer,
  its server, Mesa's Vulkan); the VM script warns when the host isn't on TESTED's versions.
- Test VMs 110 and 111 and the 61.5 GB qcow2 are gone; OpenCore disks moved are saved in /root on node 2.

## Round 20 (2026-11-19): Venera from macOS Recovery, and Recovery with Venera

The owner's idea: install Venera from the recovery before macOS is installed, with one Terminal command, and keep that
as the fallback after setup (as long as the Venera Tools CD is attached), letting the user pick the volume (not
always "Macintosh HD").

- **`install-venera`** (packaging/recovery, at the Tools CD's top; the CD's Recovery/ has the release tarball,
  `Venera Stage.pkg` and one `Venera Choice NAME.pkg` per choice). It lists the APFS volumes that are or will be
  macOS (an installed macOS's Data half found by its volume group, whatever it's named; FileVault unlocked with
  `diskutil apfs unlockVolume`, the user typing) and asks the package's choices.
  - **Before macOS is installed**: files put onto the erased volume don't last (VM 110: a marker and a LaunchDaemon
    placed from Recovery were gone after the install; the installer clears the volume, which becomes the Data
    volume). So it runs macOS's installer itself: `startosinstall --agreetolicense --volume /Volumes/VOL
    --installpackage "Venera Stage.pkg" [--installpackage "Venera Choice NAME.pkg" ...]`, after showing the license
    and asking. `--volume` isn't in this version's usage but works (without it, it picks Recovery's own volume);
    unsigned packages are accepted. The installer adds the packages at the new system's first startup, after
    launchd read /Library/LaunchDaemons (VM 110: the job ran only a boot later), so the stage's postinstall
    bootstraps local.venera.finish when installed onto "/". VM 110 end to end (erase from the installer's
    Recovery, install-venera, about 45 minutes): Venera installed at the first startup (one pass: the VM script's
    SIP) and the VM restarted into Setup Assistant on the host's GPU. That run gave the stage first, and its install
    read no choice markers (--no-app --no-agent; the markers landed seconds later): the choice packages go first now,
    and the stage's pass waits up to a minute for them. Second run (choices first): the install read
    the choices (app, agent; no video, no WebGL), restarted once, and VM 110 came up at Setup Assistant with the Metal
    desktop, the Venera app, and the guest agent on VeneraConsole.
  - **After**: the release unpacked onto the Data volume, `finish-args`, `finish-first`, the job; install.sh's boot
    pass may now be a first pass (`finish-first`): with SIP not set for Venera it sets OpenCore's security settings,
    restarts by itself, and finishes at the next boot. VM 112: a VM-script VM (SIP already set) in one pass, and with
    OpenCore's csr-active-config 0 and no AMFI argument in two (09:38 security, 09:39 install, Metal desktop).
  - **remove**: `uninstall.sh --at-boot` (new: waits for OpenCore's disk, takes the job out, restarts). VM 112:
    from the installer's Recovery, Venera out at the next startup, back on the firmware framebuffer.
  - install.sh: the boot pass starts the Venera app only in a user's session (it had bootstrapped it into Setup
    Assistant's, uid 248); the stage's choices come from `.choices` markers, kept as finish-args for a later try.
- **Recovery with Venera installed had no picture** (since the core kext went into OpenCore: every boot loads it).
  The core took the virtio-gpu device and its slot holder kept IONDRVFramebuffer off it; Recovery has no Auxiliary
  KC, so no VirtioGPUFramebuffer, and WindowServer had nothing to draw on (the progress bar stopped; `-v` showed
  Recovery's apps running). Core 0.5.9: both personalities stand aside in a Recovery or installer boot: an installed
  macOS's Recovery boots from a RAM disk (`/chosen` boot-ramdmg-extents), the installer's macOS Base System through
  `bootbase.efi` (`/chosen` booter-name; a normal boot's is boot.efi). `-vgpurecovery` takes the device anyway. VM
  112 and 110: both recoveries draw with Venera installed; the normal boot keeps the Metal desktop.
- Found on the way: Proxmox's `qm agent VMID ping` can report success while the agent isn't up (use `qm guest cmd
  VMID ping`); `pkill -f PATTERN` inside an ssh command matches the command itself.

## Round 21 (2026-11-19): pieces of old frames under a fast drag

The owner, in Screen Sharing and in Proxmox's console (VM 107, and VM 108 too): drag a window fast and pieces of it
stay behind, windows show cut off or for a moment black, pieces stay after a window closes. Not the viewers: the
blob flips flush the whole screen to QEMU, and Screen Sharing captures the same frames.
- Seen on VM 108 with tools/vncgrab.py (what the console shows) under a fast qmpinput drag: frames stitched from two
  moments and strips of earlier frames where only the desktop belonged.
- A sync log (flag file VirtioGPUMetal-synclog, empty or naming processes: every pull, every write, every write-back
  and every written surface left without one, with seeds) showed WindowServer's two other screen-sized surfaces (1
  and 4, rendered by every frame's display command buffers) pulled from their CPU bytes about 385 times each in 5 s,
  and every write-back of theirs marked "(others wrote)".
- Cause: the write-back read the surface's seed after taking its write lock, and a write lock bumps the seed: every
  write-back looked like another process's write, left the image unsynced, and the next bind pulled the bytes back.
  That pull is queued ahead of the next submit, while a newer frame of the same surface was often already drawn into
  the image: the surface went back a frame or two, and WindowServer redraws only the damaged parts on top. Fixed by
  reading the seed before the lock; then a race of the same kind was left (the encoding thread's pull check could see
  a write-back's bumped seed before the completion thread recorded it): one lock (gVgSurfaceSync) now covers a
  write-back from the seed read to the seed recorded, and the pull's check.
- After: the same drag pulls nothing (surfaces 1 and 4: ~380 writes and write-backs each, no pull, no "others
  wrote"), and the owner's own fast drags show nothing left behind. It also saves two 4 MB copies a frame.
- Also seen (VM 107's log): twins asked for window-sized surfaces in display command buffers are refused
  (kIOReturnNotPermitted); harmless, they take the write-back path.
- tools/check-vtables.py (RX4Darwin's idea, our code): clang's vtable layout for each of our classes against the
  real one in the KCs, and the 68 forwarders' slots.
  Against VM 108's 25G342 Boot and System KCs: every class OK (the IOAccel ones slot by slot against
  IOAcceleratorFamily2), the 68 forwarders on Apple's method; 7 "signature" notes are enums our headers declare as
  unsigned int (the same in the binary).
- **RDNA4's other ideas, measured on VM 108** (the owner asked for all five):
  - *Kernel log that survives a hang*: our kexts' lines already go to IOLog, so the unified log keeps them across
    restarts, and a panic leaves its report; what is lost is the last seconds before a hang or panic, which RDNA4's
    once-a-second copy loses too. The serial port doesn't: tools/serial-log.sh adds one (serial0: socket, serial=3 in
    OpenCore's boot-args through the agent) and records a file per boot on the host. VM 108: 2,842 lines of a boot,
    849 of them Venera's; then turned off again.
  - *The display pipe's own VBL*: WindowServer does call enableVBLInterrupt (each time with a disable in the same
    millisecond). IOAccelDisplayPipe::signalVBLInterrupt (exported; disassembled: counts the VBL, signals a
    transaction waiting for one, fires the pipe's VBL event source while enabled) driven at 60 Hz changed nothing:
    CVDisplayLink 59.3-61/s with no measured refresh period either way, a view's display link ~54-56/s, presented
    handlers all firing with the same uneven spacing (7-80 ms around 17). Not kept. tools/vbltest.m measures it.
    The framebuffer's own VBL timer now runs on absolute deadlines (it drifted to ~59.3 Hz re-arming 16.667 ms after
    each tick): framebuffer 0.5.2.
  - *System sleep*: Proxmox starts every VM with ICH9-LPC disable_s3=1 and disable_s4=1: no system sleep exists to be
    delayed; display sleep was checked in round 6.
  - *useIOP as a backup for the AppleParavirt class name*: no. With useIOP set and the plain class name
    (-vgpunovendor), CoreDisplay's switch came up on and went off 6 s later (vendor mask 0), and WindowServer came
    back at the login window. The class name stays the only way in; reverted.
  - *Metal's first device open*: ~200 ms in a new process (Venus' start), not RDNA4's 15 s.
  - tools/kcsyms.py lacked its imports (fixed).
- **A generated Mac identity** (the owner: "generate everything on our own, including the Wi-Fi MAC", by the model
  chosen). The VM script's identity step is now generate (default) / your Mac's / skip. Generate uses OpenCorePkg's
  macserial.linux (shipped in the host package's opencore/ from the pinned release zip): a serial and board serial
  made as a pair for the model (model code, board code for its board-id, factory and week shared, MLB checksum), a
  Wi-Fi MAC with an Apple prefix; the UUID was already the VM's own. vm/test.sh caught macserial for Linux giving the
  same pair every run (no arc4random: a fixed seed); the script supplies the randomness (week, production line, the
  last of 1-1000 pairs) and gives the 17-character MLB a random 3-digit item with its checksum recomputed (the
  generator's items repeat in a cycle: 4-12 shared board serials in 300), checked by macserial --verify: 300 of 300
  serials and board serials distinct. "Your Mac's" decodes the serial (macserial -i) and offers the serial's model when
  it differs from the VM's. Walked through the create flow on node 2 up to the plan, both ways (nothing created).

### 0.1.7 (2026-11-19)

- The VM script's Upgrade stopped at a `qm>` prompt when run in a terminal (the one-line setup): `qm monitor` reads the
  terminal instead of its stdin there. `hmp()` sends each command through `PVE::QemuServer::Monitor::mon_cmd`
  (288625b); tested in a pty on node 2 (attach, duplicate refused, detach). Released as v0.1.7 (pre-release), nothing
  else changed; get-venera fetches it.

### 0.1.8 (2026-11-19)

- The VM script's **Startup settings** (choice 6, 02ad20d): screen size (QEMU's xres/yres for the desktop, up to the
  framebuffer's 1920x1200, plus OpenCore's resolution), verbose, the menu's seconds, -vgpuoff, other boot-args, then
  choice 3's model and identity (which now defaults to the VM's model). Choices 3/5/6 offer to shut a running VM down.
  A new VM's screen size sets the desktop too. Tested on VM 108 (snapshot, rolled back): 1920x1080 Metal desktop.
  Released as v0.1.8 (pre-release); nothing inside macOS changed.

## Round 22 (2026-11-19): before 0.1.9

The owner's list (1-7, then 9 and 10): checks on GitHub, a warning before Proxmox updates replace tested packages,
TRIM, Upgrade without a USB disk, Retina modes, a faster first boot (a warm-up and faster translation), AMD hosts
(experimental), and an install with nobody at the keyboard.

- **GitHub checks** (.github/workflows/checks.yml): every script parses (macOS's in its bash 3.2) and passes
  ShellCheck's errors (it found three), vm/test.sh with OpenCorePkg's pinned zip, and the guest agent's protocol on
  macOS. vm/test.sh's older config is optional (the sample stands in).
- **The apt hook** (packaging/host/apt-check, /etc/apt/apt.conf.d/80venera): before apt installs, it names each
  TESTED package changing version and how to check and go back; warns only. Container test 28/28.
- **TRIM on thin storage**: discard=on and OpenCore's SetApfsTrimTimeout -1 (asked for a new VM on thin storage,
  startup setting 7). VM 108 (local-lvm): 100% -> 43.7% allocated at the next boot.
- **Upgrade through the agent**: guest-file-write in 4 MB pieces through mon_cmd (PVE routes guest-* to QGA), checked
  by SHA-256; the USB disk only for an agent that can't. The restart is checked by boot time (the installer
  restarts the agent and one restart request went nowhere).
- **Retina and 4K**: framebuffer 0.6.0 (modes to 3840x2160, HiRes flag from 2560 wide, VRAM for the largest mode with
  a 1920x1200 fallback), install.sh's display override for QEMU's display (0x4914/0x1234, scale-resolutions). The
  first try came up black: WindowServer's display surfaces at 16-33 MB couldn't get contiguous RAM
  (VidMemory allocPhysical). Accelerator 0.7.0 keeps one spare contiguous block from its start (36.9 MB), shared
  by allocations that can't get their own (nothing reads that memory). 1280x800 and 1920x1080 Retina on VM 108: the
  host gets 2560x1600 and 3840x2160 frames.
- **First boot**: the translator patch (packaging/translator/0001: fc_fold.rs, fold.py in Rust, by a subagent) and
  the warm-up (warm.txt: 79 sets WindowServer asked for, names and numbers only; background translation on the
  other cores). Cold start on VM 108 (caches cleared, same apps, 5 min): WindowServer waited 117 s -> 56 s. One set
  (fixed_frag_lph_cpf) still took 21 s with the background busy: the next lever, with the translator's own time.
- **AMD hosts**: Haswell-noTSX with vendor GenuineIntel in place of -cpu host (no OpenCore patches), asked first. That
  model booted VM 108 to Venera's Metal desktop on the Intel host; no AMD host to try.
- **Nobody at the keyboard**: install-venera auto (finds the empty disk, erases it, startosinstall with Venera), the
  VM script types it into the recovery's Terminal through QMP send-key (Control-F2, Utilities, Terminal; the screen's
  mean brightness and stillness say the recovery is up; the disk's first writes say the command ran), waits for the
  agent and runs Finish; --answers FILE (vm/answers.example) answers every question. VM 111 end to end on node 2:
  ~38 min to Venera's agent, Finish, Setup Assistant.
- **Found on the way: HEIF hung Setup Assistant.** VM 111's Setup Assistant stayed black (no window, on the basic
  display too): its main thread waited on CMPhoto decoding a HEIF image, whose tiles (dtil, dsts) venera-videod
  answered "no error" with no picture. Now "unsupported", and the guest decodes in software; Setup Assistant came up.
  The hosts had logged 308 such requests in 5 days (VM 107 too).
- **A new VM's Setup Assistant (VM 110, the owner's, installed with install-venera)** crashed at the account step and
  macOS restarted: SIGFPE in VFX's RGMTLComputeCommandEncoderDispatchOnGrid1D (AvatarKit's Memoji stickers). VFX's
  copy/blend kernels read [[stage_in]], which the driver refused, and VFX dispatched on the nil pipeline. Fixed in
  steps: compute stage-in from the pipeline's layout (nvmtl_translate_set_kernel_stage_in), half3 in the translator
  (packaging/translator/0002), the rest of Metal's vertex formats, command buffers of a queue completing in commit
  order (VFX read its OpenSubdiv dependency as still Scheduled), and **Metal tessellation** (de1958c: NullMoth's
  design ported, VGMTLTess.c; every buffer carries a device address). tools/mtltess passes on VM 108; the owner saw
  the Memoji draw in VM 110's Setup Assistant.
- **The Memoji editor, the wait cursor (VM 110)**: the Memoji editor and pose picker are app extensions inside
  AvatarUI.framework, not inside an .app, so the default list turned them away (58107a1: .appex gets the device);
  with a device they showed two gaps: cube textures (d928652; tools/mtlcube) and compute buffers at offsets Intel's
  Vulkan can't take, AvatarKit's 16-bit blend-shape indices at 2 mod 4 (copied through aligned scratch memory;
  tools/mtlalign). The wait cursor in Proxmox's console: premultiplied rims (8d0b9bd), noVNC 1.7 reading the rich
  cursor's red and blue swapped, and the drop shadow drawn solid by QEMU's 1-bit mask (framebuffer 0.6.2, 8df678e).
  The owner saw both right.
- **A full SMC**: VM 110's PerfPowerServices held a core for 8.5 h (501 CPU minutes), stuck in its first
  PLSMCMetricsAgent getAllKeys: QEMU's applesmc has 6 keys and no key-by-index command, and each refused request is a
  trip through the emulated port. Venera's OpenCore now carries acidanthera's Lilu 1.7.2 and VirtualSMC 1.3.8
  (BSD-3, pinned in packaging/UPSTREAM; ocvalidate clean). VirtualSMC steps aside when AppleSMC is already attached
  to another SMC device, and QEMU's applesmc is an ACPI device it attaches to first: so QEMU's applesmc leaves the
  args (VirtualSMC carries the OSK keys). New VMs have none; Upgrade adds the kexts to a VM on Venera's older image and
  takes applesmc out (a shut-down and a start instead of a restart, the OpenCore disk saved first); choice 5 does both.
  VM 111: Upgrade end to end, three boots and Recovery without applesmc, 65 keys listed in 2.8 ms (tools/smckeys;
  before: every request refused), kern.hv_vmm_present still 0. VM 110: Upgrade, PerfPowerServices 1.3 s of CPU, then
  idle. Not run: a whole unattended install without applesmc (it needs Apple's license agreed to). Lilu and VirtualSMC
  run on the macOS versions they know (Tahoe): a major macOS upgrade waits for a Venera release (docs/INSTALL.md).
  VM 107 (the owner's OK): Upgrade with the SMC change; HA started it again on the other node (proxmox1). Its older
  guest agent couldn't take the package, and the USB fallback copied the kit's Venera Tools CD, whose package was
  yesterday's release: the kexts and Metal driver stayed old. The USB disk is now made from the package being installed
  (6th commit of the day); a second Upgrade put framebuffer 0.6.2, accelerator 0.7.0 and the new Metal driver on it.
- **The Memoji menu's beach ball (VM 110)**: the pose picker sat at a full core for ~30 s on each open. A sample:
  newDefaultLibraryWithBundle -> vg_new_library, converting every module of VFX's default.metallib to IR text
  (vg_air_to_text, vg_entry_of): 585 modules, ~1.2 s per load, and AvatarKit loads it again for each renderer. A
  metallib's function table (MTLB: NAME, TYPE, OFFT's bitcode offset; the list size leaves out its 4-byte count) now
  lists the functions and each module is converted when first asked for; a library loaded without its visible
  functions (Core Image's) lists TYPE 0-2 only, as before, and dynamic-library linking still gets every module. VFX's
  library: 1.17 s -> 0.02 s. VM 111, two boots each way (the eagerlib flag file brings back the old reading): no
  missing functions either way, the desktop on Metal; mtlcube, mtlalign, mtltess pass.
  Then 618f087: converted modules kept per process (AvatarKit loads the library ~170 times a minute). The owner: no
  beach ball, a slight pause left (the Memoji are 3D, tessellated and subdivided; each picker is its own process).
- **Setup Assistant's last screen hung (VM 110)**: "Update Mac Automatically" spun for good. The closing "hello"
  animation (SetupAssistantSupportUI's textFragment) couldn't get its text pipeline: the translator typed the Segment
  buffer, whose pointer the shader keeps in a Context struct and a helper reads back (segments[i], segments[0].start),
  as one Segment instead of an array of them, and the run-time element index became a member index. The faildump
  flag file (5b9e889) saved the shader; translate_native reproduced it on the Mac; packaging/translator/0003 (a
  subagent's, reviewed): such a buffer is a runtime array of its record (body_buf_dynamic_record_element_type), with a
  hand-written test. The crate's tests: 2402 pass, the same 85 fail as before (an old spirv-val, short corpora). VM 111:
  the hello pipeline builds, a boot refuses no shader (2 in the hour before), mtlcube/align/tess pass.
  VM 111 through the whole Setup Assistant on the owner's console: the hello played (its text pipeline translated in
  2.9 s, 2.2 MB of SPIR-V; a white screen meanwhile). The private seed was remade for the new translator from VM 111's
  pool after the full setup (1927 translations, the hello's included; tools/seed-pool.sh SEED_FROM), and the
  owner's kits on both nodes carry it (not a release: make-dist ships a seed only with VENERA_PRIVATE_SEED=1).

### 0.1.9 (2026-11-20)

- Everything since 0.1.8 (round 22, Setup Assistant's Memoji and "hello", VirtualSMC, the faster library reading, the
  cursor). Released as v0.1.9 (pre-release, no seed in it). The owner's kits on both nodes are a private 0.1.9 with
  the seed; VMs 107, 108 (snapshot venera-019-pre first), 110 and 111 upgraded, each on the same Metal driver,
  framebuffer 0.6.2 and VirtualSMC. Upgrades run on both nodes at once lost their place twice (VM 108 after the copy,
  VM 107 after the USB disk; the package was in, no restart): run one Upgrade at a time; reruns finished both.
- **A new VM's black wallpaper (VM 109, 0.1.9's one-line setup), not fixed.** At first login the aerial wallpaper
  never drew and Setup Assistant's last screen waited for it: WallpaperAerialsExtension logged "VideoPlayerLayer
  failed to create decoded pixel buffer" ~1000 times a second, 0 frames enqueued, while venera-videod decoded the whole
  4K 10-bit movie again and again (2 GB, 1.4 GB of it swapped). Stopping VM 109's video service let it through (the
  guest decoded in software). Found on the way: a synchronous decode is answered Asynchronous at once, where Apple's
  host (tools/pvhost fed the guest's own messages) sends Dbuf then Demt with inf 0 and no early answer; VeneraVideo
  holds such a send and queues host requests behind its answer, so a Dbuf waits 2 s. An experiment (a spare buffer
  asked ahead, drain + replay, Demt as a plain message) is notes/sync-decode-experiment.patch: synchronous frames then
  come with their buffers and inf 0, though still just after the call. The wallpaper also opens a tile session
  (dsts), refused since the HEIF fix. But the failure could not be brought back once the wallpaper had a snapshot:
  released and patched services ran the same (one failed attempt, then ready), with the snapshot moved aside too. Not
  shipped (each synchronous frame would drain and replay a GOP: thumbnails and Quick Look decode that way). Next time
  it happens: verbose (SIGUSR1) dumps the messages in the service's state directory; tools/pvhost replays them.
  Caught again 2026-11-20 on VM 109, a second user's first login (Setup Assistant on screen): the aerials extension's
  first decode ("Handling frame during still", a synchronous VTDecompressionSessionDecodeFrame) never returned: its
  thread waited on VideoToolbox's send lock, held by the paravirtualization queue's thread inside VeneraVideo's
  method 3. FigVideoQueue: 0 frames enqueued, all along; venera-videod meanwhile took 28,653 frames (162 a second) for
  that session. No "failed to create decoded pixel buffer" this time. RunningBoard suspended the extension 60 s after
  its launch (its launch assertion ran out with nothing shown), so the screen stayed black; killing the extension
  brought the background back (a still, the extension not relaunched). Earlier the same day the first user's first
  frame took 28 s: the wallpaper shows only when its first frame beats that 60 s.
  Recorded the same day (a third user's first login, venera-videod -v, 400 messages; tools/pvhost fed them, now
  answering Demt with PVHOST_ANSWER_DEMT): the aerials' still frame is a synchronous decode with an output handler,
  and Apple's host answers it Dbuf, then Demt (decode order, inf 0, a 544-byte dp2), waits for the guest's answer to
  the Demt, and only then answers the dfrm (inf 0): the handler has the frame before the call returns. A real Mac does
  the same (a test tool, vtsync: 7 of 8 frames in their own call, decode order). Ours answers the dfrm at once with
  Asynchronous and the frames come later in display order (0 of 8 in their call), so the wallpaper decodes the next
  sample, and the next, through the whole movie, 170 frames a second, and never has a still. The experiment patch
  gets inf 0 and decode order but still a call late: VideoToolbox runs the handler on its serial
  "paravirtualization.guest" queue, which also sends the guest's answers, so while VeneraVideo holds the sync send
  (inside VideoToolbox's send lock) that queue waits, and the frame comes after the call. The hold exists for
  VideoToolbox's wait: VTParavirtualizationReplyClerkWaitForReply (+0xb2) takes the timeout's nanoseconds with
  cvttsd2si r14d (32-bit), and dispatch_time gets movsxd rsi, r14d (+0x102): 10 s overflows. Two same-length edits
  fix it (f2 44 0f 2c f0 -> f2 4c 0f 2c f0; 49 63 f6 -> 4c 89 f6). With that fixed in a process, the send needs no
  hold, and the host can answer as Apple's does. Not built yet: the patch (in-process from the Metal plugin, or
  system-wide), the kext told which senders wait properly, and videod's synchronous path (decode order: FFmpeg's
  HEVC holds frames for reordering).
  Built the same day (20aebfc): VGMTLVTFix.m, VeneraVideo 0.2.2's marker client, videod's Apple-style answer. VM 108's
  test tool: 7 of 8 frames in their call; VM 109's wallpaper (a new login): its player layer ready in 1.3 s. But
  the login screen stayed black: the background there is a copy WallpaperAgent exports to /var/db/Wallpapers/UUID
  from the extension's VideoPlayer snapshot, and AVAssetImageGenerator's stills were black on Venera before any of
  this (also with the fix off): VideoToolbox's Metal transfer (VTMTSComputeFunction) reads a 3840-wide x420 plane as
  a 960-wide RGBA16Unorm texture (the same 7680-byte rows) and the driver refused the texture. And videod's first
  synchronous path (drain + replay per frame) was OOM-killed under the generator: dozens of synchronous frames in a
  row, each replaying the GOP, and past 64 suppressed frames the replays' output piled up as 4K frames. Replaced by a
  per-packet AV_CODEC_FLAG_LOW_DELAY and an FFmpeg patch (hostvideo/patches/0001: HEVC hands a frame out at its
  frame end, decode order), no drain.
- **0.1.10 released (2026-11-20, v0.1.10 on f28a5e7, a full release, Latest).** The moving wallpaper's first frame
  (VideoToolbox's reply wait corrected in-process, VeneraVideo 0.2.2, videod's Apple-style synchronous answer with an
  FFmpeg low-delay patch), every function constant to the translator (black video stills and login-screen
  background; the installer redoes old black copies once), the login window on the GPU and its list's pictures
  (integer regroupings of a surface plane), Dock badge numbers (buffer textures one level), Core Image libraries read
  lazily (icons 13x faster), the host service's MemoryMax 2G -> 6G, Finish waiting for macOS's restart, the Tools CD
  kept in the VM. VMs 108, 109 and 107 upgraded one at a time from the private kit (each Upgrade run as its own
  systemd unit: one started from an SSH session died with it); 107's agent couldn't take the package, the USB disk
  did. VM 108 lost its mouse after its restart: two tablets (Proxmox's and the args'), fixed with --tablet 0 and in
  Upgrade since (004fb03, after the release).

### 0.1.11 (2026-11-20)

- **0.1.10's Memoji came out striped and mixed up** (Setup Assistant's account step, Users & Groups' picture picker):
  the surface-plane regrouping that let VideoToolbox convert the login list's pictures on the GPU (d3995dd) gave the
  regrouped image stale pixels, being kept in step with the surface only through its CPU bytes. Reverted (7ba5122);
  the login list's small pictures (two or more users) are missing again until a surface's images are kept in step
  on the GPU. VM 108 with only the revert: clean.
- VM script: an Upgrade turns Proxmox's own tablet off when the args bring one (two tablets: the console's mouse went
  to the one macOS wasn't reading); a new VM under a removed VM's name replaces its unused OpenCore image.
- Released as v0.1.11 (8bbac3f). VM 109's Upgrade stopped after the install: the package's agent swap took the
  installer's answer with the old agent (fixed after the release, 1099a4a: the result is read from a file).

### 0.1.12 (2026-11-21)

- **Screen Sharing left trails behind a dragged window**; Proxmox's console didn't. Screen Sharing reads SkyLight's
  display stream ("DisplayStream surface N/8", two surfaces written in turn in display command buffers) on the CPU
  as soon as commitAndWaitUntilSubmitted returns. Written every frame, they fell under the rule that stops waiting
  for a surface's write-back after 10 frames in a row (meant for CoreDisplay's scanout surfaces): their pixels came
  back ~25 ms later and Screen Sharing sent the changed parts of an older frame. Found with `synclog` and a test
  switch that waited for every write-back (no trails); only scanout surfaces (CreationProperties IsDisplayable) skip
  the wait now (fbe1e5e). VM 107 over Screen Sharing: no trails, as smooth.
- **The Memoji picker still showed 0.1.10's striped Memoji** under 0.1.11: it saves a picture of each animal in
  `~/Library/Caches/Animoji` and shows it again rather than drawing it. The installer moves them aside once
  (85d9970).
- VM script (ca454ef): HA's VMs are stopped through HA (a shutdown from macOS made HA start the VM again at once,
  and a config change went in as pending); Upgrade moves a guest agent on the ISA serial port (ten times slower,
  dropped requests of a few KB) to its virtio port, its restart then a shut-down and a start.
- Released as v0.1.12 (a080cec). Open: the login list's pictures, a DockHelper shader the translator refuses
  (`llvm.fmuladd` on `<3 x half>`), Screen Sharing's frame rate (measure), speed.

## Round 23 (2026-11-21): what still doesn't draw, speed, Screen Sharing

The owner's list: fix what doesn't draw (the login window's small user pictures with two or more users, a DockHelper
shader the translator refused), then sweep for more; Screen Sharing smoother (measure first: what limits it, and
whether the display's refresh rate matters); closer to a real Mac's speed. Not HDR.

- **DockHelper's refused shader doesn't come back.** It is RenderBox's `accumulator_color_fragment` (default.metallib,
  one function constant: a `uint4` blend state, `_shader_state`), refused once on VM 108 on 2026-11-20 at 12:58 by a
  development build ("declare without params: declare <3 x half> @llvm.fmuladd": the text ended mid-line). With the
  driver's own text of it (shaderdump, VGMTL_NODISKCACHE=1) and 0.1.12's translator, 3,300 constant sets (random, and
  random bit patterns) translate, on the Mac (tools/xlfc against a translator built for the Mac from the patched copy)
  and in VM 108 (tools/mtlpipe, MTLPIPE_FUZZ); none has been refused since 0.1.10 on 108. The faildump flag file stays
  on for DockHelper and Dock on 108 to catch it if it does.
- **The login window's user pictures, the GPU way (bd7a68f).** VideoToolbox's Metal transfer reads a 512-wide BGRA
  plane as a 128-wide RGBA32Uint texture; 0.1.10 took such regroupings with only the surface's CPU copy between the
  plane's images (stale reads: 0.1.10's striped Memoji), 0.1.11 refused them. Now the images of one surface plane are a
  group: a submitted GPU write makes its image the newest, an image behind it is copied from it on the GPU (image ->
  staging -> image, deferred work ahead of the next submit) before its use, and a write-back counts for the siblings
  too. Found on the way: a write-back copied the image in the surface's element size, which a regrouping's 16-byte
  texels overran. tools/mtlregroup (write through one, read at once through the other, both ways, ten rounds without
  waits, then the CPU copy): PASS on VM 108; with the nosibling flag (0.1.10's sync) all four checks fail. With
  WindowServer on the build: the Memoji picker clean through RGBA32Uint regroupings (saved pictures moved aside), a
  10-bit Tahoe Day still the same as the CPU's decode (tools/vtstill: brightest 689 vs 690, mean 363 vs 364), a window
  drag's synclog one pull and no sibling copies. The login window with two users (a second one added on 108): both
  small pictures show.
- **Sweep (1c)**: VM 108 opened every app in /Applications, /System/Applications and Utilities for 12 s each (not the
  ones that sound, record, log out or restore), every System Settings pane, Mission Control and Quick Look, on the
  build above. No shader refused, no translation failed, no LENIENT selector. Left: QuickTime Player and the Memoji
  editor ask for a normalized regrouping (RGBA8Unorm over a 1-byte plane, 180x720 of 720x720), still refused, so
  VideoToolbox converts on the CPU (0.1.10 saw such a regrouping "come out wrong", likely the stale-image bug: try it
  now); Contacts logs "Apple's stitcher failed" (function stitching); four helpers without a device
  (VTDecoderXPCService, efilogin-helper, Safari's platform helper, LocalAuthenticationRemoteService).
- **System Settings' panes feel slow**: each pane is its own process, and the driver's device takes 0.2-0.4 s of it
  (load -> Vulkan device on VM 109: General 0.40 s, Users & Groups 0.33, Sharing 0.23, Network 0.19), nearly all in
  Venus' instance and device creation. No translations in them; iconservicesagent's icon work ~0.4 s of driver time
  over two minutes. A start-up to make shorter for every process.
- **Screen Sharing, measured (VM 109, the owner connected from a Mac on the LAN, 0.1.12)**. Not CPU: over 100 s of
  drag, scroll and video, WindowServer used 25 % of a core, screensharingd 6 %, ScreensharingAgent 3 %; no
  VideoToolbox encoder session (videod saw only the video's decode). ScreensharingAgent: 2,741 frames in its first
  82 s (~33 a second), capture latency 131-232 ms, mean 189. The same 10 s scripted drag (tools/dragtest, qmpinput):
  alone, frame gaps mean 17.5 ms (584 of 628 at one VBL), commitAndWaitUntilSubmitted waits 0.15 ms; sharing, mean
  23.5 ms (~42 fps, 202 of 444 at one VBL, 156 at two), waits 2.37 ms each, about 1,800 of them in the run. So 0.1.12's
  wait for the display stream's CPU copy (the trails fix) costs WindowServer a quarter of its frames while sharing.
  The login failures first that day: screensharingd's RSA-SRP said "client evidence does not match" for the right
  password, also after the password was set again; a restart of the VM (a fresh screensharingd) took it.
- **The refresh rate doesn't matter here (framebuffer 0.6.3: `vgpuvblhz=N`, 24-240, runs the VBL timer at N for
  measuring; the modes still say 60).** VM 108, the same 10 s scripted drag (tools/drag-perf.sh): at 60 Hz mean frame
  gaps 18.9 and 17.7 ms; with the timer at 120 Hz (2,400 VBLs in ~21 s, checked) 17.7 and 17.6 ms, the gaps still
  15-18 ms: WindowServer paces to the mode's 60 Hz, not the VBL. Each display frame's command buffer takes ~10 ms
  commit to done, Screen Sharing captures ~33 a second and Proxmox's console shows ~33, so a mode above 60 Hz isn't
  worth advertising. Not tried: 30 Hz (it can't change that answer).
- **WindowServer waits only for the write-backs now, not the whole completion**, in commitAndWaitUntilSubmitted
  (handlers and clean-up no longer in it). Measured on VM 109 in one sharing session, the same scripted drag: 0.1.12
  mean frame gaps 32.8 and 32.3 ms, waits 3.7-3.8 ms each; the new build 30.7-31.8 ms (4 runs), waits 3.7-4.1 ms:
  about 1 ms better, within the noise. Without sharing 17.5 ms either way. The morning's session had shown 23.5 ms
  sharing: the cost depends on the session (the viewer's window or quality, likely), and in this one sharing nearly
  halves WindowServer's frames. What it waits for is the GPU finishing the frame. A Mac doesn't make WindowServer
  wait: the reader's IOSurface lock waits for the GPU. Next: have the accelerator kext make a reader of a surface
  with a pending write-back wait for it (IOSurface lock), and drop WindowServer's wait for the display stream. A
  Cmd-Shift-3 screenshot on VM 108 with the new wait: whole.
- **The reader waits instead of WindowServer (the Mac's way), built, off by default** (VGMTLLockWait.m, the lockwait
  flag file). In a reader process IOSurfaceLock -- an exported stub (NULL check, the surface's client, a tail jump)
  -- is replaced by a copy that first waits while a display-stream surface is marked "write pending"; the reader tags
  the stream's surfaces, and only for tagged ones WindowServer marks pending at the write-back's recording, clears it
  once it's in, and doesn't wait. tools/mtllockwait (the handover in one process): with it commitAndWaitUntilSubmitted
  0.25 ms and the lock 2.45 ms, without it 2.6-2.9 ms and 0.01 ms; no stale reads either way. The write-back's own lock
  is AvoidSync now (it is the pending write). VM 109, owner connected: a moderate scripted drag 25.2 ms frame gaps
  (WindowServer waiting) against 17.6 ms (reader waiting), the agent's frames more even (91-93 % of gaps under 20 ms
  against 75-87 %); fast sweeps of a large window ~33 ms and the same stalls both ways. The owner: no difference he
  could feel, "jittery" both ways, and once more pauses during fast drags with the reader waiting. So it stays off.
  Its two flaws to fix before trying again: the mark is one flag, so a lock can wait for a newer write than the frame
  it was handed; and the reader polls (100-500 us sleeps) instead of being woken. The jitter itself is WindowServer's
  frame time with a large window moving fast (~33 ms, uneven), sharing or not: the speed work.
- **Speed: CoreDisplay's scanout surfaces no longer copied back to CPU memory (0.1.13).** WindowServer keeps six
  1280x800 "CoreDisplay Scanout" surfaces (IsDisplayable); the display reads them through their twins. In a fast drag
  (tools: fast108 in the scratch helpers, dragtest swept 0.4 s corner to corner, 13 sweeps) two of them, never shown
  yet, were written back every frame (570 copies of 3.9 MB in 5 s) and waited for whenever a pause restarted the
  10-frame rule: commitAndWaitUntilSubmitted 2.62 ms a submit. Now a scanout surface has no CPU write-back and no
  wait, shown or not (screenshots read SkyLight's CaptureSurfaces, which keep both; the flag scanoutwriteback brings
  the old way back). VM 108, the same fast sweeps: mean frame gap 27.3 -> 21.4 ms (twice), frames at one VBL 86 of
  242 -> 212 of 316 and 219 of 318, the wait 2.62 -> 0.02 ms, write-backs 570 -> 1. Three Cmd-Shift-3 screenshots
  whole. Next seen: a command buffer's GPU work is 1.8 ms (timestamps) but commit -> done 10.8 ms.
- **Where a fast drag's frame time goes (VM 108, open).** tools/qmpinput.py `sweep` (one press, the window swung
  corner to corner, no pauses): mean frame gap 18.5 and 23.8 ms in two runs (the host's GPU is shared with VM 107:
  noisy). A command buffer: 1.7 ms of GPU work, 10.7 ms commit -> done; an idle round trip 1 ms (tools/mtllat); the
  in-flight depth (3, 6, 10, 16) changes nothing; WindowServer ~35 % of a core, mostly waiting. On the host,
  WindowServer's virgl_render_server ring thread (vkr-ring) ran ~49 % of a core during a sweep, the vCPUs 16-33 %,
  QEMU's main thread ~23 %: nothing saturated. Next: find what serializes the ~9 ms (the ring thread's decode of
  ~10,000 descriptor-set writes a second, the guest's fence polling in vn_relax, the completion thread's in-order
  handling), then the per-process device start-up (0.2-0.4 s), then the reader wait's second try.

### Round 23 continuation: profiling, device startup and reader waits

- The pinned Venus source polls in both fence modes. With feedback it reads the shared slot. With feedback off
  it calls the host for fence status before each backoff. The Metal driver's old comment described an interrupt
  wait that this path does not use. The new `perf` counters split commit preparation, `vkQueueSubmit`,
  completion dispatch, predecessor-status waits, fence probes and fence backoff. `gputime` also reports clock
  calibration uncertainty. The pre-GPU interval still includes host command processing and queueing behind
  earlier GPU submissions. Treat descriptor writes as a candidate until host-side measurement distinguishes them.
- Venus used to query physical-device groups twice on first enumeration, even for Metal, which only asks for
  a single device. Group enumeration now runs on the first actual group query. `initperf` logs the device startup
  phases for comparison. The two saved round trips are confirmed by the call paths. Their elapsed time on a
  guest is still to be measured.
- The opt-in Screen Sharing experiment uses Darwin notifications to wake a reader and pins the generation visible
  at lock entry. Each surface can have one deferred write. Overlapping writes keep the writer wait, and a deferred
  write has its own staging buffer so later submits cannot replace those bytes before the CPU copy. The hook sees
  the IOSurface, so it cannot match the lock to SkyLight's earlier frame handoff. If a later generation was already
  pending when the lock started, that ambiguity remains.

Guest checks pending:

1. On VM 108, repeat the same continuous sweep on the previous build and this one. Run with `perf` only, then
   with `perf` and `gputime`. Repeat with fence feedback on and off, restarting WindowServer between flag changes.
   Compare frame gap distributions as well as the host-probe and backoff totals per submitted buffer. Use the
   calibration uncertainty when comparing pre- and post-GPU times. If most of the residual is pre-GPU, profile the
   host ring thread's descriptor updates and queue submissions during the same sweep.
2. Time fresh process starts on VM 108 with `initperf` and compare the physical-device phase on the two builds.
   Repeat across several startups of the same Settings panes and compare the total startup as well.
3. On VM 108, run `mtllockwait` with the flag off and on, and verify a Cmd-Shift-3 screenshot. On VM 109, with a
   connected viewer, compare fast sweeps and scrolling with `lockwaitmeasure` first and reader waits second. Look
   for stale frames, trails, visible pauses and lock timeouts alongside WindowServer's frame gaps. Keep the
   experiment off until that comparison succeeds.

### VNC output and the next Settings startup experiment

- `python3 tools/vncgrab.py 108 10 --timings` on the Proxmox host times QEMU's raw incremental VNC updates,
  without converting frames or writing images between requests. Its JSON separates the initial full update
  from steady update gaps, receive duration, and raw pixel payload bytes. It measures a host-side raw VNC
  client. It does not include browser decoding or the user's network path.
- For an A/B run, collect WindowServer transaction gaps and flip durations with `acceltest pace` while the
  same `qmpinput.py sweep` runs. Compare with host-side VNC gaps and with what the viewer shows at the same
  guest resolution. Repeat in separate runs so a raw capture does not add load to the browser's measurement.
  Long guest gaps point to the driver. Smooth guest gaps followed by long VNC gaps point to the host display
  path. Smooth host VNC gaps followed by uneven viewer output point to encoding, delivery, or presentation.
- `skipsoftware` is a separate startup experiment for the bundled Venus ICD. It still does the renderer's
  initial properties query to identify CPU devices, then bypasses their extension, features, memory and queue
  queries. Metal had already rejected CPU devices after Venus completed that work. Compare `initperf` and
  click-to-usable time across cold opens of the same Settings panes with `skipsoftware` off and on. Repeat
  with an already running pane to see how much of the remaining delay comes from process startup.

### Round 23 VM comparison prepared locally

- Built three signed x86_64 bundles and deployment archives under `build/round23/`, using the same SDK,
  pinned Mesa 25.0.7 and translator for each. `baseline` is `91a9888` with Mesa patches through 0008.
  `timing-control` uses the updated Metal bundle with Mesa through 0009, so it logs `initperf` while keeping
  eager group queries. `patched` uses the same Metal build with Mesa through 0011. With `skipsoftware` off
  it measures deferred group queries. With the flag on it also skips the CPU device's full capability queries.
- The raw VNC timing and PPM capture paths passed local RFB fixtures, including an idle connection and a
  stall after the first update. The simulated reader hook passed generation wake, timeout, failure, and
  AvoidSync checks. The local sandbox could not create an IOSurface for the cross-process check.
- On VM 108, confirm the 1280×800 display and the active Metal bundle and ICD before each build's runs.
  Repeat the same `dragtest` window and QMP sweep, then use `dragtest`'s scripted scroll with identical timing.
  Reset `acceltest pacereset` just before motion and collect `acceltest pace` as it ends. Run without a viewer
  first, then with `vncgrab.py --timings`, then with only noVNC connected. Repeat runs and keep the browser
  scale, viewport and quality fixed. Compare frame-gap distributions and flip times with the raw update gaps
  and browser presentation separately. Use `timing-control` and `patched` with matching `perf` and `gputime`
  flags for the Venus counters, and keep the reader-wait flag absent during the console work.
- For System Settings, use General, Users & Groups, Sharing, and Network. Count a cold open only when the
  pane runs in a fresh process, and a repeat open only when the pane keeps the same process. Pair the click
  with the first complete visible pane and a responding control, then match its process to `initperf` in the
  timing builds. Confirm the actual bundle loaded by each pane. If its sandbox rejects the dev copy, take a
  VM 108 snapshot before using the system-volume bundle path. Keep the click-to-usable and device-phase
  timings separate.
- The local shell was denied outbound SSH before authentication. Guest baseline, patched timings, and the
  VM 108 screenshot and reader-wait regressions are pending. VM 109's live Screen Sharing A/B follows those checks.

### Round 23 continuation, measured on VM 108 (2026-11-21)

Builds (signed x86_64 bundles; the loaded MacOS binary and ICD checked by hash in WindowServer before each run, the
display 1280x800): `baseline` (91a9888), `timing-control` (Mesa through 0009), `patched` (through 0011), then
`ringidle` (0012), `nulls` (`build-mesa.sh` binds the optional entrypoints to NULL at link time) and the `-fs`
variants (today's Metal code with `framesig`, each with one of the three ICDs). Motion: `dragtest`'s window swung
corner to corner 8 times in one press (`qmpinput.py sweep`, 0.4 s each way) and `dragtest`'s scripted scroll,
`acceltest pace` around each, no viewer unless said.

- **WindowServer during motion** (mean frame gap; commit -> done per command buffer): baseline sweep 20.0 / 23.0
  ms, scroll 18.1 / 18.9 ms; timing-control sweep 18.6 / 17.7, scroll 19.3 / 19.3; nulls sweep 18.1 / 17.9,
  scroll 18.4. Commit -> done ~10 ms in sweeps, ~7 ms in scrolls, unchanged by every build.
- **The ~9 ms outside the GPU, split** (timing-control, `gputime`, calibration error 0.05-0.4 ms): sweep commit ->
  GPU start 7.2-7.5 ms, GPU 1.75-1.85 ms, GPU done -> seen 1.7-2.1 ms; scroll 5.0 / 1.6 / 0.6 ms. Ruled out, each
  measured: fence polling (without feedback ~24 host probes per command buffer at 0.17 ms; with feedback probes cost
  0.008 ms but the wait and the frame gaps are the same); the host ring thread going to sleep (`ringidle` 20 ms
  instead of 1: commit -> start 7.0-7.7 ms, no change; the ring thread ~55 % of a core in motion); the shared host
  GPU (another process's small command buffers round-trip in 1-1.5 ms during a sweep, as idle); per-draw decoding
  (`tools/mtldraws`: 2,000 draws add ~1.2 ms, ~0.6 us a draw); a backed-up ring (WindowServer's synchronous probes
  take 0.16 ms). What is left is WindowServer's own command buffers queueing on its host queue; it isn't what
  limits the frame rate (50-57 fps in these sweeps).
- **The console's limit is QEMU's VNC, not the driver.** Raw VNC on the host during the same sweeps
  (`vncgrab.py --timings`, no browser): 28.5-30.4 updates a second, gaps median 31.6-32.6 ms, p95 39-60 ms, a few
  0.19-2 s stalls; each 4 MB update received in ~3 ms. QEMU refreshes VNC every ~30 ms. noVNC in Chrome on the same
  LAN (0.35 ms ping), measured by wrapping the canvas draws: gaps median 33.4 ms in a sweep, **66.6 ms in scrolls
  (~15 fps), with the raw client getting 30.4 updates a second at the same moment**. noVNC asks for the next update
  only after drawing the last, so each frame costs two of QEMU's ticks. Not the browser (no long tasks, no late
  animation frames), not the relay (`pveproxy`, `qm vncproxy` under 3 %), not QEMU's VNC encoder thread (9 %), not
  JPEG (quality 9 and 2 gave the same 66.6 ms). Options are the owner's: a shorter VNC refresh in QEMU, a noVNC that
  asks for the next update as one arrives, or another console path (SPICE).
- **Loading the Venus ICD cost 130-370 ms in every process** (`initperf`; `dltime` in fresh processes: 130-146 ms
  each, lazy or immediate binding, any path, the released 0.1.12 copy too; a trivial ad hoc dylib 0.3 ms, with IOKit
  and libz 4 ms). Mesa's entrypoint tables reference ~1,543 optional entrypoints weakly and rely on missing ones
  being NULL; linked with `-undefined dynamic_lookup`, dyld searched every loaded image for each at every load.
  `build-mesa.sh` now defines each one still missing after the first link as a private absolute symbol at 0 and
  links again: binding info 64,688 -> 128 bytes, nothing left to dyld, the tables NULL as before. ICD load 1.7-3.2 ms
  in every process on 108 (WindowServer, mediaanalysisd, the panes, the tools); mtlprobe, mtlregroup, mtlsurface,
  mtlrender, mtlcompute, mtlatlas pass.
- **System Settings, cold opens** (General, Users & Groups, Sharing, Network; 2 rounds; the click to the screen
  settling, from `framesig`): timing-control 854-1505 ms with device setup 198-405 ms (ICD 167-374); patched 837-879
  ms, device 195-311 ms; patched + `skipsoftware` 844-913 ms, device 186-326 ms; nulls + `skipsoftware` 816-937 ms
  (one 2.6 s), device 24-37 ms (ICD 1.7-3.2). The device setup is 7-10x shorter, but the pane is not visibly ready
  sooner: it settles at ~0.85-0.9 s in every build, so the device isn't on the path to the first finished frame.
  `skipsoftware` and the deferred group queries: no measurable effect (the physical-device phase is 4-8 ms either
  way). Repeat opens of a running pane settle in 120-340 ms, with outliers (Sharing 1.7-7 s, Users 1.1 s).
- Regressions on 108 with the working tree: `mtllockwait` (60 rounds, twice each) with the reader wait off: commit
  3.7 ms, lock 0.02 ms, 0 stale; on: commit 0.2 ms, lock 3.1-3.4 ms, 0 stale, 0 timeouts. Three Cmd-Shift-3
  screenshots whole.
- **Screen Sharing A/B on VM 109** (the candidate build: today's working tree with the nulls ICD; the owner connected
  from a Mac on the LAN; ScreensharingAgent hooked either way, `lockwaitmeasure` for A): the same continuous sweep
  and scripted scroll. Sweeps, A (WindowServer waits): mean frame gap 19.9 / 23.3 ms, 223 of 353 and 117 of 298
  frames at one VBL, WindowServer's wait 1.6-5.8 ms a submit, the agent's frames 91 % / 80 % under 20 ms apart; B
  (the reader waits): 17.6 / 17.4 ms, 348 of 396 and 353 of 396 at one VBL, the wait 0.04 ms, 96 % / 95 % under 20 ms;
  the agent's locks waited 2.4 ms on average (max 22-50 ms), none timed out in ~2,000. Scrolls about the same either
  way (A 20.0-20.1, B 21.2-22.8 ms). The owner, watching B then A: no trails in either; B "may have looked slightly
  smoother", close. The reworked reader wait (a pinned generation, a wake-up notification) has none of the first
  version's 50-70 ms waits or pauses. It stays off by default pending the owner's decision.
- **The reader wait is on by default** (a635169, the owner's call): ScreensharingAgent waits for its frames and
  WindowServer doesn't; `nolockwait` turns it off. VM 108, `mtllockwait`: not a listed reader 3.65 ms commit + 0.02
  ms lock, listed 0.21 + 3.00 ms, listed with `nolockwait` 2.89 + 0.01 ms; no stale reads.
- **Retina sizes, VM 109 at 2880x1800 ("looks like 1440x900"), the owner connected over Screen Sharing.** The owner
  noticed it crawls. A real window drag (the sweep re-aimed for 1440x900 points; the first runs only moved the
  cursor): with WindowServer waiting, mean frame gap 107 ms (~9 fps); with the reader wait 47-50 ms. SkyLight also
  writes a full-screen **"Selective Sharing"** surface every frame while sharing; ScreensharingAgent never locks it
  (the `locknames` flag: it locks only "DisplayStream surface N/8"), so it is a GPU-side source of the stream's
  frames. It was copied back (20 MB) and waited for every frame. Now it has no write-back and no wait
  (`selectivewriteback` brings them back): Retina sweeps 36-40 ms, WindowServer's waits 4.5-6.8 ms a submit (from
  6-25 ms); the owner: Screen Sharing looks right. What remains at Retina: a command buffer's GPU work is 2.8-3.2 ms
  but commit -> GPU start 26-30 ms and GPU done -> seen 17-21 ms (`gputime`). Not QEMU's readback for the console
  (`acceltest flipms 33` halved the flips, frame gaps and latencies unchanged), not QEMU's CPU (main thread 35 %,
  the render server 35 %). Open: what in the host's path scales with the ~20 MB surfaces.

### 0.1.13 (2026-11-21)

- Released as v0.1.13 (bb0a5d4, Latest), the owner's OK: the Venus ICD bound at link time (GPU processes start
  130-370 ms sooner), scanout surfaces and SkyLight's Selective Sharing not copied back, Screen Sharing's reader
  waiting instead of WindowServer (on by default), the login window's user pictures (a surface's images kept in step
  on the GPU), framebuffer 0.6.3 (`vgpuvblhz`), and the measuring flags (`initperf`, `framesig`, `ringidle`,
  `locknames`, `lockwaitmeasure`). The owner's kits on both nodes are a private 0.1.13 with the seed (0.1.12's kept
  beside as kit-0.1.12). Open: Retina sizes (GPU work ~3 ms a command buffer, but ~45 ms through the host and back).
- **Retina on VM 108 (2880x1800, `tools/modetest W H 0 2x` now saves the mode), no Screen Sharing.** Sweeps 33-36 ms
  between frames (17.8 at 1280x800), scrolls 20-22 ms. GPU work per command buffer 3.3-3.6 ms, commit -> done 48-57 ms,
  completions dispatched 39-40 ms after commit; a Venus fence probe 1.1-1.3 ms (0.13 at 1280x800). Fence feedback
  (probes free) helps a little: dispatch 32-35 ms, sweeps 32.7-33.7, scrolls 20.2. Another process's small command
  buffers still round-trip in ~1 ms (median) during a Retina sweep (spikes to 25-60 ms): the host GPU isn't
  saturated. Calibration-free, on the GPU's clock: **WindowServer's queue sits idle 7.3 ms before each command buffer
  at Retina (3.2 ms at 1280x800), for 3.5 ms of work (1.7 ms)**; display and other command buffers alike, so not
  implicit sync with QEMU's readback of the twins. A per-submission cost in WindowServer's own context that grows
  with the screen's size. Next: fewer host submissions per frame (WindowServer makes 3-4 command buffers a frame), or
  a host-side profile (`perf` on the node: the owner's call).
- **Not the images a context holds**: tools/mtlresident keeps 0 to 48 private 2880x1800 textures (to 949 MB), each
  drawn once, and a tiny command buffer still round-trips in 0.97-1.10 ms. So batching submits on a residency theory
  is unfounded. Ruled out for Retina's per-command-buffer wait, each by measurement: GPU work, a saturated host GPU,
  the ring's wake-ups, fence polling, QEMU's flips and console readback, implicit sync on the twins, held images.
  Left: something on the host side of WindowServer's own Venus context; needs a host profile (`perf` on the node,
  the owner's call).

### Retina drag slowdown (2026-11-21)

- On proxmox2, matching VM 108 drags measured 17.9 ms per frame at 1280x800 and 32.1 ms at 2880x1800.
  The guest's `vkQueueSubmit` returned in about 0.01 ms. Intel render-engine busy time was 47% and 43%,
  respectively. In the Retina host profile, 56% of CPU samples across the Venus ring and QEMU main threads landed
  in `kernel_init_pages` and `shmem_get_folio_gfp` under i915's execbuffer validation. GEM tracepoints counted
  1,574 render-worker allocations of the padded Retina image size (21,012,480 bytes) in a 6.5-second sweep.
- WindowServer's framebuffer-fetch fallback made blank images at the size of the render pass for missing
  attachments. These images are read-only and can share one explicitly cleared texture that covers the render
  area. On VM 108, with the same test bundle and the cache off, on, then off, mean Retina frame gaps were
  34.1, 18.6, and 36.4 ms. The render worker created 1,486, 1, and 1,378 Retina-size GEM objects and reported
  132,825, 2,768, and 123,894 page allocation events during the three samples.
- The signed development build with reuse enabled by default measured 18.4 ms at 1280x800 and 18.9 and 19.9 ms
  in two 2880x1800 sweeps. WindowServer stayed up through both modes. The Metal rendering probe passed, including
  framebuffer fetch, texture upload and readback, blending, and compute writes. Two 2880x1800 scanout captures
  showed the test window in different positions with intact contents. VM 108 returned to 1280x800 with the signed
  development build loaded.

### Scanout pacing audit (2026-11-21)

- VM 108 with the Retina texture fix. Driving a matched drag with 60 Hz and 120 Hz input gave mean WindowServer
  transaction gaps of 17.3 and 16.8 ms at 1280x800, and 22.6 and 17.8 ms at Retina. The in-guest display-link test
  delivered almost 60 callbacks per second at both sizes. Its Retina transactions were 17.1 ms apart and
  completed scanout flips were 20.3 ms apart.
- Temporary kernel tracepoints matched the surface and generation when Metal prepared a copy and observed its
  fence, and when the kernel queued and completed the display flip. In the steady part of the Retina drag, the
  original 12 ms post-flip wait produced 19.65–19.77 ms mean flip gaps and 30.56–32.03 ms p95 transaction-to-flip
  time. Counting the 12 ms from the flip's start gave 17.24 ms and 21.54 ms, respectively. The p95 wait for an
  eligible frame to start flipping fell from 15.75–16.38 ms to 2.35 ms. With a second Venus context copying a Retina image at 60 Hz,
  mean flip gaps fell from 19.44 to 17.18 ms and p95 transaction-to-flip time from 30.70 to 18.82 ms.
- At 1280x800, applying 12 ms start-to-start to every flip left mean gaps near 16.7 ms but raised p99 flip gaps
  from 20.24–20.74 ms to 23.28–25.03 ms across the two comparisons. The patch keeps the configured post-flip wait
  when the call fits in the remaining part of a refresh interval. It shortens the wait when the call has used
  more of the 60 Hz budget. An explicit throttle longer than a frame retains its full wait.
- The Retina scanout calls averaged 0.4–0.7 ms for `SET_SCANOUT_BLOB` and 5.8–6.5 ms for `RESOURCE_FLUSH` in the
  unloaded traces. An isolated 60 Hz texture-to-buffer copy on the same GPU took 1.25 ms at 1280x800 and 5.80 ms
  at 2880x1800. The isolated copy and the in-guest fence interval measure different workloads.
- A raw VNC client matched all 14 one-step window moves in each pacing mode. Median host input to changed
  console pixels was 96.6 ms with the original pacing and 102.5 ms with 12 ms start-to-start. VM 108 has no
  network interface, so LAN Screen Sharing remains to be measured. With the final build, the unmodified raw
  VNC receiver got 24.72 Retina updates per second during a continuous drag.
- The signed frame-budget build averaged 18.0–18.2 ms between Retina flips during drag, 18.1 ms during resize,
  21.0 ms during guest-driven scroll, and 18.0 ms during drag with the second Venus context active. Both warm
  1280x800 drags averaged 17.2 ms. The first 1280x800 drag after reboot hit 52 unready flips. Subsequent gesture
  checks and warm repeats had zero, and the cause of the early stalls remains open. The Metal rendering probe
  passed. Two scanout captures and a macOS shortcut screenshot at 2880x1800 showed intact window contents and
  exposed background after motion. VM 108 is back at 1280x800 with the final accelerator and original core loaded.

### After 0.1.14 (2026-11-21, evening)

- The owner's kits on both nodes are a private 0.1.14 with the seed (0.1.12's and 0.1.13's kept beside). VM 109
  upgraded to 0.1.14 by the VM script's Upgrade (its own systemd unit): package 0.1.14, framebuffer 0.6.3, the
  release Metal bundle with the link-time-bound ICD, Retina mode kept.
- **Retina on VM 109 with 0.1.14, nobody connected** (2880x1800, the sweep aimed for 1440x900 points): mean frame
  gap 17.8 ms in a sweep (it was 34-36 ms on 108 and 47-107 ms on 109 over Screen Sharing before the blank-texture
  reuse and the pacing fix), 21.2 ms in the scripted scroll; WindowServer's waits 0.01-0.8 ms.
- **The cold-start stalls are the boot's warm-up, not the first drag.** VM 108 (Codex's final build) restarted,
  the load left to settle, then two sweeps: 16.7 and 16.6 ms mean, 0 unready flips in either; the kext had counted
  8 unready flips during the boot itself, before any drag. A drag during the boot's background translation is what
  stalls. Display command buffers complete in ~2.0 ms on this build (10 ms on the morning's).
- **Shared Retina on VM 109: "very very slow" was animations, not drags** (the owner, connected over Screen
  Sharing). Scripted drags looked fine, but a genie (minimize) shared drew 16 frames 66 ms apart (37 frames, 21.8 ms
  alone). The synclog showed why: every surface written in a display command buffer got a twin, including surfaces
  the display never scans out -- SkyLight's display stream (2880x1800, every frame while shared), the window
  flattened for the genie ("flattened-surface", new each time: a fresh pair of host blobs), screenshots'
  "CaptureSurface". An isolated 2880x1800 clear plus write-back is 8-9 ms (`mtllockwait 60 2880 1800`, VM 108), but
  the stream's copy took ~29 ms from commit to done queued behind the frame's other work.
- **No twin for flattened-surface, CaptureSurface, Selective Sharing** (`vg_surface_never_shown`, flag file
  `VirtioGPUMetal-twinall` restores them, rechecked every 2 s). VM 109 shared, 0.1.14 -> this build: genie 66 ->
  34-38 ms a frame, scripted drag 41.5 -> 18.9 ms, scroll 41.7 -> 25.5 ms; alone the genie 21.8 -> 19.5 ms. VM 108
  (2880x1800, nobody connected): genies 22-25 ms, minimized windows' Dock thumbnails and a Cmd-Shift-3 screenshot
  intact.
- **The display stream keeps its twin.** Without it everything was faster still (genie 28-31 ms, drag 21.4) but
  the owner saw a dragged window leave trails in Screen Sharing (live A/B with twinall, then a per-name test flag:
  trails only when the stream had no twin). The VM's own screen (vncgrab) was clean, every stream write was copied
  back whole (115 of 115 in a sweep), the reader wait never timed out. Why the stream's twin copy prevents the
  trails is open: next, a content check in ScreensharingAgent's lock hook (what it reads vs the frame written).
- Measuring Screen Sharing from the client: `ffmpeg -f avfoundation` capture of the viewer window, changed frames
  counted per 1/60 s (with `-frames:v` and `-fps_mode passthrough`: without them a raw capture ran away to 85 GB).
  A scripted drag reached the viewer at ~40 updates/s. 108 sat at its lock screen after restarts: its frame counts
  then are the lock screen clock's, not a test's.

### Round 23, night (2026-11-21): Screen Sharing's trails looked for unattended; 1x against Retina

- **A stream reader with nobody connected** (ca5b0ac, `tools/streamprobe.m` + `streamprobe.sh`). Only Screen
  Sharing's agent has Screen Recording, and launch constraints let only Apple's own job start it, so the job's next
  launch gets the probe library (`launchctl debug --environment DYLD_INSERT_LIBRARIES=...`, AMFI off) and is
  kickstarted; no permission is granted. The probe keeps a client's picture from each frame's dirty rectangles and,
  when the stream stops, compares it with the last frame in 8x8 tiles; it also checks reads against WindowServer's
  stamps (below). **The agent uses ScreenCaptureKit, not CGDisplayStream** (`SCStream`, `SCStreamFrameInfoDirtyRects`,
  queue depth, minimum frame interval; it locks read-only, option 0x1). With the probe's SCStream read off its queue,
  WindowServer cycled all 8 "DisplayStream surface N/8" and wrote a GPU-only Selective Sharing surface every frame, as
  in the owner's sessions. As a stand-in for a viewer it matches: on the earlier test build at Retina, shared genie
  32.3 ms a frame (the owner's session: 34-38), sweep 19.0 (18.9).
- **No trails without the stream's twin, in ~40 runs** (VM 109, 1x 1440x900 and Retina 2880x1800; the twin switched
  live, `twinkeep` on the test build, then `twindrop`, confirmed by synclog's "twinned" marks): CGDisplayStream and
  ScreenCaptureKit, reads at once or off-queue 8-30 ms later, read-only and read-write locks, the reader not waiting
  (`nolockwait`: the writer waits then), six busy CPU loops beside it, the Dock changing (dragtest's icon, genies).
  `streamsum`: every stamped read matched what the write-back copied (443 reads, 0 differing, no seed moved, nothing
  changed while read). The stream's last frame at rest against the screen as QEMU's VNC shows it (below the menu bar,
  whose capture indicator goes with the stream): the same in 6 of 6 sweeps, 3 with the twin and 3 without. The only
  tiles that ever differed were faint ones on the Dock's glass edge (2-32 levels apart), with or without the twin.
- **In the owner's sessions the agent's locks never waited**: every `lockwait 5 s` line of the evening said "waits
  mean 0.00", so the agent reads a frame after its write-back has landed, and a stale read at the lock isn't the cause.
  Without the stream's twin, the stream's pixels are right as written and as read; the trails need the real pipeline
  (the agent's encoder and the network viewer). **Next, with the owner connected**: `: > VirtioGPUMetal-streamsum`,
  `echo DisplayStream > VirtioGPUMetal-twindrop` (both live), a drag, then the agent's `streamsum:` lines. Reads that
  match their write-backs while trails show would put the cause in the agent's encoding or the viewer, which the twin's
  extra GPU time only changes the timing of; reads that differ would show when.
- **New flags** (ca5b0ac): `VirtioGPUMetal-twindrop` (a surface-name piece a line; those surfaces lose their twin,
  live; the inverse of the removed `twinkeep`) and `VirtioGPUMetal-streamsum` (WindowServer stamps each tagged stream
  write-back with 16 band sums and its seed; the reader's hook checks against them and logs mismatches). The hook
  logs each reader's lock options once.
- **VM 109 has this build** (bundle d051cc500d72: ca5b0ac's code, but for a line wrap in `vg_streamsum_stamp`), the
  leftover `twinkeep` gone, `perf` the only flag. Measured with the probe as the shared reader (SCStream, read 8 ms
  off its queue) and alone; WindowServer's frame gaps, mean ms:

  | mode | sweep alone | genie alone | scroll alone | sweep shared | genie shared | scroll shared |
  |---|---|---|---|---|---|---|
  | 1440x900 Retina (2880x1800) | 18.2 | 20.5 | 22.0 | 20.8 | 30.6 | 24.3 |
  | 1280x800 1x | 17.6 | 18.9 | 17.1 | 17.2 | 18.4 | 20.0 |
  | 1440x900 1x | 18.3 | 18.9 | 19.6 | 17.3 | 19.1 | 19.6 |
  | 1680x1050 1x | 17.6 | 18.6 | 18.8 | 17.4 | 18.6 | 19.4 |
  | 1920x1080 1x | 22.1 | 18.6 | 18.0 | 20.6 | 18.7 | 19.4 |
  | 1920x1200 1x | 17.7 | 18.6 | 18.7 | 17.4 | 18.7 | 18.5 |

  Every 1x size holds about 60 fps shared too; Retina's genie shared is the outlier. The probe doesn't encode or send,
  so a real viewer's numbers will be somewhat higher. 109 is back at 1440x900 1x, the owner's choice since 21:08.
- **What System Settings offers** (109, Displays, screenshots through QEMU's VNC). Every mode carries macOS's
  Television flag (IOFlags 0x00100000, not the framebuffer's; the display's EDID is QEMU's), and Settings lists it
  the way it lists a TV's. Without "Show all resolutions": 3840 x 2160, 2560 x 1440, 1280 x 800 (Default), 1080p, all
  1x, and not the current mode. With it: 3840 x 2160, 2880 x 1800, 2560 x 1600, 2560 x 1440 (the framebuffer's modes
  2560 wide and more, at 1x: chosen in Settings, 3840 x 2160 gave a 1x 3840x2160 desktop), 1920 x 1200, 1920 x 1080
  (Retina, 3840x2160 pixels), 1680 x 1050, 1440 x 900 (Retina), 1440 x 900 (low resolution) (1x), 1280 x 800
  (Default) (1x), 1280 x 720 (Retina), 1024 x 768, 1080p (1x 1920x1080). So the 1x sizes are there already, but only
  under "Show all resolutions", and only the "(low resolution)" or "1080p" label says which is which; CoreGraphics'
  public list has no 1x mode above 1920x1200 (modetest: those modes appear only as Retina). Making the short list hold
  the common 1x sizes beside the Retina ones is a framebuffer change (each mode's flags: Always Show 0x8 on the common
  1x sizes, or dropping the TV treatment) that needs a look in Settings after it: VM 108 logged in, or the owner's OK
  for 109. Not done tonight: 108 was at its lock screen.
- **Tried on VM 108 the next morning (the owner logged it in; snapshot r23-1x-pre), neither moves the short list.**
  The TV treatment comes from QEMU's EDID: its CEA-861 extension lists TV formats (4K and 1080p codes). A display
  override with the same EDID less the extension (`IODisplayEDID`, the extension count 0, the checksum redone) took
  the Television flag off every mode (IOFlags 0x3/0x7) and "1080p" became "1920 x 1080 (low resolution)", but the
  short list stayed 3840 x 2160, 2560 x 1440, 1920 x 1080 (low resolution), 1280 x 800 (Default), and the full list
  the same 13. A test framebuffer then gave 1440x900, 1680x1050, 1920x1200 and 2880x1800 Always Show (0x8) and
  3840x2160 Not Preset (0x200), loaded as such (modetest: 0x0b, 0x00800203): neither list changed. System Settings
  makes its short list itself (the 16:9 standard sizes there are, and the default) and doesn't read the mode flags, so
  the framebuffer can't put 1440x900 or 1680x1050 in it. The common 1x sizes stay one switch away ("Show all
  resolutions"), the Retina ones the entries without "(low resolution)". The override was put back and the test kext
  replaced by the one before it (both at 108's next boot); nothing was committed. Taking the CEA extension out of
  the EDID would only change the names; if wanted, in the core kext (from whatever EDID QEMU gives), not as a fixed
  override, which would pin QEMU's 1280x800 preferred mode.
- **The owner's real complaint, and the fix (framebuffer 0.6.4).** Away from 1x 1280x800, Settings had no way back:
  its one "1280 x 800 (Default)" entry always picked Retina (2560x1600 pixels), while 1440 x 900 had both entries.
  macOS calls the EDID's preferred timing the default and lists the default size once, its 1x and Retina modes merged.
  On 108, step by step: taking Retina off 2560x1600 made 1280 x 800 1x-only (no Retina 1280x800); dropping the
  framebuffer's Default flag alone changed nothing (macOS set it from the EDID); an EDID naming 2560x1600 as preferred
  gave every size both entries ("1280 x 800" and "1280 x 800 (low resolution)"), but with the framebuffer's Default
  flag on 2560x1600 a fresh start (WindowServer's saved sets moved aside) came up in 1x 2560x1600; without any Default
  flag it came up in the framebuffer's own 1x 1280x800. `target-default-ppmm` in the override changed nothing. So
  0.6.4 rewrites the EDID's first timing to the Retina size of the host's size when that mode is offered (CVT reduced
  blanking at 60 Hz, the host's image size kept) and flags no mode Default then; a host size with no Retina twin
  (1920x1200, 2560x1600 itself) keeps its EDID. Checked on 108: a fresh start in 1x 1280x800; Settings lists 13 sizes
  with both 1280 x 800 entries; 1440x900 1x -> "1280 x 800 (low resolution)" -> 1x 1280x800, "1280 x 800" -> Retina,
  and back to 1x. Quirks: Settings calls 1x 2560 x 1600 the "(Default)", and its short list (TV-style, from QEMU's
  CEA extension) is 3840 x 2160, 2560 x 1600, 1920 x 1200, 1280 x 800. A saved mode may be dropped once when the EDID
  changes (108 came up in 1x 1280x800 after the first EDID change); not checked on an upgrade.
- **0.1.15, ready for the owner's OK** (not cut): 5d922cc (no twin for surfaces the display never shows: at Retina,
  shared, genie 66 -> 34-38 ms a frame and drag 41.5 -> 18.9 in the owner's session, genie 30.6 with the probe),
  mtllockwait's size argument, and ca5b0ac (off-by-default flags and tools). To cut it: VERSION and
  packaging/host/TESTED as 028f0c1 did, then `packaging/make-dist.sh` and the release, as for 0.1.14. With it goes
  framebuffer 0.6.4 (both 1x and Retina of every size in Settings, below).

### 0.1.15 (2026-11-22)

- Released as v0.1.15 (9a7c322, Latest), the owner's OK: no twin for surfaces the display never shows (5d922cc),
  framebuffer 0.6.4 (both 1x and Retina of every size in Settings, d6ed14c), the stream probe and the `twindrop` /
  `streamsum` flags (ca5b0ac), mtllockwait's size argument. TESTED re-recorded on both nodes (the same stack as
  0.1.14). The public assets were built by make-dist; the private build (the seed) stopped at make-host because Docker
  Desktop's engine answered 500, so the owner's kits are the public host directory with the private package and
  Tools CD in guest/ and SHA256SUMS redone (60.5 MB, as 0.1.14's); kit-0.1.14 kept beside on both nodes.
- VMs 109 and 108 upgraded from the kits by the VM script's Upgrade (each its own systemd unit). Both run
  framebuffer 0.6.4 (its EDID rewrite logged) and WindowServer the 0.1.15 Metal bundle (109 the kept copy, the
  link already on the system-volume copy; 108 the kept copy); their dev bundles removed. 109 kept the owner's
  1440x900 1x through the EDID change (the saved-mode reset feared in the release notes didn't happen); 108 is at
  1x 1280x800 (snapshot pre-0-1-15 before). VM 113 (never used) not upgraded.
- **VM 107 upgraded too** (the owner's word; its storage takes no snapshot). HelperPod came back with the session.
  It came up in 1x 2560x1600 (the EDID's preferred size): its saved sets (1920x1080 1x with IOFlags 0x100003, and
  1280x800 1x with 0x100007, both from 2026-11-21) weren't used. Put back to 1x 1280x800 with modetest (saved).
  Guessed cause, the Default flag 0.6.4 no longer sets: disproved on 108. A saved 1280x800 written under 0.6.3
  (0x100007) was kept after upgrading to 0.6.4, and also to a build that kept the Default flag (0.6.5, dropped):
  macOS doesn't show the framebuffer's Default flag on 1280x800 once the EDID names 2560x1600 anyway. Why 107 lost its
  mode is open (its pre-upgrade files were overwritten when its mode was set again). The release notes say one of
  three VMs needed its mode picked again. Restarted afterwards (the owner's word), 107 kept its 1x 1280x800 and HelperPod started.
- **The "31 MB VRAM"** in System Information is the framebuffer's scanout aperture (3840x2160x4 bytes), not what
  rendering uses: Metal reports `recommendedMaxWorkingSetSize` 2.67 GB (a third of the VM's 8 GB) and
  `maxBufferLength` 2 GB (mtlprobe, 109). Only apps that read System Information's VRAM figure could be misled.
- **Proxmox shows macOS VMs' RAM as full**: it takes `mem = total_mem - free_mem` only from a virtio-balloon device's
  guest statistics (PVE's QemuServer.pm `$ballooncb`), else the QEMU process's memory; Venera's VMs have `balloon: 0`
  and macOS has no balloon driver. A stats-only balloon driver is proposed as its own task.
