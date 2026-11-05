# Research 112: what `number` should do in a checked build

*Added to the repository 2026-11-05, for issue #1988, as the research behind the owner's decisions of
that day on values and numeric evidence. The text below the rule is the report as written, kept whole,
so its caveats stand: **D1 itself was not prototyped**, only the hold; the full gates, Chrome and
Miniflare were not run on the prototype; 476 of the scanned cases gave no data; prior-art items came
from a helper agent and were not re-read. The owner took decisions 1–5 as it recommends and did not
take variant S (decision 6). [`language.md`](../language.md) §13.10 and §13.11 and
[`backend.md`](../backend.md) §16.3 are what was decided, and this report is evidence, not contract.
Its line "§16.3's order puts them last" means last in the evidence; identity parameters follow.*

---

# What should `number` do in a checked build?

Research for PR #1999, head `93605f92c`. Tested on dagon, Node 24.19, with a ReleaseSafe base beni and a throwaway checker prototype.

Marks: **RUN** I ran it. **READ** I read the code or the document. **REASON** I deduced it and did not run it. Prior-art items were collected by a helper agent, which marked them VERIFIED or RECALLED; I did not re-read those sources.

## Recommendation

**The proposal is half right. Take its mechanism and drop its surface.**

1. **Keep `number` as a closed kind, and keep `+` as `Basics.add`.** Do not make `+` a public method.
2. **Keep D1's one discriminator per `number` variable, and deliver it through the checker's existing wanted and evidence path.** This is the true part of the proposal. D1 should not be a parallel mechanism. Every instantiation of a `number` variable raises one hidden wanted, and the ABI is read from the scheme.
3. **Close F1 with a hold.**
   - A value binding is never generalised over a `number` variable that carries that wanted.
   - In a `let`, existing rule 2 already does this.
   - At the top level it needs **one new rule**: default to `Int` in the value's own group.
   - An annotated `big : number` over a computing value is refused. The escape hatch is a parameter, `big ⊤ = …`.

**Why not "existing rules answer it":** the claim is true for `let` and false at the top level. A top-level value "once per evidence" has two possible outcomes, and both are wrong (RUN):

- `Int` and `Float` share `Basics.add`, so the memo cannot tell them apart. The `Float` read gets the `Int` run's value, and the F1 hole stays open.
- If the evidence is made distinct, the value re-runs at each flip of type, effects included, while `--release` runs it once. In the probe a `Ref` was bumped 6 times for what is one value in `--release`.

**What the hold costs in this tree:** across 3 904 programs and fixtures, **no program changes between accepted and refused**. No annotated value computes at `number`. All of the changes are goldens and one error message (details under *What each candidate refuses*).

**What would change this recommendation:**

- The owner wants `+` on user types (`Vec2`) as a feature. That is a separate language feature, and it should sit on top of this design.
- The owner requires computing values to stay generic over `number`. Then use a two-slot memo keyed by discriminator, opt-in by annotation, and only for pure right-hand sides. See decision 2.
- One wanted per arithmetic site proves too slow in the checker. Then put the discriminator in its own table. The semantics stay the same. I did not measure this.
- The full gate, Chrome or Miniflare find a refusal that the runs below did not reach.

## Comparison

| | Soundness against the owner's goal | Refuses today's programs | Breaks "once, where written" | `--release` bytes | Development cost | Size |
|---|---|---|---|---|---|---|
| **Recommended: hold + D1 on the evidence path** | Closes F1. Lemma below | None found in this tree. A value used at two types would be refused | No | Unchanged by the hold (RUN). Evidence stripped in `Lower` (REASON) | One parameter per `number` variable, one branch per `+ - *` | Medium |
| 1. Hold alone | Closes the value case only. Functions still need D1 | Same | No | Same | Same | Small: under 200 prototype lines |
| 2. Memo per evidence | Holds only with a two-slot memo keyed by discriminator | None | **Yes**: first use, or never | Bytes stay; behaviour differs (effects, order) | Thunks | Medium |
| 3. `+` as a public method | **Fails as stated**: same `Basics.add` collapses the memo (RUN) | `pub big = M + 2`, `pub ops = …`, `show (1 + 2)` (RUN), and `+` starts to work on `Int32` | **Yes** at top level | Needs the same erasure as D1 | About 2× per `+` in a generic loop (noisy) | Large |
| 4. Check at read | **Fails**: half the overflowed sums are safe and wrong (RUN) | None | No | Unchanged | Small | Small, but wrong |
| 5. Boxing or tagging | **Does not answer F1**: `big` needs one tag at two types (REASON) | None | No | Would need a representation that differs per build | High | Very large |
| 6. Separate operators | Perfect: no evidence at all | Very large: 133+ Float operator sites by a rough grep, all `number` generics | No | Changes source, not semantics | None | Large migration |
| S. New: no unannotated generic over `number` | Same as the recommended design, with fewer parameters | None found (RUN, scan only) | No | Same | Lower | Small add-on |

