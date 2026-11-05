# Research 111: what can still go wrong at run time, the hole hunt for #1988

Research report for beni, 2026-11-05. The question: **what else can go wrong at run time in a beni
program, in the checked builds, that #1988 does not catch yet?** The owner's goal is that a checked
build "should never let an infinity/nan/whatever slip and let the program go into undefined
behaviour." [`language.md`](../language.md) §13, [`backend.md`](../backend.md) §16 and
[`boundary.md`](../boundary.md) §4.3 are the contract this report feeds. This report is evidence,
not contract. [`110`](110-int-soundness-survey.md) is the survey of other languages.

| Label | Meaning |
|---|---|
| **[run]** | A beni program was built with the beni of master `89acc97412` on x86-64 Linux and run on Node 24.19. A page ran under the vendored happy-dom, not in Chrome. The output is quoted. |
| **[host]** | A JavaScript expression was run on Node 24.19, and the path from beni to it was read. |
| **[read]** | Read in the source, not run. Treat it as a claim. |

## 1. The answer in brief

The checks #1988 lists are right, and they are not the whole of the goal. Three things stand
between #1988 as written and the goal:

1. **A checked `+` cannot be written today under a `number` type variable** (§2, H1). This is the
   one gap in the design itself, and it needs the owner (D1, #1996).
2. **The wall.** `Js.to` is an unchecked cast, and `undefined` reaches a `String` from an ordinary
   program (H2). Checks on arithmetic cannot see this class. D2, #1997.
3. **Two paths miss the defect path**, so a crash there does not stop a program (H3, #1994).

The rest is a list of smaller defects, most of which a check turns into a clean crash, and some of
which a check makes worse if nothing else changes: a core function that promised an answer would
start to crash (H6, H8), and a client could stop a server (H9).

Much of the list was already safe, and §4 says so.

## 2. The holes, ranked

Severity: **high** is a value its type does not admit, or a crash that does not stop the program, in
a checked build as #1988 stands. **Medium** is a wrong answer, a hang or a remote stop. **Low** is a
wrong report or a corner.

| # | Hole | Severity | Status | Issue |
|---|---|---|---|---|
| H1 | `+ - *` on a `number` variable: one body for `Int` and `Float` | high | [run] | #1996 |
| H2 | `Js.to` carries a false type: `Html.targetValue` gives `undefined` typed `String` | high | [run] | #1993, #1997 |
| H3 | A fiber's defect under a plain `Browser.program` does not stop the page | high | [run] | #1994 |
| H4 | A throw while a module loads shows no crash screen | medium | [run] | #1994 |
| H5 | `int` literals past the range are silently wrong, or `Infinity` | medium | [run] | contract, §13.3 |
| H6 | `Int.mod` is wrong near `2⁵³`, and its `+` would crash on input whose answer fits | medium | [run] | #1992 |
| H7 | `Random.int` hangs on a range wider than `2³²` | medium | [run] | #1992 |
| H8 | `Duration` leaves its documented range; #1988's note on `times` is not enough | medium | [run] | #1992 |
| H9 | A `trailer` header ends the Node server; a peer's WebSocket length would crash it | medium | [run]; the second [read] | #1995 |
| H10 | `round` of a finite value past `2⁵³` is a case #1988's table does not list | medium | [run] | contract, §13.3 |
| H11 | An optimiser pass may drop, sink or fold a check under `--release-safe` | medium | [read] | contract, §13.8, `backend.md` §16.6 |
| H12 | `language.md` §6 says arithmetic "cannot fail" | medium | read in the text | contract, §6 |
| H13 | Core's `Basics.append` and `String.append` write `+` on strings typed `Int` | medium | [read] | contract, `backend.md` §16.4 |
| H14 | A crash in one Node request stops the server for everyone | medium | by the rule | D5, decided: keep, #1998 |
| H15 | `-0` typed `Int` is visible through `toFloat` | low | [run] | D3, decided: documented, valid, #1998 |
| H16 | `Debug.toString` prints a zero's sign inverted | low | [run] | #1282 |
| H17 | `degrees` and `toPolar` overflow on finite input with a finite answer | medium | [run] by the review | #2021 |
| H18 | Other host calls with no typed error: see §3.5 | low | [host] and [read] | #1995 |
| H19 | `Int` written to a host that narrows it | low | [read] | contract, `boundary.md` §4.3 (c) |
| H20 | `Node.exitWith` takes its code modulo 256 | low | [run] | contract, `boundary.md` §4.3 (c) |
| H21 | Virtual clocks and deadlines leave the `Int` range | medium | [run] by the review | #2022 |
| H22 | A file input's non-empty `value` throws in a render, `browser` and `browser-inline` | medium | [run] by the review, happy-dom and Chrome 153 | #2020 |
| H23 | A development Worker with a Durable Object does not start | high | [run] by the review, Miniflare 2026-05-18 | #2019 |
| H24 | A `NaN` test placed where a comparison answers `false` misses `≠` | high, in the first draft's lowering | review | `backend.md` §16.2 |

*Added after the review (§8):* H21–H24 are the review's. H24 was an error of the first draft of
`backend.md` §16.2, not of master.

## 3. The evidence

### 3.1 The design gap: H1

```text
twice : number → number
twice x = x + x

twice 9007199254740991                            → 18014398509481982
twice 1.0e308                                     → Infinity
List.sum [ 9007199254740991, 9007199254740991 ]   → 18014398509481982
List.sum [ 1.0e308, 1.0e308 ]                     → Infinity
```

Emitted: `const Main$twice = (x$1) => x$1 + x$1;` and `const List$sum = (xs$1) => List$foldl(xs$1,
0, Basics$add);`. There is no evidence parameter, and `backend.md` §4 says "No type is read". The
two `Int` lines must crash in a checked build and the two `Float` lines must not.

### 3.2 `Int` sources and `-0`

| Expression | Result, typed `Int`, today |
|---|---|
| `9007199254740993` | `9007199254740992` |
| a 309-digit literal | `Infinity` |
| `0xFFFFFFFFFFFFFFFFFFFFF` | `1.9342813113834067e+25` |
| `String.toInt "9007199254740991"` | `Just 9007199254740991`. `…992` is `Nothing`: already sealed |
| `Json.decode "9007199254740993"`, `"1e999"`, `"1.5"` | `Err … InvalidValue`: already sealed. `"1e3"` is `Ok 1000`. `"-0"` is `Ok 0`, which is `-0` |
| `Json.encode (big 400)` | `Err … InvalidValue`: the encoder tests too |
| `round 1e300`, `truncate 1e300` | `1e+300` (H10) |
| `round (0/0)`, `ceiling (1/0)` | `NaN`, `Infinity` |
| `Int.mod (big 400) 3`, `(big 400) // (big 400)` | `NaN`, `NaN` |
| `Char.fromCode` of `NaN`, `-1`, `1114112` or `55296` | `U+FFFD`, a `Char`: safe |
| `Int32.fromInt` of `NaN`, `Infinity` | `0`: safe by `\| 0` |

`-0` comes from `0 * (0 - 1)`, `Int.rem (0-4) 2`, `round (0-0.4)`, `ceiling (0-0.5)`, `truncate
(0-0.5)`, `(0-1) // 2` and `String.toInt "-0"`: `1 / toFloat x` is `-Infinity` for each. `Int.mod
(0-4) 2` is `+0`. `String.fromInt`, `Debug.toString`, `==`, a `Dict` key (`Dict.get` of a map with
key `0`, at a `-0`, is `Just 1`) cannot see it. [run]

### 3.3 Silent answers from `NaN` and infinity, under today's arithmetic

These are what `--release` will keep doing. In a checked build the `NaN` or the infinity cannot
reach them, since each needs an `Int` that is not true of its type, or a comparison that crashes.

| Expression | Result |
|---|---|
| `ni == ni`, `ni < 3`, `compare ni 1` | `False`, `False`, `EQ` |
| `max ni 1`, `max 1 ni`, `min 1 ni`, `clamp ni 0 10` | `1`, `NaN`, `NaN`, `NaN` |
| `List.sort [3.0, nan, 1.0, nan, 2.0, 0.5]` | `[3,NaN,1,NaN,0.5,2]`, not sorted |
| `[ nan ] ≤ [ 1 ]`, `[ nan ] ≥ [ 1 ]`, `[ nan, 0 ] < [ 1, 1 ]`, `nan ≤ 1` | `True`, `True`, `True`, `False` |
| `Dict.insert (Dict.fromList [ ( 1, "a" ) ]) ni "b"` | `[(1,"b")]`: key 1 overwritten |
| `Dict.get (Dict.fromList [ ( 1, "a" ) ]) ni` | `Just "a"` |
| `Set.member (Set.fromList [ 7 ]) ni` | `True` |
| `List.repeat 1 ni`, `List.range 0 ni`, `String.repeat "ab" ni` | empty |
| `List.repeat 1 ii`, `List.range 0 ii`, `String.padLeft "a" ii 'x'` | `RangeError: Invalid array length`, raw |
| `go ni 0`, `go ii 0`, where `go n acc = if n == 0 then acc else go (n - 1) (acc + 1)` | a hang: a tail-call loop |
| `Pcg.list g ni`, `Pcg.list g ii` | a hang |
| `Queue.takeN q ni` | no value, then "the program cannot go on" |
| `Queue.bounded ni` | an unbounded queue |
| `Pcg.int 0 ni` | `NaN` |
| `Node.exitWith "x" ni` | `RangeError [ERR_OUT_OF_RANGE]`, raw, after the output |
| `Io.sleep ii` | a hang |
| `Io.sleep ni`, `Duration.millis ni` | a yield, `zero`: safe by the `n > 0` test |

The same programs built with `--release --allow-debug` print the same results, line for line, for
the numeric batches (a, b, h in the probes). So today's `--release` agrees with the development
build here, and the optimiser adds no difference of its own.

### 3.4 Duration, H8

```text
Duration.toMillis (Duration.seconds 9007199254740991)   → 9007199254740991000
Duration.toMillis (Duration.seconds (big 400))          → Infinity
Duration.toMillis (Duration.sum (millis M) (millis M))  → 18014398509481982
Duration.toMillis (Duration.times (Duration.seconds 1) nan)    → 0
Duration.toMillis (Duration.times (Duration.seconds 1) inf)    → 9007199254740991
```

`core/Duration.beni` says "never a crash". #1988's note says lines 82–84 keep working under the
table. They do not alone: `toFloat n * factor` on line 80 uses the `NaN`, before the tests, and
`round product` on line 87 crashes on a finite product past the range.

### 3.5 The host, H9 and H18

`handle request = { status = 200, headers = [ ( "trailer", "x" ) ], body = "hello" }`, two requests:
`ECONNRESET`, then `ECONNREFUSED`, `Error [ERR_HTTP_TRAILER_INVALID]`, exit 1. [run]

`new Headers().set("content-type", "text/日本")` is a `TypeError`. `setTimeout(f, 2147483648)` fired
after 1 ms. [host] `platforms/browser/Http.beni:777` and `:836` reach them. [read]

**Read, not run** (a second reader's audit; #1995 lists each with its line): `Server.beni:519`'s body
past the string limit; `WebSocket.beni:814`, the same; `Worker.beni:796`, `new Request` on a used
body; `Worker.beni:562`, `Worker.text 204 ""`; `Object.beni:833`, `setAlarm` out of range;
`Rt.beni:1755`, a file input's `value`; *corrected (§8):* the `204` and `setAlarm` predictions did
not reproduce in workerd, and the file input did reproduce (#2020); `Navigation.beni:131`, `goBack 4294967296`;
`Navigation.beni:162`, a `SecurityError` labelled `Throttled`; `Url.beni:173`, `toWellFormed` on an
older engine. `Storage.beni:111`'s `key(i)` and `cloudflare/WebSocket.beni:90` may read `null`
(#1993).

### 3.6 Stack, memory, and the defect path

| Program | Result |
|---|---|
| `deep 10000000`, non-tail | `RangeError: Maximum call stack size exceeded`, exit 1 |
| the same in a `Task.bracket` under `Io.run` | the same, no `rel` line: `transparent-effects-proposal.md` §16.5's rule |
| `Debug.toString` of a chain 10⁶ deep | the same |
| `==`, `<`, and a `Dict` of the same chain | fine: an answer, no overflow |
| `Json.encode` of the same chain | `Err … DepthExceeded`, typed |
| `List.foldr` and `List.map` on 2×10⁶ elements | fine |
| a `String` doubled 40 times | `RangeError: Invalid string length` |
| `List.repeat 1 5000000000` | `RangeError: Invalid array length` |
| `String.padLeft "a" 1000000000 'x'` | V8 `FATAL ERROR: invalid table size`: no beni report at all |
| `Debug.todo` in a fiber, in a `bracket` release, in a body, after a `join` | exit 1 with the message: the defect path holds on Node |
| `Io.readFile "a\u{0}b"` | `Err InvalidPath`: typed |

All of it is [run]. So on Node, a stack overflow takes the same path as a `Debug.todo`.

### 3.7 Things #1988 settles by its own decisions

`Queue.takeN` with a fraction (#1973) and `Task.forEach` with a fraction (#1974) need a fractional
`Int`, and #1985 removes the source. `Int32.fromInt ni`, `Pcg.int 0 ni` and the `Queue` rows above
need an `Int` that is `NaN`. A `Float` cannot reach a count, an index or a `Dict` key except through
`round` and its kin, so #1988's "indexing, or a count" row and its "`Dict`/`Set` key" row have
nothing to do: `language.md` §13.4 says so.

## 4. What is already safe

- **List writes.** `set`, `insertAt`, `removeAt`, `swap` and `update` with `NaN`, `Infinity`, a
  negative or a too-large index change nothing, and `get` answers `Nothing`: `core/List.beni:464`'s
  `i >>> 0 !== i`. [run] In-place writes need no bounds check beyond it.
- **`String.left`, `right`, `slice`, `dropLeft`, `pad` and `List.take`, `drop`, `slice`** give a
  defined answer on `NaN`, `Infinity` and negatives. [run]
- **Unicode.** `String` works in code points, so `String.left "😀" 1` is whole, and `Url.percentEncode`
  of a lone surrogate gives `%EF%BF%BD`. `"\u{D800}"` is `invalid_escape`. [run]
- **`Url.percentDecode`** of bad text is `Nothing`. **`Url.fromString "http://["`** is `Nothing`. [run]
- **`Schema` and `Json`** refuse every invalid `Int` of §3.2, in both directions, and have a depth
  limit on encoding. *Corrected (§8):* they do not refuse a non-finite `Float` in a host value:
  `Schema.encode Schema.float inf` is `Ok Infinity`, which is right, because the value is a legal
  `Float`. Only JSON text refuses it (`PrintFailed`).
- **Rule 9's catches.** All 20 `Js.catchIf` sites in scope name what they expect. [read]
- **`Task.sleep`** chains timers past `2³¹−1`. [read]
- **The optimiser.** A second reader searched `src/js/` for a Dart-shaped fold and found none
  (`backend.md` §16.5 has the table). `Spec.Lat` has no numeric state. [read] Coverage: `Spec.zig`,
  `Lower.zig`, `Opt.zig` at the relevant sites; `Emit.zig`, `Minify.zig`, `Reach.zig`, `Rename.zig`
  and `MarkupTree.zig` by search only.
- **A defect in a page's handler, `update`, `view`, a render, a fiber under `Tea`.** Fixtures pin
  these: `browser/tea/DefectInUpdate`, `DefectInRender`, `DefectAfterRender`, `DefectInFiber`,
  `HttpDefect`, `browser/dom/DefectInHandler`.

## 5. Decisions for the owner

*Decided by the owner on 2026-11-05, every one as the review of #1999 recommended (`language.md`
§13.10).* D1: compiler-owned numeric evidence, not two bodies (`backend.md` §16.3). D2: option 1,
with exact predicates and the partial defence said plainly. D3: **document**, not the
recommendation below: `-0` is a valid `Int`. D4: refuse. D5: keep. D6: keep the one rule. The
recommendations below are the first draft's, kept as written.

**D1. `+ - *` under a `number` variable (#1996).** Options: (1) two bodies in a checked build, one
per instantiation, as `name$s` gives a second body; (2) a hidden evidence parameter in a checked
build; (3) a check at the instantiation boundary, which misses an intermediate overflow; (4) a
refusal, which is a language change. **Recommendation: 1.** It keeps "at the operation", keeps
`--release` unchanged and has a precedent in the compiler.

**D2. `Js.to` in a checked build (#1997).** Options: (1) test `Js.to` at each concrete scalar
instantiation, add an unchecked spelling for core's deliberate lies, and add a crashing default arm
to a `case` in a checked build; (2) the same without the arm; (3) no check, audit and fix.
**Recommendation: 1.** Audits miss sites, as rule 9's history shows, and the cost is accepted.

**D3. `-0` and `toFloat` (#1998).** Options: (1) `toFloat` emits `n + 0` in every build; (2) in
checked builds only; (3) document it. **Recommendation: 1.** It changes `--release` output by a few
bytes, which #1988's "done means" forbids, so it needs the owner's word. Option 2 breaks §13.1's
promise for a program that hit no check.

**D4. `Debug` under `--release-safe` (#1998).** Options: refuse it as `--release` does, or allow it.
**Recommendation: refuse.** The reasons in `backend.md` §9 hold for any build that ships.

**D5. A crash in one Node request (#1998).** Options: keep "a defect ends the process", or fail the
one request and go on. **Recommendation: keep it** and say so in `boundary.md` §9.10. Going on after
a defect is what rule 9 forbids. Cloudflare's per-request failure stands.

**D6. Arithmetic on `±Infinity`.** The table's row is settled as written: `Infinity + 1` crashes.
§13.4 extends it to `negate`, `abs` and every math function, so `atan inf`, which has a meaning,
crashes too. *Corrected (§8):* the first draft said the only ways to `-Infinity` were `(-1) / 0` and
a negated literal. That was wrong: `String.toFloat "-1e999"`, a decoded `-1e999` and `Float.log 0
10` make it too, and it was not an argument for the rule. **Recommendation: keep the one rule**, since it is what the
owner's table says. The consequence to confirm: a `Float` that overflows is one operation from a
crash. If that is not wanted, the alternative is to limit the crash to `NaN`, and let `±Infinity`
pass through arithmetic by IEEE 754.

## 6. What this report did not do

- **No `--release-safe` exists**, so nothing here ran under a check. Every crash in the contract is
  a specification, and the first implementation will find more.
- **Chrome was not run.** Page results are happy-dom's.
- **Miniflare was not run.** Every Cloudflare row is [read].
- **`platforms/browser-inline/`** and the zig lowerings were not audited for §3.5's class.
- **No browser host test** for `<input type="file" value>`, `history.go`, a null `document.body` in
  `crashScreen`.
- **`Int`-typed `Js.get` reads in a platform** were audited by one reader, in the files listed in
  #1993 and #1995. `Worker/Object.beni` was about a third read.

The probes live in the worktree's evidence copy, `~/worktree-evidence/beni-safe-mode-spec/` on
dagon: each batch of programs, the harness and the output.

## 7. Proofs the contract rests on

*Added 2026-11-05 from the independent review of #1999, which proved them; reproduced here so that
`language.md` §13.3, §13.5 and `backend.md` §16.2 can point at them. Its deterministic JavaScript
tests (seed `0x1999`: 6 000 000 `+ - *` results against BigInt range classification, 2 000 000
divisions and 199 999 near-boundary divisions, and a cross-product of non-finite operands) found no
counterexample. They corroborate the proofs; they do not replace them. Evidence: dagon,
`~/worktree-evidence/beni-review-1999/own/math.mjs` and `math.log`.*

### 7.1 The range test is exact

Let `M = 2⁵³ − 1` and let `a`, `b` be integers in `[−M, M]`. The exact result `z` of `a + b`, `a − b`
or `a × b` is an integer. If `|z| ≤ M`, `z` is a double, and the correctly rounded operation returns
`z`. If `z ≥ M + 1 = 2⁵³`, rounding is monotonic and `2⁵³` is a double, so `fl(z) ≥ 2⁵³`; the
negative side is symmetric. So `|fl(z)| ≤ M` exactly when `|z| ≤ M`. `-0` has magnitude zero and
passes. The proof assumes safe operands and standard Number arithmetic: a host value smuggled into an
`Int` breaks the premise, which is why `boundary.md` §4.3 (h) tests `Js.to`.

The predicate is `r >= -M && r <= M`, crashing on its negation. `r < -M || r > M` is wrong: both
comparisons are `false` for `NaN`, so it passes one. Repeated integer powers check each
multiplication; no sample of `Math.pow` proves it exact.

### 7.2 A non-finite operand of `+`, `−` or `×` gives a non-finite result

A `NaN` operand gives `NaN`. An infinite operand of `+` or `−` gives an infinity or `NaN`; of `×`, an
infinity or `NaN` (infinity times zero is `NaN`). So for these three a finite result proves finite
operands, and testing the result alone is the fast path. It is false for `/` (`1 / Infinity` is `0`)
and for `**` (`NaN ** 0` is `1`), whose operands are tested. The proof is about numbers, not
JavaScript's string `+` or coercion of other host values.

### 7.3 `Math.trunc(a / b)` is the integer quotient

For safe integers `a`, `b` with `b ≠ 0`; by symmetry take both positive. Rounding could change the
truncation only by rounding an exact quotient just below an integer `k` up to `k`. Write
`d = kb − a ≥ 1`. As `a ≤ M`, `dM ≥ a`, so `d / b ≥ k / 2⁵³`. The distance from `k` to the midpoint
below it is strictly less than `k / 2⁵³`, at powers of two included. So the quotient cannot round
across `k`. An exact integer quotient is a double. This does not justify `| 0`, nor dividing a value
that is not a true `Int`.

## 8. What the independent review of #1999 changed

*Added 2026-11-05.* An independent review replayed 234 build and run attempts over 156 of this
report's probes on master `1468390492`, with Node 24.19, Chrome 153 and Miniflare (compatibility date
2026-05-18), and wrote its own probes. Evidence: dagon, `~/worktree-evidence/beni-review-1999/`.
Most of §2's holes reproduced. What it found wrong or missing, and checked again before this
amendment where it said WRONG:

- **The first draft's comparison lowering** put the `NaN` test where a comparison answers `false`;
  `NaN !== 1` is `true`, so `≠` let a `NaN` through (H24). Fixed in `backend.md` §16.2: operands are
  tested first.
- **The order of work** made a public safe mode out of monomorphic checks first. Replaced by its
  order (`backend.md` §16.8); `--release-safe` is not public until the whole guarantee holds.
- **"`--release` output does not change"** contradicted the repairs the draft required. Replaced by a
  baseline of named repairs (`language.md` §13.7). Run: `Duration.seconds M` is
  `9007199254740991000`; `toPolar ( 1e200, 0 )` has an infinite radius.
- **Core's exception** for intermediate non-finite values had no implementable rule. Replaced by
  `language.md` §13.9. New cases run: `degrees 1e308` is `Infinity` though `(pi / 180) * 1e308` is
  `1.745e306` (#2021); `Clock.virtual M`, `adjust 2`, `now` is `9007199254740992` (#2022), so the
  draft's "`Clock.now` is sealed" was wrong for a virtual clock.
- **D1** needed a whole ABI, not "two bodies": two independent `number` variables have four
  instantiations, and function values, placeholders, recursion, `$s` forms, modules and `--library`
  exports all carry it. `backend.md` §16.3.
- **Schemas**: the draft said every encoder refuses a non-finite `Float`. Run: `Schema.encode
  Schema.float inf` is `Ok Infinity` and `Json.encodeValue inf` is `Ok`. That is right; the contract
  now limits the typed `Err` to JSON text and `finiteFloat`.
- **D2's predicates**: `typeof v === "number"` does not make an `Int32`, nor `typeof v === "string"`
  a `Char`. Exact predicates and the trusted remainder are in `boundary.md` §4.3 (h). The audit gained
  `platforms/cloudflare/Worker/Object.beni:1292–1297`, a `Bool` cast of optional flags.
- **Bounds** are by the read's meaning: `List.at` and `traverseAt` lower to an unchecked `index_get`
  (`src/js/Lower.zig:11467`), and a view's index is tested before its offset is added.
- **The crash path**: module load and a plain `Browser.program` fiber also fail in `browser-inline`;
  a file input's `value` throws `InvalidStateError` in a render in both DOMs (#2020); and a
  development Worker with a Durable Object does not start, `ReferenceError: Rt$$cloudflare_workers is
  not defined` (#2019). Host counter-evidence: workerd returned 204 for `Worker.text 204 ""`, accepted
  `alarmAt M`, `alarmIn` of the longest duration and `alarmAt -1`, and accepted a Japanese header
  value that Node's `Headers` refuses. Those predictions are withdrawn.
- **Equivalence**: "`--release` has no crash" became "no inserted checks"; "the same for every
  program" became the definition of `language.md` §13.1. Fixture categories, bounded hang assertions
  and the extra cases are in `backend.md` §16.7.
- **Pointers and overstatements**: `negate` and `abs` need an infinity test as well as a `NaN` test;
  `orderOf`, `orderTest` and `primitiveOperator` are in `src/js/Lower.zig`, `listCompare` in
  `src/js/derived_runtime.mjs`; `history.go` is modulo `2³²`, so `2³² + 1` is `1`; the "only ways to
  `-Infinity`" (§5, D6) was wrong; report 110's claims on Rust RFC 560, on performance and on V8
  boxing are corrected there, its missing summary table is no longer referred to, and its GHC
  revision is pinned.
- **Smaller replay differences**: H2's later failure was "undefined is not iterable" in the review's
  probe and the `$plain` message in this report's, so the message depends on the use; `String.padLeft
  "a" 1000000000 'x'` hit the review's 768 MiB heap cap and aborted, not with this report's exact
  `invalid table size` text; `Pcg.list` on `NaN` exhausted the heap rather than only waiting. The
  review notes that seven seconds without output does not prove non-termination.

What the review confirmed is not restated here: its table "Replayed PR and report 111 claims" has a
row per hole.

## 9. What the third review changed

*Added 2026-11-05.* A third independent review, of `93605f92c`, formed its findings before it read the
earlier two. Evidence: dagon, `~/worktree-evidence/beni-review3-1999/`. It ran today's behaviour and
a logging prototype; no check fired anywhere. It found the proofs of §7 sound and the owner's
decisions faithfully recorded. Its findings, all applied:

- **A value generic over `number` has nowhere to take evidence.** Run: `big = 9007199254740991 + 2`
  served `Int` and `Float` at once, in a `let` too, and `ops = { double = λx → x + x }` did the same.
  The owner chose to hold such values (`language.md` §13.11, #2077).
- **A crash under a program-made `Task.scheduler` leaves a page running.** Run, happy-dom. The owner
  decided a program's scheduler contains nothing (`language.md` §13.6, #1994).
- **The exact tests crash correct-looking code in the tree.** Prototype: 5 916 `Js.at` reads past the
  end and 3 365 `undefined` `Bool` reads, in `Rt.beni` and `Inline.beni`. The first draft of
  `language.md` §13.6 said such reads did not exist. The rules stand (rule 10), and a sweep is a step
  of the order of work (#2078).
- **The compiler has no type at the site** (#2079), **the evidence ABI depended on a body** (#2080),
  and **`Js.cast` must be `Js.to` to every pass** (#2079).
- **`language.md` §6's unspecified order is observable by a crash**, which is why the order is now
  part of the checked contract.
- Smaller: a `Float` written to a host, a `NaN` `For` key, `^^` by squaring, "unread" against
  reachability, the named repairs, `Duration.times` as a named row, and five wording fixes in
  `backend.md` §16.
