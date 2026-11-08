## 2026-11-08 03:45 CET — WebGPU checked operations: second review fixes

**What I did.** The cancel fixture of the checked wait did not test the engine:
`releaseOnePop` released the validation pop, and the faulted internal pop rejected unhandled
inside the stub, which the driver took for the page's throw. The stub now applies a held
pop's fault only when it is released, `GpuHost.releasePop` names the filter, and
`CancelledCheckedDefect` releases the internal pop: its dev golden shows the crash screen, and
it fails with `leaveScopes`'s report removed. A pop's defect now names the device and the
operation, and a cancelled operation's object is recorded rejected.

**What I learned.** A test stub's own unhandled rejection can stand in for the engine's
defect in a transcript: a fixture about a defect must be shown to fail without the code it
is about. The merge of the S1a fixes into this branch was clean, so it stayed a pure merge.
