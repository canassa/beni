# 2026-10-31 21:24 CET — profile the ordinary generated batch

Dagon clock:2026-10-31 21:24:07 CET. Added norm§22 before implementation.
An optional borrowed GeneratedUnit.self_profile path now reaches ordinary
Session.init. The checked-controls consumer derives the literal outer path plus
.checked-controls.json only for a nonempty generated batch, and frees it after
unit.deinit. Without the outer flag, profiling remains disabled and there is no
new allocation/file/output. Unsupported-only does not start a batch or touch an
existing sidecar; consumers must choose fresh paths for independent measurements.

Actual retained CLI trace: inner modules15,embedded_modules13,modules_checked2,
cache_hits0,dropped_events0. The two ordinary check events name
GeneratedControls.beni and ControlBridge.beni. The outer warm trace separately
records modules13,embedded12,checked0,hits1. These are observed counts, not pinned
core-size constants or a profiling-time performance result. Query stdout is
byte-identical with profiling off/on.

The3new registered cases pass separately and all20checked-control cases pass:
0skipped,0failed,0leaked,0logged errors. Tests check ordinary counter partition
and named checks, unsupported fresh-path absence and reused-sidecar preservation,
and an inner path I/O failure returning2with structured diagnostic/no positive
receipt. Existing allocator/error unwinding remains in use. No CLI/type/effect
rule, ownership bypass, counter schema, production Task change or budget waiver.
One development Debug compiler build and focused tests only; no full gates or
optimized cost runs. Evidence lives in parent scratch/typed-control-profile-reviewer.
