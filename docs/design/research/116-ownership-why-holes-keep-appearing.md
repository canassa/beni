# 116 — Ownership: why the holes keep appearing, and whether v3 still holds

*Research report, 2026-11-12. The owner asked for it on pull request #2451: "Understand why these holes keep
appearing. See if the v3 idea still holds or it's another dead end, or we should go back to v2/v1." It is not
normative. It reads reports 110 to 115, the three fault folders of `bench/ownership-sweeps/`, the issues of
v1 and v2, `src/own/`, `src/own2/` and all of `src/own3/` at `4bd9066196`, and it ran the measurements of §8.
Every decision it names is the owner's.*

---

## 0. Executive summary

**The root cause is one shape, and all three checkers have it.** An in-place write is safe when two things hold:
the writer may write (a fact about one object), and nobody else observes the old value (a fact about *every* other
holder). Report 110 saw that v2 defaulted the first fact on the permissive side and proposed permissions, and v3
built them: a write needs `own`, a forgotten case gives `shared`, and no hole of the three blind rounds is a
write without permission. **The second fact was left as it was.** v1, v2 and v3 all compute "nobody else holds
it" by walking the program and listing what each value holds, and each of them has several states that mean
"I do not know what this holds" and are read as "this holds nothing": v3's `v_shared` (14 return sites), a bare
`fresh` or `shared` source in a contract, a function fact that was never recorded, a duplicate test scoped to the
wrong pair. Every one of the 30 or so hole classes since 2026-11-05 — v2's nine "one object, many names" holes,
its seven "empty read is fresh" holes, its 22 callback routes, and all 13 classes of v3's five rounds — is one
such state meeting a program that puts an object there (§2, §3). Report 110 §6.8 named exactly this residue
("three facts are still negative: a holder is dead, a value did not escape, a parameter is only borrowed") and
left it as "a claim that needs a check". The blind rounds then found their holes in precisely those three facts.

**The count is not converging, and the testing method is why it looks flat.** Generators written by the person
who wrote the fix find nothing (49 743, 9 792, 1 202 and 417 programs, 0 traps each time); a reader of the code
who did not write it finds two or three classes a day, and that rate has not moved from report 112 §6.5 to
report 115 (§4). Meanwhile each fix adds a mechanism that is itself a new reader of the same facts (`twice`,
`also`, `unknown`, `later`, a clock, groups of local functions: `src/own3/` grew 5 156 → 6 800 lines in five days
with the same 299 of 308 real writes). The speed held: 1 026 000 lines/s today on v2's modules, 7.4× v2 (§8.4). That is the signature report 110 §5.1 used to say v2 was not converging.

**Verdict: the v3 idea holds for what it claimed, and what it claimed was half the problem.** Locations on
types gave 9× v2's speed with no hole about names; permissions closed the writer's side; `flow` closed the
routes (no new route hole since report 112). It is not a dead end. But as built it is a 4 500-line walk with
no normative text, whose holder side was "kept from v2 unchanged" (report 110 §6.3), found unusable
(report 111 §3.3) and rewritten ad hoc. Going back is worse on every axis: v2 has the same shape at 38 000 lines
and 119 000 lines/s; v1 is the same shape at 23 000 lines in one file, 147 000 lines/s, with hangs and
exponential cases open, ten open soundness issues, and Lean proofs that model the thesis, not the code (§6).

**The recommended path: finish the principle, then stop fixing holes one at a time.** Apply to the holder side
what permissions did to the writer's side. One rule — *every fact a verdict depends on negatively is derived
from named, positive facts, and a missing one is the pessimistic one* — in five concrete forms (§5): a fresh
cell has a name; "no claim" and "no cell" are two values and the second carries its reason; a summary location
is `twice` until shown otherwise; one duplicate test in one place; no fact by a name. Each class found so far is
ruled out by one of the five (§5.2), at no cost to the 299 real writes and no structural cost to speed (§5.3).
First steps: (1) write the normative text of the kernel first (rule 1 of `CLAUDE.md`; v3 has none), stating
the five forms and the exhaustiveness rule; (2) land them as one slice with the compiler enforcing exhaustive
`switch`es and a run-time-safety assertion on every "holds nothing" value; (3) only then re-run the fault
folders, the nine generators and two fresh readers; (4) model the first-order kernel in Lean. What would change
this verdict: two fresh readers finding a class of hole on the kernel that none of the five forms rules out.

---

## 1. What was read, and what was run

- Reports 110 to 115, in order; the fault folders `blind-faults/`, `blind2-faults/`, `blind3-faults/`, the
  generators and `README.md` of `bench/ownership-sweeps/`.
- `docs/design/ownership-v2.md` §2, §2.14, §7, §8 and the amendments; `docs/design/ownership-checker.md` §0,
  §4, §6, §16; `docs/design/ownership-requirements.md` §3, §4.1, §7.
- All of `src/own3/` (6 800 lines); `src/own/Ownership.zig`'s use clock and summary; `src/own2/` by its design.
- Issues: `gh issue list --search "Ownership v2"`, v1's open soundness and cost issues, and the bodies of
  #2283, #2353, #2354, #2359, #2367, #2393, #2403, #2422, #2424.
