## 2026-11-09 02:39 CET — Chrome pages wait for image promises

**What I did.** Master's Chrome job failed on two WebGPU pages. Both failed
the same way on dagon, so azathoth was not the cause. `browser/gpu/BufferRefusals`
had no Chrome golden: in `test-browser` it runs on the fake GPU host, and
Chrome gives a page that is not cross-origin isolated no `SharedArrayBuffer`;
`test-webgpu` had its own golden, so nobody saw it. I blessed
`_expected.chrome-expected`; it differs from happy-dom's only there.
`browser/tea/WebGpuInputs` raced the driver: `Browser.Image` waits for
`decode()` and `createImageBitmap()`, which settle in real time, and the
driver's settle did not wait for them, so the click's transcript was
sometimes taken before the answer arrived (it passed on master's next run
and failed in every harness run on dagon). The prelude now counts those two
promises as it counts a native WebGPU one, in both DOMs (#2330).

**What I learned.** A page run alone in a fresh Chrome usually won the race;
the harness, with the same page and flags, lost it every time. A transcript
that depends on a host promise needs the driver to count it, or it is a
coin toss, not a golden.
