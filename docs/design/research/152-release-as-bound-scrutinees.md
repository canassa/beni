# 152. A `case` subject shared by its readers, and a release that wrote over it

*Research report, 2026-11-17. The blind round W found a crash of the release build under
`--lists-in-place` (`RIPTRAP`, 14 programs), and the blind round V a plain release that threw (#2547,
7 `PLAINRUNFAIL`s). Both are one defect of the specialiser (`src/js/Spec.zig`), which `master` had
already fixed for #2512 and the branch `ownership-v2-design-review` did not have.*

## 1. Summary

- **Cause.** `Lower.bindings` gives one JsIr node of a `case` subject to several parents: an `as`
  binding or a variable arm binds the subject's very node (`const w = l0`), and the decision tree's
  tests and the other patterns' reads hold the same node (`l0.length`, `$t.a`). `Spec.liveness`
  dropped a dead binding by writing `undefined` over its initialiser node *in place*, so every
  other parent of that node read `undefined`.
- **The two faults are one.** #2547: `t` of `( a, b ) as t` is unread once `fstOf` is written in, so
  `$t` became `undefined` in `$t.a` and `$t.b`; the dropped parameters the reader saw follow from
  that. Round W: the dead `case`'s length test is a call under `--lists-in-place` (the in-place
  oracle's `length` wrapper), which the specialiser keeps where a plain release drops a read, so it
  ran on `undefined`.
- **Fix.** `master`'s 42490ac7a5 (#2512), cherry-picked with its fixtures (12b41cad28, fe71caa375):
  the dead statement points at a new `undefined` literal and the initialiser is left alone. The
  cherry-pick also brings master's #2514 fix (inlined loops get fresh slot names), whose four
  fixtures fail on the branch's base too (three throw, one hangs).
- **`master`** does not have #2547: a ReleaseSafe build of `origin/master` (f9d21509ac) prints `6`.
- **New evidence:** `run/ReleaseAsBoundScrutinee` (#2547's shape, a variable arm with no `as`, `as`
  one level down in a pair, `as` over `…rest`), `run/ReleaseAsListInPlace` with a new corpus leg — a
  `.sanitize-lists-v3` fixture is also built as a release under `--lists-in-place` — and a sweep
  family `as-scrutinees.mjs` (468 programs, 82 faults before the fix, 0 after).

## 2. Where the same mistake could be

The rule: an in-place rewrite of a node holds at every parent of the node, or it is wrong. A fold to
the node's value holds (the same expression in the same scope has the same value); a drop licensed by
one reader being dead holds at one parent.

**Which nodes are shared.** A throwaway instrument counted parents over every reachable node of every
module, before and after the specialiser, on the 927 single-file `run/` programs under `--release`.
Shared nodes are expressions only — `ident` (most: a subject under several `member`s), `member`,
`index_get`, `call` (a nested list subject, `List$unsafeGet(xs, 0)`, under its test and its reads),
literals, and one `arrow` (a derived `eq` passing one lambda twice in one expression). **No statement
node has two parents**, before or after. A binding's initialiser root was shared in 45 + 22 places
(`ident` under a `const_decl` and a `member`), one of them two `const`s of one node
(`run/MatchAsPattern`).

**The rewrites.** The 35 in-place writes of `Spec.zig` at the base (`setNode`, `setData`, `copyNode`, `foldTo`, outside the helpers themselves):

| Kind | Sites | At every parent? |
|---|---|---|
| A statement rewritten (`prune`, `foldList`, `foldAt`, `srList`, `betaReduce`, `inlineStatementAt`, `inlineAt`'s splice, `liveness`'s statement) | 12 | yes: a statement has one parent |
| A node folded to its value or a name for it (`patchLiteral`, `patchStmt`'s `foldTo`, `etaIn`, `forwardEntry`, `writeRead`, `mergeSame`, `replaceScalars`, `inlineSmallAt`, `inlineAt`'s call) | 16 | yes: the same value in the same scope |
| A call's arguments trimmed (`trimCall`, `callsBelow`) | 3 | yes: by its callee, which every parent shares; `rewriteCalls` keeps a `seen` set so a shared call is trimmed once |
| `x.insertBefore(n, null)` written `x.appendChild(n)` (`appendChild`), callee and arguments | 2 | yes while the callee has one parent: lowering never shares a callee, and a copy shares one only with a call that is gone (`Copy.atom`). DOM pages only; not exercised here |
| An object's unread keys dropped (`dropKeys`) | 1 | yes: "unread" is a fact of the allocation site, which every parent shares |
| **A dead binding's initialiser written `undefined` (`liveness`)** | 1 | **no: this was the defect** |

