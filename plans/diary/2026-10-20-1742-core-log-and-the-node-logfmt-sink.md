## 2026-10-20 17:42 CEST — core Log and the node logfmt sink

**What I did**

- Read #358's contract: `boundary.md` §9.8.15 (b), §9.8.10 (d), §9.8.16 (b),
  `transparent-effects-proposal.md` §17.5, §17.6 and §17.11, research 48's log rows and
  `plans/effects-plan.md` §8.
- Listed what the spec left open. Five were details, and I took each one from the Effect source
  that §17.11 cites: the exact `logfmt` line, the level names, the order of the spans, where a
  re-annotated key goes, and a time outside a `Date`'s range. One was the owner's: §9.8.16 (b)
  put `Log.write`, a `Cmd`, in the browser's `Log`, which §9.8.15 (b) removes, and core cannot
  import `Cmd`. I asked on the dashboard (`node-log-q1`).
- Built `core/Log.beni` (levels, the direct forms, `log`, `Entry`, `setSink`, `logfmt`) and the
  sink `Io.run` installs. Wrote `run/LogFmt`, `run/LogSetSink`, `run/LogDefaultSink` and a
  black-box test of an `Io.run` program's exact standard error.
- Measured bytes with a `master` compiler on all 519 programs and pages, and opened #511 for the
  release residue.

**What I learned**

- Module names are not global the way research 48 says. `Graph.lookup` resolves a name in the
  module's own package, then the platform, then core, and `duplicate_module` fires only inside
  one package. So a browser `Log` and a core `Log` can both exist: the browser's hides core's.
  That let slice 1 land before the owner's answer.
- §17.11's `logfmt` example disagreed with the Effect function it cites. Effect quotes a value
  only when it holds white space, `"` or `=`, and writes spans before annotations.
- `--release` drops a write to a module-level cell that nothing reads, and the function written
  there. But reachability runs first, so a module reached only through that function keeps its
  `impure` top-level initialisers: `List.isPlain` in every `Io.run` program (#511).
- A `run/` fixture checks standard output only. For standard error, `World.buildAndRun` takes
  `.stderr = .{ .exact = … }`, and the run hash covers it.
- `e` is a prelude value, so `λe →` is a shadowing error.
