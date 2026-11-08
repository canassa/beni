## 2026-11-08 01:39 CET — Binary and GPU sources: review fixes

**What I did.** Answered the independent review of PR #1284. `Binary.view`
named its constructor with a computed `Js.global`, which every worker build
refuses; each kind now has its literal, and `browser/dedicated/BinaryInWorker`
keeps `view` and `Wgsl.encode` in a worker (it fails before the fix).
`Binary.Error` became one error type per kind of operation, `view` takes a
byte range, and every reported range is bytes. `Binary.Wgsl`'s errors split
into layout, uniform and codec errors. Atomics refuse a Number outside the
view's range, canvases refuse dimensions HTML or WebIDL would reset or throw
on, `Video.frame` checks the source before the rectangle and keeps the
TypeError reading to image and video elements, an `<img>` with no source is
`Empty`, and shared storage is recognised across realms. webgpu.md §3.1–§3.2
and §7 were amended to the built names. The fixtures print observed values,
each derived by hand, and the page fixture runs its acquisition and size
checks in happy-dom too.

**What I learned.** WGSL 12.1 exempts the uniform address space from the
`@align` multiple rule; only member offsets and strides are constrained
there, so the review's suggested `@align` check would refuse valid shaders.
happy-dom has no `crossOriginIsolated` and no `videoWidth`, so those checks
belong in Node with a probe or in Chrome. A `browser/dedicated/` fixture is
built in both modes by the gates even though only Chrome runs it, which is
what makes a realm refusal a gate failure.
