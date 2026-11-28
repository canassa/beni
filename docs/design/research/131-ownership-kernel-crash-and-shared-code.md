# 131 — The ownership kernel v3: a schema's constructor, and the shared code made linear

*Research report, 2026-11-14. A fix of `src/own3/` and of the code in `src/own2/` that v3 calls, for
what research report 130 §10 left open. The kernel is `ownership-v3-kernel.md`; this report changes its
§6.14, §8 and §9. Nothing in `src/own/` or in a platform runtime changed. v2's answers did not change.*

---

## 1. Result

- **No root crashes now.** 54 of the 2 731 ownership roots stopped the safe compiler in
  `Check.checkCovered`. Each names a tagged schema. The check took a schema's constructor for code. It
  is not code: the backend emits it as it emits a type's constructor. Now 0 of 2 731 roots crash, and
  every other root's v3 output is the same, byte for byte.
- **The `own2` code that v3 calls is linear now.** Four pieces were not:
  - the adapter's table of a term's instructions (`Groups.Adapter.ofTerm`): quadratic in the module;
  - the adapter's reading of aliases: exponential in a diamond of aliases (#2121);
  - the family table (`Family.Table.scan`): the same two faults;
  - the pre-pass's dispatch edges (`Prepass.run`): each declaration walked every derived row below its
    sites again.
- **A module past the layout limit is walked no further.** It authorises no write and publishes nothing,
  so the walks after it were wasted: 5 000 `==` sites over 5 000 recursive types took 11.6 s (§3.3).
- **The worst v3 time is 0.45 s now** on the shapes that were slow. Before, a chain of 3 000 types took
  20 s, and a diamond of aliases 16 deep did not end in 60 s. On these shapes the largest ratio of v3's
  time to the type check's is 0.7 (it was 117, or no end). v3's own walks keep report 130's bound.
- **v2's output is the same, byte for byte,** on every root and every sweep program (§6).
- **One cost is outside v3 and is not fixed:** the type check's own cycle pass (`check/Cycles.zig`) does
  the same walk as the old pre-pass, when the module has a constant. 3 000 `==` sites over 1 000 types take
  22 s of type check (§7).

## 2. The crash

**What happened.** `checkCovered` runs in safe builds. It asks of each instruction that "names code" in a
declaration whose code the backend emits: did a walk evaluate it? `namesCode` said yes for
`schema_ctor_top` and `ext_schema_ctor`, a constructor of a tagged schema. A pattern `Ok (Event.Set ev)`
names one. No walk evaluates the constructor of a pattern: `bindPattern` reads the pattern's shape. So
the check panicked on every program that matches on a tagged schema: 54 roots (corpus programs under
`run/`, `browser/inline/`, `emit/release/`, `ownership/` and `check/good/SchemaMembers`).

**Which was wrong: the check or a rule.** The check. A schema's constructor runs no code of the program.
`js/SchemaCtor.zig` and `Lower.ctorValue` emit `{$: "Set", a: payload}`, or the bare tag, the same
representation as a type's constructor. `namesCode` already said "no" for `ctor` and `ext_ctor`. So the
schema's constructor moves to that group. No check is turned off.

**The rule that covers it.** Kernel §6.14 now has a table of every instruction that a schema puts in a
program, each with its rule:

| Instruction | Rule |
|---|---|
| a member (`Box.print`, `Box.schema`) | code with no contract: each argument escapes at a call |
| a constructor (`Event.Set`) | no code. In a pattern: a tag test; no row describes its parts, so the pattern binds `unknown` over the scrutinee. Called: read as code with no contract, so each argument escapes and the answer is `unknown` over them |
| `via` | the default location (`walkSchema`, report 129) |
| a reference in a `via` or a body | code, walked where it is evaluated |
| the plan (`schema_record`, `schema_field`, …) | no code of its own; the workers call only the `via`s and other workers |

The rule for a called constructor is safe and loses precision: the payload escapes. Winning it back
needs a row for each schema variant. This work did not add one (§8).

## 3. The adapter and the family table

### 3.1 A table as long as the module, for each term

