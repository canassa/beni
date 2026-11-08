## 2026-11-08 00:52 CET — align Binary and GPU sources with native types

**What I did.** Merged master into `feat/webgpu-inputs` (PR #1284) and
finished its main-thread part of #1278. The WIP's handles were a parallel
family of `foreign type`s (`Binary.Buffer`, `View`, `Source`,
`Browser.Source.ImageElement`, …); they are now the generated native types of
`Browser.Host`, as option C asks (workers.md §4). The native catalogue gained
intrinsic revision 2 — ArrayBuffer, SharedArrayBuffer, DataView and every
typed array as types with no operations — and the GPU sources' IDL types ship
as the generator writes them; the shipped-module test pins all of them.
`Binary.View` and `Binary.Source` became ordinary tagged unions over those
types, which is how the bindings contract maps a typedef, and which removed
`constructor.name` sniffing from `Binary.Atomics`. In-realm `transfer` now
uses ArrayBuffer.prototype.transfer with each failure typed. Worker
transfers (`Browser.Source.clone/send/receive`, `Canvas.transfer`) were
removed, not stubbed: they wait for #1299. The fixtures print values instead
of `pass`, and the browser fixture runs every source in Chrome.

**What I learned.** `-0.0` and `negate 0.0` compile to `0 - 0.0`, which is
+0: a silent wrong answer for any Float (#2247). The ownership parity check
fails a tea page that sends a `List` from `Cmd.perform` (#2249). happy-dom
20 has ImageData, but its `createImageBitmap` refuses its own ImageData with a
TypeError, so a source fixture must gate on `VideoFrame`/`OffscreenCanvas`
rather than on ImageData. Adding a core file needs a watcher restart: the
build graph walks `core/` when it is configured.
