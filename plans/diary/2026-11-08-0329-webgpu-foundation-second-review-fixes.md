## 2026-11-08 03:29 CET — WebGPU foundation: second review fixes

**What I did.** Answered the second review of #2254. An adapter is reserved inside the
request's `start`, so a cancel delivered where the request would first suspend leaves it
free; `CancelledRequests` reaches that case with `Task.uninterruptibleMask`, and fails with
the reservation moved back before the wait. Every defect now carries its context (an `Error`
naming the operation and the device, the original as `cause`), and a channel drops a second
defect and keeps the caller's clock and log context for the path that starts a new fiber.
Snapshot counts must be non-negative integers (`SnapshotNotInteger`). The engine-visibility
refusal is now built for `browser-tea` itself (`build/bad/tea/`), and fails when
`Gpu.Engine` is added to its re-exports. A wait marks itself started only once its promise's
reactions are attached.

**What I learned.** A queued fiber unwinds at its resumption when a cancel was latched, so
only a mask lets a cancel arrive at the first suspend point after more code ran. Core's
`Task` lets a fiber's clock and log context be carried to another fiber, but not its
scheduler (#2257); today the browser stops the whole page on any defect anyway.