- The branch's history: `git log origin/master..origin/ownership-v2-design-review`, with `--stat` on `src/own3/`.
- Runs: the three fault folders under v1, v2 and v3; four cross-module probes; v3 on `core/`; the speed of v1,
  v2 and v3 on the 32 real roots. §8 has each command and each number.

---

## 2. The holes, by mechanism

### 2.1 What a verdict needs

A write of list `L` at point `t` is safe when (a) the writer holds `L` as its own, and (b) no read after `t`
observes `L`'s old contents: no later use, no other operand, no holder a callee keeps, no cell, no JavaScript, no
view. (a) is a fact about one reference. (b) is a universal statement over every holder in the program.

A checker proves (a) by carrying a positive fact with the reference. v3 does this: a permission `own` per
location (`src/own3/Frame.zig`, `EKind`, `Contract.flag_w`), and a target that is `shared`, a capture or a
function parameter's answer is refused before anything else is asked (`demand`, `Frame.zig:1202–1214`).

A checker proves (b) by enumeration: it computes, for each value the walk meets, the set of cells it can hold
(v3: `leaves`, `reach`, `atoms`), records each consumer as a read (`uses`), and asks whether any read after
`t` reaches the target (`finishDemands`). This is sound only if the enumeration is complete. Every state of the
value model that under-approximates what a value holds, every consumer that records no read, and every
duplicate the model does not see, is a hole — and it is a hole on the accepting side, because an absent holder
means "nothing to refuse".

### 2.2 v3's thirteen classes, by what was absent

| Round | Class (count of programs) | What the model said | What was true | Side |
|---|---|---|---|---|
| 111 | `[ q, q ]`, element location `shared` (3) | `shared` = no claim, no cells | holds `q` | holder absent |
| 111 | an answer with no claim (8 fixtures) | `shared`, no source | holds the captured list | holder absent |
| 111 | where the answer goes (5) | no flag on the function parameter | the answer escaped into a task or cell | escape absent |
| 111 | keeps what the callee changes later (1) | no flag | the function kept its parameter | escape absent |
| 111 | two parts of one handed value (2) | compared signature locations | two caller locations, one list | duplicate unseen |
| 111 | a prepend copies (1) | row said fresh | `List.cons` can answer the base | first-order row |
| 111 | evidence at the reference (1) | no site | the call carried evidence | consumer absent |
| 111 | entry record of unknown shape (1) | state protocol | an ordinary record | row |
| 111 | captured writer in a fold's lambda (probe) | no demand on the supply | the capture writes | fact absent |
| 111 | a new name with no point (gen seed 144) | old name holds nothing | it holds the cells until the write | liveness |
| 112 | `comp` and a nested fold (129) | the lambda's capture had no fact | it runs `cb`, which writes | fact absent → "nothing happens" |
| 112 | closure handed back, run twice (24) | "writes no own parameter" | hands a capture to a writer | fact absent |
| 112 | function wider than its holder (2 faults, 38 traps) | no source below the variable | the answer's inner lists | holder absent |
| 112 | a contract's claim that two sources are two cells (5 forms, 230 traps) | `nonlinear = false` trusted | args aliased, answers one cell | duplicate unseen |
| 113 | a later local function (4, +9 forms) | `v_shared`: "nothing is known" | holds the list it reads | holder absent |
| 113 (review) | record alias constructor as a function | `none`: no function | a function that builds the record | holder absent |
| 113 (review) | `smear` of `P xs xs`, `?` | each cell once per location | one cell twice | duplicate unseen |
| 114 | `x ▷ e`, e computed (28) | read before write (by number) | write before read (by time) | consumer order |
| 114 | one list twice in a deep level (102) | duplicates checked between parts | within one part's two entries | duplicate unseen |
| 114 (review) | a `twice` part handed on; a helper hole; `dom` keeps holes (3) | two locations, two sets; read where written; markup holds nothing | one set; read at render | duplicate / consumer |
| 115 | a new list has no name (86) | `fresh` is a flag | two `fresh` are one array; a `fresh` escaped | holder and escape absent |
| 115 | `eq`/`compare` with no annotation (34) | "a comparison only reads", by name | it writes or keeps | fact by name |
| 115 | `sortWith`'s comparator (3) | supply `shared`, escapes nothing | the elements escape into a cell | escape absent |

Every row but two (the `List.cons` row and the entry row) is a *holder, escape, duplicate or consumer that the
model represented as absent*. None is a write without permission. None is a location name: the entry/deep
levels of report 111 §2.1 held through 16 131 recursive-level programs and three blind rounds. None after
report 112 is a new way for a function value to travel.

### 2.3 v2's classes, the same shape

Report 110 §3.5 sorted v2's 40 holes of 2026-11-05 to 11-10. Read against §2.1:

- *An empty read is fresh* (7): a reader that finds no entry answers "no object" — holder absent by
  representation. `ownership-v2.md` line 4949: "An empty set is the most permissive answer there is."
- *One object, many names* (9): the holder is there, under a name the reader did not try — holder absent by
  lookup.
