## 2026-11-04 07:49 CET — a runtime module without markup

**What I did**

- Built #1812 on `program-runtime-module` (step 16 of `plans/runtime-in-beni.md`), after the owner chose A for `runtime-in-beni-q3` (both `Js` spellings, so `cloudflare`'s runtime moves and needs this). A platform with no markup names its runtime module at the top level of its manifest (`"module": "Rt"`), the module supplies `run` alone, and no runtime file is written. `Manifest.zig`, `platform.zig` (two exit-2 refusals) and `Emit.zig` changed; the spec first (`boundary.md` §5.2, §9.12 (c); `backend.md` §2, §9, §15.1).
- Rebased and pushed #1816 over Jayson's merge commit (the `IoReadDir` golden #1809 added was blessed over the runtime module); both #1809 and #1816 merged this morning, their branches deleted.
- Two `run/` fixtures with a platform of their own, `ProgramModule` and `ProgramModuleExports`, and five `World` tests.

**What I learned**

- `"exports": "program"` refused every runtime module ("not in this slice"), and `cloudflare` declares it: the feature was not usable by its one consumer until the refusal became the markup runtime module's only and the exporting entry learned to import `run` from a module.
- Under `--release` the entry's `run(main)` is handed to the specialisation pass as a call whose result is unread (`backend.md` §9). Under the exports mode the entry reads the result, and the pass pruned the returned object to `{}`: `run: hello` printed, then `$beniProgram.exports is not a function`. The fix lets `run` and `main` escape under that mode; a form that hands the call over with its result read is open.
- The corpus has no form for an exit-2 manifest failure (one stderr line, no diagnostic), so a refusal of the chain is a `World` test in `platform_test.zig`, beside `markup_split`'s.
- A `run/` project fixture with a `platform/` directory builds for that platform, so a feature of the manifest is proved by a fixture, not by a new `tests/platforms/` entry.
- `docs/design/backend.md` holds a double-encoded section sign (`Â§`) on 1 091 lines on master; a text match of `§` there fails. Issue #1837.
