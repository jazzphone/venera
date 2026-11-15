# Mesa Venus (virtio Vulkan driver) for x86_64 macOS

Goal: build `libvulkan_virtio.dylib` for an x86_64 macOS 26 guest with the Linux
DRM backend compiled out, so a macOS backend (`vn_renderer_macos.c`, talking to
the virtio-gpu kext's user client) can be plugged in later. Nothing here runs
yet: the dylib builds and links, and `vn_renderer_create_macos()` returns
`VK_ERROR_INITIALIZATION_FAILED`.

Source: Mesa tag `mesa-25.0.7` (same as the host's virglrenderer 1.1.0 era;
guest capset: wire format 1, vk.xml 1.3.269, Venus protocol spec 2).
Build: `./build-mesa.sh` (clones/fetches the tag, `git am patches/*.patch`,
venv with meson/ninja/mako/pyyaml/packaging, cross file, `ninja`, copies
results to `out/`). Cross-compiled on arm64 with `clang -arch x86_64
-mmacosx-version-min=26.0 -isysroot <MacOSX27.2.sdk>`; no Rosetta needed (and
none is installed here, so the binary was never executed).

Configure command (from the script, cross file generated beside the checkout):

    meson setup build --cross-file x86_64-macos.cross --buildtype=release \
      -Dvulkan-drivers=virtio -Dgallium-drivers= -Dplatforms= \
      -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled \
      -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dshared-glapi=disabled \
      -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dexpat=disabled \
      -Dvulkan-layers= -Dtools= -Dbuild-tests=false

The cross file needs an `objc` binary (Mesa's top-level meson.build adds the
ObjC language on darwin for the metal WSI). zlib comes from the SDK (`-lz`).
Platforms are empty, so `vn_wsi.c` is not built (no presenting yet).

## Patches (`patches/`)

1. `0001` meson: `src/meson.build` only entered `src/virtio` for KMS/DRM or
   virgl targets, so a darwin build never saw the Venus driver. It now enters
   it for `with_virtio_vk`; `src/virtio/vdrm` (Linux DRM helper lib, used by
   freedreno/asahi native-context, not by Venus) stays Linux-only.
2. `0002` portability: `SOCK_CLOEXEC` (vtest) -> `fcntl(FD_CLOEXEC)`;
   `syscall(SYS_gettid)` (`vn_gettid`, used by the watchdog) ->
   `pthread_threadid_np`.
3. `0003` the renderer split: `vn_renderer_virtgpu.c` is not compiled on
   darwin; `vn_renderer_macos.c` (stub) is. `vn_renderer.h` declares
   `vn_renderer_create_macos()` on `__APPLE__` instead of
   `vn_renderer_create_virtgpu()`; `vn_renderer_create()` still tries vtest first
   when `VN_DEBUG=vtest`, then the macOS backend. Link flags: `-dead_strip`
   and `-undefined dynamic_lookup` (see below). ICD json/devenv json name
   `libvulkan_virtio.dylib` instead of `.so`.

## Linux-only dependencies hit, and handling

| Dependency | Where | Handling |
|---|---|---|
| libdrm / `xf86drm.h`, `drm-uapi/virtgpu_drm.h`, `drmIoctl`, `/dev/dri` | `vn_renderer_virtgpu.c` | file not built on darwin; `dep_libdrm` is already `null_dep` off-Linux |
| `src/virtio/vdrm` | src/virtio/meson.build | not entered on darwin |
| `SOCK_CLOEXEC` | `vn_renderer_vtest.c` | fcntl fallback (vtest otherwise builds unchanged: AF_UNIX + SCM_RIGHTS, mmap of received fds) |
| `SYS_gettid` | `vn_common.h` | `pthread_threadid_np` |
| weak undefined entrypoints | generated `vn_entrypoints.c`, `vk_*_entrypoints`, `wsi_*_entrypoints` (`--weak`) | ELF lets a shared lib leave them undefined (and `--gc-sections`); ld64 does not. Linked with `-undefined dynamic_lookup`; the 1546 undefined symbols that remain besides libSystem/libz are all *weak* refs (`nm -um`, bind to NULL). `build-mesa.sh` fails if any *strong* undefined non-system symbol appears. Cost: a genuinely missing strong symbol would only be caught by that check, not by ld. |
| sync_file fds, `poll()` on them | virtgpu SIMULATE_SYNCOBJ | backend work (below) |
| dma-buf (`create_from_dma_buf`, `export_dma_buf`) | bo_ops | stub `info.has_dma_buf_import = false` and NULL ops in the macOS backend (vtest does the same) |
| `DETECT_OS_LINUX` / `HAVE_*` | util | compile fine; configure reports HAVE_DRI2, ALLOW_KCMP defines, harmless |
| `syscall()` deprecation warnings | n/a after patch 2 | gone |

Not Linux-specific but worth knowing: `-Wuninitialized-const-pointer` warnings in
`venus-protocol` generated headers are Apple clang 21 noise.

## Result

- `out/libvulkan_virtio.dylib`: Mach-O 64-bit x86_64, ~1.2 MB (`lipo -info`:
  non-fat, x86_64), deployment target 26.0, install name
  `@rpath/libvulkan_virtio.dylib`, links only `libSystem` and `libz`.
- `out/virtio_icd.x86_64.json`: ICD manifest, `library_path`
  `/usr/local/lib/libvulkan_virtio.dylib`, `api_version` 1.3.305. Edit the path
  (a relative `libvulkan_virtio.dylib` works with the Khronos loader) when
  deploying.
- Exported (`nm -gU`): only the three ICD entry points
  - `_vk_icdGetInstanceProcAddr`
  - `_vk_icdGetPhysicalDeviceProcAddr`
  - `_vk_icdNegotiateLoaderICDInterfaceVersion`

## What the macOS backend must implement (`vn_renderer.h`, 25.0.7)

`VkResult vn_renderer_create_macos(struct vn_instance*, const VkAllocationCallbacks*, struct vn_renderer **out)`
allocates a struct embedding `struct vn_renderer` first, fills it and returns it.

```c
struct vn_renderer {
   struct vn_renderer_info      info;
   struct vn_renderer_ops       ops;
   struct vn_renderer_shmem_ops shmem_ops;
   struct vn_renderer_bo_ops    bo_ops;
   struct vn_renderer_sync_ops  sync_ops;
};
```

`info` (all filled once at create): `drm.props` (sType DRM_PROPERTIES_EXT,
hasPrimary/hasRender and majors/minors; zero is fine), `pci.vendor_id/device_id`
(virtgpu uses 0x1af4/0x1050), `pci.has_bus_info`+`props`, `has_dma_buf_import`,
`has_external_sync`, `has_implicit_fencing` (false), `has_guest_vram`,
`max_timeline_count`, `wire_format_version`, `vk_xml_version`,
`vk_ext_command_serialization_spec_version`,
`vk_mesa_venus_protocol_spec_version`, `vk_extension_mask[32]` (copy of the
capset's `vk_extension_mask1`). These come from the Venus capset
(`struct virgl_renderer_capset_venus`, `virtio-gpu/virglrenderer_hw.h`); the
virtgpu init asserts `supports_blob_id_0`, `allow_vk_wait_syncs`,
`supports_multiple_timelines`.

`ops`:
- `void destroy(renderer, alloc)`
- `VkResult submit(renderer, const struct vn_renderer_submit*)`: `bos[bo_count]`
  to pin, `batches[batch_count]`, each `{cs_data, cs_size, ring_idx, syncs[],
  sync_values[], sync_count}`; ring_idx 0 is the context CPU timeline;
  after the batch retires on its timeline, each sync is set to its value.
- `VkResult wait(renderer, const struct vn_renderer_wait*)`: `{wait_any,
  timeout (ns), syncs[], sync_values[], sync_count}`; return `VK_SUCCESS`,
  `VK_TIMEOUT`, or `VK_ERROR_DEVICE_LOST`/OOM.

`shmem_ops` (host-visible shared memory for the command ring/reply buffers):
- `struct vn_renderer_shmem *create(renderer, size_t size)`: fill `res_id`,
  `mmap_ptr`, `mmap_size`, `refcount` (VN_REFCOUNT_INIT(1)); the common
  `vn_renderer_shmem_cache_{init,fini,get,add}` in `vn_renderer_internal.[ch]`
  can be reused as virtgpu does.
- `void destroy(renderer, shmem)`

`bo_ops`:
- `VkResult create_from_device_memory(renderer, size, vn_object_id mem_id, VkMemoryPropertyFlags, VkExternalMemoryHandleTypeFlags, struct vn_renderer_bo **out)`
  (blob resource with `blob_id = mem_id`; virtgpu picks
  `VIRTGPU_BLOB_FLAG_USE_MAPPABLE/CROSS_DEVICE/SHAREABLE` from the flags)
- `VkResult create_from_dma_buf(renderer, size, int fd, flags, out)`: may be NULL
  with `info.has_dma_buf_import = false`
- `bool destroy(renderer, bo)`: true when the last ref was dropped
- `int export_dma_buf(renderer, bo)`: may be NULL (vtest sets only the ones it supports; check call sites guarded by `info`)
- `void *map(renderer, bo)`: not thread-safe; cache in `bo->mmap_ptr`
- `void flush(renderer, bo, VkDeviceSize offset, VkDeviceSize size)`
- `void invalidate(renderer, bo, VkDeviceSize offset, VkDeviceSize size)`
  (both can be no-ops for coherent mappings)

`struct vn_renderer_bo` = `{refcount, res_id, mmap_size, mmap_ptr}`; `struct
vn_renderer_shmem` = `{refcount, res_id, mmap_size, mmap_ptr, cache_head,
cache_timestamp}`; `struct vn_renderer_sync` = `{sync_id}`. The backend wraps
each (first member) with its own handle fields.

`sync_ops` (a sync is a 64-bit timeline counter; flags `VN_RENDERER_SYNC_SHAREABLE`,
`VN_RENDERER_SYNC_BINARY`):
- `VkResult create(renderer, uint64_t initial_val, uint32_t flags, struct vn_renderer_sync **out)`
- `VkResult create_from_syncobj(renderer, int fd, bool sync_file, out)`:
  external-sync import; may be NULL/failing if `has_external_sync = false`
- `void destroy(renderer, sync)`
- `int export_syncobj(renderer, sync, bool sync_file)`
- `VkResult reset(renderer, sync, uint64_t initial_val)`
- `VkResult read(renderer, sync, uint64_t *val)`
- `VkResult write(renderer, sync, uint64_t val)`: value larger than current

Also the existing helper module (`vn_renderer_util.c`, `vn_renderer_internal.c`)
is backend-agnostic and builds as is.

## virtgpu.c: copy as-is vs. replace

`vn_renderer_virtgpu.c` is 1739 lines; `#define`s at the top
(`SIMULATE_BO_SIZE_FIX`, `SIMULATE_SYNCOBJ`, `SIMULATE_SUBMIT`) are all 1 in
this tree, meaning the driver never uses kernel drm_syncobj ioctls.

Copy nearly as-is (pure logic, no kernel types), lifting from `struct virtgpu`:
- `struct sim_syncobj` + `sim_syncobj_*` (lines ~121-464): a userspace
  emulation of a timeline syncobj: `point` (signaled value), `pending_fd`,
  `pending_point`, `pending_cpu`, a global mutex-guarded handle table
  (`util_idalloc`, `hash_table`) and `sim_syncobj_wait` using `poll()`
  over `pending_fd`s with `timeout_to_poll_timeout`. Logic (point updates,
  wait-any/wait-all, reset/query/signal) is reusable.
  **Must change:** the "fence fd" is a Linux `sync_file`: `poll(POLLIN)` on it
  fires when the host fence retires, `fence_fd = -1` means signaled, and
  `sim.signaled_fd` is a pre-signaled fd obtained by an empty CPU-ring
  execbuffer (`DRM_IOCTL_VIRTGPU_EXECBUFFER` with `FENCE_FD_OUT`). On macOS
  replace the fd with a kext-provided completion primitive (a fence id the user
  client can wait on via a mach port / `IOConnectCallAsyncScalarMethod` /
  kqueue-able pipe) and change `sim_syncobj_poll`/`_wait` accordingly; export/import
  via sync_file (`sim_syncobj_export/import` use `sync_file` merge via `poll`
  fds) has no macOS equivalent: set `has_external_sync = false` or leave
  `export_syncobj`/`create_from_syncobj` returning errors.
- `sim_submit` / `sim_submit_signal_syncs`: copy the shape. Per batch: one
  execbuffer with `ring_idx`, flag "fence out" if `sync_count`, then update
  every sync with `(fence, value)`; fd handling replaced as above. The
  `drm_virtgpu_execbuffer` fields map to `{command, size, bo_handles[],
  num_bo_handles, ring_idx, fence out}`, i.e. the kext call must accept the
  Venus command stream, the pinned resource ids and the ring index.
- `virtgpu_sync_*` wrappers (create/reset/read/write/destroy): thin; keep
  struct `virtgpu_sync { base; syncobj_handle }` with the handle being the
  sim handle.
- `virtgpu_wait` (poll over sims; builds the list of syncobj handles and
  values, `wait_any`) and `virtgpu_submit` (calls `sim_submit`) are portable
  except for error mapping.
- Sparse arrays for bos/shmems indexed by handle (`util_sparse_array`), refcount
  dance in `bo_destroy` and the `dma_buf_import_mutex` pattern, the shmem
  cache wiring, `virtgpu_bo_blob_flags` (flag selection from
  `VkMemoryPropertyFlags`), `SIMULATE_BO_SIZE_FIX` rounding, `virtgpu_init_renderer_info`
  (copy the capset handling; replace DRM/PCI fields).

Replace entirely (DRM-specific): `virtgpu_open_device/virtgpu_open`
(`drmGetDevices2`, render node/primary node, `drmPciBusInfo`),
`virtgpu_init_params` (`DRM_IOCTL_VIRTGPU_GETPARAM`: `VIRTGPU_PARAM_3D_FEATURES`,
`CONTEXT_INIT`, `RESOURCE_BLOB`, `HOST_VISIBLE`, `CROSS_DEVICE`, `SUPPORTED_CAPSET_IDs`,
`EXPLICIT_DEBUG_NAME`), `virtgpu_init_capset` (`DRM_IOCTL_VIRTGPU_GET_CAPS`, capset
id `VIRGL_RENDERER_CAPSET_VENUS` = 4), `virtgpu_init_context`
(`VIRTGPU_CONTEXT_PARAM_CAPSET_ID`, `NUM_RINGS`, `POLL_RINGS_MASK`, `DEBUG_NAME`;
this is `max_timeline_count`), `virtgpu_ioctl_resource_create_blob`
(`DRM_IOCTL_VIRTGPU_RESOURCE_CREATE_BLOB`: `blob_mem` HOST3D / GUEST,
`blob_flags`, `blob_id`, `size`, `cmd` empty), `virtgpu_ioctl_resource_info`
(res_handle), `gem_close`, `prime_handle_to_fd`/`fd_to_handle`, `virtgpu_ioctl_map`
(`DRM_IOCTL_VIRTGPU_MAP` + `mmap` of the DRM fd; macOS: `IOConnectMapMemory64` or
an equivalent into the task), `virtgpu_ioctl_syncobj_*` (the non-simulated
branches), and the `VIRTGPU_BLOB_*` / `drm_virtgpu_*` structs from
`drm-uapi/virtgpu_drm.h` (the header is vendored in `include/drm-uapi/` and
compiles on darwin, so can be reused as a layout reference for the user-client ABI).
The existing kext header `kext/VirtioGPUAPI.h` in this repo is the place for the
macOS equivalents.

Venus-specific wire needs (from the capset above): resource blob types are
`VIRTGPU_BLOB_MEM_HOST3D` (host allocated, memory from `create_from_device_memory`
with `blob_id = mem_id`) and the shmem blob (`VIRTGPU_BLOB_MEM_HOST3D` with
`blob_id = 0` for `supports_blob_id_0`, or guest memory); `VIRTGPU_BLOB_FLAG_USE_MAPPABLE`
for host-visible memory so the guest can `map` it.

## Caveats

- Never executed (no Rosetta here). `-undefined dynamic_lookup` relies on weak
  imports binding to NULL at load; verify once on a real x86_64 Mac.
- ICD manifest path is the meson prefix path; fix it when installing.
- The Metal WSI (`src/vulkan/wsi/wsi_common_metal.c`) is untouched and not
  enabled; headless only until a presenting plan exists (vn_wsi.c is only built
  with x11/wayland/android platforms).
- vtest is built and selectable with `VN_DEBUG=vtest` (needs a vtest server
  socket, `VTEST_SOCKET_NAME`), useful to exercise the guest driver against a
  host without the kext.
