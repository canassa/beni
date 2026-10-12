# 77 — The ownership checker's slice 3a: destructive reads, exclusive contents, closures

*2026-10-12. What `beni dump --stage=ownership` says once the destructive read is two asserted primitives with
`core/List`'s loops inferred over them, exclusive contents are built, local-function groups and once closures are
solved, a function parameter called inside a lambda stays in sight, and a function value handed to JavaScript
escapes what it captured (`ownership-checker.md` §17–§18) — over the corpora of research 74 and 76, line by line
against slice 2. Every figure is **[measured]** by §8's commands on the branch that adds the slice.*

---

## 0. The answer

1. **No acceptance became a rejection, and every element-edit limit of slice 2 is gone.** 52 lines changed
   verdict against slice 2: **17 became acceptances** (11 had been rejected, 6 pending), **35 rejections changed cause**,
   and none went the other way (§3). `NestedFor`'s two edits inside `List.update`, `Cmd.mapItem`'s four edits
   inside `List.map`, `Sub.both`'s inside `List.foldr`, the three `Set.foldl`/`foldr` callbacks, three recursive
   local functions and `Task.raceAll`'s once closure are all accepted now.
2. **The Lean model and the checker agree on every Table 6.2 program both run** (§5): T40, T42, T57 and T59,
   distinct and repeated, were the four slice-2 disagreements; all now agree.
3. **The summaries of `map`, `indexedMap`, `filterMap`, `update`, `foldl`, `foldr` and `initialize` are
   inferred** over two asserted primitives, `traverseAt` and `focus`; no row is asserted for any of them (§2).
   The rewrite changes no output but those two loops' arguments and `update`'s call of `focus`; every `run/`
   program prints what it printed (the run hashes were re-recorded after the emitted bytes moved); release bytes
   grow by 893 of 720 421 brotli bytes across the corpus (+0.12 %); `bench/list` shows no slowdown (§7).
4. **The new rejections are one platform's choice, made visible.** Outside the list-runtime tests, rejections went
   from 32 to 91. **69 of the 91** are `Cmd.map`'s and `Sub.batch`'s key-path extension
   (`Keyed [ …path, segment ] …`): an edit inside each command, which slice 2 rejected inside the platform
   (`supply`) and which is now accepted there and becomes a write of every caller's command — Conduit's 57, the
   six TEA tests' `Sub.batch` calls, five in the platforms. They are approximate or the position rule, and a
   copy of the path in `mapItem` would remove them all (§4). The other 22 are slice 2's, less the ones fixed.
5. **The cost is slice 2's, for slice 3a's work.** Built naïvely the new work made the pass 47 % of a check on
   Conduit (slice 2: 39 %); verdict-preserving work brought it to **36 %** (Conduit), **36 %** (`bench/corpus`,
   slice 2 32 %) and **66 %** (core, slice 2 65 %). The 20 % target is met on the 100 000-line program
   (**29.5 ms** against a 145 ms `check --jobs=1`) and missed on the smaller ones, where on Conduit two thirds of
   the pass is re-summarising the library it reaches (§6).

## 1. What was measured

Research 76's corpora and commands (§8). The slice-2 column is master's binary re-run on the same tree, so the
two compare like with like; its totals differ from research 76's printed ones by three lines of target
discovery. "Not list-runtime" excludes the 23 `run/List*` and `run/WriteRows*` programs that pin persistence on
purpose.

## 2. The library: two primitives, everything else inferred

| Primitive | Row (asserted) | Why it is a primitive |
|---|---|---|
| `traverseAt a i` | π₁ `R`, π₁`[*]` `A`; `res = π₁[*]`, taken | review 5 item 1.4: "a traversal primitive establishes that successive elements occupy separated positions"; Lean `traverse` |
| `focus xs i f` | π₁ `RAW`; π₃ `calls ≤1`, supply 1 `π₁[*]` owned, taken, `excl π₁`; `res π₁{keep cb₃ π₁}`, `[*] = π₁[*], cb₃` | "a focus operation temporarily removes one position"; Lean `focus` |
| `kept same o b` | gains `K` on π₂: aliased, never read — the one exempt comparison (thesis §6.2, A11) | Lean `close`'s source, which is no use |

