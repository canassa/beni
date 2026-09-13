# Monomorphisation vs. incremental builds: does Roc disprove the argument?

Commissioned to test a specific objection: **Roc does whole-program specialisation and is reputedly
fast, so the claim that the two are incompatible must be wrong.** Three strands — Roc's measured
compile times, where its specialisation sits relative to its cache, and how Rust reconciles the two.

**Caveat:** WebSearch was exhausted; agents worked from the vendored repos, their git history,
Roc's Zulip, and directly constructed URLs.

---

## The short answer

**Roc is fast where it caches, and slow where it doesn't — and specialisation is the part it
doesn't cache.** Both halves are true at once, which is why the reputation and the measurements
seem to conflict.

| Operation | Size | Time |
|---|---|---|
| `roc check` | 19k–58k lines | **0.06–0.78s** |
| `--opt=dev` build | 55,123 lines (230 modules) | **16.9s** |
| `--opt=dev` build | 32,821 lines | **7.1s** |
| `--opt=speed` build | same app | **42–202s** |

Source: Zulip `#announcements › build times survey`, a production app being migrated to Roc,
Aug–Sep 2026 (ids 621742635, 621893922, 623716616). Dev-build throughput works out to ~3,400
lines/s; Elm manages ~120–130k lines/s for its *entire* pipeline, roughly **35× faster per line**.

In fairness: those figures improved 5× in two weeks as the team fixed pathologies (82.5s → 16.9s on
the same file), and Roc is pre-1.0. Before those fixes the same app took 1m33s, with one entrypoint
exceeding 30 minutes or OOMing.

**The "under 1 second" claim on roc-lang.org is a target, not a measurement** — the page carries no
benchmarks. And no 100k-line Roc program has ever been compiled and timed; the compiler's own
perf harness, built around a 19,269-line synthetic file, is currently disabled and replaced with a
one-line stub.

## Why: the cache boundary sits before specialisation

Roc's per-module cache covers canonicalisation and type checking only. The phase machine
(`src/compile/coordinator.zig:437-452`) runs `Parse → Canonicalize → WaitingOnImports → TypeCheck →
Done`, and there is no post-check phase in it. Only once every module reaches `Done` does the CLI
make a single global call — `lir.CheckedPipeline.lowerCheckedModulesToLir`
(`src/lir/checked_pipeline.zig:661`, from `src/cli/main.zig:11846`) — which runs Monotype →
Monotype Lifted → Lambda Solved → Lambda Mono → LIR over the **whole reachable program**.

`design.md:2051-2064` states it outright:

> "The compiler does not cache Monotype IR, Monotype Lifted IR, Lambda Solved IR, Lambda Mono
> decisions, boxy representation plans... as part of checked modules. Those structures are
> target/session products of the current root compilation."

A `SpecializationCacheFile` format *does* exist (`src/postcheck/monotype/serialize.zig:130-152`) —
but it has **zero call sites** in the driver. Its reader/writer functions appear only in their own
unit tests, and nothing ever populates `loaded_specialization_shards`. It is unwired scaffolding.
It is also coarse: an all-or-nothing validity hash over the entire reachable specialisation set
(`computeValidityId`, `serialize.zig:1161`), not per-function memoisation.

**So specialisation is paid in full on every build**, whatever the checking cache does.

### The hypothesis that turned out false

I expected dev builds to skip specialisation — that would have dissolved the paradox. They don't.
`design.md:6993`: *"If the flag is omitted, every optimization level uses `.lss`. `.boxy` is
experimental and is selected only by the explicit `--specialize=no` opt-in."* Confirmed in code:
`currentRuntimeSpecializationStrategy` returns `explicit orelse .lss` (`src/cli/main.zig:11732`).
`--opt` selects only the codegen backend (`cli_args.zig:84-91`), a separate axis. **Roc's fast path
and its fast output are the same configuration, and both pay mono cost.**

### One-line edit, traced

