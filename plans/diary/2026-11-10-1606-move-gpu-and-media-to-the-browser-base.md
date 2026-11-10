## 2026-11-10 16:06 CET — Move Gpu and media to the browser base

**What I did**

- Moved `Gpu`, every `Gpu.*` module and `Browser.Canvas`, `Image`, `Video` and `Source` from
  `browser` to `browser-base`. The generator, staleness and coverage checks, the format
  exemptions and the ownership lists follow the files.
- Added `browser/prerender/BaseGpu`, a prerendered inline page that draws on its hydrated canvas
  and cleans up, plus the refusals `BaseGpuInView` and `BaseGpuInInit`.
- Added the `_expected.webgpu` marker, so `test-webgpu` also runs that prerendered page, against
  `_expected.webgpu-expected`.
- Replaced `browser/dom/GpuEngineReachable` with `GpuEngineHidden` refusals for `browser` and
  `browser-inline`: the engine is private on every renderer now (#2256's debt).

**What I learned**

- A constant that a prerendered `init`'s command reads is checked like `init` itself. A fixture
  helper that calls `Debug.todo` made a top-level colour constant impure. Make it a function.
- `browser-inline` has no `For` yet; a fixture shows its lines as one string.
- `test-webgpu` cannot run on this Mac, but a headless Chrome with `--enable-unsafe-webgpu` on
  Metal, driven by `tests/browser/driver.mjs --chrome=<ws> --webgpu`, is a quick way to see a
  real device succeed before the dagon run.