## The problem has two questions, and candidate 3 joins them

1. How does generic code learn the type? This concerns functions.
2. What is a value at `number`? This concerns values.

Each question can be answered without the other. The `let` hold does not need `+` to be a method. It needs a wanted on the root, or a syntactic test.

## Candidate 3 against the actual code

| Claim or need | Result | Mark |
|---|---|---|
| `x.add y` works on `Int` and `Float` | Yes, both resolve to `Basics.add` | RUN `A1` |
| A `let` value through a method is held | **True.** Second use is `type_mismatch` | RUN `C1`, `C3b`, `C7` |
| A top-level value with `where` runs once per evidence | True as a rule. **`Int` and `Float` are one evidence.** `seed ran` printed once; reads gave `6` and `6.0` | RUN `B1`, `B2`, `D4` |
| Distinct evidence fixes that | It re-runs at each flip: `blank ran` 6 times, `cells bumped: 6` for 3 rounds. `impure_polymorphic_value` does not catch this, because the position is covariant | RUN `E4` |
| Top-level evaluation time | After `main`'s body, not at load: `where value` printed after `main body` | RUN `B6` |
| An unread value | Never runs, so its crash never fires. §13.8 says `x = a + b`, unread, is evaluated | RUN `B7`, READ |
| `pub big = …` unannotated | `constrained_constant`, refused. `pub ops = …` too | RUN `B3`, `C5` |
| Literal receiver or literal argument | **`unknown_method`.** Dispatch needs defaulting first, and that is a new rule. `Elaborate.undetermined` also calls this case `internal` | RUN `A2`, `A4`, READ |
| `1 + x` | Not a problem. `wellKnownCall` gives both operands one variable, so the right side fixes it | READ `constrain/Expr.zig` |
| `number` rigid implies the method | **No.** `missing_where_constraint` on `x.add x` and on `big : number` | RUN `A5`, `B5` |
| `number` kind can go | **No.** A literal is not an `a`: `type_mismatch` | RUN `B4` |
| `Operator` writes `+` in place | `atCall` returns null when a call has evidence, so an evidence-bearing `+` stops being an operator | READ `src/Operator.zig` |
| `==` is a precedent | **Not for evidence.** The A.53 bridge exists to avoid it: "needs no evidence", "no evidence parameter" | READ `Resolve.bridge`, §9.3 |
| `let` function through dot-call is generalised | **No**, rule 3 keeps it monomorphic. The operator would need a `well_known` wanted, not a dot-call | RUN `C2`, READ |
| `+` keeps its refusal on `Int32` | **No.** `Int32` has `pub add`, `sub`, `mul`. `a.add a` works, `a + a` is refused by design (`language.md` §2.5). `a + b` as `a.add b` turns that on | RUN `F1`, READ |
| Other `add`s | `pub add : Model, Int → Model` and others exist in `ownership/`. Well-known names force a signature, so these need a rule | READ |
| ABI from the scheme (F5) | Inferred `where` lists depend on the body, so an edit moves the ABI | READ `Evidence.requirements` |

**Other readings of "make the plus a method of the variable":**

- **The type variable (most likely).** `number` itself owns `add`. This is the design I recommend, without a public method name.
- **The runtime value (`x.add(y)` in JavaScript).** A JavaScript number carries no type, so this is candidate 5 and fails the same way.
- **The binding `big`.** Each use re-expands the right-hand side. This is call-by-name, and it breaks "once".

## Questions

### Literals

`9007199254740991 + 2` has no receiver type. A method needs defaulting first. Under the recommended design it needs nothing at the site: the wanted stays open and is answered when the type is known, or `Int` if nothing settles it. That is `static-dispatch-spike.md` §8.6's rule. State it in §13.3, as F1's review asked.

