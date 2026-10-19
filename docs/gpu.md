# GPU on the Surface Duo 2

The Duo 2's Adreno 660 renders Luma's desktop on Microsoft's 5.4 kernel, where
the GPU is driven by Qualcomm's KGSL (`/dev/kgsl-3d0`) rather than drm/msm.

## Pieces

| Piece | Source | Role |
|---|---|---|
| `a660_sqe.fw`, `a660_gmu.bin`, `a660_zap.*` | stock vendor image, `/vendor/firmware` | microcode, GMU firmware and the zap shader KGSL loads (the zap shader through PIL) |
| Turnip with the KGSL backend | Fedora's Mesa source RPM, built by `duo2-build-turnip.sh` into `/opt/mesa-kgsl` | Vulkan on the Adreno through KGSL; Fedora builds Turnip for drm/msm only |
| wlroots `.duo2` | Fedora's wlroots source RPM plus `packaging/wlroots/`, `duo2-build-wlroots.sh` | lets the Vulkan renderer use a GPU with no DRM node |
| `70-luma-duo2-gpu.rules` | Duo 2 overlay | `kgsl-3d0` 0666 as the stock `ueventd.rc` has it; ION for the seat user |
| `/etc/environment` | Duo 2 overlay | `WLR_RENDERER=vulkan`, `WLR_VK_ALLOW_NON_DRM_DEVICE=1`, Turnip-KGSL's ICD |

## How the frames get to the panels

wlroots allocates each output's buffers with GBM on the display device
(`card0`, the SDE): linear XRGB8888 scanout buffers. The Vulkan renderer
imports them as dma-bufs (`VK_EXT_external_memory_dma_buf`; Turnip's KGSL
backend uses `IOCTL_KGSL_GPUOBJ_IMPORT`) and renders into them; the SDE scans
them out. Client buffers that already fit go to the panel directly
(direct scan-out).

wlroots matches its Vulkan device to the display through
`VK_EXT_physical_device_drm`, which a KGSL device cannot offer, so it never
picked the Adreno. `0001-render-vulkan-allow-a-GPU-without-a-DRM-node.patch`
lets it use the single such device when `WLR_VK_ALLOW_NON_DRM_DEVICE=1`, and
share buffers on the display device's node.

## Checks

- `duo2-vkprobe` (tools/duo2-vkprobe): lists the device and runs a submission.
  Turnip refuses `VK_KHR_display` on KGSL, so `vulkaninfo`, which enables
  every instance extension, cannot be used.
- `duo2-dmabuf-test`: the GPU fills a GBM scanout buffer through its dma-buf;
  the CPU reads the pattern back.
- `frameprobe.py` (GTK 4 tick callback): 60 fps on both panels, median
  16.7 ms, under the Vulkan renderer.

## Not yet

- OpenGL for applications: Zink (GL on Vulkan) matches its Vulkan device to the
  DRM render node like wlroots did, and fails the same way. GTK 4 and
  libadwaita applications avoid GL: `GSK_RENDERER=vulkan` renders them on
  Turnip directly (60 fps, measured with `frameprobe.py`). GTK 3 (Phosh's own
  shell) draws with cairo.
- Implicit sync: KGSL has no dma-buf sync_file import/export, so wlroots
  falls back to blocking on the GPU.
- `/dev/dma_heap` does not exist on this kernel; Turnip allocates from ION.
