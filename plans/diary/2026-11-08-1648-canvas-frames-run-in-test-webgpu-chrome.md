## 2026-11-08 16:48 CET — canvas frames run in test-webgpu's Chrome

**What I did.** Investigated #2267: in `test-webgpu`'s Chrome 153 a canvas
`getCurrentTexture` lost the device, and the next `popErrorScope` and
`onSubmittedWorkDone` rejected with `OperationError`. Reproduced it in plain
JavaScript over CDP, then measured Chrome configurations one at a time. The
runner now adds `--enable-features=Vulkan --use-vulkan=swiftshader
--use-angle=vulkan`; `SurfaceFrames` and `CanvasPage` lose their
`.webgpu-skip` and gain a `_expected.webgpu-expected` with the real clear
colors. `test-webgpu -Dcorpus=gpu/`: 106 passed, 0 skipped.

**What I learned.** The cause is the GPU process, not WebGPU. On ANGLE's
SwiftShader GL (the default with no GPU) Chrome composites in software, Skia
has no GPU backend, and the shared-image factory has no backing for a WebGPU
swap chain texture: Chrome logs `Could not find SharedImageBackingFactory …
WebgpuSwapChainTexture` and destroys the device. With Skia and ANGLE on
SwiftShader's Vulkan (`chrome://gpu`: Skia Backend GaneshVulkan, Vulkan
Enabled) the backing exists. `--headless=old`, `--use-angle=swiftshader`,
`--enable-unsafe-swiftshader`, `--ignore-gpu-blocklist`, SkiaGraphite and
`--enable-features=Vulkan` with ANGLE still on GL do not help. Without
`--use-vulkan=swiftshader` the Vulkan path picks a host GPU (dagon's NVIDIA,
which then ran out of device memory), so the pin matters. The skip's
`OperationError` was a host configuration failure; the engine's defect rule
was right to stop on it.
