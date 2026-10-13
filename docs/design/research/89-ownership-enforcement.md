# 89 — The ownership checker's slice 4: enforcement

*2026-10-13. What changes when the ownership checker's rejections become errors (`ownership-checker.md` §28): which
platforms enforce, what is an error, what the messages say, what the summaries shipped in the checked core buy, what
it costs, and which corpus programs now fail. The baseline is `origin/master` at `228681b94` (§3's figures were measured there, before the branch was rebased onto the identity promises' removal); the branch is that plus
this slice. Instruction counts are user-space instructions of the whole process (`bench/list-in-beni/icount.c`), the
minimum of three runs of `check --no-cache --jobs=1` on ReleaseFast LLVM builds of both.*

---

## 0. The answer

1. **A platform opts in with `"lists": "in-place"`** in its manifest (`boundary.md` §5.2), inherited down the chain.
   `browser-direct` declares it; nothing else does. Only there do `check` and `build` run the pass; everywhere else
   the checker is silent and the run is the one it was — `browser-tea` costs 0.04 % more on Conduit, which is noise.
2. **Every rejected line and every pending line is an error**: exact (real sharing), position (a top-level list,
   `view` writing its model) and approximate (a limit of the checker) alike. A limit cannot be accepted, because
   the build would then write in place a list nobody showed unique, and it cannot be copied silently, which the
   owner refused; so it is an error whose message says it is a limit and writes the copy. A pending line is an
   obligation a build cannot leave open. Lines of one root cause — one position, cause and reason — are one error.
3. **Four codes**: `list_still_used`, `top_level_list_changed`, `view_changes_model`, `list_may_be_shared`, each
   message in thesis Chapter 8's shape — the places with carets and labels, the consequence, the `List.copy` line,
   the verdict (§2).
4. **Core's and the platforms' summaries ship in the checked core**, as a summary block in each cache entry; a build
   reads them instead of summarising the library. The block is lossless: every summary that crosses a module
   boundary in a report is sealed through it and, in the build the tests run, compared field by field with the
   walk's — no `ownership/` golden moved.
5. **Cost**: the 10 % target is **met** on the corpus pages (+2.6 %), TodoMVC (+6.0 %) and the table app (+5.6 %),
   and **missed** on Bike Wars (+18 %) and **Conduit (+112 %)**. Conduit's cost is not the library — the blocks
   removed that — but the entry protocol's fixpoint over Conduit's model in `Main` (slice 3b, §20.4): the pass on
   `Main` is 77 % of the pass, and `entryCall` alone 22 % of the whole process. The 100 000-line check is
   unchanged (−0.006 %). §3.
6. **Three corpus pages now fail on `browser-direct`**, every one with a real reason: two start their model with a
   top-level list, one stores a view of the rows it edits later. Each now takes the `List.copy` its error asks for;
   their transcripts do not change. A fourth, `KeyedEnds`, failed until the identity promises were dropped on
   master the same day (`ownership-checker.md` §27): `List.take` is a fresh list now. §4.
7. **The applications** on `browser-direct`: TodoMVC (four programs) and the table app check clean; Conduit fails
   with one error (four model paths a view event may carry, a limit); Bike Wars with three (two real, one position).

## 1. What is enforced, and where

The pass runs after the module check, on one thread, when the run's own check found no error (§28.3). It walks the
modules the run checked and reads every other module's summaries from its block: core and the platforms from the
checked core, an app module from its cache entry. Two rules keep a cache hit sound (§28.4): an enforcing run reads
no entry without a block, and a module not from the checked core publishes its interface hash folded with its own
key, so an importer's key moves with any block it can read. `tests/blackbox/cache_test.zig` pins both: a body edit
that makes a leaf write its argument fails its warm importer, and an in-place build after a `browser-tea` build
checks both modules again. The price is the interface firewall on in-place builds (§28.11 item 1).

The pack maker reports core in the run that checks core, and a platform when its chain is in-place: core and
`browser-direct`'s chain have no rejected or pending line (117 and 5 lines, all accepted), so the pack builds. The
pack grows from 2 721 104 to 2 944 336 bytes (+8.2 %).

## 2. The messages

From `tests/corpus/build/bad/direct/`, one project per kind. Real sharing (`OwnershipAlias`):

