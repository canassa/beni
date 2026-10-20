## 2026-10-20 05:40 CEST — structural passes keep their walks per statement (#492)

**What I did**

Took issue #492 (slice 6 of `plans/type-directed-points-to.md`) on dagon. Profiled `specialise`
on the N=64 dashboard with a cap-48 diagnostic compiler built with frame pointers (DWARF
unwinding gave no user stacks): 387 ms on master, 65% in the structural passes. The plan's
first remedy, caching `preorder` per statement and `Mod.version`, was already built and could
not help. Every write in a module moved `Mod.version`, and Main's `update` and `view` are
each ONE top-level statement holding all 64 widget calls. So every function written in (256 per
pass, capped twice) re-walked that statement in `inlineScan`, `occurrences`, `assignedIn`,
`scanOf`, and each binding `replaceScalars`/`onlyInspected`/`declCount` asked about.

Built (`src/js/Spec.zig`): a change attributed to the top-level statement a pass declares it
is writing in (`within`/`leave`, `Mod.epoch`, `Mod.kept`), and one `NameScan` per statement
answering every name. It is updated in place by the subtrees a change replaces
(`retract`/`extend`), and counted again where a parent's part would change. Also a place
index kept per statement for `fuseAt`, the `backend.md` §9 *As built* note, and a `test-perf`
scenario (red on master, ratio 3.3; green after, 2.1). N=64 cap 48: 387 → 146 ms; N=16
58 → 43; output byte for byte the same; the gates are green.

**What I learned**

- std hash maps cost over a thousand instructions a probe on the self-hosted ReleaseSafe
  compiler the tests run, and `rules_test` forbids maps keyed by dense ids. My first version
  used them per node and put a Schema case 42% over its baseline. Use columns, sorted
  indexes and `KeyMap` with composite keys.
- A safety check that runs lazily, "when a kept scan is next asked", misses a wrong update
  that is used at once and then rebuilt. Check each update where it is made.
- A node's counted part reads its children, so replacing a subtree can change its parent's or
  grandparent's part (`h(x).k`, `x.k(…)`, `x.k.j`). The fingerprint of what each node reads
  caught these, and so did one real golden diff (`emit/release/tea/HttpSendUntracked`): a
  `Copy.atom` copy shares the old call's callee, so a callee no longer identifies its call.
- Safety-build checks bounded to modules of at most 3 000 nodes kept the corpus within budget
  (total +2.0%, browser/tea Http pages +10%). With them unbounded, the whole corpus passes
  (`-Dtest-budget=0`).