`traverseAt` lowers to `a[i]` as `at` does. Its obligation — the body that calls it reads the array only through
it, once per index, in one direction — is met by the five loops that call it and is listed with the trusted
surface (`ownership-checker.md` §18.5). The inferred summaries, from `beni dump --stage=ownership core`:

```
summary foldl: π1 R, π2 RA, π3 R; res ~cb3{excl cb3} ~π2; π3 calls many, supply 1 π1[*] owned taken{excl π1},
               supply 2 cb3 owned{excl cb3}, supply 2 π2 owned{excl π2}
summary map:   π1 RA, π1[*] RA, π2 R; res [*] ~cb2{excl cb2} ~fresh2{excl cb2, sep cb2 cb2} ~π1[*], ~fresh1{excl cb2, sep cb2 cb2} ~π1;
               π2 calls many, supply 1 π1[*] owned taken{excl π1}
summary update: π1 RAW, π1[*] RA; res [*] ~cb3{excl cb3} ~π1[*], π1{keep cb3 π1}; π3 calls ≤1, supply 1 π1[*] owned taken{excl π1}
summary initialize: π2 R; res [*] ~cb2{excl cb2} ~fresh2{excl cb2, sep cb2 cb2}, fresh1{excl cb2, sep cb2 cb2}; π2 calls many
```

`map`'s result is exclusive when its callback's results are exclusive and fresh across calls (`sep cb2 cb2`), the
round-5 condition; `initialize`'s the same, which is what rejects T59's `[ cell, cell ]` and accepts two literals.
`filterMap`, `indexedMap` and `foldr` read the same as their siblings. `Dict.update` is not rewritten: it reaches
no list function, and a dictionary needs a focus of its own (§4).

## 3. The table, and every flip

| Corpus | Demands | Accepted (fresh / call / param / callback-param / once) | Pending | Rejected | Rejected by cause |
|---|---|---|---|---|---|
| core | 120 (119) | 119 (9 / 20 / 85 / 4 / 1) | 0 | 1 (2) | supply 1 |
| platforms | 30 (23) | 16 (2 / 0 / 8 / 6 / 0) | 2 | 12 (11) | escaped 8, call 3, exclusive 1 |
| table app | 5 (5) | 4 (1 / 0 / 3 / 0 / 0) | 1 | 0 (0) | — |
| TodoMVC | 8 (8) | 4 (0 / 0 / 4 / 0 / 0) | 4 | 0 (0) | — |
| Conduit | 100 (23) | 42 (8 / 15 / 19 / 0 / 0) | 1 | 57 (0) | escaped 36, top-level 16, exclusive 5 |
| corpus, not list-runtime | 519 (506) | 416 (57 / 49 / 286 / 24 / 0) | 82 | 21 (19) | top-level 8, exclusive 6, call 4, supply 2, disjoint 1 |
| **subtotal** | **782** (684) | **601** | **90** | **91** (32) | |
| corpus, list-runtime tests | 179 (175) | 100 (42 / 6 / 38 / 14 / 0) | 0 | 79 (78) | escaped 34, top-level 15, call 13, later-use 11, alias 3, once 2, exclusive 1 |

Slice 2's figures in parentheses. 101 lines are new outside the list-runtime tests — call-site demands that
appear because a callback now writes what `List.map`, `List.foldr` or `Set.foldl` supplies it (77 in Conduit,
17 in the corpus, 7 in the platforms) — and four are gone (`TailModConsBranches`'s `chunks` no longer writes
its argument, below). `core/List`'s own lines moved with the text added above them and are matched by name.

**Rejected or pending → accepted (17).**

| Where | Line | Was | Why now |
|---|---|---|---|
| `browser/direct/NestedFor` 42:73, 48:66 | `List.push g.kids`, `List.update g.kids` in a `List.update` callback | rejected `supply` | `focus` supplies the element owned; the edit is `update`'s caller's, where the TEA entry protocol takes over (`pending`) |
| browser `Cmd` 150:25 ×4 | `Cmd.mapItem`'s key path, through `List.map` | rejected `supply` | `traverseAt` supplies the element owned; the write moves to `Cmd.map`'s callers (§4) |
| browser `Sub` 38:14 | `value Sub.both`, through `List.foldr` | rejected `supply` | the same |
| `run/ListForms` 156:10, `run/ListPrepend` 125:10, 126:16 (list-runtime) | `value line`, `prepends`, `appends`, through `List.map` | rejected `supply` | the same; the call sites are rejected instead, `top-level` and `escaped`, as the elements are top-level lists |
| core `Task` 2410:41 | `[ first, …rest ]` in `raceAll`'s `within` lambda | rejected `captured-edit` | a once closure, created once and handed to `within`, which calls it at most once: accepted `once` |
| `run/CallbackOrderFoldr` 40:67, 41:68, `run/CoreSetRest` 62:56 | callbacks of `Set.foldl`/`foldr` | `pending` | `Set.foldl` calls its `func` inside a lambda handed to `Dict.foldl`; the call is now a call of `func`, supplied `Dict.foldl`'s accumulator owned (§18.9) |
| `run/ReleaseEverything` 123:29, `check/good/PrependInLoop` 49:29, `run/TailModConsBranches` 115:34 | recursive local functions | `pending` | the group is solved (§18.7) |

