# Stages 4 and 5: Metal and an accelerated WindowServer on virtio-gpu (Venus)

Written 2026-11-15, from source reading only. Nothing here was run: no VM, no Proxmox host, no build.

Sources read:

- nullmoth/nvidia-macos-driver, HEAD `87e524a` (2026-11-13), cloned and read. Called **NV** below.
- steelbrain/reims-vgpu, HEAD `f378a38` (2026-11-15), cloned and read. Called **Reims** below.
- Our tree: `README.md`, `notes/PLAN.md`, `kext/VirtioGPUAPI.h`, `kext/VirtioGPUUserAPI.h`,
  `kext/VirtioGPU/VirtioGPU.hpp` and its `Info.plist`, `kext/VirtioGPUFramebuffer/VirtioGPUFramebuffer.cpp` and
  `Info.plist`, `mesa/NOTES.md`.

Evidence tags used throughout:

- **[V]** read in source. The path and a function name or line follow. Line numbers are NV `87e524a` unless marked.
- **[I]** inferred from source, from macOS behavior I know, or from the two projects agreeing. Needs a test.
- **[?]** unknown. A probe or experiment is named that settles it.

Paths starting `kexts/`, `plugin/`, `docs/`, `nvk/`, `translator/` are in the NV repo. Paths starting `guest/` or `docs/graphics-kext/`
with a Reims name are in the Reims repo.

## 0. The plan in one page

macOS gets a Metal device only when an `IOAccelerator` service in the registry names a Metal plugin bundle. The bundle's
class subclasses Apple's private `MTLIOAccelDevice`. WindowServer composites with Metal only when, in addition, its framebuffer has
an `AppleGraphicsDeviceControl` (AGDC) object on its PCI device and the accelerator offers a display pipe that accepts frame
transactions. NV and Reims agree on this and both ship it on x86 macOS 26 (NV tested 26.7.1).

NV's whole design, mapped to ours:

| NV piece | What it is | Our equivalent |
|---|---|---|
| `NVRM.kext` | NVIDIA's GPU driver, ported | `VirtioGPU.kext` (done: virtio core, Venus user client) |
| `NVRMFB.kext` | IOFramebuffer | `VirtioGPUFramebuffer.kext` (done, 2D scanout) |
| `NVAccel.kext` | `IOGraphicsAccelerator2` subclass, display pipe, surfaces | **new `VirtioGPUAccel.kext`** (AuxKC) |
| `NVRMAGDC.kext` | `AppleGraphicsDeviceControl` subclass | **new**, in the same kext or its own |
| `NVMTLDriver.bundle` | Metal device over Vulkan (30k lines) | **new `VirtioGPUMetal.bundle`**, forked and trimmed |
| NVK + `nvk-macos.patch` | Vulkan driver, talks to NVRM | Mesa Venus (done, runs on Iris Xe) |
| `libnvmtl_translate.dylib` | AIR to SPIR-V (metal2vulkan, LGPL) | same library, rebuilt |

Because NV already ships an Intel/AMD configuration of the same accelerator and plugin (`NMXAccel`, the plugin's
`0x8086` ANV path, "IOSurfaces are copied out to system memory"), most of what we need is a **headless, copy-only Metal device
for apps** (stage 4), then the same device **armed for WindowServer** with a display pipe that copies each composited
IOSurface into our framebuffer RAM (stage 5). Zero-copy scanout is a later optimization, not a prerequisite.

Order: 4.0 accelerator spike, 4a plugin loads, 4b compute, 4c render to texture, 4d IOSurface and present-shaped work, 5a WindowServer
picks the device, 5b composited frames on screen, 5c stability and speed. Rough total, one engineer part time: 3 to 5 months.
Section 6 has checkpoints; section 8 the top risks.

## 1. What the two projects do, and what we may copy

### 1.1 NV (nullmoth/nvidia-macos-driver)

`docs/HOW-IT-WORKS.md` [V] draws the stack: Metal app or WindowServer, then `NVMTLDriver.bundle` in `/Library/GPUBundles/`, then NVK
(Vulkan), then `NVRM.kext`, then the GPU. Beside that path, "WindowServer -> IOFramebuffer = NVRMFB.kext, IOAccelerator = NVAccel.kext,
AppleGraphicsDeviceControl policy = NVRMAGDC.kext". All four kexts are in `/Library/Extensions` and load from the Auxiliary Kernel
Collection, because they link IOGraphicsFamily and IOAcceleratorFamily2, "which only exist in macOS's own kernel collections"
[V `HOW-IT-WORKS.md` section 2]. That is the same reason our framebuffer is in AuxKC.

NV also builds the same accelerator for AMD and Intel GPUs (`-DNMX_ACCEL`, class `NMXAccel`) [V `nvrm-accel.cpp` L9-12, L129-135, L903-910].
In that mode the Metal device is "for apps; WindowServer draws into NMXGPU's framebuffer, and the plugin copies finished frames into
the IOSurfaces it reads". The plugin already has the matching code: vendor `0x8086` selects ANV
(`/Library/GPUBundles/nvmtl/libvulkan_intel.dylib`) [V `nvmtl_vk.c` L128-142] and `nvmtl_gpu_headless()` forces IOSurface copies
for any non-NVIDIA vendor [V `nvmtl_vk.c` L2824-2832]. This is the closest existing analog to our situation.

### 1.2 Reims (steelbrain/reims-vgpu)

A different route to the same macOS requirements, useful as a second witness:

- Its own PCI device and protocol; the Metal bundle streams Metal-level calls to the host, which decodes them with metal2vulkan
  [V `docs/graphics-kext/design.md` Decided 2]. We keep Metal translation in the guest, so none of that transfers.
- Its guest kext (`guest/kext/src/`) has the same three services on one PCI device: framebuffer, accelerator, device control
  [V `design.md` "Stage 3 accelerator kext" ~L4805, "Stage 3 device control" ~L5090].
- It documents several macOS behaviors NV does not (see 2.4, 3.6, 4.2).
- It states "IOAccel2 cannot start in a kernel where IOGPU runs" and builds on a ported IOGPUFamily stack instead [V `design.md` ~L4787].
  NV's NVAccel starts on x86 macOS 26.7.1 on real NVIDIA hardware. Which of these holds in our VM is the first question (3.1, risk 1).

### 1.3 Licenses

| Component | License | Consequence for us |
|---|---|---|
| NV `plugin/`, `kexts/`, `build/`, `package/` | PolyForm Noncommercial 1.0.0 [V `README.md` "License"] | Home-lab use is fine. Keep forked files in their own directory with the license text and per-file header. Anything we publish that contains them is noncommercial only. |
| NV `translator/` (metal2vulkan) | LGPL-3.0-or-later [V `README.md`, `NOTICE`] | Ship as a dylib the plugin dlopens, as NV does. Keep source and relink ability. |
| NV `nvk/` patches | MIT (Mesa) | Not used by us. |
| NV `kexts/NVRM/accel/re/*.h`, `iofam/*.h` (reconstructed Apple class layouts) | PolyForm NC | Same as above. They are reconstructions "read out of the binary" [V file headers]. NV's rules say "No Apple code" [V `DEVELOPING.md`]. |
| LLVM used by the plugin's AIR reader | Apache-2.0 with LLVM exception [V `NOTICE`, `docs/PROVENANCE.md` L41] | Fine. |
| Reims | GPL-2.0-or-later OR LGPL-3.0-or-later [V `LICENSE`] | Read for ideas. Do not paste into a kext: our kexts would become GPL/LGPL. |

Recommendation: vendor NV's headers and plugin files into `vendor/nullmoth/` unchanged, and write our own kext code. Our kexts then
stay our own license and only the vendored headers carry PolyForm. If this repo is ever published, revisit.

## 2. Question 1: what makes Metal.framework see a device

### 2.1 The mechanism [V]

Metal loads the vendor bundle from two properties on an `IOAccelerator` registry entry. NV's accelerator personality
(`kexts/NVRM/accel/Info.plist`):

```
IOClass                NVAccel
IOProviderClass        IOPCIDevice
IOPCIPrimaryMatch      0x000010de&0x0000ffff
IOPCIClassMatch        0x03000000&0xff000000
IOMatchCategory        IOAccelerator
IOProbeScore           100
MetalPluginName        ../../../Library/GPUBundles/NVMTLDriver
MetalPluginClassName   NVMTLDevice
```

Reims names the bundle bare (`MetalPluginName = reims-graphics`, bundle `/Library/GPUBundles/reims-graphics.bundle`) and says Metal
"does not scan that directory; it loads the bundle from two properties" found with `IOServiceMatching("IOAccelerator")`
[V `design.md` ~L4691-4698, ~L4815-4822]. NV's relative path resolves from `/System/Library/Extensions` to `/Library/GPUBundles`
[I]. Try the bare name first (Reims measured it on x86 macOS 26.6.1), the NV form second.

