# 123 — Ownership v3: every call the runtime makes into the program

*Research report, 2026-11-13. It answers reports 121 and 122, the fifth blind test of `src/own3/`
(`--ownership=v3`, pull request #2451). It is not normative: `docs/design/ownership-v3-kernel.md` is, and
this work changed its §5 (the theorem's argument), §6.12 and §6.13. It compares the branch head
`125fd0cbc9` (before) with this work (after), on the same programs, with ReleaseSafe compilers of each.*

---

## 0. Summary

Two blind readers found the same faults at `a2c60aa2b7`, and reader C found one more. All of them are in
two rules: the entry (kernel §6.13) and markup (§6.12). Each is a place where the runtime calls into the
program's code, and the checker did not apply that call.

- **The entry.** A function of the program's record with no known code was dropped. It was neither a maker
  of the model nor one of "the other functions", so what it kept was not read. And whether an answer was
  the model or a pair whose first item is the model was guessed from locations, so a tuple model was read
  at the wrong place. Now every function of the record is accounted for by a contract, and where each
  function has the model is read off the entry's declared type.
- **Markup.** A closure made in a hole was not held by the markup, and a text hole was not counted as a
  helper. And the rule's argument left out that the runtime **calls** a `For` row, a key function and a
  `Show` body with items of the markup's values. Now the markup holds every closure its holes make, and
  each of those calls is applied to its items as at a call site.

All ten live programs of the two fault folders are refused, and all ten safe twins are accepted. Every
generator and fault folder of `bench/ownership-sweeps/` has 0 traps, differences and crashes after,
against 453 before (§4). The sanitiser corpus has 0 traps before and after. The real writes are 287 of
308 before and after, the same 287.

## 1. The rules rewritten

### 1.1 The entry (kernel §6.13)

**What was wrong.** `entryCall` kept a field only when `codeOf` gave it code. A field given as
`if dark then viewDark else viewLight`, a `case` arm, a field of a top-level record, `Maybe.withDefault`
or the answer of a call went to `flowTop` and was skipped. `flowTop` refuses a function that writes its
parameter, but not one that keeps it. For `settle`, a missing producer was skipped with `continue`.
This is "no contract" read as "keeps nothing". Separately, the walk decided whether a producer's answer is
the model by looking for a location below index 0. A tuple model has its own index 0, so the guess said
"the answer is the model", the model's location was looked for at the wrong place, no source was found,
and every location stayed `own`.

**The rule now.**

- **Every function of the record is accounted for.** A field's value is a known function, or a `join` of
  known functions, and each value it can be is applied as that field (`fnMembers`). So
  `if alt then viewB else viewA` is judged as `viewA` and as `viewB`. A field with no known code is the
  default: it can write nothing, it can keep everything the runtime hands it, and **no location of the
  model is `own`**. The same holds for a field the entry's type does not name, a record not written at the
  call, and an entry whose model no function makes from nothing. A constructor whose answer holds no cell
  is the one function value of no object; it keeps nothing.
- **Where the model is comes from the declared type** (`Mod.entryShape`). The checker reads the `entry`
  parameter's record type in the platform's source. The model is the type variable of `update`'s last
  parameter. A field whose answer type is that variable answers the model; one whose answer is a tuple
  with it at item *k* (`model × Cmd msg`) has the model at *k*; a parameter of that type is the model
  parameter. A field that names the variable any other way has no fact, and no location is `own`. A field
  whose answer has the model is a **producer**; every other function field is a **consumer**. This also
  covers fields that are not `init`, `update`, `settle` or `view`, such as `subscriptions` and
  `Tea.application`'s `onUrlRequest` and `onUrlChange`, by their types and not their names.

**The corrected argument.** "No other holder" of a model location is a statement about every function
the runtime calls with the model and every function that makes it. It is derived only from a contract of
each, read at the place the declared type gives. A function with no contract, or a place no type gives,
leaves the statement with no ground, so it does not hold.

### 1.2 Markup (kernel §6.12)

**What was wrong.**

1. The markup collected what a hole reads in `markup_reads`, and only a local read added to it. A
   lambda's captures are read through `capSlot`, which added nothing, so
   `{(λ⊤ → List.length xs) ⊤}` held neither the closure nor `xs`. The same held through `Maybe.map`,
   `List.map`, an `if`, or a helper handed the lambda.
2. A hole of text that calls a top-level function was not taken as a helper, but the `dom` lowering
   evaluates it where it renders.
3. A `For` row function, a key function and a `Show` body were only read. Nothing handed them the items of
   `each` or the value in `when`. So a row that put its item in an event's message (`Pick r`) or a `Ref`
   recorded the escape against its own parameter, and that escape never reached the list.

**The rule now.** A hole holds everything its evaluation can read: each local and capture it reads, and
each closure it makes (`closureOf` adds the closure, whose leaves are its captures). Every hole that calls
a top-level function is a helper. The runtime's calls are applied (`formCalls`, `runtimeCall`): a `For`'s
row and key function with an item of `each` (and a row's position), a `Show`'s body and key function with
the value in `when`. Each goes through `applyAt`, the call rule (§6.2), so what the contract lets escape
escapes and what the function hands a function is supplied. A function with no known code is unknown
code: the item and the function escape. The function is still in the default use, so one that writes its
parameter is refused, because the runtime can call it more than once with one item.

**The corrected argument.** The runtime is a holder that the walk does not follow. It does two things
with markup: it reads the values the markup holds while it renders, and it calls code the markup gives
it. The first is covered by the markup holding everything its holes can read until it is rendered, and by
the platform rule (`boundary.md` §9.4.8) after that. The second is a call, and its arguments are items of
the markup's values. So each such call is applied, and the theorem of §5 holds with the runtime's calls as
calls. The kernel's §5 now says so.

## 2. The tests

`tests/blackbox/check_test.zig`:

- "the faults of the fifth blind test are refused": the ten live programs of `blind5c-faults/` and
  `blind5d-faults/` are refused, each with its expected line, and the ten twins are accepted.
- "the siblings of the fifth blind test are refused": four programs that the audit found (§3).
  `ShowBody` (a `Show` body keeps its value in a message), `ForKey` (a key function keeps its item in a
  `Ref`) and `TopField` (`view` is a field of a top-level record) each trap under `--sanitize-lists`
  before. `Children` (a component's children) does not trap on today's `dom` runtime, which evaluates
  that hole where the markup is made; it is refused by the same rule as a prop.

The corpus:

- `run/SsrRowKeeps` with `.sanitize-lists-v3-refuses`: report 122's `for-row-keeps` on `node`. Before,
  v3 accepts it and the sanitised run traps.
- `browser/tea/PairModelInPlace` with `.sanitize-lists-v3`: a tuple model, a `view` that is one of two
  functions, and a `For` with a row and a key function, with `update` pushing in place. It shows that the
  new rules still accept a safe program of these shapes, and that the runtime keeps no list of it.

**The tests fail before the fix.** In a second worktree at `125fd0cbc9` with this work's
`check_test.zig`, `zig build test-blackbox-check -Dtest-filter="fifth blind"` fails both tests
(`entry-tuple-pair.live` accepted; `ShowBody` accepted). With this work's `run/SsrRowKeeps`, the corpus
case fails: "v3 accepts a program it must refuse", and the sanitised run shows the stale read.

## 3. The sibling audit

Every place where the platform or a runtime calls into the program's code, and every place where a
function with no known code was skipped.

| Place | Verdict |
|---|---|
| A field of the entry's record with no known code (`if`, `case`, a call's answer, a top-level record's field, `Maybe.withDefault`) | **fixed**: each value of a `join` is applied; anything else leaves no location `own` |
| A field past the old fixed array of 12 | **fixed**: the fields are a list; a field the type does not name has no fact |
| `settle` with no code | **fixed**: a producer with no known code leaves no location `own` |
| Where the model is in an answer | **fixed**: read off the declared type (`Mod.entryShape`) |
| `Tea.application`'s `onUrlRequest`, `onUrlChange`, and `subscriptions` | **fixed**: each is a consumer by its type, accounted for like `view`; with no code, no location is `own` |
| A `For` row function | **fixed**: applied to each item (`row-parameter`, `for-row-message`, `for-row-keeps`) |
| A `For` key function | **fixed**: applied to each item (`ForKey`, a trap before) |
| A `Show` body and its key function | **fixed**: applied to the value in `when` (`ShowBody`, a trap before) |
| A closure made in a hole | **fixed**: the markup holds the closure (`hole-closure`) |
| A text hole that calls a top-level function | **fixed**: a helper, its arguments held |
| A component's children | **fixed**: a prop, so everything its holes read escapes (`Children`) |
| A component's callee and props | already derived: the callee is in the default use, the props escape |
| An event's handler | already derived: it escapes where the markup is made; the runtime hands it an event, which holds no cell of the frame |
| `Html.map`'s function | already derived: it escapes; the runtime hands it messages, which are an event's message or a handler's answer, so they hold only escaped cells and new ones |
| `Cmd` and `Sub` callbacks (`Cmd.perform`, `Sub.listen`, `Time.every`'s tagger) | already derived: each is a function handed to a callee in `core/` or a platform, which flows to that callee's contract (rule 2); the callee's code is walked, and where it hands the function to JavaScript the function is lost, so what it captured escapes (report 120 §5, `Hosted.tap`) |
| `Task` and `Io` continuations (`Task.andThen`, `Io.run`'s body) | already derived, as above: calls of walked code or of a worded row |
| `Browser.programs`, `Browser.mountAt` | already derived: each takes a `Program`, which the entry call already judged; its value is `unknown` over the record |
| Decoders and schema codecs | already derived: a function handed to `core/` flows to its contract; a derived codec is an edge of the dispatch terms (§6.11) |
| Evidence | already derived: refused where it writes, keeps or has no contract (§6.11) |
| `apply`, `flowCaptures` and the other loops that skip `fns[j] == null` | already derived: that parameter is not a function of the contract |

## 4. The gate

ReleaseSafe compilers of `125fd0cbc9` (before) and of this work (after), `run.mjs --checker=v3` on the same
generated programs, and the seven fault folders from a `LIST` of their programs. `blind4b` includes its
4 000 random blocks.

| Generator | Programs | before SAME | before REFUSED | before TRAP/DIFF/CRASH | after SAME | after REFUSED | after TRAP/DIFF/CRASH |
|---|---:|---:|---:|---:|---:|---:|---:|
| blind-faults | 24 | 11 | 13 | 0 | 11 | 13 | 0 |
| blind2-faults | 20 | 7 | 13 | 0 | 7 | 13 | 0 |
| blind3-faults | 10 | 3 | 7 | 0 | 3 | 7 | 0 |
| blind4a-faults | 12 | 1 | 11 | 0 | 1 | 11 | 0 |
| blind4b-faults | 8 | 4 | 4 | 0 | 4 | 4 | 0 |
| blind5c-faults | 10 | 5 | 0 | **5** | 5 | 5 | 0 |
| blind5d-faults | 10 | 5 | 0 | **5** | 5 | 5 | 0 |
| blind | 9792 | 1675 | 8117 | 0 | 1675 | 8117 | 0 |
| blind2 | 1202 | 502 | 700 | 0 | 502 | 700 | 0 |
| blind3 | 417 | 160 | 257 | 0 | 160 | 257 | 0 |
| blind4a | 160 | 24 | 136 | 0 | 24 | 136 | 0 |
| blind4b | 6596 | 1290 | 5306 | 0 | 1290 | 5306 | 0 |
| blind5c | 226 | 90 | 86 | **50** | 81 | 145 | 0 |
| blind5d | 1234 | 610 | 231 | **393** | 456 | 778 | 0 |
| evaluation-order | 440 | 276 | 164 | 0 | 276 | 164 | 0 |
| answers-beside | 240 | 77 | 163 | 0 | 77 | 163 | 0 |
| wider-functions | 354 | 144 | 210 | 0 | 144 | 210 | 0 |
| callbacks-keep | 720 | 108 | 612 | 0 | 108 | 612 | 0 |
| function-values | 1960 | 304 | 1656 | 0 | 304 | 1656 | 0 |
| handed-back | 2592 | 0 | 2592 | 0 | 0 | 2592 | 0 |
| aliased-arguments | 5160 | 1183 | 3977 | 0 | 1183 | 3977 | 0 |
| recursive-levels | 16131 | 4231 | 11900 | 0 | 4231 | 11900 | 0 |
| folds-callbacks | 30300 | 5392 | 24908 | 0 | 5392 | 24908 | 0 |
| **all** | 77618 | 16102 | 61063 | **453** | 15939 | 61679 | 0 |

Every generator but `blind5c` and `blind5d` gives the same verdict for every program before and after.
What moved:

- **Traps to refusals**: the 453 traps of `blind5c`, `blind5d` and their fault folders.
- **Safe twins refused** (163), all a precision loss of a stated rule:
  - 117 of `blind5d` and 9 of `blind5c`: the record's function is given with no known code
    (`views.main`, `Maybe.withDefault`, `fst` of a pair, the answer of a call such as `settleOf 0`). The
    default leaves no model location `own`. A fact that would win them back is the code a value of a
    top-level record or a call's answer can be; the owner asked for none here.
  - 35 other `rowmap` twins of `blind5d`: a row `λr → Html.map inner λ_ → Snap (List.copy r)`. `Html.map`'s
    function is kept by the runtime and captures `r`, so the row keeps its item. The twin is not safe:
    the copy is made when the function runs, which can be after a push of the same task, the reason
    report 122 §4 gives for its handler twins.
  - 2 `ssr` programs (`ssr.keykeep.live`, `ssr.showkeykeep.live`), `SAME` before only because the `ssr`
    lowering does not run key functions. The same key function on a page traps.

**The sanitiser corpus** (`bench/ownership-step0-sanitiser.mjs`, 347 fixtures): 97 same, 250 refused, 0
traps, differences or crashes, before and after.

**Real writes** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 list writes v1
judges, v3 accepts 287 at v1's position, refuses 20 and has no line for 1, before and after. The list of
refused writes is the same, line for line. No write is lost or won.

**Speed.** ReleaseFast LLVM compilers (`zig build test-perf`) of `125fd0cbc9` and of this work,
`bench/ownership-v2-review.mjs --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1`, best of three, one
machine, one after the other:

| | lines | before ms | after ms | before lines/s | after lines/s |
|---|---:|---:|---:|---:|---:|
| type check (for scale) | 169 846 | 235.7 | 236.5 | 721 000 | 718 000 |
| v3, on the modules v2 walked | 169 846 | 200.8 | 202.2 | **846 000** | **840 000** |
| v3, on all it walks | 556 500 | 523.4 | 528.3 | 1 063 000 | 1 053 000 |

The cost is under 1 % of v3's time: the declared type of each entry, and the runtime's calls of each
`For` and `Show`.

`zig build gates`: green on the final commit.

## 5. The review

One fresh Opus reviewer had the code, the kernel and `boundary.md` §9.4.8. It was asked for a function that
the runtime calls with a list and that the checker never applies, or for a missing fact still read as
"nothing", each proven by a program. It found no such hole in the changed rules. It proved one breach of
the platform rule that the checker trusts. The breach is outside this work:

- **A runtime compares a kept list by identity.** Two forms keep the last render's item and compare it
  with `===` (`language.md` §11.9, §11.18): a `For` keyed by reference (`keyed={True}`, bare `keyed`, or
  no `keyed`), and a `Show` keyed by identity. When `update` writes that item in place, it is still the
  same object. So the runtime keeps the row or body where the copying build remounts it, and an input keeps
  its text. v3 accepts the write. The sanitiser cannot see this, because its copy is a new object. So the
  reviewer used a build that edits arrays in place: four programs differ, and about 25 controls do not.
  The `For` case is the known breach #2504, which `boundary.md` §9.4.8 lists and the owner deferred. **The
  `Show` case is the same breach**, but #2504 names only `For`. It belongs to the same decision. Nothing
  is changed here.

The reviewer also tried these, and v3 refused them or was correct:

- a component's view, `Html.map`'s function, a handler, `Cmd.map`'s tag, or a component's children that
  writes its argument;
- a row, a key function or a handler that writes a capture;
- a `Cmd.perform` body or a subscription's tagger over a model list;
- markup or a closure kept in the model;
- the entry reached through `List.map`, `▷` or a partial application;
- helpers, rows and `Show` inputs that read from outside the item;
- `class` and `style` lists edited in place.

## Appendix A. Commands

From the worktree root, `ZIG_GLOBAL_CACHE_DIR` as `flake.nix` sets it.

1. The compilers: `zig build -Doptimize=ReleaseSafe --prefix <dir>` at `125fd0cbc9` and at this work.
2. The sweeps: `node bench/ownership-sweeps/<generator>.mjs <out>/<generator>`, then
   `node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 --tag=<before|after> --jobs=24 --tmp=<disk> <out>/<generator>`;
   the fault folders the same way, from a `LIST` of their programs.
3. The sanitiser corpus: `node bench/ownership-step0-sanitiser.mjs --beni=<beni> --jobs=14`.
4. Real writes: `node bench/ownership-v2-review.mjs --beni=<beni> --checkers=v1,v3 --roots=real --runs=1`.
5. Speed: `zig build test-perf "-Dtest-filter=generated module of §7.6"` (a ReleaseFast LLVM compiler), then
   `node bench/ownership-v2-review.mjs --beni=zig-out/perf/bin/beni --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1`.