**Rejected → rejected for another cause (35), all in the list-runtime tests.** `ListIndexed` (26 lines) and
`ListSpreadPatterns` (4) were `top-level`, `later-use`, `alias` or `disjoint` and are now `escaped` by §18.6's
rule — a list shown with `Debug.toString`, which hands it to `Js.pure` inside a lambda, is taken to have
escaped; `ListForms` 91:40 and 92:39 the same; `ListForms` 95:49 and 97:53 were `captured-edit` and are `once`
(a writing closure handed to `List.map`); `ListForms` 100:73 was `supply` and is `exclusive` (approximate).

**Accepted → rejected: none.**

## 4. What is still rejected outside the list-runtime tests (91), and what is pending (90)

- **`Cmd.map`'s and `Sub.batch`'s key-path extension (69, all approximate or the position rule).** The browser
  platform's `mapItem` writes `Keyed [ …path, segment ] …` for each item of a command. Slice 2 rejected that edit
  inside the platform, because `List.map` supplied its element borrowed. Now it is supplied owned, the edit is
  accepted there, and `Cmd.map`'s summary writes `π1#Cmd.0[*]#Keyed.0` — every caller's command. Conduit's 57:
  36 commands that escaped (a job's closure given to JavaScript), 16 from `Cmd.none` (a top-level value; its empty
  list makes no element, but its key paths are the position rule's), 5 whose items may share. The six TEA tests'
  `Sub.batch [ … ]` (`exclusive`, approximate: the subscriptions come from calls with no summary), the browser
  platform's `List.map list` itself (4, `escaped`), and browser-tea's `settle` (1, `call`). These are not wrong:
  in place, `mapItem` would edit a command its caller still holds. They are one platform choice, and copying the
  path (`Keyed [ …List.copy path, segment ]`) or keeping key paths out of lists would remove all 69.
- **Rejected by the full checker too (15):** the 8 top-level lists, `KeyedEnds`'s 4 identity promises, `xs ++ xs`,
  and the two `Ref.update` callbacks.
- **Limits that remain (7):** `Url.Parser`'s `Dict.update` callback (`supply`, a dictionary's focus is not built)
  and browser-tea's job table (6, `escaped` and `call`: `Dict` values that `spawn` escapes into fibers).

**Pending (90):** 88 are a TEA program's `update`, which the runtime calls and slice 3b's entry protocol will
check, or the runtime record a platform hands it in (80 corpus, 4 TodoMVC, 1 table app, 1 Conduit, 2 browser-tea); 2 are
writing closures returned from their function.

## 5. Against the Lean model

`proofs/ownership/Ownership/Fixtures.lean` records the verdicts its test suite asserts; the corpus fixtures that
run the same programs now agree on all of them:

| Program | Lean | Slice 2 | Slice 3a (fixture line) |
|---|---|---|---|
| T40 record shape | accepted | rejected `supply` | accepted (`Differential` `t40Distinct`) |
| T10 / T48 duplicate slots | rejected | rejected | rejected `exclusive`, exact (`t10`) |
| T42 distinct / repeated | accepted / rejected | rejected / — | accepted / rejected `exclusive` (`t42Distinct`, `t42Repeated`) |
| T57 distinct / repeated / repeated rows | accepted / rejected / rejected | rejected | accepted / rejected / rejected (`t57Distinct`, `t57Repeated`, `t57RepeatedRows`) |
| T59 initialize shared / distinct | rejected / accepted | rejected / rejected | rejected `exclusive` / accepted (`T59`) |
| T59 map shared / distinct | rejected / accepted | — | rejected / accepted (`T59` `mappedShared`, `mapped`) |