```
-- LIST CHANGED WHILE STILL IN USE ----------------------------- Main.beni:25:20

`[ …model.todos, n ]` adds to the end of `model.todos` itself, but `saved` still
holds the old list and is read afterwards.

24|            saved = model.todos
               ^^^^^ `saved` keeps the list here
25|            next = [ …model.todos, n ]
                      ^^^^^^^^^^^^^^^^^^^ the list is changed in place here
26|            { model | todos = next, before = List.length saved }
                                                            ^^^^^ and `saved` is read here, after the change

If the list were changed in place, `saved` would see the change when it is read
on line 26.

To change a copy and leave `model.todos` as it was, copy it there:

25|            next = [ …List.copy model.todos, n ]

Or, if `saved` only needs the list as it was, read it before line 25.

This is sharing the checker can see: `saved` is read on line 26, after the
change.
```

The language's rule, across modules (`OwnershipTopLevel`):

```
-- TOP-LEVEL LIST CHANGED --------------------------------------- Main.beni:26:8

`update` changes `model.todos` in place, but when the program starts it is
`Seeds.seed`, a top-level value.

26|main = Tea.sandbox { init = λ⊤ → { todos = Seeds.seed }, update = update, view = view }
          ^^^^^^^^^^^ the runtime hands `update` the model here

`Seeds.seed` is defined in Seeds.beni:

3|seed = [ "milk", "eggs" ]
  ^^^^ the top-level list is defined here

A top-level value is shared by every part of the program and never changes:
changed in place, it would change for every part that reads it.

Build the list where the program starts, or copy it there:

    List.copy Seeds.seed

This is the language's rule for top-level values, whether or not anything else
reads the list.
```

A limit (`OwnershipLimit`):

```
-- LIST MAY BE SHARED ------------------------------------------ Main.beni:23:12

`[ …picked, 9 ]` adds to the end of `picked` itself, and the checker cannot show
that nothing else still holds the list.

21|shown rows =
         ^^^^ `rows` keeps the list here
22|    picked = orFallback rows
                ^^^^^^^^^^ `rows` may hold the list through this call
23|    more = [ …picked, 9 ]
              ^^^^^^^^^^^^^^ the list is changed in place here
24|    List.length more + List.length rows
                                      ^^^^ and `rows` is read here, after the change

To be safe, change a copy:

23|    more = [ …List.copy picked, 9 ]

This is a limit of the checker, not proof of sharing: rows may hold it through
the call at 22:14, and is read at 24:24.
```

The other seven fixtures are a later read of the base itself, a function that holds the list, a value computed
first, `view` writing its model, a command that keeps the list (escaped), a returned writing function (pending), and
two model paths from one top-level list as one error. Every one builds on `browser-tea` with no diagnostic — the
corpus harness checks that for every `build/bad/direct/` project whose golden holds only the four codes — and the
`ownership/` kind now checks each `browser-direct` fixture too: the check fails, with those codes alone, exactly when
the dump has a rejected or pending line.

## 3. Cost

| Program, `check --platform=…` | master, direct | branch, direct | Δ | master, tea | branch, tea |
|---|---:|---:|---:|---:|---:|
| Conduit | 78 608 630 | 166 418 054 | **+111.7 %** | 76 370 433 | 76 401 976 |
| Bike Wars | 42 105 598 | 49 855 671 | +18.4 % | 40 511 097 | 40 536 876 |
| table app | 26 007 898 | 27 457 318 | +5.6 % | 24 415 863 | 24 440 426 |
| TodoMVC (`Sandbox`) | 26 890 984 | 28 503 384 | +6.0 % | 25 301 662 | 25 326 704 |
| 55 `browser/direct/` pages, summed | 1 328 134 862 | 1 362 896 648 | +2.6 % | 1 240 592 648 | 1 241 985 110 |
| 100 018 generated lines, no platform | 858 251 078 | 858 198 640 | −0.006 % | — | — |