`Adapter.ofTerm` reads a type term (a constructor's argument, an alias's body) bottom up. It kept the
instructions it had read in a `stamped.Column`, a dense array indexed by instruction. The array grows to
the largest index it is asked about. A fresh one was made for each term. So each term cost the index of
its instructions, and a module of many constructor arguments cost their number times its size.
`Family.Table.scan` did the same.

1 000 nominal types, each holding 32 of the types before it, and one function over the last type: 2.3 s.
2 000 types: 9.1 s. 3 000 types: 20 s. The type check takes 0.1 to 0.3 s.

**The fix.** A sparse map for each term, as large as the term. The operations are the same, in the same
order, so every answer is the same. The rule test of dense keys (`src/rules_test.zig`) lists both maps,
with the reason: terms nest as aliases expand, so one column cannot serve them.

### 3.2 An alias read again at each place

`Adapter.applied` expands an alias under its arguments. It did so each time it met the alias. In
`A{i} a = A{i-1} (A{i-1} a)`, `A64` has 2⁶⁴ applications below it, and the adapter read them all: issue
#2121. `check/good/AliasDiamondChain` never ended under v3 or v2. `Family.Table.applied` did the same.

**The fix in the adapter.** Each expansion of an alias under one list of arguments is kept: its id, and
what it did that a kept id does not repeat. A second expansion answers the kept id when it would do
nothing the first did not do:

- Every node an expansion names is interned. A second expansion finds each node again. So the id is the
  same, and the table does not change.
