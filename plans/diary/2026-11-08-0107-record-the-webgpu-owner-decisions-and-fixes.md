## 2026-11-08 01:07 CET — Record the WebGPU owner decisions and review fixes

**What I did.** Added a fix round to PR #2248 (`webgpu.md`). Recorded the owner's three decisions
of 2026-11-08. First, the lease refuses ordinary calls from every fiber. Second, every GPU operation
is a qualified call or a `▷` pipe. Third, `test-webgpu` is opt-in. Rewrote the §2.1 dispatch
argument. Classified all 36 GPU interfaces as handles, snapshots or the entry point, and updated the
owner column of `coverage.md` and `inventory.py` to match. Defined the set of operations the lease
refuses and its exemptions. Finished the deadlock argument and named the livelock hazard. Gave
drained outcomes a defect owner. Moved the main-thread `OffscreenCanvas` into S3 and S5. Made
naming a step of each slice. Wrote the realm claim as an assumption that a generator check enforces.

**What I learned.**
- A forwarding method in `Gpu.Handle` cannot reach a native handle at all, because an alias is
  looked through to the generated module. The partial-coverage argument was not the real reason.
- The realm check proves nothing per GPU operation, because the engine calls the GPU through
  private code. Worker admission rests on uniform `(Window, Worker)` exposure, so the generator
  must assert it.
- I edited `inventory.py` and `coverage.md` together by hand, because dagon has no python3 to
  run `inventory.py --check`.