What the plugin receives: Metal allocates `MetalPluginClassName` (a subclass of private `MTLIOAccelDevice`) and calls
`-initWithAcceleratorPort:` with the accelerator's `io_service_t`. The plugin may return `nil` to decline. NV declares exactly that
[V `plugin/NVMTLDevice.m` L194-198, L947]. Metal.framework discovers devices by iterating accelerators and calling that init, so
`MTLCopyAllDevices` lists only what the plugin creates [V `docs/MULTI-GPU-DESIGN.md` L17: "`MTLCopyAllDevices` can list only what
the plugin creates"]. One caveat NV hit: returning nil before calling `[super initWithAcceleratorPort:]` crashed Metal's dealloc, so
NV keeps the half-built object alive instead (`nvmtl_refuse_before_init`, ~L938). Copy that.

The accelerator side must also be a real registered `IOGraphicsAccelerator2` (section 3). NV sets, after `IOGraphicsAccelerator2::start`:
`IOAccelRevision = 2`, `IOVARendererID = 0x01020000 | n`, `NVAccelSurfaceWait = 1`, calls `registerService()`, and later adds
`IOGLBundleName = AppleMetalOpenGLRenderer` [V `nvrm-accel.cpp` L865-880, L670-680]. Reims' list adds `AcceleratorProperties`
containing `IOAccelDisplayPipeCapabilities`, `DisplayPortCount`, `IOGVACodec`, `IODVDBundleName` [V `design.md` ~L4822-4830].

Recommended registry set for first boot of our accelerator: `MetalPluginName`, `MetalPluginClassName`, `IOAccelRevision=2`,
`IOVARendererID` (copy NV's form), `IOAccelDisplayPipeCapabilities` (only at stage 5, see 4.2). Skip the video and GL keys until needed.

### 2.2 Bundle location and layout [V/I]

- Directory: `/Library/GPUBundles/VirtioGPUMetal.bundle`, executable `Contents/MacOS/VirtioGPUMetal`, `CFBundlePackageType BNDL`,
  ad-hoc signed [V `finish_package.sh` L37-45, `build_plugin.sh`]. NV's bundle `Info.plist` is not in the repo, only referenced
  (`test_package_complete.py` L182: `CFBundleIdentifier`, `CFBundleExecutable`, `CFBundlePackageType`). No principal-class key is needed
  because the class name comes from the accelerator.
- Build line [V `build/build_plugin.sh`]: `clang -arch x86_64 -bundle -fobjc-arc -framework Foundation -framework Metal
  -framework IOSurface -framework IOKit ...` as a single `-bundle` Mach-O. Deployment target must not exceed the guest (NV's `-mmacosx-version-min=15.0`
  note: a plugin built with the 26 SDK default got `minos 26.0` and dyld refused it on 15) [V `build_plugin_release.sh` header].
  Ours runs only on 26, so default is fine.
- Files must be readable by `_windowserver`: root-owned, `go-w,a+rX`. NV hit a crash loop after install because a helper left an
  allow-list at mode 0600, so WindowServer got no device and "CoreDisplay aborted ('Failed to create MetalDevice') on every start"
  [V `package/install.sh` L472-477].
- The deployment path to the VM is the existing transfer disk; the bundle must end up in `/Library/GPUBundles` on the data volume.

### 2.3 Allow-lists: there is no Apple allow-list [V]

The "allow-list" in NV is the plugin's own: `/Library/GPUBundles/nvmtl-allow.txt`, read in `nvmtl_process_is_allowed()`
(`plugin/NVMTLDevice.m` L740-800). Format: one process name per line; `*` all; `-name` deny; `!name` allow only when the accelerator is
armed; plus hard-coded rules (WindowServer is refused on a headless GPU; `NVMTL_ENABLE` env overrides; `mtlprobe`, `nvmtltest` always
allowed). It exists to bisect and to keep WindowServer off an unarmed device. We should keep the same file format: it is the best
bring-up control we will have (turn the device on for one process at a time).

### 2.4 Trust, AMFI and SIP

NV needs, for WindowServer to map the bundle:

- `boot-args`: `amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0`, plus `Lilu.kext` and `AMFIPass.kext` in OpenCore
  `Kernel > Add` [V `README.md` "Install", `SECURITY.md` L21-25, `CHANGELOG.md`: "Without one, WindowServer refuses the Metal driver"].
  Their message: "WindowServer is a platform binary: with AMFI enforcing it refuses the Metal plugin ('mapping process is a platform
  binary, but mapped file is not')" [V `package/install.sh` L726-733].
- `csr-active-config` `0x0A43`, "the tested value" [V `README.md` L53].
- `SecureBootModel Disabled` (for unsigned kexts).

Our VM: SIP `0x203`, boot-arg `amfi_get_out_of_my_way=1` (task statement). Decoding with XNU's `csr.h` bit numbers [I, from memory of
`csr.h`]: `0xA43` = untrusted kexts (0x1) + unrestricted filesystem (0x2) + unrestricted NVRAM (0x40) + unapproved kexts (0x200) +
unauthenticated root (0x800). `0x203` has 0x1, 0x2 and 0x200 only. The two extra bits NV uses are not obviously needed to load a
bundle from `/Library/GPUBundles` (that is a data-volume path). **[?]** Settle in 4a: copy the bundle, boot, check `MTLCopyAllDevices` in
a user process and in WindowServer; if refused, add `amfi=0x80` and `ipc_control_port_options=0` first (cheap, boot-args), SIP bits last.
Whether `AMFIPass.kext` is in our OpenCore config is not stated in the task. `amfi_get_out_of_my_way=1` alone disables AMFI on its own on
stock macOS [I]; check `ioreg`/`kextstat` once.

Reims found a further gate with SIP **on**: Metal asks the system if `/Library/GPUBundles/...` is a trusted path and answers yes only
for a path with the SIP "rootless" storage class, which a plain copy lacks, so with SIP on Metal declines the bundle and WindowServer
loops [V `design.md` ~L4701-4720]. They fixed it with a Graft-routed MAC-policy kext (`RgfxGate`). NV works without that because its SIP
value turns the filesystem protection off [I]. Our `0x203` includes unrestricted FS (0x2), so we expect to follow NV, not Reims. If
a bundle copy is ignored, this is the first suspect. Do not build RgfxGate-style gating unless needed.

### 2.5 What Metal needs from the device object

The base class `MTLIOAccelDevice` does its own `IOServiceOpen` calls on the accelerator in `initWithAcceleratorPort:` [I: the NV plugin has none
of its own for these; `grep IOServiceOpen` in `plugin/` finds nothing but matching calls]. The kernel family answers them. The plugin then
calls `-initLimits` to fill the limit tables: "zero limits make CoreImage refuse" [V `NVMTLDevice.m` `initLimits` block in `initWithAcceleratorPort:` ~L990-1005; Reims `design.md` ~L4740].
The accessor values (`registryID`, `location`, `headless`, `lowPower`, `removable`, `peerGroupID`...) are `@dynamic` in NV's class
[V `NVMTLDevice.m` L811], so the base class computes them from accelerator registry properties.

## 3. Question 2: the minimum kernel accelerator

### 3.1 Which classes, and the Tahoe ABI problem

NV's `NVAccel` subclasses `IOGraphicsAccelerator2` [V `re/IOGraphicsAccelerator2.h`, `nvrm-accel.cpp` L258], whose base `IOAccelerator` lives in
IOGraphicsFamily and adds no virtuals [V `re/IOAccelerator.h`]. `IOGraphicsAccelerator2` is abstract: **17 pure virtuals are the entire
required vendor interface**, 67 more virtuals have working defaults [V `re/IOGraphicsAccelerator2.h` header comment]. It is 3544 bytes
(`0xdd8`); every subclass's members start after that [V static_assert]. NV's minimal set, all in `nvrm-accel.cpp` and `nvaccel_stubs.h`:

| Class | Base | What NV does | What we need |
|---|---|---|---|
| `NVAccel` | `IOGraphicsAccelerator2` | real: `populateAccelConfig`, `getStampMemory`, `newEventMachine`, `createUserGPUTask`/`createKernelGPUTask`, `newDisplayMachine`, `newDisplayPipe`, `newSurface`, `newResource`, `newMemoryMap`, `newVid/SysMemory`, `new{GL,CL,2D,Video}Context`, `configureDevice` (no-op), `teardownDevice` (no-op), `newUserClient`, `probe`, `start` [V L279-330] | same, mostly stubs |
| `NVEventMachine` | `IOAccelEventMachineFast2` | no-ops except `writeStamp`; "we do not use family channels" [V L157-172] | same, trivially |
| `NVDisplayMachine` | `IOAccelLegacyDisplayMachine` | `displayModeDidChange` calls `enableAccelerator()` [V L176-188] | same (this unlocks allocations, see below) |
| `NVTask` | `IOAccelTask` | GPU VA allocator | a fake VA range allocator (the GPU VA is meaningless to Venus) |
| `NVMemoryMap` | `IOAccelMemoryMap` | commits to GPU page tables | no-op `commit/release/update`, return true |
| `NVResource` | `IOAccelResource2` | pageon/pageoff, aperture | sysmem-backed, trivial |
| `NVSysMemory`, `NVVidMemory` | `IOAccelSysMemory`, `IOAccelVidMemory` | VidMemory over the framebuffer's VRAM | see 3.4 |
| `NVSurface` | `IOAccelLegacySurface` | `shapeSurface` and copy stubs | mostly stubs |
| `NVDisplayPipe` | `IOAccelLegacyDisplayPipe` | **`performTransaction`**, `initFramebufferResource`, `isTransactionComplete` | the one real piece, section 4 |
| `NVGLContext`, `NV2DContext`, `NVCLContext`, `NVVideoContext` | `IOAccel*Context2` | logging stubs of the pure virtuals (generated by `accel/gen_stubs.py`) | same, generated |

The reconstructed headers in `kexts/NVRM/accel/iofam/*.h` and `re/*.h` give the layouts; the vtable order of each is "load-bearing and
machine-generated" [V `IOGraphicsAccelerator2.h` L25-40]. Their generators (`re/gen_virtuals.py`, `re/vtable.py`, `verify_class.py`,
`DRIVER-CONTRACT.md`) are referenced but **not in the public repo** (`re/` has only four headers) [V file listing]; `build/legacy/vtdump.py`
and `vtfit.py` are. We cannot regenerate them, so we vendor the headers as shipped for Sequoia and re-verify vtable shape
against our guest.