### Does `number` go?

No (RUN `B4`). Keep it, and imply the wanted.

- `number, number2` are two variables, so two discriminators.
- `pow` is `number, number → number` in the code today, and #1985 makes it `Float`.
- Error messages stay as they are.
- Numeric requirements should not count towards the 64-constraint cap. A value with 300 `number` fields is data and needs none (`WideRecordEqInts`).

### Is the ABI a function of the scheme?

Under the recommended design, yes. Schemes publish the kind (`Schemes.zig:728`, READ), so an importer counts `number` quantifiers with no interface change. This answers F5.

### D1's list

`Evidence.requirements` is the one source for promotion, instantiation and interfaces (READ). So group calls, `let` promotion, `Convention`, sub-wanteds and `$s` already carry evidence. Answers for the rest:

- **Per-site class (F4).** A `+` site is an instantiation of `Basics.add`, so its answer is the class.
- **`G1`.** A `where` method generic over `number` compiles today (RUN). Sub-wanteds should carry it (REASON).
- **Numeric `foreign`.** There is none in the tree (review, READ).
- **`Js.to` at a `number` variable.** It raises no wanted, because its `a` has no kind. No such site exists: core has 18 `number` functions and platforms have none (RUN log). Refuse it or test it by the discriminator.

**A narrowing worth taking.** The spec says "arithmetic, a conversion or a comparison". Comparisons, `negate`, `abs`, `min`, `max`, `clamp` and integer patterns need no discriminator. A `NaN` or finite test is correct at `Int`, because a true `Int` passes it (REASON). Only `+ - *` differ, and so `sum` and `product`.

### `--release` and the cache

**Can the checker's output be the same while evidence differs by mode? Yes.**

- `--release` is not in the check cache key: "no emitted byte is cached" (`Key.zig`, READ).
- So the checker always computes the rows, and `Lower` drops the numeric ones. §16.3's order puts them last, so this is a prefix of the evidence.
- `Convention` and `Cycles` must not count them, or acceptance would depend on the mode.
- §16.1's "the mode is part of every cache key and every interface" can then go.

This is REASON. **I did not prototype D1.** The hold itself was tested (RUN): 634 `run/` programs, development and `--release`, 1 268 builds; 1 262 byte-identical. The other 6 are 3 programs whose `Debug$log` became `Debug$logAs`, because the type is now known. A real `--release` refuses `Debug`.

**Development cost (RUN, one run, loaded machine, treat as rough):**

| Emission shape | ns per element |
|---|---|
| bare `+` | 0.95 |
| Int test | 1.94 |
| Float test | 1.25 |
| D1 discriminator | 1.64 |
| evidence function per method | 3.70 |

The discriminator beat the monomorphic Int test here, which is noise-level and proves only that it is cheap. The per-method function was about twice D1.

### Does "once per evidence" hold up?

No (see the table). Under the hold, no `number` thunk exists, so F7 stays a text fix. Crash time and `Debug.log` order equal a monomorphic value's. Suspension is unaffected: the `sync` check already covers top-level values (READ, not probed).

### Candidate 4

Verified. `M + 2 - 2` is `9007199254740990`, a safe integer, and the true answer is `…991`. In a sweep of 572 000 sums whose intermediate overflowed, 285 571 read back safe, and **142 714 of those were wrong** (RUN `js/cand4.mjs`).

### What each candidate refuses

Prototype: `prototype-hold.patch`. It holds `let` values at the enclosing rank and binds top-level values to `Int`.

- **Differential scan (RUN):**
  - 3 904 cases across `tests/corpus`, `examples`, `bench`, `platforms`.
  - 2 450 accepted by both, 1 453 refused by both, **1 changed**: the text of an already-refused program.
  - 476 of the refused failed on an unknown module under my driver, so they gave no data there.
- **Held bindings:** 494 `let`, 46 top-level, 12 functions inside data; none is used at two types. Zero annotated values compute at `number`.
- **Corpus under the prototype (RUN):**
  - `emit/`, `browser/`, `build/`, `workers/`, `run/` pass.
  - `check/` differs in 3 golden texts: `Inference.iface`, `NumberVariableNamedByKind.iface`, `WideRecordEqFunction.diag`.
  - One `dump --stage=types` golden prints `counter : Int`.