`liveness`'s marking of the dead initialiser's nodes (`Mod.objects`) is read only for binding
statements, which have one parent, and only stops a binding being processed again.

`Opt.zig` mutates nothing: its plan drops statements (one parent) and substitutes per `ident` node,
and its counts walk every occurrence, so a shared `ident` counts twice and is never a single use.
`Rename.zig` rewrites the name column only.

## 3. Evidence

- **Fixtures.** At the base 47aeb7854a, `-Dcorpus=run/Release` fails 11 of the fixtures (ten throw,
  `ReleaseInlinedLoopInLoop` hangs past the guard), among them `ReleaseAsBoundScrutinee [release]`
  and `ReleaseAsListInPlace [release-lists-v3]`; at the head all pass.
- **The blind rounds.** W's 14 `RIPTRAP` programs and V's 7 `PLAINRUNFAIL`s: all 21 `SAME` on every
  leg.
- **The family** `as-scrutinees.mjs`, 468 programs: base 16 `RIPTRAP` and 66 plain release runs that
  threw (lists, pairs, records and constructors; `as` at the top, one level down, over `…rest`, and
  variable arms); fix 228 `SAME`, 240 `REFUSED`, 0 faults.
- **Size** (`bench/size.mjs`, base and fix compilers on the same tree): the development column and
  every program but the 12 the base miscompiled are byte for byte the same, `bench/corpus` included;
  release total +45 brotli bytes, all in those 12. No `emit/` golden changes.

## 4. Sweeps

`bench/ownership-sweeps/run.mjs --checker=v3 --mode=both --jobs=24` (plain, sanitised, in place, and the release
pair) with the self-hosted ReleaseSafe compiler of the fix: every generator of the folder (`corpus.mjs` and
the new `as-scrutinees.mjs` included), its 13 fault folders, `harvest-v2-records/` (rebased in), and the blind rounds' 21 programs
(`blindset`: W's 14 `RIPTRAP`s, V's 7 `PLAINRUNFAIL`s). Faults are `TRAP`, `DIFF`, `IPTRAP`, `IPDIFF`,
`RIPTRAP`, `RIPDIFF`, `CRASH` and a failing plain release run (`rip=PLAINRUNFAIL`).

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| `alias-ctors` | 188 | 79 | 109 | 0 | 0 | — |
| `aliased-arguments` | 5160 | 1216 | 3944 | 0 | 0 | — |
| `answers-beside` | 240 | 79 | 161 | 0 | 0 | — |
| `answers-sends` | 54 | 19 | 35 | 0 | 0 | — |
| `as-scrutinees` | 468 | 228 | 240 | 0 | 0 | — |
| `blind-faults` | 24 | 11 | 13 | 0 | 0 | — |
| `blind` | 9792 | 1675 | 8117 | 0 | 0 | — |
| `blind10i-faults` | 16 | 7 | 9 | 0 | 0 | — |
| `blind10i` | 474 | 151 | 209 | 0 | 0 | 114 PLAINFAIL |
| `blind2-faults` | 20 | 7 | 13 | 0 | 0 | — |
| `blind2` | 1202 | 501 | 701 | 0 | 0 | — |
| `blind3-faults` | 10 | 3 | 7 | 0 | 0 | — |
| `blind3` | 417 | 160 | 257 | 0 | 0 | — |
| `blind4a-faults` | 12 | 1 | 11 | 0 | 0 | — |
| `blind4a` | 160 | 24 | 136 | 0 | 0 | — |
| `blind4b-faults` | 8 | 4 | 3 | 1 | 0 | — |
| `blind4b` | 6596 | 1188 | 5406 | 2 | 0 | — |
| `blind5c-faults` | 10 | 5 | 5 | 0 | 0 | — |
| `blind5c` | 226 | 77 | 147 | 2 | 0 | — |
| `blind5d-faults` | 10 | 5 | 5 | 0 | 0 | — |
| `blind5d` | 1234 | 449 | 785 | 0 | 0 | — |
| `blind6e-faults` | 12 | 4 | 8 | 0 | 0 | — |
| `blind6e` | 238 | 91 | 140 | 0 | 0 | 7 PLAINFAIL |
| `blind7f-faults` | 2 | 0 | 0 | 0 | 0 | 2 TIMEOUT |
| `blind7f` | 960 | 396 | 564 | 0 | 0 | — |
| `blind8g-faults` | 8 | 4 | 3 | 1 | 0 | — |
| `blind8g` | 121 | 21 | 99 | 1 | 0 | — |
| `blind9h` | 3213 | 849 | 2364 | 0 | 0 | — |
| `blindset` | 21 | 21 | 0 | 0 | 0 | — |
| `bounded-walk-faults` | 12 | 2 | 4 | 2 | 0 | 4 TIMEOUT |
| `bounded-walk` | 34 | 5 | 7 | 4 | 0 | 18 TIMEOUT |
| `build-read` | 1050 | 248 | 802 | 0 | 0 | — |
| `callbacks-keep` | 720 | 108 | 612 | 0 | 0 | — |
| `casts-at-vars` | 222 | 0 | 222 | 0 | 0 | — |
| `corpus` | 1741 | 1199 | 522 | 1 | 3 | 12 BOTHFAIL, 1 TIMEOUT, 3 PLAINFAIL |
| `evaluation-order` | 440 | 276 | 164 | 0 | 0 | — |
| `folds-callbacks` | 30300 | 5152 | 25148 | 0 | 0 | — |
| `function-values` | 1960 | 300 | 1660 | 0 | 0 | — |
| `handed-back` | 2592 | 0 | 2592 | 0 | 0 | — |
| `harvest-v2-records` | 28 | 2 | 24 | 2 | 0 | — |
| `host-values` | 81 | 2 | 79 | 0 | 0 | — |
| `records` | 1876 | 353 | 1523 | 0 | 0 | — |
| `recursive-levels` | 16131 | 3869 | 12262 | 0 | 0 | — |
| `runtime-calls-faults` | 8 | 2 | 5 | 1 | 0 | — |
| `wider-functions` | 354 | 144 | 210 | 0 | 0 | — |
| `worded-no-location` | 156 | 0 | 156 | 0 | 0 | — |
| **total** | **88601** | **18937** | **69483** | **17** | **3** | |