T1, T2, T3, T7, T12, T14, T15, T17, T33, T46, T52 and T53 agree as in research 76. **No disagreement remains.**
As before, the model was not run here (no Lean toolchain); the comparison is with its fixtures' recorded verdicts.

## 6. What it costs

`check` and `build` do not run the pass. The pass in the dump (`--self-profile`'s `ownership` event against the
`check` events of the same run, best of 7, ReleaseFast):

| Target | Slice 2 | Slice 3a, naïve | Slice 3a |
|---|---|---|---|
| `bench/corpus` | 6.0 ms, 32 % | 8.3 ms, 45 % | **7.1 ms, 36 %** |
| Conduit | 13.7 ms, 39 % | 16.2 ms, 47 % | **12.3 ms, 36 %** |
| core (every summary) | 12.5 ms, 65 % | 15.6 ms, 87 % | **13.3 ms, 66 %** |
| 100 000-line program (644 modules, 7 335 summaries) | 26.6 ms | 30.7 ms | **29.5 ms** |

The 100 000-line program checks in 145 ms single-threaded (`check --jobs=1`), so the pass is about **20 %** of a
check there. (Its generator writes `modBy`, which beni refuses; the measurement replaces it with `Int.mod`.)

What brought it down, each step checked to change no line of core's, the platforms', Conduit's, `bench/corpus`'s
and 137 more corpus targets' dumps: Esc indexed by cell instead of scanned (`isEscaped` and the `covers` it called were
a quarter of the cycles); `tracked` remembered per type variable; the path arithmetic (`concat`, `dropFirst`)
remembered; `norm` in place; uses indexed by local for liveness; no walk for a library declaration whose parameters
and result all cross; no verdicts or line text in a walk nobody prints; one arena per walk depth, reused.

**Where the time goes now.** Per module (exclusive cycles, Conduit): the 16 Conduit modules take a third; the
library they reach — `Schema` (129 walks), `Tea`, `Task` (174 walks), `List`, `Dict`, `Http` — two thirds, all of
it recomputed in every dump. Within a walk the profile is flat: abstract-value operations, cell and path hashing,
summary instantiation and read-off, none above 8 %. On `bench/corpus`, whose library use is light, the report's
own modules are three quarters, and recursive groups walk three to four times (`ExprParser`: 54 walks). The
remaining large lever is not in the walk: the library's summaries belong in the embedded checked core and its
interfaces (§16.10), which slice 4 publishes.

## 7. The rewrite changes no behaviour

- **Output.** `traverseAt a i` lowers to `a[i]`, as `at a i` does. The only emitted changes are `mapHelp` and
  `indexedMapHelp` without their `xs` argument (they answer `a` when every result was its element, and `map`
  answers `xs` when its loop answered `a`), and `update` calling `focus`. Six `emit/release` goldens moved for
  exactly these; the run hashes were re-recorded, and every `run/` and `browser/` program printed what it printed.
- **Release bytes** (`node bench/size.mjs`, 448 programs): `release_gross_brotli_bytes` 720 421 → 721 314
  (+893, +0.12 %); TodoMVC 8 945 → 8 976.
- **Speed** (`node bench/list/run.mjs --before-rev=origin/master --rounds=5`, pinned): every workload within noise,
  `map` and `filter` faster at 1 000 and 10 000 elements (0.86×, 0.79×) — the loop lost an argument. The harness's
  100 000-element `map` figure is bimodal for both cores (one run read 968 µs before and 983 after, the next 515
  and 960), so it was re-measured in a process per build: 509–515 µs before, 509–514 µs after, `indexedMap`
  510–516 and 510–517.

## 8. How to reproduce

```sh
zig build -Doptimize=ReleaseFast
B=./zig-out/bin/beni
$B dump --stage=ownership core
$B dump --stage=ownership --platform=browser-tea examples/conduit/src
$B dump --stage=ownership --self-profile=p.json bench/corpus          # the `ownership` event
node bench/size.mjs --beni=$B
node bench/list/run.mjs --before-rev=origin/master --beni=$B --rounds=5
```

The corpus sweep is research 74's: every target dumped under the first platform it checks with, each line matched
with slice 2's at the same module, position, operation and base.