**Tahoe change [V `accel/gen_tahoe_fwd.py` docstring]:** macOS 26 "made 27 IOAcceleratorFamily2 methods private and retyped 7 more, so a
kext can no longer link to them by name". The vtable layout is unchanged ("every base vtable has the same slot count and order as on
macOS 15; checked ... against the 26.7.1 KDK") and Apple still exports every base vtable. NV's fix: for each now-unlinkable inherited
slot, generate an override that tail-jumps through the base class's exported vtable (`tahoe_fwd.h`, 68 slots, `-DNM_TAHOE`). We need the
same. It requires a Kernel Debug Kit that matches the guest (26.7.x; NV used 26.7.1) to dump the vtables and list missing symbols
(`gen_tahoe_fwd.py NVACCEL_BINARY MISSING_SYMBOLS`, with `vtdump`). **Prerequisite: download the KDK for 26.7.3.** [?] whether one exists
for 26.7.3; if not, use the closest and verify slot counts in the guest's SystemKC itself (read-only extract from the VM disk).

**First, the spike (stage 4.0): does IOAcceleratorFamily2 start in our guest?** NV measured it on bare metal with an NVIDIA GPU. Reims says
IOAccel2 and IOGPU cannot coexist in its (ported-IOGPU) guest. Our VM has `AppleParavirtGPU.kext` on disk but it does not match our
device [V `PLAN.md`]. **[?]** Whether `com.apple.iokit.IOAcceleratorFamily2` is present in the guest's SystemKC and whether an
`IOGraphicsAccelerator2` subclass can start there is the cheapest experiment and the biggest risk. It decides between this plan
and a Reims-style IOGPU port, which would be far larger. See 6 (4.0) and 9 (probes).

### 3.2 What the family answers and what we must supply

The accelerator exposes three family user clients, implemented by Apple, reached through `IOGraphicsAccelerator2::newUserClient`
[V `re/IOGraphicsAccelerator2.h` L55-69]:

- `IOAccelDevice2`: ten external methods, all family-implemented: `get_config`(64 B) `get_name` `get_event_machine`(600 B)
  `get_surface_info` `set_stereo` `get_next_global_object_id` `get_current_trace_filter` `get_device_info` `get_next_gid_group`
  `set_api_property` [V `re/IOAccelDevice2.h`].
- `IOAccelSharedUserClient2`: 21 selectors for resources: `new_resource`, `delete_resource`, `pageoff_resource`, `get_surface_info`,
  `create_shmem`, `setup_dirty_ring`, `allocate_fence_memory`, `create_mtl_event`... [V `re/IOAccelSharedUserClient2.h` L190-211].
- context and display-pipe user clients (`IOAccelDisplayPipeUserClient2`, command-queue/context clients).

The vendor's contribution to what these return is small [V]:

- `populateAccelConfig(IOAccelConfig*)` fills a 0x70-byte record: name pointer (NV: `"NVIDIAAccelerator"`), `AccelCaps=15`,
  flags `0x30844300`, max texture 16384x16384, max framebuffers (+0x28) and a few bytes [V `nvrm-accel.cpp` L279-312]. We copy these
  offsets, change the name, and re-verify by reading what the family pre-filled (NV logs it first, and refuses if the record would
  cross a page).
- `getStampMemory(unsigned *)` returns a 16 KB physically contiguous buffer (4096 stamps) [V L261-264]. `NVEventMachine::writeStamp` writes it.
- `newUserClient(task, security, type, handler)`: types the family knows go to `IOGraphicsAccelerator2::newUserClient`. NV adds a private
  type family `0x4E56xxxx` ('NV'+n) that creates NVRM's user client and attaches it under the accelerator [V L731-770]. See 3.5.

**The enable gate (important) [V]:** `IOAccelSharedUserClient2::new_resource` calls `acceleratorWaitEnabled()`, which sleeps until bit
`0x2` of the flags dword at accelerator ivar `+0xc78` is set. The only thing that sets it is `enableAccelerator()`, which the family
calls from `IOAccel[Legacy]DisplayMachine::display_mode_did_change`. "Every allocation on our accelerator hung here, in the kernel, for as long as this bit stayed clear."
[V `re/IOGraphicsAccelerator2.h` L100-112]. NV calls `enableAccelerator()` itself in `start` (`enableFromHook("start")`) and from
`NVDisplayMachine::displayModeDidChange` [V L791-800]. We must do the same or every `IOSurface` and every app resource hangs.

### 3.3 Which kext, which collection

IOAcceleratorFamily2 and IOSurface are System KC (`OSBundleLibraries` lists `com.apple.iokit.IOAcceleratorFamily2 2.0.0`,
`com.apple.iokit.IOSurface 1.0`, IOGraphicsFamily, IOPCIFamily) [V `kexts/NVRM/accel/Info.plist`]. OpenCore can only inject into
and link against the Boot KC, so the accelerator goes in **Auxiliary KC, installed in `/Library/Extensions`**, exactly like our
framebuffer, built into the AuxKC by the same `kmutil create ... --repository /Library/Extensions -A` flow NV's `install.sh` uses
[V L340-345, L498]. Our existing framebuffer deploy flow covers this. Reims instead uses Graft to bind a Boot-KC kext to System-KC
classes so everything is OpenCore-injected [V `guest/graft/README.md`]; that is an option for later, not needed.

**Recommendation: separate kext `VirtioGPUAccel.kext`** (class `VirtioGPUAccel` plus the AGDC class), not merged into
`VirtioGPUFramebuffer.kext`, so that an accelerator panic or a boot-arg kill switch does not remove the display. Both talk to the
core through `callPlatformFunction` as today. Reims keeps them in one kext [V `design.md` ~L4805-4812: "a second IOService in the one kext,
on the same PCI device"]; both work.

### 3.4 Service tree and tie to our framebuffer

Today: `IOPCIDevice` has the core `VirtioGPU` (default category), `VirtioGPUFramebufferSlot` (category `IOFramebuffer`, score 30000, holds
the slot against `IONDRVFramebuffer`) and a `VirtioGPUDisplay` nub that the framebuffer matches [V `kext/VirtioGPU/Info.plist`,
`VirtioGPU.hpp`]. The accelerator adds a third sibling on the same `IOPCIDevice`:

```
IOPCIDevice 1af4:1050
 |- VirtioGPU                  (core, Boot KC, default category)
 |   `- VirtioGPUDisplay       (nub)
 |       `- VirtioGPUFramebuffer   (IOFramebuffer, AuxKC)
 |- VirtioGPUFramebufferSlot   (category IOFramebuffer)
 |- VirtioGPUAccel             (NEW, category IOAccelerator, AuxKC)  <- MetalPluginName here
 |   |- IOAccel...Carrier x N  (NEW, parents for user clients, see 3.5)
 |   `- (family-created user clients)
 `- VirtioGPUDeviceControl     (NEW, AGDC, category of its own)
```

This is NV's and Reims' arrangement. Reims: "the framebuffer matches in category `IOFramebuffer`, the accelerator in category `IOAccelerator`,
both children of the one `IOPCIDevice`" [V `design.md` ~L4805-4812]. NV's accelerator also matches `IOPCIDevice`, not the framebuffer [V Info.plist].

The accelerator finds our framebuffer the way NV finds `NVRMNVDAFramebuffer`: `addMatchingNotification(gIOFirstPublishNotification,
serviceMatching("VirtioGPUFramebuffer"), ...)`, reads the framebuffer's `IOFBDependentIndex` property (our framebuffer does not set it today **[?]**; NV's sets it
at `nvrm-fb.cpp` L3250), and calls `fDM->found_framebuffer(fb)` on the display machine, which makes the family create a display pipe
through our `newDisplayPipe()` [V `nvrm-accel.cpp` `fbPublished` ~L369-410, `registerPendingLocked` L592-668]. A pipe's `+0x98` field is its framebuffer; NV verifies it after the
call and stops if the family did not add a pipe [V L627-648]. We replicate with care: unchecked NULL pipes crash.