A body edit in a leaf module changes its `source_hash`, so its `CheckedModuleId` changes. Because
that id folds in `direct_import_checked_module_ids`, **every transitive importer's id changes too** —
they all miss cache and get re-checked, even when the edit touched nothing in the interface. No
semantic or interface hashing short-circuits this. Then, regardless of what hit or missed,
specialisation reruns from scratch over the entire program.

This is worth noting independently of monomorphisation: it confirms that §8.1's interface firewall
is ahead of Roc's shipped behaviour.

### The team's own account

`#compiler development › "Caching strategy for Roc"`, 2025-01-15 — Richard Feldman:

> "unfortunately the most expensive parts of the compilation are in the backend of the compiler,
> and they're also the most challenging to cache" (id 493788325)

> "the specializations are the hard part" (id 493788478)

Joshua Warner's proposed mitigations were (1) cache only where specialisation isn't required, and
(2) reduce the need for it via Swift/.NET-style type erasure — noting that the latter *"does remove
the ability to effectively cache a lot of interesting code."* As of the current source, caching mono
output is recognised as valuable and unsolved; the hard part they name is that a new specialisation's
home module is ambiguous — the generic's module, or the call site's?

## Rust: possible, at a price, still open after a decade

Rust ships monomorphisation *and* incremental compilation, so the combination is clearly not
impossible. How it works:

- Mono items are collected whole-crate by `collect_and_partition_mono_items`, just before codegen.
- The results are partitioned into **codegen units**, and the CGU — not the function — is the cache
  line. Incremental builds use **256 CGUs instead of the default 16**, purely to make invalidation
  finer.
- A green CGU dep-node means its object and bitcode files are still valid and LLVM is skipped.

The costs, from Rust's own documentation and issue tracker:

- **Worse codegen.** More, smaller CGUs mean less cross-function inlining; the docs say incremental
  "inhibits certain optimizations... and is therefore not recommended for release builds."
  Incrementality is bought by degrading output.
- **Cross-crate duplication is the default.** *"All monomorphized (specialized) functions from Crate
  A appear within a single codegen unit for Crate B"* — downstream crates re-instantiate upstream
  generics into their own units rather than sharing.
- **Memory.** Incremental-compilation memory blowup is a labelled bug category (`I-compilemem`),
  with live issues reporting 32GB+ RAM and 30-minute compiles (#122944), a 2026 regression (#161660)
  and an allocator-failure ICE (#137536).
- **Still open.** Nethercote's 2025 compiler-performance post lists incremental compilation among the
  areas with the most remaining headroom, and reports a mono-item efficiency change (PR #132566)
  worth a 5% mean wall-time reduction on incremental builds that involve codegen.

*Correction to earlier notes:* the "16–19GB incremental artifacts / OOM on an 8GB machine compiling
`rustc_middle`" figure cited in report 04 could not be re-verified on recheck. The failure *shape* is
well evidenced by the issues above; treat that specific number as unconfirmed.

## Conclusion for this design

1. **The objection doesn't land, but it sharpened the claim.** The right statement is not
   "whole-program work is impossible with incremental builds" — Rust disproves that. It is that
   **specialisation is the phase nobody has made cheap to cache**, and the two projects that tried
   say so in their own words: Feldman calls it "the hard part," and PureScript's creator declined to
   build it because "being global, it doesn't always play nicely with separate compilation" (09 §2).
2. **Roc's numbers support the budget, from the other direction.** Its *checking* — the phase it
   caches — runs 58k lines in 0.78s, which is the right ballpark for §2's targets. Its *building* —
   the phase it doesn't cache — is 35× slower per line than Elm's whole pipeline. We are aiming at
   the first profile, and the reason we can is that there is no specialisation phase to pay for.
3. **§8.1 is validated as a side effect.** Roc's cache key folds importer ids, so a private body
   edit invalidates every transitive importer's checking. The interface firewall exists precisely to
   avoid that, and Roc's measured check times are achieved *despite* this, not because of it.