**Where Conduit's time goes.** `--self-profile` of the release build: the pass is 27.7 ms against the module check's
17.0 ms; reading every block the pass needs is 5.6 ms in the safe build. Per module (`ownership_module`, safe build),
`Main` is 178 of the pass's 232 ms. `perf` on the release build puts `Ownership.run` at 41 % of the process's samples,
`Walker.entryCall` — the model at entry as the fixpoint of `init` and `update` (§20.4) — at 22 %, and inside it the
instantiation of `update`'s result and its sorts. The dump on master, which summarises core in the same process,
spends 33.4 ms in the pass on Conduit; the build, reading core from blocks, 27.7 ms. So shipping the summaries removed
the library's share, which research 77 measured at two thirds when the entry protocol did not exist; on today's
Conduit the entry protocol dominates and blocks cannot help it.

**Why this is reported and not fixed here.** Rule 10: the target is missed on Conduit because of an analysis the
slice does not own, and making it cheaper means changing how the entry fixpoint computes — a change to verdict-making
code that must be measured against every entry golden on its own. Two directions, for the slice that takes it: carry
`update`'s result per message constructor and stop instantiating the whole summary each round (O6 would need that
split anyway), or memoise the instantiation of a class at a model it has already seen.

## 4. Corpus programs that now fail on `browser-direct`

| Page | Code | Why | Kind |
|---|---|---|---|
| `KeyedInPlace` | `top_level_list_changed` | `init` returns the top-level `rows`; `update` edits `model.rows` in place | the language's rule (T53) |
| `KeyedInPlaceMap` | `top_level_list_changed` | the same | the language's rule |
| `ForForms` | `list_may_be_shared` | `Tail` stores `rest`, a view of `model.rows`'s array, in `model.tail`; `Swap` and `Edit` then change `model.rows` in place, and the page would show `tail` changed | real sharing, reported as a limit: the entry's fixpoint joins `update`'s arms (§20.4) |
Each takes the fix its message writes: `List.copy rows` in `init`, and `List.copy rest`. The transcripts are
unchanged, the run hashes of the three re-recorded. `ForForms` is worth a second look: it is real sharing the
checker reports only as a limit, because the fact that settles it — which arm stored what — is joined away at the
entry. Before this branch was rebased onto the identity promises' removal (§27), `KeyedEnds` failed too, as a limit:
its `insertAt` appended to `List.take rows k`, which was then `rows` itself when `k` covered it. `List.take` builds
a fresh list now, and the page is accepted as written.

No other `browser/direct/` page, `emit/direct/` application or `build/bad/direct/` project produces an ownership
error, and the `browser-tea` pages run nothing new.

## 5. The applications on `browser-direct`

| Program | Errors | |
|---|---|---|
| TodoMVC, four programs | 0 | |
| table app | 0 | |
| Conduit | 1 `list_may_be_shared` | `update` edits four `errors` lists a view event may carry (P6's coarse rule; O6 would confine them) |
| Bike Wars | 2 `list_still_used`, 1 `top_level_list_changed` | `Bike.update`'s `current.trail ++ other.trail` with `current` read after (R2), `Bike.shoot` while `red.trail` is read after, and both trails starting as `Game.initBikes` |

Conduit and Bike Wars do not build on `browser-direct` yet for other reasons (S4, S5); these are `check`'s errors.

## 6. Open questions

1. **The pass on the DAG and the block in the interface** (§28.11 item 1): it restores the firewall on in-place
   builds and makes the pass parallel.
2. **Conduit's entry fixpoint** (§3): the cost target needs it.
3. **Paths in messages.** A model path is printed as the report prints it, `model#Article.0.errors`; a reader needs
   `errors` inside the `Article` page. A rendering for people is a message change only.
4. **Places inside `update`.** An entry error points at the program constructor, where the runtime hands `update` the
   model; it could also show the write inside `update`, which the summary does not locate today.

## 7. How to reproduce

```sh
zig build -Doptimize=ReleaseFast --prefix ~/.cache/beni-s4-rf    # and the same over `git archive origin/master`
gcc -O2 -o ~/.cache/icount bench/list-in-beni/icount.c
~/.cache/icount B check --no-cache --jobs=1 --platform=browser-direct --root=examples/conduit/src examples/conduit/src
B check --no-cache --jobs=1 --platform=browser-direct --root=examples/conduit/src examples/conduit/src --self-profile=p.json
zig build test-blackbox -Dcorpus=wnership     # the ownership/ kind and build/bad/direct/Ownership*
```
