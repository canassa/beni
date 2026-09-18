# DCE — the before-picture

Raw numbers behind `backend.md` §9's *Reachability elimination* sub-sections.
Taken on 2026-09-18 against `b48160b`, built in a throwaway worktree with a
plain `zig build` (**Debug**, so every timing below is a Debug timing and only
the ratios travel). Machine: the development box; one run each, no ABBA — these
are *before* figures for a change that will move them by two orders of
magnitude, so a byte of noise does not turn anything.

Everything marked **approximate** comes from a script that reads the emitted
JavaScript back rather than from the compiler's own graph:

- it splits each generated `.mjs` into top-level declarations on a column-0
  `const`/`function` (the same rule `bench/size.mjs:180-198` already relies on),
- takes every identifier token inside a declaration that is the name of another
  top-level declaration, or of a name bound by a `*.foreign.mjs` import, as an
  edge,
- and walks from the names `out/main.mjs` mentions.

It **over**-approximates (a name inside a string literal counts as a reference)
and it cannot see an edge that is not spelled in the output — but every edge in
the emitted JavaScript *is* spelled, because dev output has no renaming, so the
reachable figures below are a safe upper bound on what the compiler's own graph
would keep. Scripts are not checked in; they lived in the session scratchpad.

## 1. `bench/size.mjs` at `b48160b`, unmodified

`node bench/size.mjs`, whole output. Headline lines only:

| | floor (`Empty.beni`) | `bench/corpus` | total, 71 programs |
|---|---:|---:|---:|
| files | 19 | 26 | 1 356 |
| raw | 70 684 | 125 456 | 5 191 976 gross / 244 096 net-adjusted |
| gzip | 16 896 | 27 100 | 1 230 903 gross |
| brotli | 14 116 | 22 914 | 1 029 824 gross |
| `derived_bytes` / `derived_functions` | **3 159 / 22** | **11 659 / 59** | **248 907 / 1 721** |
| `eq_bytes` / `eq_functions` | 1 041 / 8 | 4 121 / 24 | 83 126 / 644 |
| `compare_bytes` / `compare_functions` | 1 874 / 9 | 6 561 / 21 | 146 716 / 699 |
| `order_bytes` / `order_tables` | 244 / 5 | 977 / 14 | 19 065 / 378 |

The floor's 3 159 / 22 reproduces report 19 §5.1's B column exactly. Its raw
figure has drifted from 68 791 to 70 684 since the spike (`+1 893`), which is
everything that landed on `master` after it; the derived split has not moved.

## 2. Approximate reachability — the null program

`main = Node.done`, built with `--platform=node`.

| | value |
|---|---:|
| generated `.mjs` (excluding `main.mjs`) | 11 files, 53 757 B |
| sibling `*.foreign.mjs` | 7 files, 16 695 B |
| top-level declarations emitted | **188** |
| …reachable from `main` | **2** (`Empty$main`, `Node$done`) |
| declaration bytes emitted | 47 821 |
| …reachable | **93** (0.19 %) |
| derived functions emitted | 22 (3 205 B by this script's split, 3 159 B by `size.mjs`'s) |
| …reachable | **0 / 0 B** |
| sibling exports bound by an `import` | 68 |
| …reachable | **1** (`Node.printLines`, through `Node$done`) |
| generated modules with nothing reachable | **9 of 11** — every `core/*` module |

Predicted output after elimination, by hand from the same tree: `main.mjs`
(232 B) + `Empty.mjs` (102 B, unchanged) + `platform/Node.mjs` (245 B today,
~150 B once its import and export lists shrink to `printLines` / `Node$done`) +
`platform/Node.foreign.mjs` (795 B) + `platform/runtime.foreign.mjs` (848 B)
≈ **2.1 kB in 5 files, from 70 684 B in 19** — a 97 % cut, with
`derived_bytes` exactly 0. That is the acceptance number.

## 3. Approximate reachability — `tests/corpus/run/Dictionaries.beni`

