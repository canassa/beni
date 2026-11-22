## 2026-11-10 15:56 CET — a workers/ fixture can inject a host fault (#1263)

**What I did.** Worker `workers-fault-inject`. The `workers/` corpus kind could not make a host
call throw anything but the failure the platform names, so no fixture saw the test of a `catch`
(rule 9). On master the gap was still there and the three `Js.catchIf` tests too (`resolveUrl` and
`idFromString` in `Worker.beni`, `kvPut` in `Worker/Storage.beni`). A fixture may now hold a
`host-faults.mjs`, a wrapper entry module. The build does not change. The harness
(`corpus_test.zig`, `runWorker`) copies the file into the output directory as `_host-faults.mjs`
after the build, and `tests/workers/driver.mjs` starts the Worker from it when it is there. The
wrapper imports `./_worker.mjs`, replaces one host call, and exports the build's default and its
object classes again. Four fixtures use it: `HostFaultPut` (a plain `Error` from `kv.put` stops the
object), `HostFaultFull` (an `Error` with `SQLITE_FULL` is `Err Full`; a value that is no `Error`
with the same message stops the object), `HostFaultId` (a `RangeError` from `idFromString` is a
500, not `InvalidId`) and `HostFaultUrl` (a `RangeError` from `new URL` is a 500, not "does not
resolve"). `tests/corpus/README.md` (*A host fault*) and `boundary.md` §9.12 (k) say how.
Measured with `zig build test-workers`: 42 cases green with the platform as it is; with the three
tests changed to `λ_ → True`, 42 cases and 8 failures, exactly the eight new cases.

**What I learned.**

- A wrapper entry is enough; no test platform is necessary. Under workerd (Miniflare
  4.20260518.0) a method on the prototype of a host object can be replaced:
  `Object.getPrototypeOf(state.storage.kv).put` and `Object.getPrototypeOf(env.NS).idFromString`.
  A class that extends the build's object class is accepted as the Durable Object class, and
  `globalThis.URL` can be replaced by a subclass before the first request.
- The copy goes into the output tree, not beside it. The run-hash digest covers the output tree
  before and after the run, so a file the driver wrote there itself would make the recorded digest
  differ from the checked one. The harness writes it before the first digest.
- A fixture that only shows the named failure (`SQLITE_FULL` is `Err Full`) cannot be red with a
  catch-all mutant. It needs a second step with a value that the test must refuse, here a thrown
  object that is not an `Error`.
- The error page of a defect has the same `content-length` in the development and the release
  build, wrapper included, so one golden serves both cases.