- An expansion tests the account (a limit on a step's payload). A test passes again unless the account
  has failed since. So a kept id first asks whether the account has failed, and if it has, fails as the
  first test would.
- An expansion that met a family head while a payload is read handed the head's arguments to
  `contexts`. A kept id hands them again, each at its last place. `payloadSteps` reads `contexts` as a
  stack and skips an id it has seen, so an earlier copy of an id that comes again later in the same run
  is never read: dropping it changes nothing. (The first version of this work expanded such an alias
  again; the review found that a diamond of them stayed exponential, §9.)
- An expansion that reserved a record's row is expanded again: v2's account counts each reservation, and
  its verdict depends on the count (`ownership-v2.md` §4.4). v3's account has no allowance and v3 counts
  its own work, so v3 sets `repeat_reservations = false` and keeps these too.
- A kept id adds what it did to the counts of the expansion around it, so that one is judged the same.

**The fix in the family table.** The same memo. A reading of an alias stands for one parameter or none,
and adds some edges. The kept reading adds its edges again, each once, in the order of their first
places. A repeated edge changes nothing in Tarjan (the second update of `low` is the first) or in
`close` (an "or" over the edges). So the families, and their numbers, are the ones the old code found.
The key is the alias, the head's module and a hash of the arguments. The arguments are kept and
compared; a key whose arguments differ is read again and not kept.

### 3.3 A module past the layout limit

A type of more than 4 096 locations (`Loc.max_layout_entries`) makes the module authorise no write and
publish no contract (kernel §8). But the other declarations were still walked, to the module's budget.
5 000 mutually recursive types, each holding a list, and 5 000 `==` sites: 11.6 s of v3 before this
work and 6.5 s after the fixes above, against 0.08 s of type check. Now no declaration, `via` or export
is walked after a type passes the limit (`Mod.stopped`), as after a declaration passes the budget. The
module's limit line and its exit code are the same; only the refusal lines of the declarations not walked
are gone. Over the 2 731 roots, four dumps change this way (`ownership/MutualCycles`,
`check/good/OwnershipAnnotationDag`, `check/good/RequirementBelowDepth512`,
`run/EvidenceDagBuildDepth32`): each is past the limit already.

## 4. The pre-pass's dispatch edges

`Prepass.run` orders a module's declarations by Tarjan over their edges. The third leg of
`check/Edges.zig` is every dispatch site's terms and the body of every derived row below them. Each
declaration walked its own rows again. 3 000 functions `g x y = x == y` over the last of 300 types,
each holding 32 types before it: 6.2 s, against 0.05 s of type check.

The order of the edges matters: Tarjan's order of the groups is the order in which v2 and v3 walk the
declarations. So the new code (`own2/TopEdges.zig`) must give the same edges in the same order. It
gives each target at its first place only. That is enough: a repeated edge changes nothing in Tarjan.

**The argument.** `Edges.termsEdges` is a depth-first preorder walk from the roots, in order, each term
once. So a declaration's edges are the first visits of its `top` terms. Let the *sequence* of a term be
the targets of the walk from that term alone, in order.

- **The roots.** When the next root's walk starts, every term visited so far had its whole subtree
  visited. The walk from the next root visits what the walk from it alone visits, less what was
  visited, in the same order. So a declaration's edges are its roots' sequences, one after the other,
  each target kept at its first place.
- **A term on no cycle.** The same holds for each child: no child reaches the term or a term above it.
  So the sequence of the term is its own target, then its arguments' sequences, then its row's, each
  target at its first place. A row's merged sequence is kept once for each row.
- **A term on a cycle** (the rows of recursive types). Tarjan over the terms and rows groups them. Each
  cycle passes through a row, so Tarjan starts at the rows only. Inside a group, the walk runs exactly as
  `Edges` runs it. Where it leaves the group, the term it reaches cannot reach the group, so its sequence
  is spliced in. A target it adds twice is kept at its first place. Every member of a group reaches the
  same targets. A group that reaches at most one target gives every member that one, at no cost.

**The cost.** Each term's sequence is made once. A term with one part that has targets shares that part's
sequence, so memory grows only where two parts differ. The one place that costs more is a group on a cycle
that reaches two or more of the module's declarations: it is walked once for each member that a sequence
asks for. In a derived row, the module's own declarations that a row can call are its `eq` and its
`compare`, one method each for the whole module (`static-dispatch-spike.md` §11), and an `eq` row calls
no `compare`. I found no program that makes such a group.

**The check.** Safe builds compare each declaration's edges with those of `Edges.declEdges`, for each
module whose dispatch table has at most 4 096 terms (`TopEdges.crossCheck`, kernel §9). All 2 731 roots
and every corpus program of the gates pass it.

## 5. The worst shapes

A generator (`worst.mjs` in the scratch directory of this work; not kept in the repository) writes:

- `chain.N`: N nominal types, each holding 32 earlier ones, and one function over the last;
  `chainx.N` the same with the types in another module;
- `diamond.D`: a diamond of aliases D deep, held by a constructor and used; `diamondp.D` the same as the
  argument of a recursive type; `AliasDiamondChain`, the corpus program of #2121;
- `eq.T.S`: T types each holding 32 earlier ones, S functions that compare two of the last, with a `main`;
  `eqlib.T.S` the same with no constant; `eqrec.T.S`: T mutually recursive types; `eqtop.D.S`: record
  aliases D deep over a type whose module declares its own `eq`, so every derived row calls it;
- `schemas.N`: N tagged schemas, each matched on; `schemachain.N`: N record schemas, each holding the one
  before;
- two programs of report 130's tests (`deep.K12.N1000`, `inst.F2040.N30`), to show v3's own walks did
  not move.

ReleaseSafe LLVM compilers of `891190fe96` (before) and of this work (after), `beni check
--ownership=v3 --ownership-everywhere --no-cache --jobs=1`; the `ownership3_module` phase and the `check`
phase of `--self-profile`, in ms, one run each:

| Program | Lines | Before: v3 / check | After: v3 / check | After: verdict |
|---|---:|---:|---:|---|
| `chain.1000` | 4 017 | 2 322 / 104 | 21 / 99 | accepted |
| `chain.2000` | 8 017 | 9 083 / 190 | 33 / 184 | accepted |
| `chain.3000` | 12 017 | 19 977 / 273 | 44 / 263 | accepted |
| `chainx.3000` | 12 017 | 22 / 299 | 44 / 280 | limit, as before |
| `diamond.16` | 92 | no end in 60 s | 11 / 18 | accepted |
| `diamond.64` | 284 | no end in 60 s | 11 / 19 | accepted |
| `diamondp.16` | 91 | no end in 60 s | 12 / 18 | accepted |
| `diamondp.64` | 283 | no end in 60 s | 11 / 18 | accepted |
| `famdiamond.16` (review) | 82 | no end in 60 s | 11 / 17 | accepted |
| `famdiamond.64` (review) | 274 | no end in 60 s | 11 / 17 | accepted |
| `AliasDiamondChain` | 836 | no end in 60 s | 10 / 18 | accepted |
| `eq.300.3000` | 16 212 | 6 184 / 5 825 | 20 / 5 725 | accepted |
| `eq.300.6000` | 31 212 | 12 052 / 11 713 | 25 / 11 390 | accepted |
| `eq.1000.3000` | 19 012 | 23 184 / 20 689 | 29 / 20 242 | accepted |
| `eqlib.300.3000` | 16 209 | 6 173 / 53 | 20 / 53 | accepted |
| `eqrec.300.3000` | 16 508 | 468 / 476 | 17 / 438 | accepted |
| `eqrec.1000.3000` | 20 008 | 1 799 / 1 521 | 20 / 1 505 | accepted |
| `recmut.500.5000` (review) | 27 499 | 2 908 / 40 | 19 / 41 | limit |
| `recmut.5000.5000` (review) | 49 999 | 11 475 / 77 | 51 / 80 | limit |
| `eqtop.100.3000` | 15 423 | 207 / 2 367 | 224 / 2 346 | accepted |
| `eqtop.100.6000` | 30 423 | 404 / 5 560 | 444 / 5 923 | accepted |
| `schemas.300` | 6 009 | panic | 25 / 35 | accepted |
| `schemas.3000` | 60 009 | panic | 84 / 155 | accepted |
| `schemachain.3000` | 15 018 | 31 / 1 708 | 28 / 1 573 | accepted |
| `deep.K12.N1000` | 5 059 | 235 / 39 | 238 / 37 | limit |
| `inst.F2040.N30` | 2 411 | 143 / 70 | 139 / 69 | limit |

The `check` column moves by up to 30 % between runs on a busy machine.

- **Worst v3 time:** 20 s before (`chain.3000`), or no end (the diamonds); 0.44 s after
  (`eqtop.100.6000`).
- **Worst ratio of v3 to the type check, on these shapes:** 1 220 before (`famdiamond.12`: 20.3 s against
  17 ms), 117 for a program that ends in a few seconds (`eqlib.300.3000`), or no end; 0.72 after
  (`schemas.300`), and 6.4 where v3 uses its own budget (`deep.K12.N1000`).
- **The bound.** The code of `own2` that v3 calls is linear in the program and in the places it
  describes: each term once, each alias under one list of arguments once, each dispatch term once (with
  the exception of §4). v3's own walks keep report 130's budget: at most 16 384 units for each token,
  about 0.1 ms. So v3 takes at most about 0.1 ms for each token of a module, plus time linear in the module
  for the shared code. A ratio to the type check has no constant bound in general: the type check can
  take far less than 0.1 ms a token. On report 130's shapes the largest was 131, and this work does not
  change those walks (`deep` and `inst` above).
- **Slower:** `eqtop` by 10 %. Making the term groups and the sequences costs more than the old walk
  where each declaration has its own small terms and no row is shared. It stays linear.
- **Still slow, and linear** (the review): a chain of nominal types each holding 32 earlier ones and a
  `List Int`, with one function that writes a list of the last one. 5 000 types: 4.6 s of v3 against
  0.64 s of type check, about 7 times; 1 000 types: 0.96 s against 0.14 s. Each passes the layout limit,
  and the time is spent before it: the layouts below the limit are built and counted (report 130 §3).

## 6. Tests

Black-box, `tests/blackbox/check_test.zig`, six new tests. Each was run on `891190fe96` in a second
worktree with the new test file copied in (never `git stash`). The six take 4 s together on the gates'
compiler.

| Test | Program | On `891190fe96` | After |
|---|---|---|---|
| a tagged schema's constructor is a constructor | a schema of this module and one of another, each matched and built | panic in `checkCovered` | accepted |
| a long chain of nominal types | 2 000 types, each holding 32 earlier ones | did not end in 10 s | accepted |
| a diamond of aliases | `check/good/AliasDiamondChain` | did not end in 10 s | accepted |
| many `==` sites | 1 500 comparisons over the last of 300 such types, no constant | did not end in 10 s | accepted |
| a diamond of aliases under a family head | the review's shape, 16 deep | did not end in 10 s | accepted |
| a module past the layout limit | 5 000 recursive types holding lists, 5 000 `==` sites | did not end in 10 s | the layout limit |

## 7. Gates

ReleaseSafe LLVM compilers of `891190fe96` (before) and of this work (after; built from the code of the
final commit).

**Sweeps** (`run.mjs --checker=v3`, every generator and every fault folder). 0 TRAP, DIFF or CRASH, and
no timeout, before and after. **Every program has the same verdict before and after**, so SAME is the
same in every folder:

| Folder | Programs | SAME | REFUSED | Other |
|---|---:|---:|---:|---|
| blind-faults | 24 | 11 | 13 | |
| blind2-faults | 20 | 7 | 13 | |
| blind3-faults | 10 | 3 | 7 | |
| blind4a-faults | 12 | 1 | 11 | |
| blind4b-faults | 8 | 4 | 4 | |
| blind5c-faults | 10 | 5 | 5 | |
| blind5d-faults | 10 | 5 | 5 | |
| blind6e-faults | 12 | 4 | 8 | |
| blind7f-faults | 2 | 0 | 1 | 1 BOTHFAIL |
| blind8g-faults | 8 | 4 | 4 | |
| bounded-walk-faults | 12 | 2 | 9 | 1 BOTHFAIL |
| runtime-calls-faults | 8 | 2 | 6 | |
| aliased-arguments | 5 160 | 1 183 | 3 977 | |
| answers-beside | 240 | 77 | 163 | |
| blind | 9 792 | 1 675 | 8 117 | |
| blind2 | 1 202 | 502 | 700 | |
| blind3 | 417 | 160 | 257 | |
| blind4a | 160 | 24 | 136 | |
| blind4b | 6 596 | 1 229 | 5 367 | |
| blind5c | 226 | 81 | 145 | |
| blind5d | 1 234 | 456 | 778 | |
| blind6e | 238 | 90 | 141 | 7 PLAINFAIL |
| blind7f | 960 | 404 | 556 | |
| blind8g | 121 | 21 | 100 | |
| bounded-walk | 34 | 5 | 23 | 6 BOTHFAIL |
| callbacks-keep | 720 | 108 | 612 | |
| evaluation-order | 440 | 276 | 164 | |
| folds-callbacks | 30 300 | 5 392 | 24 908 | |
| function-values | 1 960 | 304 | 1 656 | |
| handed-back | 2 592 | 0 | 2 592 | |
| recursive-levels | 16 131 | 4 140 | 11 991 | |
| wider-functions | 354 | 144 | 210 | |

- **v2's output** (`dump --stage=ownership --ownership=v2 --ownership-everywhere`, hashed): identical on all
  79 013 sweep programs and on 2 730 of the 2 731 roots. The one that differs is `AliasDiamondChain`, which
  did not end before. Two more roots (`core`, `platforms/browser`) differed in the first run and are the
  same when run again with either compiler: the roots' runs share the worktree's cache, so the first run
  of a root can read entries another compiler wrote. The review compared 2 339 corpus cases and its own
  programs, and found them identical too.
- **v3 on the roots:** 0 panics of 2 731 (54 before). Every other root's output is the same, except the
  four of §3.3 past the layout limit.
- **The sanitiser corpus** (`bench/ownership-step0-sanitiser.mjs`, 347 fixtures): 93 same, 254 refused, 0
  traps, differences or crashes, before and after.
- **Real writes** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 writes v1
  judges, v3 accepts 287, refuses 20 and has no line for 1, before and after, line for line. **No write is
  lost or won.**
- **Speed** (ReleaseFast LLVM compilers, `--checkers=v1,v2,v3 --runs=3 --jobs=1`, two runs each): v3 on
  v2's modules (169 846 lines) **533k and 531k lines/s before, 547k and 546k after** (318.6 → 310.7 ms).
- **`zig build gates`:** green on the final commit.

## 8. Precision

- **Lost:** none. No sweep program, sanitiser fixture or real write changed its verdict.
- **Not won back:** a called schema constructor lets its payload escape (§2), and a pattern on a schema
  constructor binds `unknown` over the scrutinee. A row for each variant of a tagged schema would win
  both back.
- **Won:** the 54 roots that crashed now give a verdict; `AliasDiamondChain` and the diamonds now end.

## 9. The review

A fresh reader had the code and the kernel after the second commit, and again after the last. It was
asked for a v3 check that panics, takes more than a few seconds, or a limit that accepts, and to review
`c31da10fe0`.

- **Found: a diamond of aliases whose bottom is a family head, inside the family's own constructor.** The
  adapter did not use a kept reading while a payload is read, so each level cost four times the one
  below: 12 levels took 12 s, 16 did not end. **Fixed:** a kept reading records the family heads'
  arguments it handed on, each at its last place, and hands them on again. `payloadSteps` reads them as a
  stack and skips what it has seen, so an earlier copy of an id that comes again later is never read. A
  test.
- **Found: 5 000 `==` sites over 5 000 mutually recursive types**, 7 s, refused by the layout limit and the
  module's budget. **Fixed:** a module past the layout limit is walked no further (§3.3). A test.
- **Found, not fixed: a chain of types that each hold 32 others and a list** takes about 7 times the type
  check, linearly (§5).
- **Held:** no panic in a v3 sweep of 1 469 corpus programs; no limit that accepts; v2's output identical
  on 2 339 corpus cases and on its own programs; `TopEdges` gives the edges `Edges.declEdges` gives,
  in order; the schema constructor is not code in the backend, and every use of one it tried (bound,
  handed to `List.map`, built in a lambda, piped, nested, imported, generic, through
  `Schema.decode`/`encode`) was refused where it should be; the one group of the terms no row reaches holds no
  term on a cycle and is never read as a group; the replay of family arguments is exact; `Mod.stopped`
  cannot accept a write or publish a contract.
- **`c31da10fe0`: correct.** Before it, a first read of a worded contract inside `rowInfo` set the read
  bit and then cleared every bit, so rows kept in that pass forgot what they had read. Now the bit is set
  after the read. No other source of a stale answer was found.

## 10. What is open

- **The type check's cycle pass** (`check/Cycles.zig`) walks every derived row below each declaration's
  sites, when the module has a constant (`eq.1000.3000`: 20 s of type check). It is the walk the
  pre-pass did, and `TopEdges` would serve it. It is the type check's, not v3's, so this work did not
  change it.
- **A group of rows on a cycle that reaches two or more declarations** would cost its size for each member
  asked (§4). No program found makes one.
- **v2 still expands again an alias that reserved a record's row,** so that its account counts the same.
  On a diamond of such aliases v2 stays exponential until its account fails. v3 keeps them.
- **A chain of types each holding 32 others and a list** costs v3 about 7 times the type check before the
  layout limit stops it (§5).
- **The roots' outputs read the cache.** A root dumped twice from one worktree can give another v2 output
  the first time, after a run of another compiler (§7). This work did not look further.

## 11. How to reproduce

```sh
# compilers: the commit before, and this work
(cd base && zig build -Doptimize=ReleaseSafe --prefix ../before)
(cd wt && zig build -Doptimize=ReleaseSafe --prefix ../after)
# the roots, under v3 and v2 (a script over bench/ownership-roots.mjs with allOwnership: true)
#   beni dump --stage=ownership --ownership-everywhere --ownership=<v2|v3> --jobs=1 <root argv>
# the sweeps, as report 130 §11; and every sweep program dumped under --ownership=v2, hashed
node bench/ownership-sweeps/run.mjs --beni=<compiler> --checker=v3 --tag=<tag> --jobs=24 --tmp=tmp <folder>
node bench/ownership-step0-sanitiser.mjs --beni=<compiler> --jobs=14
node bench/ownership-v2-review.mjs --beni=<compiler> --checkers=v1,v3 --roots=real --runs=1 --jobs=8
zig build test-perf "-Dtest-filter=generated module of §7.6"
node bench/ownership-v2-review.mjs --beni=zig-out/perf/bin/beni --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1
# the tests on the commit before, with the test file copied in
(cd base && zig build test-blackbox-check "-Dtest-filter=a tagged schema's constructor" \
  "-Dtest-filter=a long chain of nominal types" "-Dtest-filter=a diamond of aliases is read" \
  "-Dtest-filter=many \`==\` sites")
```
