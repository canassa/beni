# Schema representation prototype

**Dated research artifact — 2026-09-22.** Report 33 is the record; this code and
the captured `results.json` are its evidence. This is not a supported library,
is not wired into `zig build`, and is not a project gate. Limitation assertions
deliberately pin observed wrong behavior; green does not mean production-ready.

An isolated ordinary-Beni experiment, not production schema syntax or an Effect
parity claim. See [the plan](../../plans/schema-prototype.md) and
[the results report](../../docs/design/research/33-schema-prototype.md).

Run with the installed compiler and pinned Node 24:

```sh
nix develop --command node bench/schema-prototype/run.mjs
```

This builds development/release at jobs 1/8, checks deterministic output, runs
the scenarios under Node and Chrome, checks negative compilation fixtures, and
reports size and one browser microbenchmark. Chrome defaults to the macOS
application path; use `--no-browser` for a semantics-only run.

- [Library representation and limits](LIBRARY.md)
- [Scenario coverage and counterexamples](CASES.md)
- [Runner and measurement method](RUNNER.md)
- [Unresolved effects compatibility](EFFECTS.md)

The foreign boundary lives only in `platform/`; `src/` and `cases/` are Beni.
No production compiler/core changes or new schema grammar are included.