| | value |
|---|---:|
| top-level declarations emitted | 188 |
| …reachable | **28** (14.9 %) |
| declaration bytes emitted | 48 486 |
| …reachable | **14 472** (29.8 %) |
| derived functions emitted / reachable | 22 / **0** |
| sibling exports bound / reachable | 68 / **6** |
| generated modules with nothing reachable | 4 of 11 (`core/Char`, `core/Debug`, `core/Result`, `core/Set`) |

Dictionaries uses `Dict`, which is `where`-constrained throughout, and still
reaches **no** derived function: every comparison it does is
`String$compare`, a hand-written core value, passed as evidence.

### What whole-file sibling copying costs here

A sibling is hand-written JavaScript and is copied whole, so the unit is the
file and not the export. For `Dictionaries`:

| sibling | exports | reachable | bytes | still copied? |
|---|---:|---:|---:|---|
| `core/Basics.foreign.mjs` | 35 | 1 | 4 979 | yes |
| `core/Char.foreign.mjs` | 4 | 0 | 1 207 | **no** |
| `core/Debug.foreign.mjs` | 3 | 0 | 1 715 | **no** |
| `core/List.foreign.mjs` | 3 | 1 | 2 991 | yes |
| `core/String.foreign.mjs` | 20 | 3 | 4 160 | yes |
| `platform/Node.foreign.mjs` | 3 | 1 | 795 | yes |

Dropping the two unreachable files saves 2 922 B. The four that stay carry
**12 925 B for six reachable exports of sixty-one**, against ~14.5 kB of
reachable generated code — so per-export sibling elimination is worth roughly
as much again as everything else this pass does, and it is not in M3c.

## 4. Approximate reachability — `bench/corpus`

Built the way `bench/size.mjs:434-495` builds it: a synthesised `BenchMain`
that imports the seven modules the compiler can take (`Counter`, `Data.Token`,
`DictExtra`, `FormValidation`, `PrettyPrinter`, `Router`, `Ui.View`) and whose
`main` is `Node.print "size"`.

| roots | decls reachable | decl bytes reachable | derived reachable | modules with nothing reachable |
|---|---:|---:|---:|---:|
| `main` only | **1 of 336** | 43 of 97 357 | 0 of 59 | 16 of 18 |
| every export of the root package | 240 of 336 | 75 655 of 97 357 | **48 of 59** (10 614 of 11 790 B) | 2 of 18 |

This is the whole argument for the `--library` root rule and for changing
`bench/size.mjs`. Under `main`-only roots the benchmark measures one
declaration and stops meaning anything. Under library roots it measures the
library, and **derived code barely moves** — 90 % of the derived bytes survive,
because a `pub` type's `eq` and `compare` are exported and a consumer may call
them. Both facts belong in the spec: the first is a bug the instrument would
otherwise acquire silently, the second is the honest statement that DCE does
not shrink a *library*.

## 5. Emit cost today, for the throughput acceptance

`beni build --self-profile=… --platform=node tests/corpus/run/Dictionaries.beni`,
Debug binary:

| phase | µs |
|---|---:|
| whole build (wall, first to last event) | ~101 200 |
| `emit` (single event, thread 0) | **18 719** |
| counters | `emitted_files 19`, `emitted_bytes 71 679`, `modules 11` |

Emit is ~18 % of a Debug cold build and prints 71 679 B. The reachable share is
29.8 % of declaration bytes (§3), so eliminating before lowering removes about
two thirds of the lowering and printing work on this program. The reachability
walk itself is a DFS over 188 + 68 + 22 = 278 nodes; at 100 k lines the node
count is O(declarations) and the walk is still microseconds. **The expectation
is that `emit` gets faster, not slower**, and `emitted_files` / `emitted_bytes`
are already the counters that show it.

## 6. `emit/` goldens under the two candidate root rules

Every fixture under `tests/corpus/emit/` built exactly as
`tests/blackbox/corpus_test.zig:472` builds it, then the fixture's own
`out/<Stem>.mjs` analysed for which of its declarations survive.

