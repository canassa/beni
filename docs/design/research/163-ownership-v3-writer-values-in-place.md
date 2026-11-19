# 163 — Writer values under v3: routed where they are made, no copying form

*Research report, 2026-11-19. #2574, from blind round AM's first borderline (research report 161
was the base, `f28c5169be`). Kernel §12 item 5 holds the rule (*A writer value is routed where
it is made*, and its callback-writer paragraph).*

---

## 1. Result

- **The copying forms are gone.** Kernel §12 item 5 said a writer value "handed to a call that
  has no line, or bound anywhere but at a call's argument", and a callback-taking writer handed
  on as a value, "is the plain function, which copies". Under the owner's rule (`backend.md` §4,
  2026-10-15: every accepted write in place, every unprovable one a compile error, no copying
  fallback) that text was the fallback. It is rewritten: a writer named as a value is routed
  where the reference is, and every form no rule judges is refused, with the fix in the message.
- **Every shape of the issue is routed** (§2), and its live twin is refused by v3 and traps or
  differs under a mutant of v3 that is unsound; on the base, the same mutant let 366 of 384 such
  live twins through as SAME, because the write copied.
- **No verdict moved to refused** on any root; the ledger is 309 of 319, row for row (§4).
- **Sweeps and corpus, four legs: 0 faults** besides the known three (§5). A scan of the 3 188
  wholly accepted programs finds no core writer that runs unrouted.

## 2. The rule and the shapes