- **These goldens overstate the real rule (REASON).** `pub h = List.singleton 2` is held by my syntactic test, but carries no numeric wanted, so the real rule keeps it general.

**Not covered:** the full gate (another job held the lock, so I ran `-Dcorpus=` per directory), Chrome, Miniflare.

Variant S binds unannotated *functions* too (`prototype-sml-variant.patch`). Scan result: **no program went from accepted to refused**, 8 fixtures changed message or code only. Confirmed active: `twice x = x + x` at both types is refused. The 476 gap applies to it as well, and I did not run the corpus on it.

### Why the hold is sound (REASON)

**Lemma.** If a value's `number` root carries no numeric wanted, its values at that root come only from `int` literals, passed through parametric code. A literal is within `M`, or refused. So it is true of `Int` and of `Float`, and one evaluation is correct for both.

I tried to break this with `y = f ⊤`, `Just (M + 2)`, `{ double = twice }`, `id (M + 2)`, a recursive `let`, and a `let` function capturing a held value. Each raises a wanted or is fixed by a use.

**The one exception is `Js.to`.** Its `a` has no kind, and that is trusted code (§13.2). Note `Debug.toString (3000000 * 3000000 * 3000000)` now crashes as `Int`. That is the intended rule, and the message should say to annotate `Float`.

## Prior art

The closest designs agree with the hold. Treat items marked by the helper as not independently re-read.

- **Roc:** `+` is the method `plus`, yet values are monomorphic: "default rather than generalize", to stop "silently recomputed" values. An annotation is the opt-in. Literals needed `from_numeral` and a default, which is the new rule candidate 3 denied.
- **Haskell:** the monomorphism restriction exists because a value "might be computed twice"; the History paper calls it "manifestly a wart" and records a program running "exponentially slower". Resolution there is module-wide, which is what beni must avoid: a use must not change a declaration's type.
- **Futhark, SML, ReScript:** a closed overload, resolved near the declaration, no generalisation of values (Futhark: "*unless* they are syntactically functions"). This is variant S.
- **Rust RFC 560:** checked in development and unchecked in release, the closest analogue. Generic code gets it by monomorphisation.
- **Regrets:** Lattner on Swift's overloads and literals; Roc's `4.7 / "cheese"` with open constraints; ReScript removing `+.` as awkward; Elm leaving the limit to the docs (#1832).
- No language found memoises per evidence, and none uses a run-time discriminator on an untagged double. The second point is a reason to keep clones open as a later step: they use the same per-site table, and `number` has two members, so they always terminate. Not measured.

## Decisions for the owner

1. **`+` stays `Basics.add`, closed over `number`.** Yes is my recommendation. `+` on user types is then a separate feature.
2. **A computing value generic over `number`:** refuse it (recommended), or allow it behind the annotation with a two-slot memo for pure right-hand sides. The second keeps programs and gives up "once, where written".
3. **Top-level default:** `Int` in the value's own group (recommended), not "first use". First use across a module makes a declaration's type depend on its uses, which defeats the interface firewall.
4. **`ops = { double = λx → x + x }`** is held like the rest. No use at two types exists in the tree. The hatch is `ops ⊤`.
5. **D1 on the evidence path, by one discriminator,** narrowed to `+ - *`, replacing §16.3's "body or callees" with the scheme.
6. **Variant S.** Unannotated functions are not generic over `number`. It removes hidden parameters from about 80% of the `number` functions the scan logged (~350 of 440, with duplicates). It adds a real departure from Elm, and buys cost only, not soundness. Rule 7 says it needs its own case; I do not recommend it now.

**Owed to the spec if these are taken:** `language.md` §6 and §13.3, `checker-v2.md` §8.4, `backend.md` §16.1 and §16.3, plus a hint for the refusal. The playground may want the opposite default, as GHCi did.

## Evidence

On dagon, `~/worktree-evidence/beni-number-evidence/`:

- Probes and logs: `probes*/`, `probes*.log`, `multi/` (never built; superseded by `probes3/`)
- Scans: `scan/`, `scan-sml/`, `scan.mjs`, `bytes.mjs`, `bytes.out`
- Corpus logs: `blackbox-hold-targeted*.log`
- Microbench: `js/`
- Patches: `prototype-hold.patch`, `prototype-sml-variant.patch`

The worktree is removed and pruned. Nothing was pushed, and no issue or PR was touched.