| fixture | decls | exports | imports | dropped, roots = `main` | dropped, roots = the module's exports |
|---|---:|---:|---:|---:|---:|
| ComparisonOperators | 10 | 10 | 2 | 9 | **0** |
| ConstantMethodCall | 5 | 5 | 2 | 4 | **0** |
| DerivedCompare | 15 | 8 | 2 | 14 | **0** |
| DerivedCompareNominal | 18 | 13 | 2 | 17 | **0** |
| DerivedEmissionOrder | 13 | 7 | 2 | 12 | **0** |
| DerivedEqList | 5 | 3 | 2 | 4 | **0** |
| DerivedEqNominal | 18 | 14 | 1 | 17 | **0** |
| DerivedEqShapes | 11 | 7 | 1 | 10 | **0** |
| EvidenceParameters | 8 | 5 | 2 | 7 | **0** |
| EvidenceValue | 8 | 6 | 2 | 7 | **0** |
| MethodTargets | 8 | 8 | 3 | 7 | **0** |
| PrimitiveEvidence | 10 | 5 | 2 | 9 | **0** |
| TailCallLoop | 3 | 3 | 3 | 2 | **0** |
| TypeDispatch | 7 | 6 | 2 | 6 | **0** |

**14 of 14 goldens change under `main`-only roots; 0 of 14 change under the
library rule.** Several would be gutted rather than merely re-blessed:
`DerivedCompareNominal.js` is 115 lines of which 114 are derived code and one
is `main`, and its intent comment says in so many words that *nothing below
uses these and they are all emitted anyway* — a claim about eager derivation in
the declaring module that is still true and that a `main`-only build would
delete the evidence for. Import lines move too: 12 of the 14 lose at least one
import under `main`-only roots.

## 7. Facts about the current emitter that the numbers rest on

- Every module of the graph is emitted, unconditionally —
  `src/js/Emit.zig:673-717`, `for (0..count)`. No filtering of any kind exists;
  a whole-repo grep for `reach|live|dead|prune|shake` in `src/` finds prose only.
- `emissionOrder` (`src/js/Lower.zig:496-538`) is a permutation of *all*
  declarations, not a subset: `for (0..count) |root|` at `:506`.
- The export list is `pub` values with a body + every nominal derived row +
  `main` when it is not `pub` — `src/js/Lower.zig:637-680`. Nominal derived
  rows are exported **regardless of the type's `pub`** (`:639-660`), which is
  why a library build cannot drop them.
- Cross-module imports are already use-driven, collected by `need` /
  `needDerived` / `needName` during lowering (`src/js/Lower.zig:743-759`), so
  they shrink for free once a referencing declaration is dropped.
- The **sibling** import is not: `importStatements` imports every
  `foreign_value` declaration of the module whether used or not
  (`src/js/Lower.zig:688-695`).
- A sibling file is copied iff its module declares any `foreign`
  (`src/js/Emit.zig:725-729`); the platform runtime is copied unconditionally
  (`src/js/Emit.zig:736-757`).
- A declaration's instructions are contiguous — `Bir.Decl.inst_start` /
  `inst_end`, used by `Lower.declSiteRange` (`src/js/Lower.zig:1612-1617`) — so
  a per-declaration edge scan is a slice walk and not a tree traversal.
- `Bir.refs` records `import_value(module symbol, name symbol)` **symbolically**
  and `Resolve` never rewrites it (grep: no `refs` in
  `src/resolve/Resolve.zig`), while it *does* rewrite the instruction into
  `ext_value(Graph.Index, ValueIndex)` (`src/resolve/Resolve.zig:303-309`).
  That asymmetry is why the cross-module leg of the graph reads instructions
  and not `refs`.
- No sibling in `core/` or `platforms/node` has a top-level statement other
  than imports, exports, `const`/`function` declarations and comments —
  checked over all seven. `platforms/node/runtime.js` is the only one with a
  module import (`node:process`).
- A top-level beni constant can have a *call* in its initialiser and does:
  `platform/Node.mjs` emits `const Node$done = Node$printLines({$:0,…});`.
  `printLines` returns `{code, out}` and writes nothing, so it is pure to
  evaluate — which is the property §9's drop rule needs.