Each place a writer value can run is judged by v3 already: a call of it, however the callee
value was reached (`call` evaluates the callee to the writer's `fnref` and applies its contract);
a call that hands it on (`flow` into the callee's contract); a closure that captured it
(`flowCaptures` where the closure flows); and a holder that keeps or loses it is the default
location, which refuses a writer (§6 rule 8). So in a module whose lines are accepted, every run
of a writer value is a write v3 accepted, and the oracle may route the value itself.

- **`Enforce.valueWriter`**: each `ext_value` of a writer of `List`, `Dict` or `Set` that is
  not a call's callee, read through top-level aliases of other modules (a platform's `pub ins =
  Dict.insert`, `Prepass.aliasStep`, as `Mod.calleeOf` reads it), gets the line `value
  <writer>: accepted call` unless v3 refused it there, and the channel lists it.
- **`Lower.reference`** wraps such a reference: `_sanitize$writer(site, value)`, or, for the
  suspendable twin of a callback-taking writer, `_sanitize$writerWait(site, value,
  Task.andThen)` (new in both runtimes), which settles the base once the answer is there. A call
  through a `let` alias is routed at its call with the writer itself (`unroutedCallee`), so no
  write is routed twice. `Lower.coreWriterAt` follows a platform's alias at a call
  (`Probe.ins d 3 30` is `_sanitize$list` with `Probe$ins`), and `Enforce.coreValueOf` does too,
  so `Probe.upd` (an alias of the walked `Dict.update`) is named as a writer.
- The v3 message of a refused writer value says the fix: *Call the function directly where it
  writes, or hand it straight to the call that runs it, or change a copy (`Dict.copy`)*; a
  `Dict` or `Set` write names `Dict.copy` or `Set.copy` instead of `List.copy`.
- `Lower.routeWriterValues` and `Enforce.handsCoreWriter` (routing at the handing call) are gone:
  the value routes itself.

| Shape (issue #2574 and AM's borderline 1) | Now |
|---|---|
| `w = idW Dict.insert; w d0 3 [ 30 ]` | routed |
| `idW (idW Dict.insert)`, `(λf → f) Dict.insert`, `idW ins` (a local alias) | routed |
| `apply (idW Dict.insert) d0` | routed |
| `idR Dict.remove`, `idSet Set.insert` | routed |
| a platform's `pub ins = Dict.insert`, called or handed on | routed |
| a captured writer value (`h = λx → w x 7 70`), called or handed on | routed |
| `idU Dict.update`, `idP Dict.sortBy` with a parking callback, `idLU List.update` parking | routed (`writerWait`) |
| `List.push`, `List.set` through the same productions | routed |
| a writer in a record's field, a list, a `Maybe`, a tuple, a constructor, a top-level value, a function's answer | refused, as before, with the fix named |

Fixtures: `run/WriterValuesRouted` (14 shapes, `.sanitize-lists-v3`, SAME in every leg),
`run/WriterValuesRoutedLive` (its twin, 14 refusals), `run/WriterValuePlatformAlias` and
`…Live` (a project platform layer, 5 forms), `run/WriterValuesKept` (7 refusals),
`run/WriterValuePlatformKept` (the review's finding, §6); the message
in `check_test.zig`. With the lowering reverted the corpus fails the routed fixtures (`v3
accepts the list write 81:13 value Dict.insert …, which the sanitised build does not wrap`).
With `Frame.useReaches` answering "no" (a mutant, not committed), all 14 live twins of
`WriterValuesRoutedLive` and all 5 of `…PlatformAliasLive` trap under the sanitiser and print
the written value through the old name in place; on the base the same mutant prints SAME for
all of them.

## 3. Sweep: `writer-values.mjs`

Eight writers × thirteen productions × six uses × live/dead, 1 248 programs.

| Compiler | SAME dead | REFUSED dead | REFUSED live | TRAP live | SAME live |
|---|---:|---:|---:|---:|---:|
| lane | 384 | 240 (the five kept forms, all) | 624 | 0 | 0 |
| lane, `useReaches` mutant | 384 | 240 | 240 | **384** | 0 |
| base, `useReaches` mutant | 384 | 240 | 240 | 18 | **366** |

## 4. Verdicts and the ledger

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of all 2 894 roots, base and
lane on the lane's sources:

| Change | Lines | Where |
|---|---:|---|
| absent → accepted | 41 | the new `value <writer>` lines: `run/DictWriterRouting` 7, `…Live` 6, `run/ListSanitiserValues` 2, the new fixtures 26 |
| any other | 0 | |

No other line of any root differs (the final compiler, after the review fix).

**The ledger** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): 319 list writes
v1 judges, v3 accepts 309 and refuses 10, the same rows; 27 v3 refusals at positions with no v1
line, as before. **No real-root line changed.**

## 5. Sweeps and corpus, four legs

`run.mjs --checker=v3 --mode=both`, the lane's ReleaseSafe compiler.

| Sweep | Programs | SAME | REFUSED | Faults | Other |
|---|---:|---:|---:|---:|---|
| `writer-values.mjs` | 1 248 | 384 | 864 | 0 | every live twin refused |
| `dicts.mjs` | 7 164 | 779 | 6 385 | 0 | as in report 161 |
| `records.mjs` | 1 876 | 353 | 1 523 | 0 | |
| `function-values.mjs` | 1 960 | 300 | 1 660 | 0 | |
| `handed-back.mjs` | 2 592 | 0 | 2 592 | 0 | |
| `callbacks-keep.mjs` | 720 | 108 | 612 | 0 | |
| corpus | 1 816 | 1 264 | 531 | 3 | the known `run/ListSanitiserTrieHolder`, `dom`/`tea` `ShowAndBranches`; 12 BOTHFAIL, 4 PLAINFAIL, 1 LIMIT, 1 TIMEOUT (`run/TailModConsMerge`) |

**Scan.** Each of the 3 188 SAME programs above (before the review fix, which refuses only a platform form) built in place, and each reference to a core
writer in its program modules read (2 707): every one is the writer of a `_sanitize$` call or
inside the eta-expansion that is one. `List.sortBy` (11 hits, a new list, no writer) is the only
other match.

## 6. Review

One fresh adversarial reader (Opus), about 190 programs in eight batches: writer values inside
core's calls (`List.foldl`/`foldr`, `map2`, `initialize`, `Dict.foldl`), `Ref`, joins,
two calls, fibers, `Debug.log`, pipes and `_`; core functions that hand a writer back
(`Log.span`, `Task.scope`/`par`/`race`, `Queue`, `Deferred`); app functions running a writer
on a top-level base or twice; parking `Dict.update`/`List.update` under `Task.par`; platform
`foreign`s that take or hand back a writer; another module's folds over one base twice; writers
through `where` evidence; markup holes, `For` and `Show`. **No TRAP or DIFF in any leg.**

**One finding, fixed.** A platform's top-level value that a call answers (`pub lPush = idL
List.push`, `(λf → f) Set.insert`, `idU Dict.update`) held a writer v3 refused in the platform
(`value <call Probe.idL>: rejected call`), but a platform's refusals stopped no build except
evidence's, and no reader follows such a value (`aliasStep` reads only a name), so the program's
`Probe.lPush b0 3` had no line and ran the plain writer, which copies: SAME in every leg, with
`b0` read after. Now that refusal stops every build (`Enforce`, `kept_writer`: a refused
`value` line of cause `call` in a module that is no core module and no program's, other than
the body of a top-level alias, which every reader reads as the writer). No real root has such a
line (every root's dump, platforms included). `run/WriterValuePlatformKept` (refused in the
platform; accepted before, the write copied). The same constant in a program module was refused
already.

## 7. Reproduce

```sh
node bench/ownership-sweeps/writer-values.mjs <dir>/wv
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=16 --tmp=<disk> <dir>/wv
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
```