- *Function values, a list of routes* (10, plus 12 more over v2's life): a route with no row — fact absent.
- *Cells and loans* (5): #2403, #2422: "exports no escape" — escape absent.
- *A contract does not cover its body* (3), *one entry counted once for many slots* (1), #2424: duplicate unseen.

v2's last weeks' issues read the same: #2283 "the read is empty and the write is taken as fresh"; #2353, #2354,
#2359 "reads fresh"; #2367 "does not treat 'the callback keeps its answer' as an escape"; #2393 "the escape
lands on nothing"; #2403 "exports no escape"; #2422 "records no parameter escape for a `⊤` arrival"; #2424
"the two entries come out apart".

### 2.4 v1, the same shape at a lower rate

v1's domain states the convention outright: "an empty set means *provably no cell*, never 'unknown'"
(`ownership-checker.md` §4.3). Its open soundness issues are the same rows: #2158 "an imported function value
is read as its call, seven routes accepted and stale" (fact absent); #1982 "a callback's need is not checked
when the callee supplies it a lambda" (fact absent); #2474 and #2349 "a list that a cell callback answered is
written in place while the cell holds it" (escape absent); #1956 (holder absent); #2455 "a local function's
read of a captured record's field is missed" (consumer absent); the `P xs xs` and `?` programs of report 113
§6.3 that v1 accepts and traps (duplicate unseen). Report 115 §4.4 found three more v1 traps in 417 programs,
and report 111's generator found #2474 in 20 000.

v1 is found at a lower rate because fewer people look at it (it is frozen) and because it is coarser where it
lacks a summary: a call with no summary reads every argument at the call and answers `⊤call`, never owned
(§6.1, amended 2026-10-16). That coarseness, not a principle, is why v1 refuses `twoOf`, `withG` and `both` of
report 115 §4.1 (§7).

### 2.5 So: one shape, three carriers

The domain changed twice (values and paths; slots; locations). The holes did not change shape, because the
shape is not in the domain. It is in the *way the holder side is computed*: by enumeration over a model with
"don't know" states that read as "nothing". Report 110 §5.3 said this of the alias-analysis family: "When a
rule forgets a case, the first family accepts a wrong write. The second refuses a right one. v2 needs both …
Today it derives the first from the second." v3 built the second family for permissions and kept the first
family for holders. The holes are where the first family always has them.

Is it the domain, the way it is built, or the way it is tested? All three, in this order of weight:

1. **Built.** The holder side has no stated invariant in any of the three designs that a reader can check
   line by line. v3 has no normative text at all (report 111 §7 item 3 and report 112 §8 item 4 asked for one;
   neither was written). Rule 1 of `CLAUDE.md` says why that matters.
2. **Tested.** The method that finds holes is a code reader who did not write the fix (§4). The method that is
   run after each fix is a generator written by the fixer, which has found nothing four times in a row.
3. **Domain.** The domain is right for speed and for names. It is neutral on holders: a type-indexed domain
   neither causes nor prevents a "holds nothing" default. The three-value split (`none` / `shared` / `unknown`)
   that report 113 introduced is the first domain-level fix of the holder side, and it was partial (§5.1).

---

## 3. The permissive states of v3, enumerated

Report 110 found v2's permissive default in one function (`Forest.kidAt`, line 46) and the design text that
blesses it. v3's are spread over the walk. Each of these is a place where a value or a fact that can hold cells
is represented by something that holds none, at `4bd9066196`:

| Site (`src/own3/Frame.zig`) | What it returns | What it means in a verdict |
|---|---|---|
| `evalInner` `else => return v_shared` (1659) | a value with no claim and no cell, for any instruction tag the walk does not name | an unhandled expression holds nothing of the frame |
| `project` on `.shared, .closure, .fnref` (912) | `v_shared` | a part of a function or of a no-claim value holds nothing |
| `project` on `.built` with no matching kid (923) | `v_shared` for a field | a field the construction did not name holds nothing |
| `capture` in a declaration's own frame (1469), a value read before it is bound (1507) | `v_shared`, `failed = true` | the contract of a failed walk is still published and read by importers (`Check.walkDecl`, 693–699); only an app module's build is stopped (`Enforce.zig:198–211`) |
| `.top` with no contract or a non-constant (1537, 1538) | `v_shared` | a top-level value with no contract holds nothing of the frame — right for a true top-level value, by the position rule |
| `ctorValue` with no row (1719, 1721, 1731, 1732) | `v_shared`, "the default function" | asks nothing; §2.5 of report 112 gives its answer every cell in sight, so this one is on the safe side |
| `memberValue` with no contract (2571), `capVal` unbound (2300) | `v_shared`, `failed = true` | as the failed walk above |
| `Src.fresh` (`Contract.zig:40`) | a flag with no identity | two `fresh` sources are two cells; a `fresh` cell cannot escape (report 115 §4.1: 86 programs) |
| `Src.shared` as a supply (`Check.wordedFn`, 628) | no sources | what the function is handed cannot escape (report 115 §4.3) |
| `methodCall` `reads` by name (2582) | read only | a method named `eq` or `compare` with no role is never checked (report 115 §4.2) |
| `evidenceTerm` `depth > 8 → return` (2622) | unchecked | evidence nested past eight is not judged |
| `markAtom` `depth > 8 → return` (1042) | no flag | a chain past eight does not reach its parameter (unreachable today: atom runs are flat) |
| `Root.linear = true` by default (104), `nonlinear = false` by default (`Contract.zig:115`) | parts apart until shown otherwise | the claim that two sources are two cells is the default, and the caller must find the exception (report 112 §6.3, report 114 §4.2) |

Against these, the pessimistic defaults that *were* built and that no round found a hole in: a write target
that is `shared`, a capture or an answer is refused (`demand`); a function in a `top` location may not write
(`flowCode`); a value that no rule follows is `unknown` and holds each cell in sight (`unknownOf`, since report
113); a lost answer holds each argument in sight (`lostAnswer`); a `flow` deeper than 16, a `resolve` deeper than
12, an `answerOfCode` deeper than 8 and a `partsOf` deeper than 8 fall to the pessimistic side. These are the
places where report 110's principle was applied, and they are clean.

The list also shows the depth constants `8, 12, 16, 24, 32, 200` of a prototype (`Seen`, `SrcState.seen`,
`flow`, `resolve`, `partsOf`, `solveCodes`). Nine of them fall to the safe side, two (`evidenceTerm`,
`markAtom`) to the permissive side, and none is a loud `ownership_limit` as R-7.4 requires. They are not
holes today; they are the prototype's habit.

---

## 4. Is the hole count converging

### 4.1 The numbers

| Round | Programs the fixer's tests ran with 0 trap before the round | Who found the holes | Classes found | Code added |
|---|---:|---|---:|---:|
| 111 (first run of the corpus) | — | the sanitiser corpus and two generators | 10 | 453 lines of fixes inside the 5 156 |
| 112 (rebuild to `flow`) | 49 743 (four sweeps, after the rebuild) | the author's hand search (121 programs), then two reviewers reading the code | 3 (one in five forms) | +920 net (1 505 added, 585 removed) |
| 113 | 9 792 (blind sweep: 0) | a tester reading `Frame.zig` | 1 (+2 by the fix's reviewer) | +441 net (595, 154) |
| 114 | 1 202 (blind sweep: 130 traps, after the hand probes found the two classes) | a tester reading `src/own3/`, 43 hand probes | 2 (+3 by the fix's reviewer) | +283 net (414, 131) |
| 115 | 417 | a tester reading `src/own3/`, about 40 hand probes | 3 | open |

(`git diff --shortstat` between the round's end commits, `src/own3/` only: `2cdaac2079`, `3372bd2841`,
`e7c695049b`, `418b816171`; 5 156 → 6 076 → 6 517 → 6 800 lines.)

The sweep columns say the same thing four times: a generator written by the author of the code under test, or
after the fix, finds no fault (report 112 §6.4: "It is blind for the checker and not for its author"). The
reader columns say the other thing four times: a person who reads the code and did not write it finds two or
three classes in a day, and the rate from report 112 §6.5 (one reviewer, one fault in a day) through 113 (one
tester, one class and two review faults), 114 (two plus three) and 115 (three) does not fall. Report 110 §3.7
said of v2: "Review of the last fix is the main detector." It is v3's main detector too.

### 4.2 What the rounds found, measured against the design

Three of 115's classes are ones v1 and v2 refuse, and report 110 §3.9 and 111 §3.9 had already recorded the
pattern ("v2 has each of these facts in a precise form … the prototype now has a coarse form of each"). Report
111 §6 said it plainly: "A fault of the prototype that v2 never had has no fixture." The rounds are rediscovering,
one class at a time, facts that v1 and v2 learned the same way over three weeks. That is what a checker built
without the holder-side principle does; the rate is the rate of readers, not a property of v3's code.

### 4.3 What each fix costs

`src/own3/` grew 5 156 → 6 800 lines. The concepts added since report 111: `Use` with three kinds and
composition, five sinks, `unknown`, `later` slots and `capVal`, groups of local functions solved to a fixed
point, a clock, `twice`, `also`, `linear`, `nonlinear`, `old_result`, `hit_all`, `Seen`, `SrcState`. Each is a
new reader of the atoms, and three of the five rounds' review findings were in the fix of the round before
(report 112 §6.5 on `argsApart`; report 114 §9 on `twice` and the markup clock). The precision did not move: 299
of 308 real writes at reports 111, 112, 113 and 114. This is the curve report 110 §5.1 measured on v2 ("a new
named concept entered on each work day … the amendments follow programs that failed. The argument did not
predict them") and used to say v2 was not converging. v3 is on the same curve, five days in.

**So: not converging, and not diverging either.** The found-per-reader-day rate is flat. It will stay flat until
the holder side has a principle, because the holes are in the holder side and no fix has touched its default.

---

## 5. Does the v3 idea hold

### 5.1 The idea, part by part

Report 110 §6 proposed three changes. Each can be judged on its own evidence after five rounds:

| Change | Claim | Evidence | Holds? |
|---|---|---|---|
| Locations: one name per object, entry and deep levels | no name can be missed; cost follows places, not paths | no hole about a level's name in 16 131 recursive-level programs and three blind rounds; 1 049 000 → 958 000 lines/s on v2's modules (v2: 119 000). One cost: a summary location holds many cells, so "one cell twice in it" needs a fact (`twice`), and report 114's hole 2 was that fact missing | **yes** |
| Facts are permissions; default is no claim | a forgotten case gives `shared`, which refuses | no round found a write accepted without permission; report 111 §3.5 and §3.9 found the claim is "half of the rule": `shared` refuses a write, it does not say what the location holds | **yes, for the writer's side; silent on the holder side** |
| A contract on a function-typed location; one `flow` rule | one rule covers every route | 173 of 175 faults of 111–112 explained; no route hole since 112; 115's two function holes are nameless answers (`fresh`) and a `shared` supply, not routes | **yes, for routes; the facts a route carries can still be nameless** |

The idea therefore holds exactly as far as it reaches, and it reaches the writer's side and the names. The
holder side it inherited: report 110 §6.3 says "The third test is today's liveness and holder check, unchanged",
report 111 §3.3 says "'Today's liveness, unchanged' was not usable", and `Frame.zig`'s 4 500 lines are what
replaced it, with no text. Report 110 §6.8 knew the residue: "What stays a claim that needs a check. Three facts
are still negative. A holder is dead. A value did not escape. A parameter is only borrowed." §2.2 above is the
list of those three claims failing.

### 5.2 A principle for the holder side, and what it rules out

The permission principle, stated for holders: **every fact a verdict depends on negatively is derived from
named, positive facts, and the default for a fact that no rule derives is the pessimistic one.** The negative
facts of a write are: no other holder, no escape, no duplicate, no later read, no write by a function it is
handed. The positive facts they must be derived from are: names of cells, recorded reads, recorded escapes,
recorded supplies. In five concrete forms for `src/own3/`:

1. **A fresh cell has a name.** `Src.fresh` becomes `fresh(k)`, `k` an allocation site of the callee (v1 does this:
   `fresh_k`, "numbered so that two result paths naming one `k` may be one cell", `ownership-checker.md` §16.2).
   A contract's result entry then holds a named cell, two entries with one `k` are one cell, and an escape of
   `fresh(k)` is an escape of a name. Rules out 115 §4.1 (all three shapes: `( x, x )`, `( g x, x )`, `h x; x`).
2. **"No claim" and "no cell" are two values, and the second carries its reason.** Today `v_shared` means both
   (report 113 §6.1 split off `unknown` for the first and left `v_shared` with 14 sites). `shared` stays for a
   value whose cells are provably outside the frame — a top-level value, JavaScript — with the reason in the
   value; everything else that the walk cannot follow is `unknown(V)` (holds each cell of `V`). `evalInner`'s
   `else`, `project`'s fall-throughs and a failed walk's contract go to `unknown`, and a `switch` on a value's
   tag has no `else`. A bare `Src.shared` in a *supply* is refused by construction: a supply is sources, or the
   whole argument (`wordedFn`: a `many` parameter with no `taken` is handed the elements of parameter 0, not
   `free`). Rules out 111's `[ q, q ]` and eight answers, 113's later function and alias constructor, 115 §4.3,
   and the whole first row of §3.
3. **A summary location is `twice` until shown otherwise; `linear` is derived, never assumed.** Today a made root
   is `linear = true` and a contract `nonlinear = false` by default, and `uniqueTail` removes a duplicate atom in
   silence at six sites. The positive fact is "each source once": `uniqueTail` is the one place that sees every
   duplicate, so it is the one place that sets `twice` on a summary entry, and `linear` is true only when no
   entry is `twice` and no two entries overlap. Rules out 114's hole 2 and its review fault 1, 113's `smear`
   faults, and 112's fault 3 by making `sourcesApart` a check of a derived fact instead of a repair of an
   assumed one.
4. **One clock, the walk's.** Done in report 114 §7.1 (`timeOf`). Keep it as the only order; a read with an
   instruction number is a compile error.
5. **No fact by a name.** `eq`/`compare` at `methodCall`, `Dict.focus`, `Send`, and the entry's field names are
   strings today (§3). A dispatch site knows its target: a method call is a call of that target's contract like
   any other, and the "a comparison only reads" rule becomes a *check* on every `eq`/`compare` that `==` can
   reach, annotated or not (the role comes from the dispatch tables, not from `pub` plus an annotation). The
   trusted rows get words (`sender`, words on `Dict.focus`), as report 111 §7 item 5 asked. Rules out 115 §4.2.

Together with the exhaustiveness rule (every `switch` over a value kind, a source kind or a use kind has no
`else`; the compiler then refuses a new kind until each reader has a case — `partsOf` already works this way,
report 112 §6.5), the five forms cover every row of §2.2 except the two rows that are rows (`List.cons`, the
entry record), and the ordering row that form 4 closed. The invariant to write down is one sentence per form,
and each is checkable by a reader against the code because each names the one place that produces the fact.

### 5.3 What it costs

**Precision.** Form 1 costs nothing: v1 names fresh cells and accepts 308 of 308. Form 2 costs where a value
truly holds nothing and cannot show it: the 14 `v_shared` sites are top-level values (right, kept), the default
function (safe already), and failures and unhandled tags (rare; today they are silent approximations in the
permissive direction, which R-7.4 forbids anyway). Form 3 costs where apartness is assumed today and is true:
`sourcesApart`'s step 1 already refuses when arguments alias, so the measured cost is report 112 §6.4's 40 %
acceptance of `aliased-arguments.mjs`'s safe twins against v2's 100 % — a cost v3 already pays. On the 299 real
writes no fresh cell reaches two places and no summary location is written through a call (report 110 §3.8:
no contract of 1 872 writes at a level), so the expected movement is zero; §8 says what to measure. Form 5
costs the two `Hosted.beni` comparisons report 112 §5.4 already refuses until `Js.get` has a row.

**Speed.** None of the five changes the shape of the work: names are integers on sources, `unknown` is a value
kind that exists, `twice` moves from six sites to one, the clock exists, and a role lookup replaces a string
compare. The pass stays proportional to instructions times locations (report 110 §6.7). §8.4 measures v3 at
`4bd9066196`, after the fixes of 113 and 114: 1 026 000 lines/s on v2's modules, 7.4× v2, the same ratio as
at report 112 within noise. Two rounds of fixes of the kind §5.2 generalises cost no speed.

**Code.** Less, not more: the five forms delete `shared`-with-sources (`REntry.shared`'s `copyAtoms`), the six
duplicate tests, the `isDictFocus`/`isSender`/`"eq"` strings, and the arguments by hand in `sourcesApart`'s
comment. The kernel that is left — values, atoms, reads, escapes, demands, contracts — is a few thousand lines,
which is the size report 110 §3.7 said a Lean model can follow.

### 5.4 Records, cells and fibers under the principle

- **Records.** A record is an object with a cell per field; a field is a location already (`Loc.LabelKind.field`),
  and liveness by field is `Read.mask`. `{ r | f = v }` is a write of `r` at `.f`, observed by any holder that
  reads `.f` later; form 2 makes a field no rule named `unknown`, form 3 makes a record built from one value at
  two fields `twice`. One pass, as report 110 §6.6 said; v3 reads a record update as a copy today, so this is
  the first stage after the kernel.
- **Cells.** A cell's contents are never `own` (right); a value read out of a cell is held by the cell for ever,
  so under form 2 it is `unknown` with the cell as its source, not `shared`, and an escape into a cell is an
  escape of a name (form 1). The loan of `Ref.modify` — the open v2 hole #2422 — is a contract fact: the callback
  is handed the contents `free` for one run and must answer them; that is `flow` with a `rewrites`-like flag,
  not a new mechanism.
- **Fibers.** A value a spawned closure captures is held by the fiber until it runs; under form 2 the closure's
  captures escape where it goes to a `top` location (`captureEscapes` does this already). A loan across a
  suspension point is the one fact that needs the effects checker's suspension bits; it is a row on the
  suspending primitives, by form 5 a word, not a name.
- **`foreign`.** A `foreign` with no word escapes its arguments and answers `unknown` (today `shared`: form 2).

None of these needs a sixth form. Each is a new kind of cell for the same five rules.

---

## 6. The alternatives: v2, v1

| | v1 (`src/own/`) | v2 (`src/own2/`) | v3 (`src/own3/`) |
|---|---|---|---|
| Lines, files | 26 126, 5 (23 025 in `Ownership.zig`) | 38 021, 170 | 6 800, 5 |
| Soundness issues | ~12 open (#1956, #1982, #2158, #2164, #2349, #2455, #2474, #1990, #1478, #1080; report 113's `P xs xs` and `?`; report 115 §4.4's three) | 86 since 10-25, 40 on the slot domain, 9 open at report 110; #2443 since | 13 classes in five rounds; 3 open (report 115) |
| The shape of the holes | §2.4: the same | §2.3: the same | §2.2: the same |
| Real list writes | 308 of 308 | 308 of 340 lines; 252 of v1's 308 at the same position | 299 of 308 |
| Speed, 32 roots, one core | 170 000 lines/s today; superlinear and hanging cases open (#2253 5 min, #2301 66 s, #2356 15 s and 1.7 GB, #2390) | 138 000 lines/s today; the size limit refuses ordinary code (report 110 §4.3) | 1 026 000 lines/s today on the same modules (§8.4) |
| Normative text | `ownership-checker.md`, 8 233 lines, amendments | `ownership-v2.md`, 9 991 lines, amendments | none |
| Proof | `proofs/ownership/`: the thesis's design, three `sorry`, names `src/own` nowhere | none | none; the first-order kernel fits the model (report 110 §6.8) |
| Records | one walk, 2.4 % of the cost | a second pass, #2443 | not built |

**Going back to v2** means a checker with the same hole shape at six times the code, at half the budget, whose
own soundness section says the theorem "does not say that an accepted program is safe", whose record design
walks every module twice, and whose growth curve report 110 measured and judged. Nothing in the five rounds
makes that judgement wrong; the rounds found the same shape in v3 at a tenth of the size, which is the one
thing that makes it fixable.

**Going back to v1** means keeping the production checker, which is a legitimate choice for *today's* builds
(it is the default and nothing here changes that). As the design to carry forward it has the same shape of
hole (§2.4), is found at a lower rate only because it is frozen and coarser, misses the budget by a factor of
two with open hangs, and its proofs do not reach its code. Its one real asset — `fresh_k` names and the
`⊤call` rule — is form 1 of §5.2, which v3 can take.

**v1 and v2 refuse what v3 accepts by principle in one case and by coarseness in the rest** (§7).

---

## 7. Why v1 and v2 refused what v3 accepted

| v3 hole | v1 | v2 | Principle or coarseness |
|---|---|---|---|
| 113: later local function holds a list | refused `later-use` | refused `later-use` | v1 §4.2: "a closure value records which `(local, path)` pairs its body reads … looked up when needed, so a local function may name a local bound after it" — **principle**, the same one report 113 §6 then built |
| 114: `x ▷ e` with `e` computed | refused all 28 | **accepted all 28** | v1's `point` is a walk counter (`Ownership.zig:11690`, `consume` increments it in walk order) — **principle**. v2 has the same hole as v3 had (report 114 §4.1), unreported before that round |
| 114: one list twice in a deep level | refused 94 of 102 (accepts the 8 through `?`) | refused all 102 | v2: the one-below and every-name rules (§2.1) — principle for v2's names; v1: coarse levels — **coarseness**, and the `?` form is v1's own hole |
| 115: a new list with no name | refused all 122 | refused all 122 | v1: `fresh_k` named, `⊤call` for a call without a summary — **principle**. v2: a fresh object of a call is one atom with the call's identity — **principle** |
| 115: `eq`/`compare` unannotated | refused all but `listeq.keep` (3 traps) | refused all 54 (`comparison`, `later`) | v2: the comparison check on every method — principle. v1: coarse read of the method call — **coarseness**, with its own hole on a keep |
| 115: `sortWith` comparator keeps | refused (traps on `keepUpd`) | refused (traps on `keepUpd`) | both: an element handed to a callback is held — principle for the direct form; all three trap on the `Ref.update` form, which is #2474's shape — **a shared hole** |

Two of six by principle in v1, three of six in v2, and in each case the principle is one of §5.2's forms. The
rest is coarseness that v1 and v2 pay for in precision and that v3 need not.

---

## 8. Measurements

*Filled from the runs of 2026-11-12 on a ReleaseSafe compiler of `4bd9066196` (sweeps) and a ReleaseFast one
(speed). Commands in Appendix A.*

### 8.1 The fault folders at the branch head

`run.mjs`, ReleaseSafe compiler of `4bd9066196`, `--jobs=8`.

| Folder | Programs | v3 at head |
|---|---:|---|
| `blind-faults/` (report 113) | 24 | 13 `live` REFUSED, 11 `dead` SAME |
| `blind2-faults/` (report 114) | 20 | 10 `live` REFUSED, 1 `dead` REFUSED (`deep-summary-twice.dead`, report 114 §8), 6 `dead` SAME, 3 `none` SAME |
| `blind3-faults/` (report 115) | 10 | **5 `live` TRAP**, 5 `dead` SAME |

So the branch head has the fixes of 113 and 114 and the three open classes of 115, as the reports say. No
`CRASH`, no `DIFF`.

### 8.2 Cross-module probes

No blind round built a two-module program (reports 114 §6, 115 §6), and a contract crosses a module as label
paths (`Contract.publish`, `Reader.layout`). Four probes, each a `Main.beni` and a `Helper.beni` (Appendix B),
take three of the fault shapes across the boundary: `keep2 ( q, q )` (report 112 §6.3's first-order form),
`early-argument` (report 113 §4.2) and `deep-summary-twice` (report 114 §4.2).

| Probe | v3 | v2 | v1 |
|---|---|---|---|
| `xmod-keep2.live` | REFUSED `later-use` 12:9 | REFUSED `alias` 12:9 | REFUSED 12:9 |
| `xmod-keep2.dead` | SAME | SAME | SAME |
| `xmod-early.live` | REFUSED `disjoint` 13:33 | REFUSED `disjoint` 13:33 | REFUSED 13:33 |
| `xmod-deep.live` | REFUSED `element` 10:17 | REFUSED `disjoint` 10:17 | REFUSED `Helper.beni` 14:17 |

The boundary held for these three shapes: the verdict at the call is the one-module verdict. Four programs are
not a sweep; §9 item 5 owes the generator.

### 8.3 Failed walks in core

`beni dump --stage=ownership --ownership=v3 --ownership-everywhere --platform=node core`: 1 895 lines, no
`limit` line and no refusal. So today no declaration of `core/` publishes the contract of a failed walk (§3,
row 4); the channel exists and nothing reaches it.

### 8.4 Speed

`bench/ownership-v2-review.mjs --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1`, ReleaseFast LLVM compiler of
`4bd9066196`, one machine, the best of three runs, the 32 real roots of report 110. The time of a checker is the
sum of its profile events; v3 walks `core/` and the platform again in each root (no block), so its like-for-like
figure is its time on the modules v2 walked.

| | lines | ms | lines per second | at report 112 |
|---|---:|---:|---:|---:|
| type check (for scale) | 169 826 | 237.9 | 714 000 | 601 000 |
| v1 | 169 826 | 999.8 | 170 000 | 147 000 |
| v2 | 169 826 | 1 232.3 | 138 000 | 121 000 |
| v3, on the modules v2 walked | 169 826 | 165.5 | **1 026 000** | 958 000 |
| v3, on all it walks | 556 396 | 433.5 | 1 284 000 | 1 178 000 |

The machine was faster today across the board (the type check too), so the ratio is the figure: v3 is 7.4×
v2 and 6.0× v1 on the same modules, against 7.9× and 6.5× at report 112. The fixes of reports 113 and 114
(+724 net lines) cost nothing measurable. v3's slowest real root is `platforms/browser` at 735 000 lines/s.

**Real writes, unchanged.** Of the 308 list writes v1 judges, v3 accepts 299 at the same position (fresh 34 of
36, call 44 of 51, param 185 of 185, entry 16 of 16, callback-param 20 of 20); the nine refusals are those of
report 111 §4.4, and the two refusals at a position v1 does not judge are `platforms/browser/Hosted.beni`'s
`compare` and `eq` (report 112 §5.4). v2 refuses 32 lines; v3 accepts 21 of them. Across four rounds of fixes
(5 156 → 6 800 lines) the precision on real code has not moved by one write in either direction.

---

## 9. What would settle what this report cannot

1. **Convergence under the principle.** Land §5.2 as one slice. Then two readers who did not write it read
   `src/own3/` for one day each and write probes. The claim is "no class that a form of §5.2 does not name".
   One such class refutes the verdict of §0; none in two reader-days is the first evidence that the holder side
   converges. The same test on today's code gives two to three classes a day (§4.1), so the experiment has a
   control.
2. **The cost of form 3 on real code.** The 299 writes and the 345 sanitiser fixtures before and after `twice`
   by default. Expected: no real write moves; some `deep.*.callee.dead` twins stay refused (report 114 §8).
3. **The failed-walk channel.** Whether a declaration of `core/` or a platform reaches `failed` under v3 today
   (§8 item 3). If one does, its published contract is a permissive default of §3 that no importer can see.
4. **The markup rule.** Report 113 §6.4 and 114 §9 leave one accepted class by decision: a local function builds
   markup that holds a list, the caller writes the list, the `dom` lowering reads it at render. It is a platform
   row, not a checker fact (form 5), and it costs 12 of 308 real writes to refuse by default. The owner decides
   it; the checker should carry it as a word on the platform's markup primitive either way.
5. **Cross-module contracts.** No blind round built a two-module program (reports 114 §6, 115 §6). §8 item 2
   runs four; a generator family over module boundaries is owed.

---

## Appendix A. Commands

All from the worktree root, `ZIG_GLOBAL_CACHE_DIR` set as `flake.nix` sets it.

1. **The compilers.** `zig build -Doptimize=ReleaseSafe` installs `zig-out/bin/beni` (sweeps).
   `zig build test-perf "-Dtest-filter=generated module of §7.6"` installs the ReleaseFast compiler at
   `zig-out/perf/bin/beni` (speed).
2. **The fault folders.** For each of `blind-faults`, `blind2-faults`, `blind3-faults` and each checker `vN`:
   `node bench/ownership-sweeps/run.mjs --beni=zig-out/bin/beni --checker=vN --tag=vN --jobs=8 --tmp=<disk> bench/ownership-sweeps/<folder>`.
3. **The cross-module probes.** The four programs of §8 item 2 are listed in the report; each is a directory
   with `Main.beni` and `Helper.beni` and a `LIST`, run with the same command.
4. **Failed walks in core.** `beni dump --stage=ownership --ownership=v3 --ownership-everywhere --platform=node core | grep '^limit'`.
5. **Speed.** `node bench/ownership-v2-review.mjs --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1`.

## Appendix B. The cross-module probes

Each probe is a directory with the two files below; `LIST` names the directories. They are not committed.

`xmod-keep2.live` (`.dead` prints `List.sum w` alone):

```text
-- Helper.beni
import List

pub keep2 : List Int × List Int → List Int × List Int
keep2 p = ( p.0, p.1 )

-- Main.beni
import Helper
import List
import Node exposing (Program)
import String

main : Program
main =
    q = [ 1, 2 ]
    r = Helper.keep2 ( q, q )
    w = List.set r.0 0 9
    Node.print (String.fromInt (List.sum w + List.sum r.1))
```

`xmod-early.live`:

```text
-- Helper.beni
import List

pub bumpThen : List Int, (Int → Int) → Int
bumpThen xs h =
    ys = List.set xs 0 9
    List.sum ys + h 1

-- Main.beni
import Helper
import List
import Node exposing (Program)
import String

main : Program
main =
    xs = [ 1, 2, 3 ]
    h n = g n
    g n = List.sum xs + n
    Node.print (String.fromInt (Helper.bumpThen xs h))
```

`xmod-deep.live`:

```text
-- Helper.beni
import List
import String

pub type Lst
    = Cons (List Int) Lst
    | Nil

pub f : Lst → String
f t =
    case t of
        Cons _ (Cons a (Cons b _)) →
            w = List.set a 0 9
            String.fromInt (List.sum w) ++ "/" ++ String.fromInt (List.sum b)

        _ →
            "-"

-- Main.beni
import Helper exposing (Lst, Cons, Nil)
import List
import Node exposing (Program)

main : Program
main =
    q = [ 1, 2 ]
    Node.print (Helper.f (Cons [ 0 ] (Cons q (Cons q Nil))))
```