- **Faults**: the corpus's three `TRAP`s are the known ones (`run/ListSanitiserTrieHolder`;
  `dom/ShowAndBranches` and `tea/ShowAndBranches`, #2504). **0 new**, and no `rip=` line anywhere.
- Every generator's totals are report 151's; the corpus has 14 programs more than report 151 counted,
  among them the 12 fixtures this report adds or takes from master, and 12 `SAME` and 2 `REFUSED` more.

## 5. The review

One fresh adversarial reader (Opus), told to find a program whose release build differs from its
development build, wrote and ran 22 probes under four builds each (development, `--release`, and v3
with and without `--release --lists-in-place`): a second `case` on an `as` name, `as` over a
`Debug.log` or call argument in a function written in its caller, tuples of lambdas and of user
calls as subjects (aimed at item 6's `eta` and at shared `member`s), scalar-replaced record
subjects, shared `List$unsafeGet` calls aimed at the single-call rule, reads bound by a pattern and
then an in-place write of the `as` name, tail loops over `as`-bound lists written in their caller
(#2514's path), constructors and closures with `as` at two levels, constant and unseen arguments.
**No finding**: every probe prints the same with the fix; three of them throw on the base, which
confirms the fix independently. The reader named one place it could not exercise: `patchLiteral`'s
"object position" flag is set by the first parent met. Folding a node to its exact literal is the
same value at every parent, so a property read through the literal reads what it read through the
name; the flag only keeps a `null` out of an object position and weighs size, and changes no value.

## 6. Files

- Fix: `src/js/Spec.zig` `liveness` (cherry-picked), `src/js/Lower.zig` (#2514, cherry-picked).
- Rule: `backend.md` §9, *Reading off*, amended for #2547; `src/js/JsIr.zig`'s header.
- Fixtures: `tests/corpus/run/ReleaseAsBoundScrutinee`, `ReleaseAsListInPlace`, master's
  `ReleaseUnreadAs*` and `ReleaseInlinedLoop*`; the corpus leg `release-lists-v3`
  (`tests/blackbox/corpus_test.zig`, `tests/corpus/README.md`).
- Sweep: `bench/ownership-sweeps/as-scrutinees.mjs`.