New cross-kext ABI (like NV's `nvrm_vram_abi.h`: `nvAllocVram`, `nvFreeVram`, `nvScanoutInfo`) in a header `kext/VirtioGPUAccelAPI.h`:

- `vgpu.scanoutInfo`: framebuffer returns `kva`, `pitch`, `width`, `height`, `bytes` of its current RAM scanout. [V pattern `NVRMVramRequest`,
  `nvrm_vram_abi.h`]
- `vgpu.flushNow`: already `kVGPUFlush`; the pipe calls it right after copying a frame.
- `vgpu.newClient` on the core: returns a `VirtioGPUUserClient` for the accelerator to attach (3.5).

**VRAM:** NV's `NVVidMemory::allocPhysical` asks the framebuffer for VRAM; a refusal returns false and the resource stays in system
memory [V L1264-1315]. For a CPU-only scanout NV returns `nullptr` from `initFramebufferResource` ("another GPU's panel ... frames
reach this panel only through performTransaction's copy into kva") [V L1171-1182]. That is our case exactly. So: `newVidMemory` returns an
object whose `allocPhysical` returns false, `initFramebufferResource` returns `nullptr`, and every resource stays sysmem. Reims'
and NV's headless path both prove the plugin copies IOSurface contents in and out of system memory. **[?]** that the family tolerates a
vidmem that never allocates on every path (pageon/pageoff, `calculateIOSurfaceDeviceCacheVRAMBytes`); NV's `NVResource` has overrides for those
that we copy (`kexts/NVRM/accel/nvaccel_stubs.h`).

### 3.5 User-client routing for the Venus transport (this matters for WindowServer)

Our Venus transport is a user client of the core service `VirtioGPU` (`IOServiceOpen("VirtioGPU")`, `kVGUC*` selectors) [V
`VirtioGPUUserAPI.h`]. That works from unsandboxed processes today. **WindowServer's sandbox denies opening it.** NV found this
exactly: "Sandbox: WindowServer deny(1) iokit-open-user-client NVRMUserClient. `com.apple.WindowServer.sb` ends in prefix rules
(`iokit-registry-entry-class-prefix "IOAccel"`) among them, so a compositor may open any user client belonging to the graphics accelerator" [V
`nvk/nvk-macos.patch` ~L13466-13475]. NV's answer: `NVAccel::newUserClient` recognizes a private type (`0x4E56000n`), asks NVRM to build its client with
`callPlatformFunction("nvNewAccelClient")`, **attaches it under a carrier IOService** and returns it. The plugin opens `IOServiceMatching("NVAccel")`
with that type, falling back to opening NVRM directly for unsandboxed tools [V `nvrm-accel.cpp` L731-775, `nvk-macos.patch`
~L13495-13515].

We copy this design:

- `VirtioGPUAccel::newUserClient`: type `0x56470000 | n` ('VG'+n) -> `core->callPlatformFunction("vgpu.newClient", task, &uc)` -> attach under a carrier
  -> return. Everything else goes to `IOGraphicsAccelerator2::newUserClient`. The `kVGUC*` ABI is unchanged.
- **Carriers.** `IOService::attach` "sleeps at ~1019 children"; NV pre-creates 32 carriers named `IOAccelNVRMCarrier` and round-robins
  [V L240-243, L851-864]. The class name starts with `IOAccel`, which may or may not matter to the sandbox prefix rule [I]. Name ours
  `IOAccelVirtioCarrier` as cheap insurance.
- The plugin's Venus renderer (our `vn_renderer_macos.c`, patch 0004) opens the accelerator first and the core as fallback. One-line change.
- **Process restriction.** NV lets only WindowServer take the surface-complete marks, by process name (`proc_selfname`) [V L2119-2128]. We do the
  same for the `surfaceMark` selector (4.2) so no app can stall a present.

**[?]** Whether the sandbox rule is on the opened service's class chain (`IOAccelerator` in `VirtioGPUAccel`'s ancestry) or on the user
client's parent. The carrier naming covers both. Settled by one WindowServer run in 5a, visible as a `Sandbox:` line in the log.

### 3.6 Starting order and the "armed" model (prevents boot loops)

Two documented hazards:

- **Registered accelerator whose plugin cannot load: black screen loop.** NV: "WindowServer used to stop at start with `Failed to
  create MetalDevice` every ten seconds until the startup guard switched the driver off" [V `CHANGELOG.md` L313]. Reims: "a registered
  accelerator still aborts it ... Where no accelerator is registered, WindowServer composites in software" and "Registration waits for the bundle"
  [V `design.md` ~L4915-4950].
- **Accelerator before display pipe is registered.** NV withholds `MetalPluginName` at start, restores it only when the display pipe is
  up (`onCountGrewLocked` calls `setProperty("MetalPluginName", fMetalPlugin)`), and keeps WindowServer from starting during bring-up
  by `adjustBusy(1)` on the service and a "boot hold" that `IOKitWaitQuiet` in WindowServer waits behind [V `nvrm-accel.cpp` L670-680,
  L929-938; `NVRM.cpp` L799, L1031-1037].

NV's arming sequence, in `NVRM.cpp` L1157-1170 [V]: accelerator level 1 (register framebuffer, restore plugin name), level 4 (aperture),
AGDC up, then `debug.nvaccel_iop=1` (publish `IOAccelDisplayPipeCapabilities` so transactions are accepted), then release the hold.
A newly published `MetalPluginName` is only seen by **new** processes: "a NEW process that asks Metal for this accelerator can now load
the plugin (already-running ones will not)" [V L673-677].

Our scheme, used in all stages:

1. `VirtioGPUAccel::start` is gated by a boot-arg `vgpuaccel=1` (boot-loop guard; NV: "boot-arg nvaccel=1 absent: NOT starting")
   [V L840-843] and a second kill switch `-vgpuaccoff` (as `-nvoff`/`-vgpuoff`). Without them the kext does nothing.
2. The accelerator starts and registers, **without** `MetalPluginName`.
3. A sysctl `debug.vgpuaccel` (or an IOConnect selector on the core, usable from a root tool) adds `MetalPluginName` and the pipe
   capabilities. Stage 4 uses this "late arm": WindowServer is already running in software, so it never sees the device, and only test
   processes started afterwards do. This is the safest possible development mode.
4. Stage 5 moves the same steps into the kext, early, under a boot hold, in NV's order, and publishes the plugin name last.

## 4. Question 3 and 4: the plugin, WindowServer and scanout

### 4.1 The plugin: what to keep, adapt, drop

NV's plugin is 86 files, ~3.8 MB source [V `plugin/`]. Core sizes: `NVMTLObjects.m` 8.8k lines (the Metal object graph),
`nvmtl_vk.c` 12k lines (everything Vulkan), `NVMTLDevice.m` 3.3k, `NVMTLLibraryLoad.m` 3.6k (metallib/AIR to SPIR-V), `NVMTLEventSync.m` 1k
(command buffer scheduling, WindowServer marks). **About a third of the bytes (1.26 MB) are NVIDIA-only and drop** (largest: `nvconv_lib.h`
888 KB).

Architecture seam [V]: the Metal layer (`NVMTL*.m`) calls a C API declared in `nvmtl_vk.h` (274 `nvmtl_vk_*` entry points); only
`nvmtl_vk.c` talks to Vulkan. Vendor assumptions are few: 7 sites of `0x10de` in `nvmtl_vk.c`, 3 in `NVMTLDevice.m`, none in the
Metal layer. NVK-specific escape hatches are `dlsym`'d optional entries (`nvmtl_nvk_*`, about 60 references in `nvmtl_vk.c`) and return
"feature off" when absent. So the port is "teach `nvmtl_vk.c` about Venus, delete NVIDIA features, change the surface-complete
transport".

| File(s) | Verdict | Notes |
|---|---|---|
| `NVMTLObjects.m/.h`, `NVMTLDevice_contract.m`, `NVMTLForward.m`, `NVMTLEmbedded.m` | **keep** | Metal objects (queue, buffers, textures, encoders, heaps, argument buffers). Forwarding table `NVMTLForward.m` maps our classes to `MTLIOAccel*` counterparts for Apple's private-method signatures [V L30-46]. |
| `NVMTLLibraryLoad.m` | **keep, adapt paths** | `newLibraryWithData`, AIR read via LLVM C API, translate, SPIR-V cache with write-tested cache dirs (WindowServer's sandbox only allows its own folders) [V L212-217, L459-470, L517]. |
| `NVMTLDevice.m` | **adapt** | `initWithAcceleratorPort:` (vendor/accelerator class check, allow-list, `nvmtl_vk_init`), `initLimits`, `+load`, working-set/caps answers. Remove multi-GPU card selection (`nvmtl_card_wanted`), nvdec/nvenc/DLSS registration. |
| `nvmtl_vk.c`, `nvmtl_vk.h` | **adapt (the main work)** | See 4.3. |
| `NVMTLEventSync.m` | **adapt** | Replace the NVK "surface escape" with our user-client selector (4.2). |
| `nvmtl_*.h` pure helpers (hazard model, slots, page life, live, cache file, sampler state, tex upload, multiview, icb, sparse) | **keep** | Small, "pure over their own state", with host tests in `tools/test_*.c`. Hazard tracking is correctness work; keep default behavior. Sparse and ICB can stay gated off. |
| `NVMTLMetal4.m` | **defer, gate off** (`NVMTL_METAL4=0`) | macOS 26 apps probe Metal 4; start with it reporting NO. |
| `NVMTLGL.m`, `NVMTLGLVBlank.m` | **defer** | OpenGL renderer over Metal (Safari WebGL, GL apps). Not needed for WindowServer. It uses Apple's own libLLVM and `libGLDPlugin` [V `NVMTLGL.m` L7-8]. |
| `NVMTLMetalFXDLSS.m`, `nvmtl_dlss.*`, `dlss/` | **drop** | NVIDIA DLSS. |
| `NVMTLSass*.m`, `nvmtl_sass_*.h`, `nvmtl_vendor*`, `NVMTLVendorCompiler.m` | **drop** | RTX 50 machine code and NVIDIA's closed compiler. |
| `nvconv*`, `nvmtl_app_profile*`, `nvmtl_fps_limit.h`, `nvmtl_game_priority.h`, `nvmtl_mfx_native_profile.inc`, `nvmtl_gpu_policy.h`, `nvmtl_card_select.h`, `tools/nvmtl-boost`, `nvmtl-smi` | **drop** | Games, power policy, multi-card. |
| `nvmtl_y422*`, `nvmtl_yuv422*` | **defer** | Video formats. |
| `air_dis.c` | **keep** | Out-of-process AIR decoder, protects against crashes in malformed shader libraries. |
| `translator/` (metal2vulkan + `wrapper/`) | **keep, rebuild** | `libnvmtl_translate.dylib`; see 4.4. |

Plugin-side changes for Venus, concretely [V sites unless marked]:

- `nvmtl_vk_set_accelerator` and `nvmtl_vk_vendor` recognize `IOObjectConformsTo(port, "VirtioGPUAccel")` and set a Venus
  pseudo-vendor (keep `0x1af4`); ICD path `/Library/GPUBundles/vgpu/libvulkan_virtio.dylib` (`nvmtl_icd_lib_path`, `nvmtl_vk.c` L128-142).
  The plugin `dlopen`s the ICD directly and calls `vkGetInstanceProcAddr` or `vk_icdGetInstanceProcAddr` before falling back to a Khronos
  loader [V L1130-1150]. Our `libvulkan_virtio.dylib` exports exactly `vk_icdGetInstanceProcAddr` [V `mesa/NOTES.md` "Result"], and
  `vkexec` already ran without a loader [V `PLAN.md`]. No Vulkan loader is needed.
- Force `nvmtl_gpu_headless()` true for Venus (that path exists for non-NVIDIA vendors) so `nvmtl_vk_surface_share_on()` stays off
  and IOSurface textures are "private per process (copies)" [V L2824-2842]. That path is `nvmtl_surface_image_create` in `NVMTLDevice.m`
  L1580-1650: private image, `IOSurfaceLock`, `memcpy` in, copy out with seed tracking [V `NVMTLObjects.m` L1523-1720]. It needs no
  kernel cooperation, which is why it is the first path to run.
- Drop the `_open` rebind (NVRM-specific, `nvmtl_vk.c` L1136) and the NVRM wait code. Keep the `_sysconf` rebind: sandboxed
  processes cannot read `hw.memsize` [V L473-478, L1135].
- The Vulkan device may report a 32 GB device-local heap (host shared memory) [V `PLAN.md`, vkprobe]. Clamp what the plugin reports as
  `recommendedMaxWorkingSetSize` and the VRAM figure (`nvmtl_vk_vram_bytes`); NV's code without `VK_EXT_memory_budget` "estimates at 70%
  of the card" [V the `nvlog` at ~L1295 of `nvmtl_vk.c`]. Pick an explicit cap (a fraction of guest RAM).
- Load the Vulkan device lazily if possible. NV calls `nvmtl_vk_init()` inside `initWithAcceleratorPort:` and refuses the device if it fails
  [V L969-973]. In a VM every process that creates a Metal device creates a Venus context, an instance and a device (`vkCreateDevice` took
  7.3 ms, `PLAN.md`). See risk 4.

### 4.2 What WindowServer needs to composite with Metal and show it

Facts, with the source of each:

1. **A Metal device whose registry ID is the display's GPU.** CoreDisplay and WindowServer pair the framebuffer with an accelerator through
   its PCI device. Without an `AppleGraphicsDeviceControl` on that PCI device, "WindowServer's IOPresentment builds a display pipe only for a
   framebuffer whose PCI device has an AGDC ... Without one, CoreDisplay logs 'Unable to find display pipe for IOFB service' and WindowServer picks the
   software compositor" [V Reims `design.md` ~L5090-5104]. NV runs the same object: `NVDADeviceControl : AppleGraphicsDeviceControl` created and attached by hand to the
   PCI device from a worker, `d->attach(pci); d->start(pci)` [V `kexts/NVRMAGDC/nvrm-agdc.cpp` ~L209-221]. Its personality matches
   `IOResources` (`IOResourceMatch IOKit`) in a loader class, and the library `com.apple.AppleGraphicsDeviceControl` (`1.0.0`) is a System-KC dependency [V Info.plist].
   AGDC vendor commands to answer [V]:
   - cmd `1`: vendor info `{version 0x30000, "NVIDIA", vendorID, vendorClass 2}`, struct size `0x2c`;
   - cmd `0x980`: `AGDCGPUCapability_t`, size `0xdc`: `portMask`, `countA..D`, `maxFramebuffers`, `pciDevice`, `framebuffer[20]` (one per `IOFBDependentIndex` slot);
     it is read when WindowServer (re)starts and decides how many display pipes exist;
   - `0x921`/`0x711` (link config and plane-scaler caps; NV "K5"), Reims also answers `3` and `0x301` (the GPU wrangler's index)
     [V Reims `design.md` ~L5099-5104]. Everything else `kIOReturnUnsupported`.
   Declaration of the AGDC base class (size `0x110`, one pure `vendor_doDeviceAttribute`) is in `kexts/NVRMAGDC/AppleGraphicsDeviceControl_re.h`
   [V]. Reims has its own (`guest/kext/src/AppleGraphicsDeviceControl.hpp`).
2. **The display pipe accepts transactions.** `NVAccel` publishes `IOAccelDisplayPipeCapabilities = {DisplayPipeSupported = true,
   TransactionsSupported = true}` on itself, and `NVDisplayPipe::performTransaction(IOAccelDisplayPipeTransaction2*)` receives the plane
   IOSurface via `txn->getPlaneIOSurface(0,0)` (or `getPlaneResource`) [V `nvrm-accel.cpp` L1401-1405, L1476-1560, L1621-1630].
   `validateTransaction` returns success, `isTransactionComplete` reports the async state [V L1448-1457].
3. **The copy path, which is all we need first.** For a surface that cannot be flipped, NV does: wait until the surface's GPU work is
   marked finished (`nvSurfWaitReady`), require BGRA, `l10r` (30-bit) or `RGhA` (half-float) [V L1553-1562; `kexts/NVRM/accel/nv_iop_pixel.h` has the
   per-row converters], map the IOSurface's `IOMemoryDescriptor` read-only, get the framebuffer's scanout `kva`/`pitch`, **require the source
   size to equal the scanout size** [V L1578], and convert row by row. The `iopMapSurface` cache keeps 4 mapped sources [V L1417-1441].
   This is a ~100-line function for us: our scanout is BGRX in RAM, our flush is `kVGPUFlush`.
4. **Surface completion marks: WindowServer does not wait for the GPU.** NV measured WindowServer swapping before its composite finished
   (issue 196, "~1.3 ms of each 6.9 ms frame"). The plugin tells the kernel "this IOSurface is pending" at commit and "ready" when the GPU is done,
   and the pipe waits for ready before it reads the pixels [V `nvrm-accel.cpp` L1736-1760, L2119-2128, L2461-2462; plugin
   `nvmtl_vk_surface_gpu_mark`, `nvmtl_vk.c` ~L2870]. The kernel side restricts this to `proc_selfname == "WindowServer"` and uses a user-client
   escape, because "WindowServer's sandbox denies sysctl writes" [V L2119-2125]. We need a `surfaceMark(id, pending)` selector on our
   accelerator-routed user client and a `surfaceWaitReady(id)` in the pipe (bounded wait, then drop the frame, as NV's flip path does).
   Without it frames tear or show stale pixels: NV's "5 of 40 flicker recordings" were copies of surfaces whose newest pixels were
   not yet in system memory [V L1545-1552].
5. **Mode change delivery.** The accelerator must be told about display mode changes so its pipe and `enableAccelerator()` run:
   `NVAccel::deliverModeChange`, called from `onCountGrewLocked` right after `found_framebuffer` [V `nvrm-accel.cpp` L670-672; notes at L796 and L5489-5520 of `nvrm-fb.cpp`: after wake, "IOGraphicsAccelerator2 stayed
   disabled (no displayModeDidChange after wake), so every IOSurface lock/purge waited"]. Our framebuffer must forward
   `IOFramebuffer` mode-set and wake notifications the same way (it uses stock `IOFramebuffer`, so this is the family's job once the pipe exists, but verify).
6. **VBL interrupts.** WindowServer's display link keys off `registerForInterruptType(kIOFBVBLInterruptType)`. NVRMFB implements it with a
   hardware vblank and a timer fallback `fVblTimer` [V `nvrm-fb.cpp` L702-780, L2958-2995]. **Our framebuffer implements none** (no `registerForInterruptType` in
   `VirtioGPUFramebuffer.cpp`; its timer only flushes). The software compositor tolerates that; the Metal path may not **[?]**. Plan
   a 60 Hz timer VBL first (copy NV's `vblPeriodAbs` clamp), later drive it from RESOURCE_FLUSH completion.
7. **Pixel formats and sizes.** The login window uses 10-bit `l10r` surfaces; HDR uses half float [V `nv_iop_pixel.h`, `nvrm-accel.cpp` L1486-1495]. Our framebuffer advertises only
   `IO32BitDirectPixels` [V `VirtioGPUFramebuffer.cpp` L35]. NV's `nv_iop_convert_row` handles all three and is reusable.
8. **IOSurface-backed drawables.** WindowServer renders into `CAMetalLayer` drawables, which are IOSurface-backed textures reached through
   `-[MTLDevice newTextureWithDescriptor:iosurface:plane:]` [V `NVMTLDevice.m` L1666-1670]. NV keeps WindowServer's usage flags as asked (it wraps
   "hundreds of surfaces a second, none Core Image targets") [V L1650-1664].

Scanout options, in the order we should build them:

| Option | Mechanism | Needs | Status |
|---|---|---|---|
| **A. copy into the framebuffer's RAM** | `performTransaction` memcpy of the IOSurface rows into `vram_`, then `kVGPUFlush` | Nothing new in the device. | **Build this.** It is NV's own non-flip path. |
| **B. alias the IOSurface pages as the 2D scanout resource** | per-IOSurface `RESOURCE_CREATE_2D` + `ATTACH_BACKING` with the surface's page list, `SET_SCANOUT` to that resource | Cache resources by surface ID; the family allocates ~3 surfaces and recycles them. Keeps the guest copy out of the frame path. | **[I]** worth it only if A shows up in profiles. Our full-frame flush today is 4.2 ms [V `PLAN.md`]. |
| **C. guest-memory blob + `SET_SCANOUT_BLOB`** | `BLOB_MEM_GUEST` resource over the surface pages; QEMU's udmabuf path scans out without a CPU copy | `kVGUCCreateBlob` currently supports HOST3D only ("guest-memory blobs not implemented yet", task statement); QEMU needs `blob=on` (already) and `/dev/udmabuf` (present on the Proxmox host, [V `PLAN.md`]) | **[?]** QEMU 11.1's `SET_SCANOUT_BLOB` for virgl builds. Probe, don't assume. |
| **D. GPU-resident scanout** | render directly into a host image that is the scanout | Venus image export to QEMU as a dmabuf | **[?]** research item; not on the critical path. |

Frame cost estimate for A at 1280x800 [I]: GPU render on host (small) + `vkCmdCopyImageToBuffer` into a host-visible blob + fence (we measured a
fenced empty submit at 4.1 ms) + 4 MB `memcpy` into the IOSurface + 4 MB `memcpy` into `vram_` + flush (4.2 ms). Roughly 15 to 25 ms of
latency per frame, 30 fps achievable if frames are pipelined. That is on par with the current 30 Hz software flush and removes the CPU
compositing load (234% CPU on a Genie minimize today).

### 4.3 Vulkan features the plugin wants, and what Venus on ANV offers

All extensions in `kWant[17]` are **optional**: the plugin enumerates what the device has and enables what it can, and each missing one
turns a feature off with a log line [V `nvmtl_vk.c` L1202-1262]. The 17 are: `VK_EXT_extended_dynamic_state3`, `VK_EXT_depth_clip_enable`,
`VK_EXT_memory_budget`, `VK_KHR_acceleration_structure`, `VK_KHR_ray_query`, `VK_KHR_deferred_host_operations`, `VK_EXT_external_memory_host`,
`VK_EXT_image_drm_format_modifier`, `VK_KHR_external_memory_fd`, `VK_EXT_mutable_descriptor_type`, `VK_KHR_cooperative_matrix`,
`VK_EXT_calibrated_timestamps`, `VK_EXT_sample_locations`, `VK_KHR_pipeline_executable_properties`, `VK_EXT_provoking_vertex`,
`VK_KHR_vertex_attribute_divisor`, `VK_EXT_pipeline_robustness`.

Hard requirements (the plugin refuses a device without them) [V]:

- A queue family with graphics and compute [V L1196].
- Vulkan 1.3 instance (`VK_API_VERSION_1_3`), `bufferDeviceAddress` enabled unconditionally [V L1325]. ANV on Iris Xe: yes. Venus:
  advertises `vk.xml 1.3.269` and the host's ANV is 1.3.309 [V `PLAN.md`]. `bufferDeviceAddress` on Venus is supported when the host has it; **[?]** verify
  that the guest sees the feature.
- Descriptor indexing set for the bindless path (`g_bindless`) is optional; when absent the plugin has a non-bindless path (`NVMTL_NO_BINDLESS`)
  [V L1393-1407]. Correctness of that fallback on a compositor workload is untested by NV on ANV.

Venus filters the host's extension list through its own `vk_extension_mask` [V `mesa/NOTES.md` "info"]; anything the host has but Venus has
not implemented is invisible. The facts we have: ANV 1.3.309 host, `vkprobe` shows 7 memory types (host-visible coherent and cached) and 1 graphics+compute
queue family [V `PLAN.md`]. **[?]** The exact extension and feature list. **Action for 4a:** extend `tools/vkprobe.c` to dump every
instance and device extension and the features the plugin reads (`Vulkan11/12/13Features`, dynamic-state3, sampler ycbcr, etc.) so we
know before building.

Consequences already visible:

- `VK_KHR_external_memory_fd` and `VK_EXT_image_drm_format_modifier`: NV uses them only for the IOSurface VRAM share path (`g_extfd`, `g_linmod` in
  `nvmtl_vk_surface_share_on`) [V L2833-2842]. We turn that path off anyway.
- `VK_EXT_external_memory_host` (NV's `newBufferWithBytesNoCopy` import) is probably absent from Venus **[?]**; the plugin falls back to a copy
  [V `NVMTLDevice_contract.m` L47-80: "COPIED ... resynced at every submission"].
- `VK_KHR_acceleration_structure` and ray queries: off. No Metal ray tracing.
- `VK_KHR_cooperative_matrix`: needs exact tile shapes; likely absent; off.
- `VK_EXT_memory_budget` absent -> estimated working set [V `nvmtl_vk.c` ~L1295].

A WindowServer-level feature check, not yet answered: the CoreDisplay and CoreAnimation shader set uses vertex/fragment pipelines with blending,
`[[color(n)]]` framebuffer fetch (emulated by the plugin through copies when absent, `fetch_copy`), 16-bit float formats, BC/ASTC maybe, and Metal
`argument buffers` (the plugin's `NVMTLEmbedded.m` handles texture handles inside buffers). These are known to work on NVK; they have not been
exercised on ANV through Venus **[?]**.

### 4.4 Shader translation

Pipeline [V `NVMTLLibraryLoad.m` L18-60, L800-830]: a `.metallib` or AIR bitcode arrives via `newLibraryWithData`; the plugin reads the bitcode **in
process** with LLVM's C API (`LLVMParseBitcodeInContext2`, `LLVMPrintModuleToString`) from `air-runtime/libLLVM.dylib` shipped in the bundle, or, if the library
is too large or unreadable, by the out-of-process `nvmtl-air-dis` (`plugin/air_dis.c`); the resulting LLVM IR text goes to `libnvmtl_translate.dylib`
(`translator/wrapper`, over `translator/translator` = metal2vulkan), which emits Vulkan SPIR-V plus reflection; SPIR-V is cached on disk in a
write-tested folder and handed to the Vulkan driver.

- metal2vulkan is "Alpha" with an unstable API [V `translator/translator/README.md`]. NV carries its own fixes in `wrapper/` (bindless tables, wide loads, alignment guards,
  `src/*.rs`) and in the translator (tests such as `gated_texture_descriptor_slots.rs`, `bounded_growth.rs`). Use NV's tree, not upstream.
- Needs Rust 1.87+, `spirv-tools` crate (builds SPIRV-Tools; `cmake` required) for validation [V `Cargo.toml`]. The translator is pure Rust: **test it natively on the
  arm64 Mac** (no Rosetta here, `mesa/NOTES.md`), cross-compile only the shipped `x86_64-apple-darwin` dylib.
- AIR needs a bitcode reader that accepts Apple's dialect. NV ships "upstream LLVM" as `air-runtime` and calls it sufficient [V `PROVENANCE.md` L41,
  `CHANGELOG.md` L137]; NV's GL path instead `dlopen`s Apple's own `/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib`
  [V `NVMTLGL.m` L7]. **[?]** If that system library exports the same C API entry points (`LLVMParseBitcodeInContext2`, `LLVMPrintModuleToString`), we avoid building LLVM.
  Probe it with `dlsym` in 4b. Otherwise build a minimal upstream LLVM (BitReader, AsmWriter) as a dylib.
- Test inputs need AIR. Apple's frontend produces it: `xcrun metal` on the Mac, which on current Xcode is a separate "Metal Toolchain"
  component **[?]** to download. `CoreDisplay.framework/.../default.metallib` is the real target in the guest
  (`nvmtlProbeGPUPass` in `NVMTLDevice.m` L1010-1018 reads it).
- Runtime MSL source compilation (`newLibraryWithSource`) goes through Apple's compiler service for the device, which NV's older packages served with
  a vendor compiler bundle and NV now dropped [V `HOW-IT-WORKS.md` section 3 "NVIDIAShared.bundle is no longer in the package"]. WindowServer uses precompiled libraries, so this can wait.

### 4.5 Memory and IOSurface sharing mapped onto our blobs

Our primitives [V `VirtioGPUUserAPI.h`, `PLAN.md`]: `kVGUCCreateBlob(blob_mem=HOST3D, flags, size, blob_id)`, `kVGUCMapBlob` + `IOConnectMapMemory64`
into the process from a 2 GB host-visible window (`hostmem`, a range allocator of 2048 ranges), fenced `kVGUCSubmit`, `kVGUCWaitFence`. Venus makes
and maps blobs itself for `vkAllocateMemory` of host-visible types; device-local memory is not mapped into the guest.

Plan:

- **Phase 1 (stage 4d and 5b): private images with copy in and out.** Each IOSurface texture is a Vulkan image in device memory. "Surface in" =
  `IOSurfaceLock(read-only)`, `memcpy` into a host-visible staging buffer, `vkCmdCopyBufferToImage`; "surface out" = `vkCmdCopyImageToBuffer`, wait,
  `IOSurfaceLock`, `memcpy` back, seed update [V `NVMTLObjects.m` L1523-1720]. Seeds avoid re-uploading unchanged surfaces. All of this uses only mapped Venus
  blobs and existing code. No kernel changes.
- **Phase 2: staging memory pools.** Each process's staging buffers come from the same 2 GB window. Budget it: WindowServer at 1280x800 with ~6 surfaces is ~30 MB, but
  every Metal process holds buffer and staging memory too, and `hostmemAllocate` has a 2048-range cap [V `VirtioGPU.hpp` `kMaxHostmemRanges`]. Needs an accounting and
  a per-process cap; see risk 4.
- **Phase 3 (optional, 5c+): back IOSurface memory with a HOST3D blob** so the CPU view and a linear host image are the same pages and "surface out" disappears. That needs a
  `newSysMemory` whose memory descriptor wraps the blob mapping (a `IOMemoryDescriptor` over the hostmem BAR range, which our core already builds for user mappings) and a
  linear `VkImage` bound to the same `VkDeviceMemory`: ANV renders to linear slowly and cross-process coherence is complex. Treat as research; not planned.
- Guest-memory blobs (`BLOB_MEM_GUEST`, mentioned as not implemented) are only for scanout option C and for Venus shared memory the user client already handles
  differently. Not needed for stage 4.

## 5. How the plugin reaches the kernel

NV's plugin itself makes no kernel calls beyond IOKit registry reads; Vulkan (NVK) does the rest via the accelerator-routed RM user client (3.5), and surface marks go
through the same connection. Our equivalent: plugin -> `libvulkan_virtio.dylib` -> `IOServiceOpen(VirtioGPUAccel, 0x5647_xxxx)` -> `VirtioGPUUserClient` with the existing
selectors, plus two new ones: `kVGUCSurfaceMark(surfaceID, pending)` and optional `kVGUCSurfaceQuery` for debugging.

## 6. Staged build order, checkpoints, risks, effort

Effort is focused-engineer days for the stage, excluding VM reboot waits, assuming the previous stage passed. Kernel work carries kernel-panic reboots
(each AuxKC change is `kmutil` + reboot). Always take a VM snapshot before arming anything (section 7).

### Stage 4.0: accelerator spike (no Metal yet)

- **Do:** `VirtioGPUAccel.kext` in AuxKC: class `VirtioGPUAccel : IOGraphicsAccelerator2`, category `IOAccelerator`, matches `0x10501af4`, all pure virtuals stubbed
  (generate with the same approach as `gen_stubs.py`/`gen_tahoe_fwd.py`), `configureDevice`/`teardownDevice` trivial, `populateAccelConfig` copying NV's offsets, `enableAccelerator()`,
  `IOAccelRevision`, **no `MetalPluginName`**, boot-arg gate. Header set: vendor NV's `re/` and `iofam/` headers.
- **Prereqs:** a KDK for the guest's macOS build; `vtdump`-style check of the guest's SystemKC vtables (slot counts) before first load.
- **Checkpoint:** kext loads; `ioreg -c IOAccelerator` shows `VirtioGPUAccel`; no panic; a test tool opens the family user clients (types of `IOAccelDevice2`, shared) with `IOServiceOpen` and
  `IOConnectCallMethod` for `get_config` returns the filled record; a `new_resource` call does not hang (proves `enableAccelerator`).
- **Riskiest unknowns:** (1) the family starts at all alongside the guest's IOGPU/AppleParavirtGPU (Reims says no, NV says yes on hardware); (2) vtable and class-size drift on
  26.7.3; (3) IOPCIDevice open conflicts with the core.
- **Effort:** 4 to 7 days.
- **Abort condition:** if `IOGraphicsAccelerator2::start` cannot run in this guest, stop and decide between a Graft/IOGPU route (Reims-scale effort) and staying software. Everything below depends on this.

### Stage 4a: plugin loads, `MTLCopyAllDevices` lists the device (late arm)

- **Do:** `VirtioGPUMetal.bundle` with `VGMTLDevice : MTLIOAccelDevice`, `initWithAcceleratorPort:` that checks `IOObjectConformsTo(port, "VirtioGPUAccel")`, calls super,
  runs `nvmtl_vk_init` against Venus, `initLimits`, and returns. Kernel: `debug.vgpuaccel=1` publishes `MetalPluginName`/`MetalPluginClassName`. A tiny `mtlprobe` tool prints
  `MTLCopyAllDevices`, `name`, `registryID`, `supportsFamily:`, `recommendedMaxWorkingSetSize`, `isHeadless`.
- **Allow-list:** on, only `mtlprobe` and the user's shell test tools. WindowServer excluded by running already.
- **Checkpoint:** `mtlprobe` prints one device named for the Iris Xe; `ioreg` shows the plugin keys; WindowServer unaffected; killing `mtlprobe` leaves no leaked Venus contexts.
- **Riskiest unknowns:** AMFI/SIP/trust gates for the bundle (2.4); base-class `initWithAcceleratorPort:` expectations that the family must meet (config, stamps, names);
  Venus feature gaps making `nvmtl_vk_init` fail; `nil` return path crash (2.1).
- **Effort:** 5 to 8 days.

### Stage 4b: a compute kernel runs

- **Do:** buffers (`newBufferWithLength`, map via Venus host-visible blobs), library load for a host-built `.metallib`, translator + AIR reader, `newComputePipelineState`,
  command queue/buffer/compute encoder, `waitUntilCompleted`. A blit encoder copy. `addCompletedHandler`. A shared event if cheap.
- **Checkpoint:** `mtlcompute` runs a vector add and a small reduction; results correct for 16 M floats; a blit copy matches; timing recorded (compare to `vkexec`: 64 MB copy 23 ms).
- **Riskiest unknowns:** translator output on ANV (SPIR-V validation passes, runtime differences); Venus and `bufferDeviceAddress`/descriptor indexing availability; `LLVM` reader choice (4.4);
  synchronous waits and ring behavior under many small submits.
- **Effort:** 12 to 20 days (the translator build and the first end-to-end pipeline dominate).

### Stage 4c: render to a texture

- **Do:** render pipeline (vertex+fragment AIR), render pass descriptors, `MTLTexture` 2D (BGRA8, RGBA16F), samplers, depth if needed, blending, `drawPrimitives`, `replaceRegion`/`getBytes`, blit
  between textures, readback to a buffer. Enable argument buffers (`NVMTLEmbedded.m`).
- **Checkpoint:** a triangle and a textured quad render into an offscreen texture and a CPU readback matches a reference within tolerance; clear + load/store actions; a Core Image or
  `MPSImageGaussianBlur`-free smoke test.
- **Riskiest unknowns:** pipeline-state variants for Apple's blend/format combos on ANV; framebuffer-fetch emulation (`fetch_copy`); texture formats Venus/ANV lacks (packed 10-bit, some compressed).
- **Effort:** 15 to 25 days.

### Stage 4d: IOSurface textures and presentation shape

- **Do:** `newTextureWithDescriptor:iosurface:plane:` with the private image + copy-in/out path; `CAMetalLayer` in a test app
  (`MTKView` sample) shows a rotating quad **in a window through the software compositor**: the app draws with our device, WindowServer still composites in software and reads the IOSurface.
- **Checkpoint:** a Metal app animates correctly in a window at 30+ fps with the device allowed for that process only; `IOSurfaceLock` read in the app shows the GPU's pixels; seeds and
  hazard behavior correct.
- **Riskiest unknowns:** copy-out latency; WindowServer reading IOSurfaces we write from another process's mapping while its own software path composites them (this is the NV "headless GPU hands frames to
  another GPU's WindowServer" path, so it is proven there); VBL cadence for the app.
- **Effort:** 8 to 12 days.

At this point the app-only Metal device exists. WindowServer is untouched.

### Stage 5a: WindowServer picks the Metal device

- **Do:** `VirtioGPUDeviceControl` (AGDC) answering cmds 1, 3, 0x301, 0x921, 0x980; framebuffer sets `IOFBDependentIndex`; accelerator registers the framebuffer
  (`found_framebuffer`) and verifies the pipe; `newDisplayPipe`/`NVDisplayPipe` analog with `performTransaction` as option A (4.2); `IOAccelDisplayPipeCapabilities`;
  framebuffer VBL timer; the arming sequence and boot hold moved into the kext (3.6); plugin allow-list adds `WindowServer`.
- **Checkpoint:** boot with `vgpuaccel=1`: the registry shows the AGDC and a display pipe; WindowServer's log shows it opened the accelerator user clients (and any `Sandbox:` denials fixed
  by 3.5); `system_profiler SPDisplaysDataType` shows "Metal: Supported" for our device; WindowServer uses the Metal compositor (not "Software compositor activated") even if the screen is
  black.
- **Riskiest unknowns:** every item of 4.2; WindowServer abort loops ("Failed to create MetalDevice"); a sandbox denial we did not predict; AGDC fields CoreDisplay validates; VBL.
- **Effort:** 10 to 20 days. The highest variance of any stage: each experiment is a reboot and some end in a black screen.
- **Abort condition:** a loop. Recovery is the snapshot or OpenCore boot-arg `-vgpuaccoff` (section 7).

### Stage 5b: composited frames on screen

- **Do:** surface pending/ready marks and `surfaceWaitReady`; copy pixel formats BGRA/l10r/RGhA; frame pacing at the framebuffer's VBL; drop frames instead of waiting forever.
- **Checkpoint:** desktop visible through the Metal compositor at 1280x800; Genie minimize no longer pegs the CPU (compare to the 234% CPU baseline in `PLAN.md`);
  Mission Control and the login window render; sustained 30 fps for 10 minutes without a leak in Venus contexts or hostmem; `screencapture` matches what is on the host display.
- **Riskiest unknowns:** shader coverage for CoreDisplay/CoreAnimation/SwiftUI; GPU hang or device loss inside WindowServer (device loss makes the desktop black: NV had to add "device
  removed" errors so WindowServer does not abort [V `CHANGELOG.md` L31]); sync correctness (tearing, stale frames); performance regressions versus software.
- **Effort:** 15 to 30 days.

### Stage 5c: stability, speed, options

Hotplug and resolution changes (the framebuffer already has modes), sleep/wake (NV's section on sleep is long [V `docs/SLEEP-WAKE.md`]), HiDPI modes, scanout option B or C,
VBL driven by flush completion, multi-process hostmem accounting, Safari/WebGL with the GL layer, Metal 4 gate. Open-ended.

### Summary of effort

| Stage | Days (focused) |
|---|---|
| 4.0 | 4-7 |
| 4a | 5-8 |
| 4b | 12-20 |
| 4c | 15-25 |
| 4d | 8-12 |
| 5a | 10-20 |
| 5b | 15-30 |
| **Through 5b** | **~70-120 days** |

## 7. Safety protocol for bring-up (when work starts; nothing is done now)

- Snapshot VM 108 (`clean-dev` already exists) before each kernel-facing stage; keep OpenCore's picker reachable (`oc_kext.py CONFIG - picker` per `PLAN.md`).
- Two independent kill switches: boot-arg gate `vgpuaccel=1` (absence = does nothing) and `-vgpuaccoff` (present = does nothing even if the first is set), the pattern of `nvaccel=1`
  / `-nvoff` [V `nvrm-accel.cpp` ~L840, `HOW-IT-WORKS.md` section 2]. NV also adds an OpenCore tool entry that boots with the driver off [V `HOW-IT-WORKS.md` section 5].
- Never publish `MetalPluginName` before `WindowServer` exists until 5a; the late-arm sysctl is the default through 4d.
- Keep `PLAN.md`'s existing rules: no network on VM 108; logs via the registry `ProbeLog` because IOLog does not reach the unified log [V `PLAN.md` "Lessons"].
- Install by the existing transfer-disk flow. Bundle files root-owned, world-readable; confirm with `sudo -u _windowserver test -r ...` as NV does [V `install.sh` L477].

## 8. Top risks (ranked)

1. **IOAcceleratorFamily2 may not start in this guest.** Reims builds on IOGPUFamily because "IOAccel2 cannot start in a kernel where IOGPU runs" [V `design.md` ~L4787]; NV's NVAccel runs on hardware macOS 26.7.1 [V
   `docs/EVENT-WAIT.md` "Measured system": macOS 26.7.1 with "Tahoe NVAccel"; NV also says this "does not qualify macOS 26 support generally"]. Our guest has `AppleParavirtGPU` on disk. If this fails the plan changes shape. Mitigation: the 4.0 spike is first and cheap. Also the ABI:
   reconstructed class layouts (`re/*.h`) were verified on Sequoia and patched for Tahoe through vtable forwarding; any drift is a kernel panic. Mitigation: KDK, slot-count checks, snapshot.
2. **WindowServer is in the blast radius, and it loads our plugin.** A registered accelerator with a missing/refused plugin or a missing pipe aborts WindowServer in a loop; once armed, a
   Vulkan device loss or translator failure inside WindowServer blanks the desktop. NV needed boot guards and a "device removed" error path to survive this [V `CHANGELOG.md` L31, L313]. Mitigation:
   late-arm until 5a, allow-list bisection, snapshots, the two kill switches, a "fall back to software compositor" behavior when `nvmtl_vk_init` fails in WindowServer.
3. **Shader coverage and correctness on Venus/ANV.** metal2vulkan is alpha; NV's tree has many NVIDIA-specific fixes; the plugin has only run against NVK, never ANV through Venus; Venus hides extensions
   that NV's optional paths use. One wrong pipeline variant in CoreDisplay's shader set breaks the desktop. Mitigation: extend `vkprobe` to dump features before 4b; run NV's test oracles
   (`tools/oracles`, `tools/test_*`) as a corpus; test with CoreDisplay's real `default.metallib`.
4. **Frame synchronization and VM cost.** WindowServer swaps before the GPU finishes, so the kernel needs pending/ready marks; Venus fenced latency is ~4 ms; copy-out per frame; and every process that creates a
   Metal device creates a Venus context, instance and device (7.3 ms for the device) plus host render-server state, all drawing on one 2 GB hostmem window with a 2048-range cap. Dozens of processes
   (Dock, SystemUIServer, ControlCenter, Spotlight UI) will hit it. Mitigation: lazy Vulkan init after the Metal device exists, per-process hostmem accounting, allow-list excludes background helpers
   initially, test with `vm_stat`/hostmem counters, measure host render-server counts.
5. **Sandbox, trust and security gates.** WindowServer's sandbox, library validation and SIP bits differ from what NV tested (`0xA43` plus `amfi=0x80` plus `ipc_control_port_options=0`; ours is `0x203` plus `amfi_get_out_of_my_way=1`),
   and Reims documents a SIP-class trusted-path gate that NV avoids only through its SIP value. A user-client-class mismatch in the accelerator routing means a silent "no device" in WindowServer. Mitigation: 2.4 order
   of experiments, 3.5 routing, and reading WindowServer's `Sandbox:` and `amfid`/`taskgated` log lines on first arm.

Secondary: no VBL in our framebuffer (4.2.6); AuxKC approval records and `kmutil` quirks per update [V `install.sh` L454-470]; PolyForm headers if the repo goes public (1.3); OpenGL, video, Metal 4 and MPS
fast paths missing (apps, not WindowServer); `newBufferWithBytesNoCopy` unimportable (copies); working-set reporting from a 32 GB host heap.

## 9. Read-only probes to run before and during 4.0 (none run yet)

All on the guest or host after you decide to; they only read.

1. In the VM: `kmutil showloaded --list-only | grep -E 'IOAccel|IOGPU|IOSurface|AppleGraphicsDeviceControl|IOGraphics'`, `ioreg -rc IOAccelerator`, `ioreg -l | grep -i MetalPlugin`,
   `csrutil status`, `nvram boot-args`, `nvram csr-active-config`. Confirms 3.1 and 2.4.
2. On a Mac with the KDK for the guest's macOS build: `nm -g` the KDK's IOAcceleratorFamily2 for the symbols NV lists as missing; `vtdump` the vtable slot counts of the 14 base classes.
3. Extend `tools/vkprobe.c` to print all extensions and the features read in 4.3, then run it in the VM. Decides which plugin paths are live.
4. `dlsym` test of `/System/Library/PrivateFrameworks/GPUCompiler.framework/.../libLLVM.dylib` for the C API symbols (4.4).
5. `xcrun metal` availability on the build Mac (Metal Toolchain component).
6. QEMU 11.1 source on the Proxmox host (read-only): `hw/display/virtio-gpu-virgl.c` for `SET_SCANOUT_BLOB` support with virgl blobs (4.2 option C).

## 10. Source index

NV (`nullmoth/nvidia-macos-driver` @ `87e524a`):

- Overview: `docs/HOW-IT-WORKS.md`, `DEVELOPING.md`, `README.md` (install table), `SECURITY.md`, `NOTICE`, `docs/PROVENANCE.md`.
- Accelerator kext: `kexts/NVRM/accel/Info.plist`; `nvrm-accel.cpp` (classes L157-258, `NVAccel` L258, `populateAccelConfig` L279, `newUserClient` L731, `probe` L801,
  `start` L821, `onCountGrewLocked` L670, `registerPendingLocked` L592, `initFramebufferResource` L1151, `performTransaction` L1476, caps L1621, marks L2119, stamp L3090);
  `nvaccel_stubs.h`, `tahoe_fwd.h`, `gen_tahoe_fwd.py`, `gen_stubs.py`; reconstructed headers `re/{IOAccelerator,IOGraphicsAccelerator2,IOAccelDevice2,IOAccelSharedUserClient2}.h`, `iofam/*.h`.
- Arming: `kexts/NVRM/NVRM.cpp` L799 (boot hold), L1031 (`releaseBootHold`), L1157-1170 (arm sequence).
- AGDC: `kexts/NVRMAGDC/{Info.plist,nvrm-agdc.cpp,AppleGraphicsDeviceControl_re.h}`.
- Framebuffer link: `kexts/NVRMFB/fb/nvrm-fb.cpp` (VBL L702-780, L2958; `IOFBDependentIndex` L3250), `kexts/NVRM/nvrm_vram_abi.h`.
- Plugin: `plugin/NVMTLDevice.m` (allow-list L740, init L947), `nvmtl_vk.c` (vendor L107-142, init L1664, extensions L1202, surface path L2824-2960), `NVMTLObjects.m` L1523-1720,
  `NVMTLLibraryLoad.m`, `NVMTLEventSync.m`, `NVMTLForward.m`, `air_dis.c`, `translator/`.
- Routing through the accelerator: `nvk/nvk-macos.patch` ~L13466-13515.
- Installer: `package/install.sh` (AuxKC build L340-345/L498, perms L472-477, AMFI note L726-736).

Reims (`steelbrain/reims-vgpu` @ `f378a38`): `docs/graphics-kext/design.md` (Decided 12-15, "Stage 3 guest stack" ~L4688, "accelerator kext" ~L4805, "Registration waits for the bundle" ~L4915,
"device control" ~L5090), `guest/kext/src/RgfxAccelerator.*`, `RgfxDeviceControl.*`, `guest/graft/README.md`.

Our tree: `README.md`, `notes/PLAN.md`, `kext/VirtioGPUAPI.h`, `kext/VirtioGPUUserAPI.h`, `kext/VirtioGPU/VirtioGPU.hpp`, `kext/VirtioGPU/Info.plist`,
`kext/VirtioGPUFramebuffer/VirtioGPUFramebuffer.cpp`, `mesa/NOTES.md`, `mesa/patches/0004-*`.
