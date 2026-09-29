# Checker findings — the bug catalogue for the rewrite

Written 2026-09-24 against `master` = `7427828`. This is the input to the ground-up rewrite of the
type checker ([`docs/design/checker-v2.md`](../docs/design/checker-v2.md) is the architecture,
[`checker-rewrite.md`](checker-rewrite.md) the slice plan, queue row 78 the tracker).

**IDs are stable.** `CK-NN` is never renumbered or reused. A finding that turns out to be wrong
is marked *withdrawn* in place. A new finding takes the next free number at the end.

**The cut-over (R11, 2026-09-27).** v2 is the default checker. Every finding whose status below
reads *claimed* was **promoted** at R11: its fixtures moved from `tests/pending/` into
`tests/corpus/` (the paths below are updated), and its scenarios into `ordering_test.zig`
(`PERM`, `NEST-OVER`, `NEST-DEEP`), `abuse_wide_test.zig` (CK-79, CK-82) or `perf_test.zig`
(`NEST-UNDER`); see `checker-rewrite.md` R11 *As built*. Still red after R11: CK-49, 50, 52 to 56,
58 to 60 and 86 (R13), CK-88 (R12), CK-126 (the schema slices), CK-37's rest (R14).
**R12 (2026-09-27)** deleted v1: CK-88 and CK-95 (with its duplicate CK-127) are fixed and in
`test-perf` and `abuse_wide_test.zig`, and CK-132 (v1 only) is closed with v1.
**R13 (2026-09-27)** fixed the diagnostic-quality findings: CK-49, 50, 52 to 56, 58 to 60 and 86
are promoted, CK-94, CK-116 and CK-129 (CK-86's duplicate) are fixed with new fixtures, and CK-115
is not reproduced (a guard). Still red: CK-126 (the schema slices), CK-37's rest (R14).
**R15 (2026-09-27)**, the audit of the finished checker at `8b98464`, added CK-135 to CK-168 (*R15's
audit*, before the summary table): 22 behavioural findings with red fixtures or scenarios under
`tests/pending/`, and 12 structural ones with none. All are the R15-fix slices'.
**R15-fix-D (2026-09-28)** fixed CK-126 (the last pre-R15 red), CK-143, CK-145, CK-147 and CK-148;
each fixture is promoted, CK-143's two scenarios into `test-perf`.

## Sources

Five read-only reviews of `7427828`, all on 2026-09-24, merged here with duplicates folded
together. Each entry credits its sources:

| Tag | Review | Scope |
|---|---|---|
| **core** | inference core | `TypeStore`, `Types`, `Constrain`, the HM half of `Solve`, `Cycles`, the group loop |
| **disp** | static dispatch | resolution, evidence, derivation, `Dispatch`, `Lower`'s evidence reading |
| **orch** | orchestration | `Check.zig` driver and pipeline, exhaustiveness, publication, recovery, `Session` quiet |
| **adv** | adversarial black-box | about 240 probes, `--jobs` and cache differentials, declaration permutations |
| **roc** | Roc comparison | how `references/roc` (`f083385`) does static dispatch |
| **plan** | this catalogue | re-ran every probe on `7427828` and root-caused the adversarial findings |

The queue rows the reviews started from are 71–77. Each one is an entry here, cross-referenced:
row 71 → CK-38, row 73 → CK-25, row 74 → CK-24, row 75 → CK-36, row 76 → CK-37 (and the new
variant CK-03), row 77 → CK-29. Row 72 is done. Its mechanism is where CK-27 and CK-28 come from,
so its fixtures are regression controls for the rewrite (`checker-rewrite.md` R8).

## Conventions

- `B` is a Debug `beni` built from `7427828`.
- **build+run** means `B build --no-cache --platform=node --out=out <files> && node out/_main.mjs`.
- **check** means `B check --no-cache --platform=node <files>`. Pass `--platform=node` only when a
  module imports `Node`.
- `Main.beni` begins with `import Node exposing (Program)` whenever it has a `main`. The programs
  below leave that line out. Where `show` appears it is
  `show : Bool -> String` / `show b = if b then "True" else "False"`.
- **Observed** was re-run on `7427828` for this catalogue (**plan**) unless the entry says
  otherwise. Anything not reproduced is marked **not reproduced** or **suspected**.
- **Fixture** is the path under `tests/pending/` where slice R0 of `checker-rewrite.md` writes the
  red fixture. The fixture moves to the same path under `tests/corpus/` when its slice turns it
  green (`checker-rewrite.md` §2). A `.codes` golden is the pending-only form of a `.diag`
  (`checker-rewrite.md` §2.3).
- **Slice** names a slice of `checker-rewrite.md`.
- Every file:line is at `7427828`.
- **Invariant references, corrected 2026-09-24** (design review S18). Five structural entries cited
  `checker-v2.md` invariants by numbers that did not match its §2. Since round 2 they are corrected
  in place, and this table records what changed.

  | Entry | Was | Should be |
  |---|---|---|
  | CK-10 | I2 ("one pool per rank"), I4, I6 | I1 with §6.6 (rigid instances pooled), §11.2 (the fixpoint's own frame), §7.3 (no "ok" past the guard), I4 |
  | CK-14 | I10, I11 | I12 |
  | CK-18 | I3 ("flags merged by one function") | §4.1 (`Flags` merged only in `Unify`), no invariant ID |
  | CK-26 | I8 | I10 |
  | CK-35 | I5 | I14 |

## Severity scale

| Severity | Meaning |
|---|---|
| **unsound-runtime** | an ill-typed or wrongly compiled program builds with exit 0, then gives a wrong answer or throws |
| **compiler-crash-or-hang** | an internal error, `not_implemented` stop, panic or non-termination on input |
| **valid-program-rejected** | a program the spec accepts is refused |
| **nondeterminism** | output depends on something other than the program's content (ids, order of unrelated edits) |
| **performance** | super-linear time against `fast-compiler.md` §2's budget |
| **diagnostic-quality** | the right verdict with a wrong, misleading or missing message |
| **latent** | a structural defect with no misbehaving program shown yet |

## Root-cause classes

Every entry belongs to exactly one class. The class names the mechanism the rewrite has to make
impossible. `checker-v2.md` §1 maps each class to the invariant that closes it.

| Class | Name | What goes wrong |
|---|---|---|
| **K1** | Annotation generality unchecked | an annotated binding's rigid variables are never verified to still be generic after solving, so an annotation can be false while callers trust it |
| **K2** | Constraints and obligations outside the type graph | method-constraint `fn_var`s and obligation variables are not children of their carrier for level adjustment, copying, occurs and promotion, and obligations are decided at a rank that does not own them |
| **K3** | Graph walks that are not total | a walk runs on a graph the occurs check has not cleared, stops at a fixed depth, or reads one link of a record extension chain |
| **K4** | Evidence computed in many places | evidence slot counts, order, nesting and calling convention are derived independently by about a dozen checker functions and again by `Lower`, and agree only by convention |
| **K5** | Default answers | a hole, a give-up or a shortcut is answered "yes, structurally" instead of being checked or reported |
| **K6** | Own-method ordering | a module's own unannotated method is typed by *priority groups*, so whether a use checks depends on source order |
| **K7** | Capability computed several ways | "can `T` answer `m`?" is computed by up to five algorithms at up to eight points, separately from resolution itself |
| **K8** | Stale generation context | the solver reads context (`env.local_var`) that constraint generation has already moved past |
| **K9** | Intra-module pipeline | failure and suppression are keyed on diagnostic *text regions* and not state, settling is repeated, and there are several publication paths |
| **K10** | Interface representation gaps | a record field saturates or cannot say what the source declared |
| **K11** | Super-linear bookkeeping | whole-store memsets, re-settling per group, linear scans per resolution |
| **K12** | Id-order dependence | which diagnostic appears depends on interner id order |
| **K13** | Diagnostic selection | hint, headline or region chosen without the facts that decide it |
| **K14** | Outside the checker | parser, BIR lowering or JS lowering. Catalogued here because the rewrite's slices own the fix |
| **K15** | Specification drift | a normative document says something the code deliberately does not do. Added 2026-09-24 (design review N1) |

---

## A. Inference core

### CK-01 — An annotated `let` binding's rigid variable escapes, and callers trust the false annotation

- **Severity** unsound-runtime. **Area** core: annotated `let`. **Class** K1.
- **Sources** core #1; adv F1 (`sk5`, `sk4`, `sk7`).
- **Program** (`Escape`):

  ```elm
  f x =
      let
          g : a -> a
          g y =
              x
      in
      g "hello"

  main = Node.printLines [ String.toUpper (f 5) ]
  ```

  Variants:
  - `sk4`: the escape goes through `let pair = [ x, y ] in x`.
  - `sk7`: a row variable escapes. `g : { r | x : Int } -> { r | x : Int }; g y = o`.
- **Command** build+run. `dump --stage=types Main.beni` for the scheme.
- **Observed**
  - `dump` prints `f : a -> String`.
  - `build` exits 0, then `TypeError: s.toUpperCase is not a function`.
  - `sk7`: RECORD NOT CLOSED at the caller in `main`, not inside `coerce`.
  - Control: with `f : b -> String` annotated, it is `rigid_mismatch` (`sk6`), and top-level rigids
    are protected (`g4`).
- **Expected**
  - `rigid_mismatch` at `x` in `g`'s body. The annotation promises every `a`, and `x`'s type is
    fixed by the enclosing definition.
  - Spec: `checker.md` §6.1 ("a declaration with an annotation is checked against its annotation's
    rigid scheme") and §6.2 ("rigid vs non-identical → `rigid_mismatch`").
- **Root cause**
  - `Constrain.zig:1090-1105` (`declareBinding`) reads the annotation twice: a generalised flex
    scheme for every use, and a rigid copy for the body.
  - Nothing checks after solving that the rigids are still generic. A rigid merged into an outer
    flex just takes the outer rank (`Solve.zig:866-875`, `917-925`).
  - Elm checks this with `isGeneric` over the `let`'s rigids.
- **Fixture**
  - `check/bad/LetAnnotationRigidEscape.beni`. `.codes`: `rigid_mismatch` at `x` in `g`, contains
    "ANY type".
  - `check/bad/LetAnnotationRowEscape.beni` (the `sk7` form). `.codes`: `rigid_mismatch` at `o`.
- **Slice** R4.

### CK-02 — Generalisation ignores variables reachable only through a method constraint on an outer-rank receiver

- **Severity** unsound-runtime. **Area** core: generalisation × dispatch. **Class** K2.
- **Sources** core #2 (`CstrGen`).
- **Program**:

  ```elm
  type T = T Int
  pub combine : T, Int -> Int
  combine (T a) b = a + b

  f x =
      let
          g y = x.combine y
      in
      ( g 1, g "s" )

  main =
      let ( n, m ) = f (T 5)
      in Node.printLines [ String.fromInt n, String.fromInt m, String.fromInt (m * 2) ]
  ```
- **Command** build+run. `dump --stage=types`.
- **Observed**
  - `f : a -> ( b, c ) where a.combine : a, d -> e`. The `where` has free `d`, `e` that the type
    never links to.
  - Exit 0, and the program prints `6`, `5s`, `NaN`.
- **Expected**
  - `type_mismatch` at `"s"` in `g "s"`. `g`'s parameter type is reachable from the constraint on
    the outer-rank `x`, so HM(X) does not generalise it.
  - Spec: `static-dispatch-spike.md` §6.4 describes this case and claims rules (a) and (b) remove it.
    Rule (a) fires only for young-pool receivers, and rule (b)'s assert does not exist.
- **Root cause**
  - `adjustRankContent` (`Solve.zig:5009-5035`, the `.flex`/`.rigid` arm at `:5011`) never visits a
    constraint set's `fn_var`s.
  - `occurs` and `nthChild` (`:5060`, `:5095`) skip them too.
- **Fixture** `check/bad/OuterReceiverConstraintLevels.beni`. `.codes`: `type_mismatch` at `"s"`.
- **Slice** R6.

### CK-03 — A cyclic type reaches method resolution and the checker never stops

- **Severity** compiler-crash-or-hang. **Area** core × dispatch: occurs timing. **Class** K3.
- **Sources** core #3 (`CR4`, `CR2`). This is a new variant of queue row 76.
- **Program**:

  ```elm
  f : Int -> Int
  f z =
      let
          k y = ( y, y ) == y
      in
      z
  ```

  Also `case (\y -> ( y, y ) == y) of _ -> z`.
- **Command** build.
- **Observed**
  - `timeout 20` expires (exit 124).
  - Core measured about 150 MB/s of allocation. The stack is `targetFor → fillPart → derivedUse →
    targetFor …` at depth 4200 with branching factor 2.
- **Expected** `infinite_type` at `k`'s binding. Spec: `checker.md` §6.2 (occurs check).
- **Root cause**
  - The occurs check runs after `dischargeObligations` and `generalize` (`Solve.zig:730-739`,
    `4729-4735`).
  - Rule U0/U3 resolution runs inside `unify` (`Solve.zig:2231` `method`, `:3499` `targetFor`, `:404`
    `fillPart`, `:4116` `derivedUse`) on the not-yet-checked cyclic graph.
  - Row 76's `cycle_check_depth = 64` (`:714`, `:1993`) counts obligation generations. A single
    `targetFor` walk never reaches that check.
- **Fixture**
  - `check/bad/CyclicReceiverResolution.beni`, both forms. `.codes`: `infinite_type` ×2.
  - Pending perf scenario "a cyclic receiver in a `let` reports `infinite_type` within 5 s"
    (`tests/blackbox/pending_test.zig`).
  - *R0, as written:* both `.codes` positions are `*`. The spec does not pin which defence sees
    this cycle first: `checker-v2.md` §6.3's `binders_end` (at the parameter `y`) or §9.5's
    cycle-safe resolver walk (at the `==`). R6 blesses the real `.diag`. The scenario is
    `scenario/CK-03`: best of 3 runs, each bounded at 5 s, red signature `timeout`.
- **Slice** R6.
- **Added by R6a's review (2026-09-25):** `tests/corpus/check/bad/CyclicReceiverNoMethodLookup.beni` (a method used on a receiver already on a cycle is one `infinite_type` and no lookup: review F5), claimed.

### CK-04 — The occurs check covers only headers, so lambda and case binders can have infinite types

- **Severity** unsound-runtime. **Area** core: occurs. **Class** K3.
- **Sources** core #4 (`Omega`, `CR1`). The diagnostic half was also noted by adv.
- **Program**:

  ```elm
  g : Int -> Int
  g x =
      let
          _ = (\y -> y y) (\y -> y y)
      in
      x

  main = Node.printLines [ String.fromInt (g 2) ]
  ```

  And `f : Int -> Int; f z = (\y -> y y) "s"`.
- **Command** build+run.
- **Observed**
  - `Omega`: exit 0, then `RangeError: Maximum call stack size exceeded`.
  - `CR1`: TYPE MISMATCH whose expected type is printed as a 25-level unrolled arrow
    `((((… -> …) -> Int) -> Int) …`, not `infinite_type`.
- **Expected** `infinite_type` at the lambda parameter `y`. Spec: `checker.md` §6.2, and Elm's
  `Constrain`, where lambda and case binders are `CLet` headers and are occurs-checked.
- **Root cause**
  - `let_` and `finishTopLevel` occurs-check only `Header.v` (`Solve.zig:734-739`, `4730-4734`).
  - `Constrain.lambda` (`Constrain.zig:955`) and `caseExpr` (`:987`) register no binder for the
    check.
  - `unifyQuiet`'s depth guard (`Solve.zig:811`) returns `true` and is reachable from accepted files.
- **Fixture** `check/bad/InfiniteTypeAtBinder.beni` (`Omega`'s `g` and `CR1`'s `f`). `.codes`:
  `infinite_type` ×2.
  - *R0, as written:* `infinite_type` **×3**, one per self-applied lambda parameter. `Omega` has
    two lambdas, `(\y -> y y) (\y -> y y)`, and each is cyclic on its own, so §6.3's
    `binders_end` reports both before the application. `CR1` adds the third.
- **Slice** R4.

### CK-05 — An undetermined `tuple_index` or interpolation obligation is reported at an inner `let` whose variable belongs to an outer scope

- **Severity** valid-program-rejected. **Area** core: obligations. **Class** K2.
- **Sources** core #8 (`TupOrder`).
- **Program**:

  ```elm
  snd : ( Int, Int ) -> Int
  snd ( _, b ) = b

  f p =
      let
          a = p.0
      in
      a + snd p

  h n =
      let
          s = "n = ${n}"
      in
      s ++ String.fromInt (String.length n)

  main = Node.printLines [ String.fromInt (f ( 1, 2 )), h "x" ]
  ```
- **Command** build+run.
- **Observed**
  - AMBIGUOUS TUPLE at `p.0` and AMBIGUOUS INTERPOLATION at `${n}`, exit 1.
  - Control: `k p = p.0 + snd p` is accepted.
- **Expected**
  - Prints `3`, `n = x1`.
  - Spec: `checker.md` §6.4 says obligations are discharged "at generalisation time" for variables
    being generalised. These variables are not generalised at the inner `let`.
- **Root cause**
  - `let_` drains its rank's obligations before `generalize` (`Solve.zig:730`).
  - `dischargeTupleIndex` (`:2197`) and `dischargeInterpolatable` (`:2169`) report a still-flex
    variable immediately, whatever its rank.
- **Fixture** `run/ObligationEscapesInnerLet.beni` → `3`, `3`, `3`, `n = x1`. That is `f`, the `g`
  and `k` controls, and `h`.
- **Slice** R5.
- **Status** claimed by R5 (2026-09-25): both obligations ride on their variable and are decided when `snd p` and `String.length n` bind it, in the enclosing declaration (`checker-v2.md` §4.5 *As built by R5*). The fixture is GREEN under `--checker=v2` and in `CLAIMED`.

### CK-06 — `?` commits to `Result` before anything can say `Maybe`

- **Severity** valid-program-rejected. **Area** core: `?`. **Class** K2. It conforms to the old
  spec, so the fix changes the spec.
- **Sources** core #9 (`TryOrder`).
- **Program**:

  ```elm
  h m =
      let
          v = m?
      in
      Just (v + 1)

  main = Node.printLines [ Debug.toString (h (Just 1)) ]
  ```

  Also `k m = case m? of v -> Just (v + 1)`.
- **Command** build+run.
- **Observed** TYPE MISMATCH `Maybe a` vs `Result b c` at `Just`, plus one at each call. 4 errors,
  exit 1.
- **Expected**
  - Prints `Just 2`, `Just 3`.
  - Spec: `checker.md` §6.5 specified greedy order. **Owner decision D2 (2026-09-24,
    `checker-v2.md` §21):** `?` is a deferred obligation, decided when either side becomes
    concrete, defaulting to `Result` only at the generalisation boundary.
- **Root cause** `tryShape` (`Solve.zig:1802`) tries `Result` first and commits while both sides
  are flex.
- **Fixture** `run/TryDefersShape.beni` → `Just 2`, `Just 3`.
- **Slice** R5.
- **Status** claimed by R5 (2026-09-25): `?` is an obligation on its subject and its target's result, decided when either becomes concrete and defaulted to `Result` only at §8.1 step 3 of the boundary whose rank they still have (`checker-v2.md` §8.6 *As built by R5*). The fixture is GREEN under `--checker=v2` and in `CLAIMED`.

### CK-07 — Which record-field error is reported depends on interner id order

- **Severity** nondeterminism. **Area** core: record unification. **Class** K12.
- **Sources** core #10 (`det`).
- **Program**. `Main.beni` imports a module `Aaa` whose content does not matter:

  ```elm
  import Aaa

  f : { pp : { aa : Int }, qq : { bb : Int } } -> Int
  f r = 0

  g : { pp : { cc : Int }, qq : { dd : Int } }
  g = { pp = { cc = 1 }, qq = { dd = 2 } }

  main = f g + Aaa.z
  ```
- **Command** check.
- **Observed**
  - With `import Aaa`, MISSING FIELD names `bb`.
  - Rename the module to `Zed`, change nothing else, and it names `aa`.
  - `--jobs` did not change it in 24-module stress runs (core), so this is input-order dependence,
    not thread timing.
- **Expected**
  - The first failing field **in name-text order**, which is `aa` for both.
  - Spec: CLAUDE.md rule 5 intent, and `checker.md` §7 (field order is by text, never by symbol id).
- **Root cause** `unifyRecord` (`Solve.zig:1145`) unifies shared fields in symbol-id order, and the
  first failure wins `s.problem`.
- **Fixture** `check/bad/FieldErrorTextOrder/` (`Aaa.beni`, `Main.beni`). `.codes`: `missing_field`
  contains "`aa`".
  - *R0, as written:* `check/bad/FieldErrorTextOrder.beni`, a single file. `f`'s annotation writes
    `omega` before `alpha`, so `omega` is interned first. The message names `beta` (inside
    `omega`); it must name `apple` (inside `alpha`, first by text). The same file with the two
    fields swapped names `apple`. `.codes`: `missing_field 26:7 contains "`apple`" lacks "`beta`"`.
  - **Correction to Observed.** `--jobs` does change the two-module form. `Aaa.beni` only counts
    because it interns `qq`, `dd` and `bb` (its content matters, contrary to the program note
    above). At `--jobs=8`, 8 of 30 runs of `Aaa` + `Main` named `aa` and 22 named `bb`. At
    `--jobs=1` all runs named `bb`. So the two-module form is flaky as a red fixture. The thread
    dependence is its own finding, CK-71.
- **Slice** R4.

### CK-08 — A closed record whose field was read is refused for `==`

- **Severity** valid-program-rejected. **Area** core: records × dispatch. **Class** K3.
- **Sources** adv `rc1` (reported as a symptom of the alias constructor); root-caused by **plan**,
  which found it has nothing to do with the constructor.
- **Program**:

  ```elm
  main =
      let
          p = { x = "b", y = "a" }
      in
      Node.printLines [ p.y, if p == { x = "b", y = "a" } then "eq" else "ne" ]
  ```
- **Command** build+run.
- **Observed** NO METHODS HERE: "A record has no methods, so I cannot resolve `.eq` here:
  `{ x : String, y : String }` … Hint: write `(x.eq) a`", exit 1.
- **Expected**
  - Prints `a`, `eq`.
  - Spec: `static-dispatch-spike.md` §6.3, closed record row. The record is closed.
- **Root cause**
  - A fully concrete record is not generalised (`adjustRankContent`, `Solve.zig:5009-5035`), so
    every use of `p` shares one node.
  - The field access unifies it with `{ y : a | ext }` (`Constrain.zig:681`). `unifyRecord` keeps
    the open side's node (`Solve.zig:1226`), so `p`'s type becomes the chain `{ y | { x | {} } }`.
  - `methodOnRecord` (`:3119-3124`) and `targetFor` (`:3558-3563`) test only one extension link.
- **Fixture** `run/ClosedRecordAfterFieldAccess.beni` → `a`, `eq`.
- **Slice** R6 (normalised records and the total closedness test land in R4, but the program uses `==`,
  which v2 resolves from R6; moved 2026-09-24, S7).

### CK-09 — Locals of a mutually recursive group are resolved against the last member's locals

- **Severity** unsound-runtime. **Area** core: constraint generation for SCC groups. **Class** K8.
- **Sources** disp F7 (`p8`, `p7`).
- **Program**:

  ```elm
  f x y =
      if x == 0 then String.length (String.toUpper y) else g (x - 1)

  g a = f a 5

  main = Node.printLines [ String.fromInt (g 1) ]
  ```

  And, for the types dump:

  ```elm
  pub u x y = v 1 y x
  pub v p q r = u r q
  ```
- **Command** build+run. `dump --stage=types`.
- **Observed**
  - `f : number, number2 -> Int`. Exit 0, then `TypeError: s.toUpperCase is not a function`.
  - The second program prints `u : number, a -> b` and `v : number, a, number -> b`.
- **Expected**
  - `type_mismatch` at `5` in `g a = f a 5`, because `y` is a `String`.
  - `u : a, b -> c` and `v : number, b, a -> c`.
  - Spec: `checker.md` §6.1 (SCC groups).
- **Root cause**
  - `Check.zig:1624-1639` sets `env.local_var` per member during generation.
  - The `.instantiate` nodes this produces (`Constrain.zig:584-595`) are resolved at solve time
    through `Solve.schemeOf`'s `.local` arm (`Solve.zig:1459`), which reads the **last** member's
    slice.
  - A reference past the end of that slice returns `null`, which silently poisons the type.
  - Present since M2b (`c6763d1`).
- **Fixture**
  - `check/bad/MutualGroupLocals.beni`. `.codes`: `type_mismatch` at `5`.
  - `check/good/MutualGroupLocalTypes.beni` + `.iface` with the two correct schemes. The
    interface letters each scheme on its own, so `v` is written `number, a, b -> c`.
- **Slice** R5 for the dispatch-free `check/good` half; R6 for the `check/bad` half, whose program
  uses `==` (2026-09-24, S7). Lands with CK-31, which it masks.
- **Status** the `check/good` half was claimed by R4b. R5 (2026-09-25) adds and claims `check/good/MutualGroupFiveMembers.beni`, R5's reviewer case for I11: five members with their parameters in five orders and the obligation forms on them (`pair.0`, `${k}`) — GREEN under `--checker=v2`, and on v1 a `kind_mismatch` at `m2`'s `if flag`.

### CK-10 — Core bookkeeping gaps

- **Severity** latent. **Area** core. **Class** K3 (item 1 also touches K1; filed once, 2026-09-24,
  N1).
- **Sources** core #11.
- **Findings**. No program shown to misbehave, so these are **suspected**:
  1. `declareBinding`'s rigid `check_builder` variables are never added to the `let`'s pool, and
     there is no `adoptSince` (`Constrain.zig:1090-1105`). They keep a young rank forever. CK-01's
     fix needs them pooled.
  2. The deriver runs a `Solver` at `rank = generalized` (`Check.zig:1325-1336`), so every variable
     it creates is born quantified.
  3. `unifyQuiet`'s depth guard returns `true` (`Solve.zig:811`). Its comment says it is unreachable
     from an accepted file, and CK-04 makes it reachable.
- **Fixture** none. These are structural. `checker-v2.md` I1 with §6.6 (rigid instances
  pooled in their frame), §11.2 (the fixpoint's own frame), §7.3 (no "ok" past the guard) and I4.
- **Slice** R4.
- **Status** closed (checked by R15-fix-J, 2026-09-28): all three were v1's, deleted at R12, and
  v2 holds each by construction — an annotation's rigid reading is made at the frame's rank and
  pooled (`constrain/Decl.zig`'s `rigidReading`, §6.6); a derived-context run solves in a frame
  of its own (`Contexts.run`'s `pushFrame(.fixpoint)`); `Unify` past `max_depth` fails
  `too_deep`, never "ok" (§7.3).

---

## B. Pipeline, publication and recovery

### CK-11 — A warning turns off exhaustiveness and refutability checking for its declaration

- **Severity** unsound-runtime. **Area** pipeline: exhaustiveness gate. **Class** K9.
- **Sources** core #5 (`WarnExh`); orch F1 (`warnskip`, `warnskip2`).
- **Program**:

  ```elm
  type Colour = Red | Green | Blue

  pub pick a b c =
      if a == b then
          case c of
              Red -> "red"
              Green -> "green"
      else
          "no"

  main = Node.printLines [ pick 1 1 Blue ]
  ```

  Also `type Shape = Circle Int | Square Int` with `pub size a b (Circle r) = if a == b then r
  else 0` and `size 1 1 (Square 7)`.
- **Command** build+run.
- **Observed**
  - Only the `ambiguous_method_receiver` warning, exit 0.
  - The first program prints `green` for `Blue`. The second prints `7`, reading a `Square`'s payload
    as a `Circle`'s.
  - Without `pub` it is MISSING PATTERNS, exit 1.
- **Expected**
  - `missing_patterns` and `refutable_parameter_pattern`, plus the warning.
  - Spec: `checker.md` §6.6, "no type **errors** in that declaration".
- **Root cause** `ModuleCheck.exhaustive` (`Check.zig:1675-1686`) builds its skip set from every
  item in `mc.diagnostics`, whatever the severity.
- **Fixture** `check/bad/WarningKeepsExhaustiveness.beni` (both declarations). `.codes`:
  `ambiguous_method_receiver` ×2, `missing_patterns`, `refutable_parameter_pattern`.
- **Slice** R1 on v1 (a severity filter, one line). R4 makes it structural: a per-declaration failure
  bit.
- **Status** fixed on v1 by R1 (2026-09-24): `ModuleCheck.exhaustive` skips a declaration only for a
  diagnostic of severity `error`. The fixture is promoted to
  `tests/corpus/check/bad/WarningKeepsExhaustiveness.beni` with its blessed `.diag` (the four lines
  of the `.codes`). R4's structural bit is still owed.

### CK-12 — A module is silenced by an earlier phase's *warning*

- **Severity** latent. **Area** `Session` quiet computation. **Class** K9.
- **Sources** orch F1 (twin).
- **Finding**
  - `Session.zig:1302-1311` sets `quiet[m]` for any pending earlier-phase diagnostic, warnings
    included, and a quiet module reports no type errors at all.
  - No frontend phase emits a warning today, so there is no program. The frontend artifact cache
    already stores non-error rows (`Session.zig:1031`).
- **Expected** `quiet[m]` is set by errors only. Spec: `checker.md` §4.3 and `Options.quiet`'s
  comment.
- **Fixture** none possible black-box until a frontend warning exists. R1 adds an in-source unit
  test on the quiet computation (a documented rule-3 exception).
- **Slice** R1.
- **Status** fixed by R1 (2026-09-24): `Session.markQuiet` counts errors only, pinned by the in-source
  test "markQuiet: an earlier phase's ERROR quiets its module, a WARNING does not" (red with the
  severity filter removed).

### CK-13 — Schema members and schema constructors bypass the `<error>` and too-deep guards of publication

- **Severity** unsound-runtime: an ill-typed dependent is accepted. `build` refuses schemas today,
  so there is no runtime path yet. **Area** publication. **Class** K9.
- **Sources** orch F2 (`deepschema`, control `deepctl`).
- **Program**
  - `Deep.beni` holds a 600-deep inferred tuple `deep`, `conv = mk deep`, and
    `pub schema S = Int via conv`, with no `pub` value exposing `deep`.
  - `Use.beni` has `bad : Deep.S.Type` equal to the same tuple with `42`, not a `String`, at the
    bottom.
- **Command** `B check --no-cache Deep.beni Use.beni`.
- **Observed**
  - Exit 0 with nothing printed. `dump --stage=interface` shows the member type truncated.
  - Control (the same depth through a `pub` value): NESTING TOO DEEP, exit 1.
- **Expected**
  - `nesting_too_deep` in `Deep`, and the member published as `<error>`.
  - Spec: `checker.md` §5, "a guard that poisons must report first", and §7.
- **Root cause**
  - `fillInterface` writes `schema_members` (`Check.zig:1778-1793`, add at `1790`) and
    `schema_ctors` (`1795-1813`, add at `1810`) with a bare `writer.add`.
  - The value path (`1746-1772`) checks `hasError` and `too_deep`.
  - There are four publication paths, and only two apply the guard.
- **Fixture** `check/bad/SchemaMemberTooDeep/`. `.codes`: `nesting_too_deep` in `Deep.beni`.
  - *R0, as written:* `nesting_too_deep Deep.beni:*`. The value path reports at the declaration's
    annotation or body (`Check.noteDeepDecl`). Which region stands for a schema member is R4's to
    decide.
- **Slice** R4 (one publication routine).

### CK-14 — Recovery is region-based, and `quiet` is enforced by hand in 37 places

- **Severity** latent. **Area** recovery. **Class** K9.
- **Sources** orch F8.
- **Findings**
  - "Did this declaration fail?" is answered by whether a diagnostic's region falls inside its
    instruction range (`Check.zig:1675-1686`, O(diagnostics × decls)). It cannot see a failure
    reported at a site inside another member of the same SCC.
  - `quiet` is 37 hand-written `if (r.quiet) return;` guards in `Diagnostics.zig`.
  - Three paths append directly: schema errors (`Check.zig:1203-1212`), `verifyReads` (`:927`) and
    `internalAlways`.
- **Fixture** none. `checker-v2.md` I12 (§15.1–§15.2) makes it structural.
- **Slice** R4.
- **Status** closed (R15-fix-J, 2026-09-28). v2 answers "did it fail" with failure bits
  (`Report.failed`), and its last hand-written `quiet` guards (in the shared texts, CK-151), its
  `internalAlways` and its second append path (`Incremental.verifyReads`, CK-146 (4)) are gone:
  the list grows only through `Report.emit`/`Report.appendTo`.

### CK-15 — Pipeline rot in `ModuleCheck.run` and `Driver.install`

- **Severity** latent. **Area** orchestration. **Class** K9.
- **Sources** orch F7.
- **Findings**
  - Steps are numbered 1, 2, 3, 5, 7, 6, 8 (`Check.zig:1130-1388`).
  - `Driver.install`'s header promises four things and does at least six.
  - Dead code: `Types.settleSchemaEndpoint`, `Types.includeSchemaEndpoint`,
    `Solve.deriveDeclaredTypes` (`Solve.zig:4386`).
  - `schema_plan_ok` is decided before `Cycles.run`, the last error-producing phase (`Check.zig`
    ~1349 vs `1379`).
  - "Were there priority groups?" is encoded as `pending.capacity != 0` (`1298`, `1312`).
- **Fixture** none. `checker-v2.md` §5's named phases.
- **Slice** R4 and R9.
- **Status, after R9 (2026-09-27).** Closed for v2, which from R9 checks every module under
  `--checker=v2`: `check2/Module.zig` runs P1–P9 once each, in order, named; the schema plan is
  built in P9 after `Cycles.run`, gated on no error (`checker-v2.md` §16); P5, P6, P8 and P9 have
  profile events of their own (R8c); and `Incremental.install`'s header now lists the five steps
  its body does, numbered in order. v1's rot (`ModuleCheck.run`'s step numbers, its
  `schema_plan_ok`, the dead `Types` settles, `pending.capacity`) stays with frozen v1 and goes with
  it at R12.

---

## C. Equality, capabilities and derivation

### CK-16 — `Basics.eq`'s structural walk treats a variable inside a structure as satisfied

- **Severity** unsound-runtime. **Area** the `equatable` marker. **Class** K5.
- **Sources** core #7a (`EqLeak`).
- **Program**:

  ```elm
  same : a, a -> Bool
  same x y = Basics.eq [ x ] [ y ]

  same2 x y = Basics.eq ( x, 1 ) ( y, 1 )

  main =
      Node.printLines
          [ if same (\n -> n + 1) (\n -> n + 1) then "equal" else "different"
          , if same2 (\n -> n + 1) (\n -> n + 1) then "equal" else "different"
          ]
  ```
- **Command** build+run.
- **Observed**
  - Exit 0. Prints `different` twice: functions compared at run time.
  - `same2` is inferred as `a, a -> Bool` with no `equatable`.
  - Control: `Basics.eq x y` directly is `not_equatable`.
- **Expected**
  - `not_equatable` in `same`'s body, because the rigid `a` has no `equatable` flag and users cannot
    declare one.
  - `same2` inferred `∀(a: equatable)`, and `not_equatable` at its call with lambdas.
  - Spec: `checker.md` §6.3 and §6.4, the rigid-var and flex-var rows.
- **Root cause** `walkDerivableMode` (`Solve.zig:2088-2167`, `.flex`/`.rigid` at `:2118`) treats
  both as satisfied. It neither requires the rigid's flag nor sets it on the flex.
- **Fixture** `check/bad/BasicsEqThroughStructure.beni`. `.codes`: `not_equatable` in `same`,
  `not_equatable` at `same2`'s call.
  - *R0 follow-up (review S4):* the lines are `contains "ANY type"` and `contains "function"`, the
    words of the direct controls' messages.
- **Slice** R5.
- **Status** claimed by R5 (2026-09-25): `check2/Instances.zig`'s marker walk requires a rigid's flag and propagates it, with an obligation at the same region, to a flex (`checker-v2.md` §11.4 *As built by R5*). The fixture is GREEN under `--checker=v2` and in `CLAIMED`.
- **Status, after R5's review (2026-09-25).** One question is one message: the walk flags only after a `yes`, every row it makes carries the question's `origin`, and an origin reports once (`checker-v2.md` §11.4 *As built by R5, after its review*). The claim now also rests on `tests/corpus/check/bad/EqOneQuestionMerged`, `…/EqOneQuestionPerSite` and `…/EqRecordFieldFunctionAtComparison` (claimed), and on the symbol-order twins `tests/corpus/check/bad/EqOneQuestionRecord` and `…NamesFirst` and `…/EqFunctionFieldThroughCall`, which are green on v1 and v2 and listed in `v2-green.txt`. CK-17's class holds under v2 too: `check/bad/WideRecordEqFunction` is in `v2-green.txt`.

### CK-17 — The equatable walk gives up at 256 entries, and giving up means "equatable"

- **Severity** unsound-runtime. **Area** the `equatable` marker. **Class** K5.
- **Sources** core #7b (`WideEq`, `WideEq2`, control `NarrowEq`).
- **Program** `r = { f1 = \n -> n + 1, f2 = 1, …, f300 = 1 }`, then `Basics.eq r r`.
- **Command** build+run.
- **Observed**
  - Exit 0. Prints `eq`.
  - With 2 fields: NOT EQUATABLE, exit 1.
- **Expected** `not_equatable`. Spec: `checker.md` §5 (guards report) and §6.4.
- **Root cause**
  - Fixed 256-entry stack (`Solve.zig:2091`). A full stack returns `.unknown` (`:2139`, `2155`,
    `2159`, `2161`).
  - `dischargeEquatable` accepts `.unknown` (`:2043`).
- **Fixture** `check/bad/WideRecordEqFunction.beni`, generated with 300 fields. `.codes`:
  `not_equatable`.
- **Slice** R1 on v1 (make the walk growable, so width never yields `.unknown`; turning `.unknown` into
  a refusal would reject a valid 300-field all-`Int` record, S9). R5 makes it structural.
- **Status** fixed on v1 by R1 (2026-09-24): `walkDerivableMode`'s worklist is growable (256 entries
  inline, then the heap), its 65 536-step budget is gone, and `EquatableResult.unknown` no longer exists. The mark makes one
  walk linear, but a nested walk at a boundary type takes a fresh mark and overwrites the outer
  one, so a shared sub-DAG can be walked again (CK-80, which is older than R1). The fixture is promoted to
  `tests/corpus/check/bad/WideRecordEqFunction.beni`. The same walk gated DERIVED `==`, where
  `.unknown` was a refusal: a 300-field all-`Int` `r == r` was NOT EQUATABLE on 7427828 and now
  runs (`tests/corpus/run/WideRecordDerivedEq.beni`). `abuse_test.zig` holds the reviewer's two
  100 000-field records (all `Int`: checks; a function at field 99 999: `not_equatable`). A DERIVED
  record `==`/`compare` is capped at 4 096 fields, because wider ones threw at run time — CK-79.

### CK-18 — `dischargeEquatable`'s flex arm would drop a variable's method constraints

- **Severity** latent (dead code). **Area** equatable. **Class** K2.
- **Sources** core #7, disp F11.
- **Findings**
  - `Solve.zig:2034` rebuilds `Flags` without `.constraints`.
  - It is unreachable because no generator emits `.equatable`. `Constrain.Node.Tag.equatable` is
    dead too.
- **Fixture** none. `checker-v2.md` §4.1/§7.1 (`Flags` are merged only in `Unify`, `wants` and `obls` included) and deletion.
- **Slice** R5.
- **Status** closed structurally by R5 (2026-09-25) for v2: v2 has no `.equatable` constraint node, and every `Flags` it writes is the old one copied with one field changed (`Unify.flex`, the marker walk, `Solve.attach`), never rebuilt from parts (`checker-v2.md` §4.1 *Decided by R5*, §11.4 *As built by R5*). v1's dead arm stays (v1 is frozen) and goes with v1 at R12.

### CK-19 — An `equatable` flag answers `==` structurally, ignoring the type's `eq`, depending on statement order

- **Severity** unsound-runtime. **Area** dispatch × equatable. **Class** K7.
- **Sources** disp F1 (`p1`, `p2`).
- **Program**. `Ci` has `pub eq` comparing case-insensitively:

  ```elm
  type Ci = Ci String
  pub eq : Ci, Ci -> Bool
  eq left right = case left of Ci a -> case right of Ci b -> String.toLower a == String.toLower b

  viaMarker x y =
      let
          _ = Basics.eq x x
      in
      x == y

  main = Node.printLines [ show (Ci "a" == Ci "A"), show (viaMarker (Ci "a") (Ci "A")) ]
  ```
- **Command** build+run.
- **Observed**
  - `True`, `False`.
  - Swap the two `let` statements (`r = x == y` first) and it prints `True`.
- **Expected**
  - `True`, `True` in both orders.
  - Spec: `static-dispatch-spike.md` §3.4 (row 72 correction): the `equatable` marker is not an `eq`
    method.
- **Root cause** `builtinRigidTarget` (`Solve.zig:2811-2828`, equatable arm `:2818-2826`) is
  consulted from `dischargeMethod` (`:2685`), `resolveMethod` (`:2728`, `:2751`) and `targetFor`
  (`:3526`, `:3552`).
- **Fixture** `run/EquatableMarkerIsNotEq.beni`, both statement orders → `True` ×3.
- **Slice** R1 on v1 (delete the arm). R8 makes it structural: one resolution path.
- **Status** fixed on v1 by R1 (2026-09-24): `builtinRigidTarget` answers only the `number` kind.
  No other corpus golden moved, `dispatch/` included, and `check/bad/BasicsEqStillStructural` still
  passes. The fixture is promoted to `tests/corpus/run/EquatableMarkerIsNotEq.beni`. R8's single
  resolution path is still owed.

### CK-20 — A rigid variable inside a derived shape is answered with structural equality

- **Severity** unsound-runtime. **Area** dispatch: Rule U2 in parts. **Class** K5.
- **Sources** disp F5 (`p10`; control `p12`).
- **Program**:

  ```elm
  pairEq : a, a -> Bool
  pairEq x y = ( x, 1 ) == ( y, 1 )

  recEq : a, a -> Bool
  recEq x y = { v = x } == { v = y }
  ```

  Called with the `Ci` type from CK-19, and with lambdas.
- **Command** build+run. `dump --stage=dispatch`.
- **Observed**
  - Exit 0, `False False False`. It compares functions, and ignores `Ci.eq`.
  - The dump has `part 0 err` and no diagnostic.
- **Expected**
  - `missing_where_constraint` at each `==`, naming `a.eq`.
  - Spec: `static-dispatch-spike.md` §6.2 Rule U2 and §6.3, rigid without the name.
- **Root cause**
  - `targetFor`'s `.rigid` arm (`Solve.zig:3543-3554`) returns `.err` with no diagnostic.
  - `Lower.partValue` (`Lower.zig:2898`, `:2909-2910`) answers `.err` with `Basics.eq`.
- **Fixture** `check/bad/RigidInsideDerivedShape.beni`. `.codes`: `missing_where_constraint` ×2 at
  the operators.
- **Slice** R6. The `Lower` half (no structural answer to a hole) is R2.
- **Added by R6a's review (2026-09-25):** `tests/corpus/check/bad/RigidInDerivedShapeOncePerSite.beni` (one `missing_where_constraint` per rigid and method at a use: review F4), claimed.

### CK-21 — A `where` clause's method type is never checked when the receiver is a `number` literal

- **Severity** unsound-runtime. **Area** dispatch: the `number` bridge. **Class** K5.
- **Sources** adv F3 (`u1`, `u2`, `u4`, `w9`); root-caused by **plan**.
- **Program**:

  ```elm
  f : a, a -> String
      where a.eq : a, a -> String
  f x y = String.toUpper (x.eq y)

  main = Node.printLines [ f 1 2 ]
  ```

  Also `where a.compare : a, a -> Int` with `x.compare y + 1` (prints `LT1`), the same through
  `g x = f x x` (prints `EQ1`), and `where a.compare : a, a -> Bool` (prints `t`).
- **Command** build+run.
- **Observed**
  - Exit 0, then `TypeError: s.toUpperCase is not a function`.
  - Control: with `n : Int` it is TYPE MISMATCH (`w9d`).
- **Expected** `method_constraint_mismatch` or `type_mismatch` at the call, as for `Int`. Spec:
  `static-dispatch-spike.md` §6.2 Rule U1 and U2, and §3.2 (well-known signatures).
- **Root cause**
  - The `.flex` arm of `dischargeMethod` (`Solve.zig:2685-2690`) and of `resolveMethod`
    (`:2728-2732`) answer through `builtinRigidTarget` (`:2811-2819`) without unifying `c.fn_var`
    with `a, a -> Bool|Order`.
  - The `.rigid` arm does unify (`:2750-2752`).
  - **Suspected** the same in `checkAgainstRigid`'s bridge (`:2618-2621`).
- **Fixture** `check/bad/WhereClauseNumberReceiver.beni` (the four forms). `.codes`: one mismatch
  per call.
  - *R0 follow-up (review S4):* each line also has `contains "-> Bool"` or `contains "-> Order"`,
    the well-known signature the `Int` control prints ("But I need: Int, Int -> …").
- **Slice** R6.

### CK-22 — A private `eq` is used or ignored depending on the module and the nesting

- **Severity** unsound-runtime (incoherent). **Area** dispatch: privacy. **Class** K7.
- **Sources** disp F8 (`c1`); adv F7 (`pv2`, `pv3`).
- **Program**
  - `M` declares `pub type T = T Int`, a **private** `eq` comparing `modBy 10`,
    `pub inside : T, T -> Bool` with `inside a b = a == b` (annotated, as in `dr/c1`), and
    `pub type Holder = Holder T`.
  - `Main` declares `type W = W M.T`.
- **Command** build+run.
- **Observed**
  - `M.inside (M.T 1) (M.T 11)` is `True`: the private `eq`.
  - `M.T 1 == M.T 11`, `[ M.T 1 ] == …` and `M.Holder … == …` are `private_method`.
  - `W (M.T 1) == W (M.T 11)`, `( M.T 1, 0 ) == …` and `{ a = M.T 1 } == …` build and print
    `False`, using the structural `M$T$$eq`.
- **Expected** (D1 as amended 2026-09-24, `checker-v2.md` §11.3):
  - **Inside `M`** the private `eq` answers: `inside (T 1) (T 11)` is `True`, and so is `M`'s own
    `( a, 0 ) == ( b, 0 )` at `T`.
  - **The module rule is unchanged by privacy.** `M`'s private `eq` is `Holder`'s `eq` too.
    - Inside `M`, `Holder (T 1) == Holder (T 11)` is the module-rule clash (`type_mismatch`).
    - From `Main`, `M.Holder … == …` is `private_method`.
    - `7427828` already does both, so neither is part of this finding.
  - **Outside `M`**, `W …`, the tuple, the record and the list are `private_method` in `Main`. That
    is the defect: `7427828` builds them and answers `False` through a structural `M$T$$eq`.
  - Spec: `static-dispatch-spike.md` §3.3 and §6.3.1 step 2, amended by `checker-v2.md` §11.3.
- **Root cause**
  - `privateInOtherModule` (`Solve.zig:3474`) is consulted on direct resolution only.
  - The eager derived rows in `M` and derivation in `Main` (`nominalTarget`, `:4031`) never ask it.
- **Fixture**
  - `check/bad/PrivateEqOutsideModule/`. `.codes`: `private_method` at each of the 4 refused
    comparisons.
  - `run/PrivateEqInsideModule/` → `True`, `True`.
  - *R0, as written:* only the `check/bad` fixture: `W`, the tuple, the record and the list, each
    `private_method` at its `==`. `M.inside` is annotated (N2).
  - *R0: `run/PrivateEqInsideModule/` is not written, because its expectation was ambiguous under
    the spec.*
  - **Resolved 2026-09-24 (planner).** D1 is amended so the module rule stands, and
    `run/PrivateEqInsideModule/` becomes a **regression guard in `tests/corpus/`**, because v1
    already gets it right. `M` has the private `eq`, `pub inside : T, T -> Bool` (`a == b`) and
    `pub insideTuple : T, T -> Bool` (`( a, 0 ) == ( b, 0 )`), and `Main` prints both applied to
    `M.T 1` and `M.T 11`, which gives `true`, `true` (the round 4 probe `priv`). It is not a pending
    fixture. The pending half of CK-22 is R0's `check/bad/PrivateEqOutsideModule/` as written.
  - *R0 follow-up:* written as `tests/corpus/run/PrivateEqInsideModule/`. It prints `true`, `true`,
    as `Debug.toString` renders them, on 7427828.
- **Slice** R8.
- **Status** R8a (2026-09-26), its cross-module half, claimed: a derived context that reaches another module's private `eq` is `absent_private`, and every comparison in `Main` of `check/bad/PrivateEqOutsideModule` — the wrapper `W`, the tuple, the record, the list — is `private_method` (checker-v2.md §11.2's absent reason). The in-module half of D1 (a private `eq` suppresses the module's other derived `eq` rows) stays R8b's.
- **Status** R8b (2026-09-26), D1 end to end, claimed: the module rule counts a module's value of the name `pub` or not, so a private `eq` suppresses every derived `eq` row of its module (`dispatch/PrivateEqStillDerives`, now in `v2-expected.md`); the record says so — a `private_method` row naming the type whose module holds the private method (`checker-v2.md` §14.2 *as amended by R8b*) — so a THIRD module that compares a wrapper of the second's is `private_method` too, with a message naming the private method, its type and the value that holds it (`check/bad/PrivateEqThroughThirdModule`, `…Shapes`, both claimed; `scenario/PERM` permutes the declaring and the wrapping module).

### CK-23 — A phantom type argument that is a function blocks `==`

- **Severity** valid-program-rejected. **Area** derivation: capability. **Class** K7.
- **Sources** adv F8 (`e12`); root-caused by **plan**.
- **Program**:

  ```elm
  type Tag a = Tag Int
  t : Tag (Int -> Int)
  t = Tag 1
  main = Node.printLines [ show (t == Tag 1), show (t < Tag 2) ]
  ```
- **Command** build+run.
- **Observed** NOT EQUATABLE `Tag (Int -> Int)` and NO METHODS HERE (compare), exit 1.
- **Expected**
  - Prints `True`, `True`. Elm accepts it.
  - The message's own hint says "a `type` is comparable exactly when everything it can hold is".
  - Spec: that hint and `static-dispatch-spike.md` §6.3.1 step 4. Settled by **owner decision D4**
    (derived contexts, `checker-v2.md` §11).
- **Root cause**
  - `walkDerivableMode` pushes every type argument (`Solve.zig:2138`) whether or not it occurs in a
    payload. `derivable` then reports it (`:2903-2908`).
  - One evidence parameter per type parameter (A.20, `Dispatch.zig:189-192`) is the ABI behind it.
- **Fixture** `run/PhantomParameterEq.beni` → `True`, `True`.
- **Slice** R8.
- **Status** claimed by R8a (2026-09-26): a phantom parameter contributes no context entry (§11.2), so `run/PhantomParameterEq` prints `True`, `True`; across modules, `run/DerivedContextAcrossModules` compares `A.Tag (Int -> Int)` through the published context.

### CK-24 — A wrapper does not inherit a schema endpoint's settled function exclusion (queue row 74)

- **Severity** unsound-runtime: it checks, and `build` refuses schemas, so there is no runtime path
  yet. **Area** capability × schema. **Class** K7.
- **Sources** queue row 74; orch F6. Re-reproduced by **plan** in the same-module form. The
  cross-module form is now correct.
- **Program** (one module):

  ```elm
  import Schema exposing (Conversion)

  mk : Int -> Conversion Int (Int -> Int)
  mk n = Debug.todo "checker-only conversion"

  conversion = mk 0

  pub schema Fn tagged "kind" of
      Wrapped as "wrapped"
          payload : Int via conversion

  type Wrap = Wrap Fn.Type

  same : Wrap, Wrap -> Bool
  same left right = left == right
  ```
- **Command** `B check --no-cache Main.beni`.
- **Observed**
  - Exit 0, even with `conversion` annotated.
  - Adding `sameFn : Fn.Type, Fn.Type -> Bool; sameFn l r = l == r` gives exactly one NOT
    EQUATABLE, for `Fn.Type`, and none for `Wrap`.
- **Expected** `not_equatable` at `same`'s `==`. Spec: `schema.md` §3–§4 (S2 property settling) and
  `static-dispatch-spike.md` §6.3.1 step 4.
- **Root cause**
  - The schema property pass (`Schema.settleProperties`) and the ordinary capability passes are
    interleaved rather than composed (`Check.zig:1249-1336`).
  - `Wrap`'s answer is settled before the endpoint's exclusion is known and never revisited.
- **Fixture** `check/bad/SchemaWrapperExclusion.beni`. `.codes`: `not_equatable` at `same`.
- **Slice** R8.
- **Status** R8a (2026-09-26), claimed on the way: `Wrap`'s context is computed when first asked, after the endpoint's schema group is done, so it inherits the endpoint's settled exclusion. The schema endpoint through the fixpoint (§11.5) and `Schema.settleProperties` leaving v2's path stay R8b's.
- **Status** R8b (2026-09-26), closed in v2: a tagged endpoint is a unit member of the one fixpoint, its payloads read from `Schema.State` once its schema's group is done (demanded before the run), a mention only a `via` makes joined lazily; `Schema.settleProperties` and every schema property bit are off v2's path (`rules_test.zig`'s S4 fence). Claimed on top: `check/bad/SchemaWrapperExclusionThroughOwnType` (the function reaches the endpoint through a `via` target that mentions it back; 7427828 checks it clean, and v2 before R8b was `internal`) and `check/bad/SchemaEndpointInFlight` (a comparison inside the schema's own group is `method_needs_annotation`, naming the schema).
- **Status** R8b's review round (2026-09-26): the in-flight refusal narrowed (rule 7). A CLOSED type compared while a schema its payloads go through is in flight is deferred and checked in P5 (`tests/corpus/check/good/SchemaEndpointInFlightClosed.beni`, accepted; `check/bad/SchemaEndpointInFlightFunction.beni`, refused once the group is done, claimed); an encoded endpoint is never in flight (`tests/corpus/check/good/SchemaEncodedInFlight.beni`); `check/bad/SchemaEndpointInFlight.beni` is now the parametric case, the one still refused, with a hint naming the conversion. The lazy `via` join is replaced by an exact unit graph (CK-119).

### CK-25 — Generic derivation cannot carry a nested method's own requirement (queue row 73)

- **Severity** valid-program-rejected. Before row 72 it was unsound-runtime. **Area** derived ABI.
  **Class** K4.
- **Sources** queue row 73; disp; roc §3 and recommendation 3.
- **Program**:

  ```elm
  -- Holder.beni
  pub type Holder a = Holder a
  pub eq : Holder a, Holder a -> Bool
      where a.key : a, () -> Int
  eq left right = case left of Holder l -> case right of Holder r -> l.key () == r.key ()

  -- Keyed.beni
  pub type Keyed = Keyed Int String
  pub key : Keyed, () -> Int
  key k u = case k of Keyed n _ -> n

  -- Main.beni
  import Holder
  import Keyed
  type Outer a = Outer (Holder.Holder a)
  main =
      Node.printLines
          [ show (Holder.Holder (Keyed.Keyed 1 "a") == Holder.Holder (Keyed.Keyed 1 "b"))
          , show (Outer (Holder.Holder (Keyed.Keyed 1 "a")) == Outer (Holder.Holder (Keyed.Keyed 1 "b")))
          ]
  ```
- **Command** build+run.
- **Observed** NOT EQUATABLE `Outer Keyed` at the second `==`, exit 1.
- **Expected**
  - Prints `True`, `True`.
  - **Owner decision D4 (2026-09-24):** a derived function takes one evidence parameter per entry of
    its inferred **context** (here `a.key`), not one per type parameter.
  - Spec: `checker-v2.md` §11 and §12. Amends `static-dispatch-spike.md` §9.4 and A.20.
- **Root cause**
  - The derived ABI in `static-dispatch-spike.md` §9.4: "one evidence parameter per type parameter",
    answering only the method being derived.
  - `nominalTarget` (`Solve.zig:4031`) and `deriveOneParts` (`:4622`).
- **Fixture** `run/GenericDerivationNestedRequirement/` → `True`, `True`.
  - *R0:* an oracle twin exists after all. The same project with
    `type Outer = Outer (Holder.Holder Keyed.Keyed)` prints `True`, `True` on 7427828.
- **Slice** R8.
- **Status** claimed by R8a (2026-09-26): `Outer`'s context is `(0, key)`, so `Outer$$eq = ($m$0, $x, $y) => Holder$eq($m$0, $x.a, $y.a)` and `run/GenericDerivationNestedRequirement` prints `True`, `True`. Across modules the entry carries `key`'s type as a scheme (§14.2 as amended); `cache_test.zig`'s derived-context scenario uses it.

### CK-26 — Capability is computed up to eight times by several algorithms, with different hit and miss paths

- **Severity** latent. No wrong output found beyond CK-19, CK-23 and CK-24, which are its symptoms.
  **Area** orchestration × dispatch. **Class** K7.
- **Sources** orch F6; disp R4; roc §4.
- **Findings**
  - `Types.settleDispatchCapabilities` runs at `Check.zig:1249` and `1312`.
  - `settleOrdinaryCapabilities` runs at `1298`, `1313`, and inside the deriver `1325-1336`.
  - `Schema.settleProperties` runs at `1252` and per group.
  - The hit path (`Driver.install`, `Check.zig:991-1087`) uses a third mechanism:
    `restoreDerivedCapabilities`.
  - `Solve.zig:4560` (and `4280`, `4285`) `@constCast`s the session `Types` table through a
    `*const`.
  - A partial-hit experiment agreed byte for byte on five fixtures. The equivalence is asserted by
    tests, not by construction.
- **Fixture** none. `checker-v2.md` I10: one fixpoint, one owner, published contexts, no recomputation
  on hit.
- **Slice** R8.
- **Status** closed by R8a (2026-09-26), structurally: one computation (`check2/Contexts.zig`), one verdict reading it (`check2/Derivable.zig`), published rows read by importers and by `js/Lower`, nothing re-settled on a hit; `check2/rules_test.zig`'s S4 fence has no reader left. v1 keeps its own settle for its own modules until R12.

---

## D. Evidence

### CK-27 — A custom method's parts pair scheme quantifier *i* with type argument *i*

- **Severity** unsound-runtime. **Area** evidence: parts. **Class** K4.
- **Sources** disp F2 (`p3`). The row 72 mechanism introduced it.
- **Program**:

  ```elm
  -- H.beni
  pub type Holder a = Holder a
  pub eq : Holder (List a), Holder (List a) -> Bool
      where a.eq : a, a -> Bool
  eq left right = case left of Holder l -> case right of Holder r -> l == r

  -- Main.beni
  import H
  type W = W (H.Holder (List Int))
  main =
      Node.printLines
          [ show (H.Holder [ 1, 2 ] == H.Holder [ 1, 2 ]), show (H.Holder [ 1, 2 ] == H.Holder [ 1, 3 ])
          , show (W (H.Holder [ 1, 2 ]) == W (H.Holder [ 1, 2 ])), show (W (H.Holder [ 1, 2 ]) == W (H.Holder [ 1, 3 ]))
          ]
  ```
- **Command** build+run.
- **Observed**
  - `True False True True`.
  - The emitted code passes `List$eq` where `H.eq` expects element equality.
- **Expected** `True False True False`. Spec: `static-dispatch-spike.md` §7.1 (A.64): the parts of
  a `top`/`ext` are "one target per constraint the named value's scheme puts on a type parameter".
- **Root cause**
  - `constrainedParts` (`Solve.zig:3924-3948`), fed by `importedValueParts` (`:3954`) and
    `ownValueParts` (`:3989`), maps by index.
  - `Lower.evidenceShapeOk` checks counts, not kinds.
- **Fixture** `run/CustomEqHeadMatching/` → `True`, `False`, `True`, `False`.
  - *R0 follow-up (review S5):* the element type is `Nocase.Ci`, whose own `eq` ignores case
    (CK-19's `Ci`, in its own module), compared on `[ Ci "a" ]` against `[ Ci "A" ]` and
    `[ Ci "b" ]`. The Int lists could not tell `H.eq` from structural equality, so a `W` that
    ignored `H.eq` would have printed the expected lines. The oracle twin, the two direct lines
    alone, prints `True`, `False` on 7427828. The fixture prints `True`, `False`, `True`, `True`.
- **Slice** R6.

### CK-28 — The same mapping refuses a valid program with a stale message

- **Severity** valid-program-rejected. **Area** evidence: parts. **Class** K4.
- **Sources** disp F3 (`p4`).
- **Program** `H.eq : Holder ( a, b ), Holder ( a, b ) -> Bool where a.eq …, b.eq …`, and
  `type W = W (H.Holder ( Int, String ))` in `Main` compared with `==`.
- **Command** build+run.
- **Observed**
  - NOT IMPLEMENTED YET at `W`'s declaration.
  - The message says "a `Target.ext` carries no range of its own", which has been false since A.64
    (`Lower.zig:3420`).
- **Expected** Prints `True`, `True`, `False`. Spec: as CK-27.
- **Root cause** `Solve.zig:3936`: `if (counts.len != args.len) return .empty`.
- **Fixture** `run/CustomEqTupleHead/` → `True`, `True`, `False`.
  - *R0 follow-up (review S5):* `W (H.Holder ( Int, Nocase.Ci ))`, comparing `Ci "a"` with
    `Ci "A"` (`True`) and with `Ci "b"` (`False`). A structural `W` would print `False` for the
    first. The oracle twin, the direct line alone, prints `True` on 7427828. As written, 7427828
    still stops with NOT IMPLEMENTED YET.
- **Slice** R6.

### CK-29 — A joined method constraint's type is never generalised (queue row 77)

- **Severity**
  - compiler-crash-or-hang: INTERNAL ERROR on row 77's program.
  - valid-program-rejected on the minimal form.
- **Area** generalisation × dispatch. **Class** K2.
- **Sources** queue row 77; disp F4 (`r77`, `r77c`).
- **Program** (minimal):

  ```elm
  check x y =
      let
          same a b = a == b
      in
      [ same x y, x == y ]

  u1 = check "a" "b"
  u2 = check 1 2
  ```

  Row 77's program: `type Tree a = Leaf | Node a (Tree a)`, `same a b = { v = a } == { v = b }`,
  `[ same x y, Node x Leaf == Node y Leaf ]`, and `main = Node.printLines (List.map (check "a" "a")
  show)`.
- **Command** build.
- **Observed**
  - Minimal: TYPE MISMATCH at `check 1 2` (`number` vs `String`).
  - Row 77: INTERNAL ERROR "The hidden arguments of this call do not add up".
- **Expected**
  - Both build.
  - Row 77 prints `True`, `True`.
  - The minimal form, given a `main` printing `u1` and `u2`, prints `False`, `False`.
- **Root cause**
  - After `finishTopLevel` the receiver has rank 0 but its joined `eq` constraint's `fn_var` has
    rank 1 (instrumented by disp).
  - `copyHelp` (`Solve.zig:1682-1691`) shares non-generalised nodes, so every instantiation of
    `check` reuses one method type.
  - The underlying cause is the one in CK-02: `adjustRank` (`:4987-5057`) never walks constraint
    `fn_var`s.
  - The join (`attachConstraint` `:2305` → `unifyPending` `:2573`) merges a generalised node with a
    live one.
- **Fixture** `run/LetHelperJoinedMethod.beni` (both programs, one `main`) → `False`, `False`,
  `True`, `True`.
  - *R0, as written:* `main` prints all of `u1`, `u2` and `checkTree "a" "a"`. The expected
    output is `False` ×4, then `True`, `True`.
- **Slice** R6.

### CK-30 — Ordinary recursion with `==` or `<` stops the build with an internal error

- **Severity** compiler-crash-or-hang. **Area** evidence at calls inside a binding group.
  **Class** K4.
- **Sources** adv F5 (`z1`, `ie7`, `ie10`, `m1`, `m1b`, `m2`); root-caused by **plan** with new
  probes `z1t` and `m1s`.
- **Programs**:

  ```elm
  f n = if n == 0 then True else f (n - 1)                          -- z1
  f n m = if m == n then True else f (n ++ "x") m                   -- z1t (String, no number)
  f n = if n > 0 then n + f (n - 1) else 0                          -- ie7
  g xs m = case xs of
      [] -> m
      x :: r -> g r (if x > m then x else m)                        -- m1s
  f x y = if x == y then True else g x y                            -- m1b
  g x y = f y x
  ```

  Also `findMax`/`step` (`m1`) and `a1`/`b1` with two constraints (`m2`).
- **Command** build.
- **Observed** INTERNAL ERROR "The hidden arguments of this call do not add up" at the recursive
  call. `check` exits 0, and only `build` fails.
- **Expected**
  - All build. `z1` prints `T`, `ie7` `10`, `m1s` `q`, `m1b` `T`.
  - `m1` prints `9` and `q`.
  - `m2`: `a1 [ 1, 2, 3 ] [ 2, 3 ]` is `0` and `a1 [ "x" ] [ "x" ]` is `1`.
  - Spec: `static-dispatch-spike.md` §6.4 and §7.2.
- **Root cause**
  - A call to a member of the same recursive group gets its forwarding site when the reference is
    checked (`instantiate`, `Solve.zig:1419-1437`, `tagInstantiated` `:4319-4322`).
  - Whether it should exist is decided later by `promote` (`:4834`), and nothing reconciles the two.
  - **(a)** When the constraint is answered directly (the `number` bridge, or a concrete type found
    later), `emitSites` (`:4201-4218`) answers the forwarding site too and `detachConstraint`
    (`:2422`) removes the constraint. `f` gets `evidence=0`, but the call carries one site.
  - **(b)** When the constraint arrives after the reference was checked, the call gets no site but
    the constraint is promoted.
  - `Lower.refuseEvidence` (`Lower.zig:3750`) catches both.
- **Fixture** `run/RecursionWithComparison.beni` (all eight forms, one `main`).
- **Slice** R7.
- **Status** R7 (2026-09-26), its demand half: the `run/` fixtures R6b claimed (`RecursionWithComparison`, `DeadMiscount`) hold in every declaration order in `scenario/PERM` (programs `m1b`, `dead`), which R7 claims.
- **Since R2a** (2026-09-24, review S1) `check` refuses this miscount with the I7 `internal` even
  in a declaration nothing reaches: `Lower` used to meet it only on code dead-code elimination
  kept, so such a program built and ran before R2a. Kept on purpose (`checker-v2.md` §13.1 as
  amended); pinned by `tests/corpus/run/DeadMiscount.beni`.

### CK-31 — A mutually recursive group's sites carry the evidence indices of its first member

- **Severity** compiler-crash-or-hang. It is latent on `7427828` behind CK-09, and fixing CK-09
  exposes it. **Area** evidence: promotion. **Class** K4.
- **Sources** disp F6 (`p5`), confirmed on disp's patched binary.
- **Program**:

  ```elm
  f n x1 x2 y1 y2 = if n == 0 then x1 == x2 else g (n - 1) y1 y2 x1 x2
  g n p1 p2 q1 q2 = if n == 0 then p1 < p2 else f (n - 1) q1 q2 p1 p2

  main = Node.printLines [ show (f 0 1 1 "a" "b"), show (f 1 1 1 "a" "b"), show (g 0 "a" "b" 1 1), show (g 1 "a" "b" 1 2) ]
  ```
- **Command** build+run.
- **Observed**
  - On `7427828`: four TYPE MISMATCHes caused by CK-09.
  - On the patched binary: INTERNAL ERROR at both recursive calls. `g`'s `p1 < p2` reads `g`'s `eq`
    slot.
- **Expected** `True`, `True`, `True`, `False`. Spec: `static-dispatch-spike.md` §7.2: canonical
  order is per declaration.
- **Root cause** `promote` (`Solve.zig:4856-4883`) emits a variable's sites once, under the first
  header's canonical order (`seen`).
- **Fixture** `run/MutualGroupEvidenceOrder.beni` → `True`, `True`, `True`, `False`.
- **Slice** R7.
- **Status** R7 (2026-09-26), its demand half: `run/MutualGroupEvidenceOrder` (R6b's claim, `p5`) holds in every declaration order in `scenario/PERM`, which R7 claims.

### CK-32 — An operator used as a function and applied directly is an internal error

- **Severity** compiler-crash-or-hang. **Area** evidence: operator sections. **Class** K4.
- **Sources** adv F6 (`op1`–`op3`, `op5`, `op6`); root-caused by **plan**.
- **Program**:

  ```elm
  main = Node.printLines [ if (==) 1 1 then "t" else "f", if (<) "a" "b" then "t" else "f" ]
  ```

  Also `List.all xs ((==) 1 _)`, `\v -> (==) 1 v`, and `(==) x y` under `where a.eq`.
- **Command** build.
- **Observed**
  - INTERNAL ERROR "hidden arguments … do not add up" at `(==)`.
  - Control: `eqf = (==)` in a `let`, then `eqf x y`, works (`op4`).
- **Expected** `t`, `t` (and `op1`'s seven answers `f t t f t f t`). Spec: `language.md` §6.5.
- **Root cause**
  - `Constrain.call`'s "S3 SHIM" (`Constrain.zig:910-914`) types a call of an operator-section
    lambda with two arguments as a well-known call and puts the site on the **call** instruction
    (`:888`).
  - `Lower.callExpr` lowers the call normally, and `valueEvidence` (`Lower.zig:1896-1903`) gives a
    `lambda` callee 0 evidence.
- **Fixture** `run/OperatorSectionApplied.beni` (`op1`, `op2`, `op3`, `op5` and `op6` in one `main`).
- **Slice** R6.

### CK-33 — A constrained zero-parameter value of function type is defined curried and called flat

- **Severity** unsound-runtime. **Area** evidence calling convention (backend). **Class** K4.
- **Sources** adv F2 (`d2`, `d2a`, `d2c`, `d2d`, `d2f`, `d2g`); **plan** (`d2x`, root cause).
- **Program**:

  ```elm
  maxOf : a, a -> a
      where a.compare : a, a -> Order
  maxOf a b = if a < b then b else a

  h = maxOf

  same = (==)

  main = Node.printLines [ String.fromInt (h 1 2), h "a" "b", if same 1 2 then "t" else "f" ]
  ```

  Variants:
  - `h` annotated with the `where`.
  - `h = \x y -> maxOf x y`.
  - `h "m" _`.
  - `pub h` used from another module, in value position (`List.foldl [ 1, 5, 2 ] 0 M.h`).
- **Command** build+run.
- **Observed**
  - Exit 0. It prints the JavaScript source text `($p$1, $p$2) => Main$maxOf($m$0, $p$1, $p$2)`
    twice.
  - `same 1 2` is `t`.
  - Only the unannotated `pub h = maxOf` is caught, by `constrained_constant` (`d2b`).
- **Expected**
  - `2`, `b`, `f`, and the cross-module fold `5`.
  - Spec: `static-dispatch-spike.md` §8.1 and §8.2, A.85. A reference and a call must agree.
- **Root cause** `Lower` decides the parameter count of such a value in three places:
  - the definition (`declaration`, `Lower.zig:664` → `:701`) uses the declaration's parameter count
    0 and emits `($m$0) => value`;
  - a direct call (`callExpr`, `:3739-3796`, `:3791-3795`) emits `h(ev, args…)`;
  - a cross-module reference (`externalArity`, `:2049-2057`) uses the type's arity.

  The comment at `Lower.zig:660-662` ("the checker refuses it first") holds only for unannotated
  `pub` (`Solve.zig:4888-4897`).
- **Fixture** `run/ConstrainedFunctionConstant/` (`Main.beni`, `M.beni`) →
  `2`, `b`, `f`, `t`, `2`, `b`, `1`, `5`.
- **Slice** R2 (one `Convention` function shared by `Lower`, `Cycles` and `Edges`, `checker-v2.md`
  §12.5; moved from R1 on 2026-09-24, design review S8).
- **Status** fixed by R2b (2026-09-24), and the fixture promoted to
  `tests/corpus/run/ConstrainedFunctionConstant/`. `check/Convention.zig` (`checker-v2.md` §12.5, as
  amended by R2b) is the one place a constrained value's definition, call, value-position reference
  and load-time behaviour are decided, from `DeclInfo.convention` (`dispatch_bytes` 3) or, for an
  import, from its interface. `h = maxOf` is now `($m$0, $p$1, $p$2) => maxOf($m$0, $p$1, $p$2)`,
  `same = (==)` is `($m$0, $p$3, $p$4) => $m$0($p$3, $p$4)`, and `M.h` in value position is
  eta-expanded over the same two parameters. `tests/corpus/run/ConstrainedFunctionConstantRoutes/`
  covers the other routes (annotated and not, lambda, `if` and `let` bodies, a recursive lambda, a
  recursive group through a lambda-bodied member, partial application, higher-order arguments local and
  imported, `--release` through the corpus's second pass), `cache_test.zig` the warm rebuilds that
  rewrite `M.h` three ways without re-checking its importer, and `dispatch/Conventions.beni` the
  column. Found on the way: CK-84.
  *Review amendments (2026-09-24):* a point-free member of an initialiser circle is `cyclic_value`
  with or without its `where` (B1, `check/bad/EvidenceFunctionConstantCycle*.beni`; controls in
  `run/EvidenceFunctionRecursionAccepted.beni`); an unannotated `pub` of function type is no longer
  `constrained_constant` (S3, `check/good/ConstrainedPubFunctionConstant/` and a `build_test.zig`
  run); per-call evaluation of an `applied` body is documented and pinned (S1, CK-85).

### CK-34 — An evidence-only constant counts as deferring for the cycle check

- **Severity** unsound-runtime. **Area** `Cycles`. **Class** K4.
- **Sources** core #6 (`CstrCyc`, control `CstrCyc2`).
- **Program**:

  ```elm
  zs : List a where a.eq : a, a -> Bool
  zs = List.filter zs (\x -> x == x)

  ints : List Int
  ints = zs

  main = Node.printLines [ String.fromInt (List.length ints) ]
  ```
- **Command** build+run.
- **Observed**
  - Exit 0, then `RangeError: Maximum call stack size exceeded` in `Main$zs`.
  - Without the `where`: VALUE DEFINED IN TERMS OF ITSELF.
- **Expected** `cyclic_value`. Spec: `checker.md` §6.7. Since queue row 57 a zero-parameter evidence
  declaration is **called** at every read, so it runs.
- **Root cause**
  - `Cycles.zig:152-154` counts "has evidence parameters" as deferring.
  - `checker.md` §6.7's sentence says the same and is stale.
- **Fixture** `check/bad/EvidenceConstantCycle.beni`. `.codes`: `cyclic_value` at `zs`.
- **Slice** R2, with CK-33 (one `Convention`; moved from R1 on 2026-09-24, S8).
- **Status** fixed by R2b (2026-09-24), promoted to `tests/corpus/check/bad/EvidenceConstantCycle`
  with its `.diag` (one `cyclic_value` at 14:1 naming `zs`, as the `.codes` said). `Cycles` asks
  `Convention.defers`: a `thunk` runs at every read and a `constant` at load, and both are nodes that
  RUN; `checker.md` §6.7's stale sentence is gone. `check/bad/EvidenceConstantCycleMutual.beni` is
  the two-member form.

### CK-35 — Speculation rollback is journalled by hand across about fourteen side tables

- **Severity** latent. **Area** dispatch speculation. **Class** K4.
- **Sources** disp F11.
- **Findings**
  - `tryShape`'s rollback (`Solve.zig:1812-1860`) and `TargetProbe` (`:3017-3050`) omit
    `evidence_next` and `part_slots`.
  - It is harmless today because `Lower` reads the pre-order, not the indices.
- **Fixture** none. `checker-v2.md` I14: speculation journals only the store and append-only queues.
- **Slice** R6.
- **Status** closed (R15-fix-J, 2026-09-28): v1's `tryShape` and `TargetProbe` went at R12, and v2
  never speculates; the store's unused journal is deleted too (CK-152, `checker-v2.md` §7.5
  *amended 2026-09-28*), so nothing is journalled anywhere.

---

## E. Ordering

### CK-36 — An own unannotated method used before its group is refused, depending on source order (queue row 75)

- **Severity** valid-program-rejected. **Area** own-method ordering. **Class** K6.
- **Sources** queue row 75; disp F9 (`o1`/`o2`); orch F5 (`row75`/`row75b`); adv (`box`); roc §1.
- **Programs**
  - `type T = T Int`, then `use a b = T a == T b`, then an unannotated private `eq` on `T`
    (`o1`).
  - Row 75: `pub type T`, `pub type U`, an unannotated `pub compare` on `U` whose `let` holds
    `T 1 == T 2`, then an unannotated `pub eq` on `T`.
  - adv `box`: an unannotated `pub eq` on `Box a` whose body uses `==` on its own type.
- **Command** build.
- **Observed**
  - METHOD NEEDS AN ANNOTATION, exit 1.
  - Swap the declarations (`o2`, `row75b`) and it checks. `row75b` prints `custom eq used`.
- **Expected**
  - All check. Row 75 prints `custom eq used` in both orders.
  - **Owner decision D3 (2026-09-24):** no annotation is ever required for `eq`/`compare`, or any
    method, for ordering reasons. A use of an own untyped method is deferred to the using group's
    boundary (`checker-v2.md` §10).
  - Retires `method_needs_annotation` (`static-dispatch-spike.md` §10.12).
- **Root cause**
  - Priority groups (`Check.zig:1254-1308`) cover only `pub eq` and `pub compare` and their
    syntactic closure.
  - Everything else follows SCC order, which falls back on source order.
  - The refusal is at `Solve.zig:698`.
- **Fixture** `run/OwnMethodBeforeDefinition/` (`o1`, row 75 and `box` as modules) → the outputs of
  their reordered twins.
  - *R0, as written:* modules `Box`, `O1`, `Row75`, `Main` → `False`, `True`, `True`, `True`,
    `True`, `custom eq used`.
  - `Box`'s payload is a `String` rather than adv's `a`. Otherwise the unannotated `pub eq` is the
    `ambiguous_method_receiver` warning, and a `run/` fixture must build silently.
  - `O1` compares with `modBy x 10` (subject-first), not the probe's `modBy 10 x`.
- **Slice** R7.
- **Status** claimed by R7 (2026-09-26): nesting at demand (`checker-v2.md` §10.2, §10.8) checks `run/OwnMethodBeforeDefinition` in every order of each of its three modules (`scenario/PERM`: `o1`, `row75`, `box`).

### CK-37 — Row 76's cycle check is periodic, and a rejection poisons the shared receiver

- **Severity** latent, with diagnostic-quality risk. **Area** drain termination. **Class** K3.
- **Sources** queue row 76; disp (state of row 76); roc recommendations 5 and 6.
- **Findings**
  - The drain runs the occurs check every `cycle_check_depth = 64` generations (`Solve.zig:714`,
    `:1993`). That is sound for the case it targets, but it is a magic bound on a symptom. CK-03
    shows a walk that never reaches it.
  - The rejection calls `s.poison(o.v)` on the receiver (`:1996`), so independent sites sharing that
    receiver go silent. Roc flags the constraint class, not the receiver
    (`references/roc/src/types/store.zig:756-771`).
- **Fixture**
  - Existing `check/bad/LetHelperCyclicReceiver` and `abuse_test.zig`'s row-76 scenario. Their
    expectations change under **owner decision D5**: the helper generalises, so the program becomes
    valid (`checker-rewrite.md` R14).
  - New pending `check/bad/RejectedReceiverDoesNotSilence.beni`: two independent errors on one
    receiver, both reported. `.codes`: both.
  - *R0: not written, because the expectation is ambiguous under the spec.* The candidate is row
    76's `pairEq` plus `&& x < y`. On 7427828 it gives one `infinite_type`, at the `==`: the
    rejection poisons `x`, and the `<` goes silent. An `x.size ()` wanted with no cycle in it is
    already reported on 7427828, so an *independent* error is not silenced today. Only another
    method on the cyclic receiver is.

    Under `checker-v2.md` the outcome depends on which defence fires first:
    - if §9.5's resolver walk fires first, it is `infinite_type` at `==` and at `<`, because the
      `dispatch_rejected` flag silences only the same method;
    - if §6.3's `binders_end` or §8.2's boundary occurs check sees `x ~ List x` first, it is one
      `infinite_type` at the parameter `x`, and `x` is poisoned.

    R6 writes this fixture once the order is pinned.
  - **Pinned 2026-09-24 (planner; `checker-v2.md` §9.5).** The order is fixed, and it matches
    `7427828`:
    - eager draining runs the resolver walk right after the node that closed the cycle, so it fires
      first;
    - it reports one `infinite_type` and poisons the cycle's root, so nothing reports it again;
    - a non-cycle rejection does not poison, and flags only that method.

    Both behaviours are already v1's, so these are **regression guards in `tests/corpus/`**, not
    pending fixtures. R6a must keep them green:
    - `check/bad/CyclicReceiverReportedOnce.beni`, `f x = x == [ x ] && x < [ x ]`: exactly one
      `infinite_type`, at 2:7, the `==` (round 4 probe `cyc1`). It is used instead of row 76's
      `pairEq`, whose expectation R14 changes.
    - `check/bad/RejectedReceiverDoesNotSilence.beni`: `x : T` with `x.foo 1 + x.baz 2 + x.bar 3 +
      String.length x`, where `T`'s module has only `bar`. It gives two `unknown_method`s and one
      `type_mismatch` at `String.length x`, so the receiver is not poisoned (round 4 probe
      `indep`).

    What stays open in CK-37 is structural (the periodic bound, and receiver poisoning on a
    non-cycle rejection in v1's cycle path), plus R14's changed expectations.
  - *R0 follow-up:* both guards are written in `tests/corpus/check/bad/` with blessed `.diag`s:
    `CyclicReceiverReportedOnce` (one `infinite_type`, at 7:7 after the intent comment) and
    `RejectedReceiverDoesNotSilence` (`unknown_method` at 18:6 and 18:16, `type_mismatch` at
    18:49).
- **Slice** R6 (cycle-safe walks, class flag). R14 for D5.
- **Added by R6a's review (2026-09-25):** `tests/corpus/check/bad/RejectedMethodClassWide` (the class flag OR-merged on every union, so `[ x, y ]` and `[ y, x ]` report alike: review F3), claimed.

---

## F. Interface and representation

### CK-38 — An imported type silently loses arity above 255 (queue row 71)

- **Severity** valid-program-rejected. **Area** interface record. **Class** K10.
- **Sources** queue row 71; re-reproduced by **plan**.
- **Program** `pub type Wide a0 … a255 = Wide a255` in `Wide.beni`, and `w : Wide.Wide Int … Int`
  (256 arguments) in `Main.beni`.
- **Command** `B check --no-cache Main.beni Wide.beni`.
- **Observed** WRONG TYPE ARITY: "`Wide` takes 255 type arguments, but here it has 256."
- **Also observed** (R2a stage 2's review, 2026-09-24, on 7fd409e and after): `==` or `<` on an
  imported nominal of 256 or more type parameters is four `internal` diagnostics (the I7 assert,
  `checker-v2.md` §13.1) at every use, where 255 imported, or 256 in one module, is fine: the
  `ext_derived` requirement count comes from `types.entry(id).arity`, the same `u8`. So a valid
  program gets an INTERNAL ERROR, not only `wrong_type_arity`; and the cross-module half of
  `static-dispatch-spike.md` §9.2's wide form (past 4 096 entries) is unreachable until this is
  fixed.
- **Expected** Checks. Spec: `language.md` §4 (no arity limit stated).
- **Root cause** `Types.Entry.arity: u8` (`Types.zig:81`), the interface type rows
  (`Interface.zig:293`, `358`, `369`), and the saturating cast at `Interface.zig:871`.
- **Fixture** `check/good/WideTypeArity/` + `_expected.iface`, generated. On 7427828 it is
  `wrong_type_arity` at `Main.beni:10:9`.
- **Slice** R3 (interface v3).
- **Status** fixed by R3 (2026-09-25): `Interface.Type.arity` and `Types.Entry.arity` are `u16`,
  `iface_bytes` 3 and `digest_version` 2; lowering refuses a 65 536th type parameter with the new
  code `too_many_type_parameters` (`language.md` §10), so nothing saturates. Promoted
  `check/good/WideTypeArity/` (its hand-written golden had 255 parameter names — the saturated
  width — and is blessed at 256). The "also observed" half was worse by 3487c12 than the R2a note
  says: `==` on an imported 256-parameter type BUILT, exit 0, and threw `TypeError` at run time —
  pinned by the new `run/WideTypeArityEq/` (dev and `--release`), and past 4 096 parameters by
  `cache_test.zig`'s cross-module wide-form scenario (cold, warm, partly warm). Red on 3487c12:
  all three, and `abuse_wide_test.zig`'s 65 536-parameter refusal (a Debug panic in
  `deriveOneParts` after 35 s of pairwise duplicate checking in lowering, which is a sort now).

### CK-39 — An imported record-alias constructor is typed as an opaque nominal

- **Severity** valid-program-rejected. **Area** interface instantiation. **Class** K10.
- **Sources** **plan** (`a9`).
- **Program** `Pt.beni`: `pub type alias P = { x : Int, y : String }`. `Main.beni`:
  `import Pt exposing (P)`, then `p = P 1 "a"` and `Node.printLines [ p.y ]`.
- **Command** build+run.
- **Observed** TYPE MISMATCH "This is not a record with a `y` field: It is: `P`".
- **Expected** Prints `a`. Spec: `language.md` §0 ("everything not listed is Elm's"). Elm's record
  constructor builds the record.
- **Root cause** `Schemes.instantiateCtor` (`Schemes.zig:779-781`) always builds an `app` result:
  "only a `type` declares constructors".
- **Fixture** `run/RecordAliasConstructorImported/` → `a`.
- **Slice** R3.
- **Status** fixed by R3 (2026-09-25): a constructor row carries `result: record_alias` and the
  alias's field names in declaration order; `Schemes.instantiateCtor` builds the alias of the
  record, and `js/Lower.zig` emits and reads an imported alias's constructor by those names
  (`CtorRep.record` is `local` or `imported`; `refuseAliasCtors` is deleted). Promoted
  `run/RecordAliasConstructorImported/`, and R1's `build/bad/RecordAliasConstructorImported/`
  moved to `run/RecordAliasConstructorImportedToString/` (`Debug.toString (P 1 "a")` prints the
  record). Both red on 3487c12 (build refused).

---

## G. Performance

### CK-40 — Schema property settling is cubic in the number of schemas in a module

- **Severity** performance. **Area** pipeline. **Class** K11.
- **Sources** orch F3; re-measured by **plan**.
- **Program** a module of `pub schema S{i} = Int`, i = 0..n.
- **Command** `B check --no-cache --jobs=1 S{n}.beni`.
- **Observed**
  - ReleaseFast (plan): 200 → 0.08 s, 400 → 0.68 s, 800 → 5.43 s.
  - Orch measured 1 600 → 231.7 s.
  - Debug (plan): 200 → 3.74 s, 400 → 16.5 s.
  - With the per-group calls removed (orch's scratch copy), 1 600 schemas take 0.18 s with the same
    interface.
- **Expected** Linear. Budget: `fast-compiler.md` §2, > 250k LOC/s per core.
- **Root cause**
  - `schemas.settleProperties` runs after every group containing a schema (`Check.zig:1304-1307`,
    `1317-1320`).
  - Each call recomputes every endpoint (`Schema.zig:108`), and each recomputation memsets a
    store-sized `seen` (`Types.zig:371`).
- **Fixture** a pending perf scenario in `tests/blackbox/pending_test.zig`: time(2n)/time(n) ≤ 2.5
  for n chosen so the fixed build takes ≥ 0.5 s at n (calibrated in R0).
  - *R0, as written:* `scenario/CK-40`, n = 400.
  - Calibration used a Debug build of 7427828 with the per-group `settleProperties` calls
    disabled. 200 / 400 / 800 schemas took 339 / 596 / about 1 100 ms (ratio 1.98). 7427828 takes
    3 892 / 16 979 ms and over two minutes.
  - Swapping that binary in turned the scenario GREEN, and rule (b) fired.
- **Slice** R8. The fixpoint is lazy and memoised, with no per-group settling.
- **Status** R8a (2026-09-26): v2 settles endpoint properties when next read after a schema group, and once after P4 (`Solve.settleSchemas`), never per group: 300 / 600 schemas in 13 / 25 ms (ReleaseFast). Its v2 twin is in `perf_test.zig` (`test-perf`); the v1 scenario stays red, v1 being frozen.

### CK-41 — `Schemes.Writer.resetMemo` makes interface writing quadratic in constructors

- **Severity** performance. **Area** publication. **Class** K11.
- **Sources** orch F4; re-measured by **plan**.
- **Program** a chain of `pub type A{i} = A{i} Int A{i-1} | B{i}`.
- **Observed**
  - ReleaseFast: 2 000 → 0.35 s, 4 000 → 1.34 s, 8 000 → 5.33 s.
  - Orch's phase timers put 5.35 of 6.08 s in `fillInterface`. Amortised growth took it to 24 ms.
- **Expected** Linear.
- **Root cause** `resetMemo` (`Schemes.zig:260-282`) reallocates and memsets to `store.count()`
  whenever the store grew, and `fillCtorTerms` (`Check.zig:1936-1993`) grows it before every
  constructor.
- **Fixture** pending perf scenario (ratio, as CK-40).
  - *R0, as written:* `scenario/CK-41`, on ONE `pub type Big` with n = 14 000 constructors, not the
    chain.
  - Why not the chain: with `resetMemo` growing ×2 (Debug), the chain still took 746 / 2 254 /
    7 742 ms at 2 000 / 4 000 / 8 000 types. That is ratio 3.0 to 3.4, because of the per-type
    residue described under CK-42, so it would stay red after R3. Independent `pub` types behave
    the same: 458 / 1 126 / 3 370 ms.
  - The single type isolates `resetMemo`. With the fix, 8 000 / 16 000 / 32 000 constructors take
    375 / 665 / 1 227 ms. On 7427828 they take 2 950 / 10 636 / about 42 000 ms.
  - Swapping the fixed binary in turned the scenario GREEN (ratio 1.88), and rule (b) fired.
- **Slice** R3 (shared `Schemes.zig`: epoch marks).
- **Status** fixed by R3 (2026-09-25): `Schemes.Writer`'s memo is live per slot while its stamp is
  the current epoch, a new scheme is one increment, and the arrays grow at least ×2. The scenario
  is the first timing scenario PROMOTED, into `tests/blackbox/perf_test.zig` (`zig build
  test-perf`, the manager's decision; `checker-rewrite.md` §2.5): 12 / 18 ms at 4 000 / 8 000
  constructors (ratio 1.50) on R3, and red through `test-perf` on 3487c12, 400 / 1 476 ms (3.69).

### CK-42 — Linear scans and quadratic de-duplication in dispatch resolution

- **Severity** performance, **suspected**: read from the code, no scaling curve beyond orch F4's
  residue. **Area** dispatch. **Class** K11.
- **Sources** disp F11; orch F4 (residue).
- **Findings**
  - `ownDeclNamed` and `ownPubDeclNamed` (`Solve.zig:3439`, `:3456`) scan the declarations per
    resolution.
  - `evidenceIndexOf` (`:4276`) scans every annotated constraint.
  - `siteOrigins` and `appendSite` (`:4241`, `:4346`) de-duplicate quadratically.
  - Orch F4 left about 0.5 s of an 8 000-type chain in the final deriver block
    (`settleOrdinaryCapabilities` + `deriveOrdinaryDeclaredTypes`).
- **Fixture** pending perf scenario "5 000 declarations, each comparing its own type with `==`":
  ratio as CK-40.
  - *R0: reproduced, no longer only suspected.* `scenario/CK-42` uses n = 5 000. On 7427828
    (Debug), 2 000 / 4 000 / 8 000 declarations take 1 057 / 2 775 / 8 213 ms. At n the scenario
    measured 3 983 ms, and 2n exceeded 9 957 ms on all three runs.
  - The super-linearity is not only dispatch. With CK-40's and CK-41's fixes in, 2 000 / 4 000 /
    8 000 independent `pub type`s with no `==` take 458 / 1 126 / 3 370 ms.
  - The self-profile puts it in the `check` event, outside constrain and solve. `dep_digest` is
    super-linear too: 79 → 262 ms from 4 000 to 8 000 types.
  - R6 must account for both before this can turn green.
  - **Superseded by the R0 follow-up (review S1).** The review measured the control, the same
    program with `x == x` on an `Int` in place of the nominal `==`: 2.6 s / 7.6 s at 5 000 /
    10 000, a ratio of about 2.9 with no dispatch at all. So the dispatch fix alone could never
    have turned the scenario green.
  - `scenario/CK-42` now times both programs, best of 3 each. It asserts on the **extra** cost of
    nominal dispatch: `extra(n) = t(nominal, n) − t(control, n)`, and
    `extra(2n) / extra(n) ≤ 2.5`. The review's numbers give 1.5 s → 5.2 s, a ratio of about 3.5.
  - The per-declaration residue is its own finding, CK-75.
- **Slice** R6 (name index built in phase P3; EvIds replace site lists).

---

## H. Outside the checker

### CK-43 — The implicit record-alias constructor emits a tagged object

- **Severity** unsound-runtime. **Area** JS lowering. **Class** K14.
- **Sources** adv F4 (`rc2`, `rc3`, `rd5`); root-caused by **plan**.
- **Program**:

  ```elm
  type alias P = { x : Int, y : String }
  main = Node.printLines [ String.toUpper (P 1 "a").y ]
  ```

  Also `p.x`, `getY p` with `getY : P -> String`, and the partial `P 2 _`.
- **Command** build+run.
- **Observed**
  - Exit 0, then `TypeError: Cannot read properties of undefined`.
  - `rc2` prints `undefined` and an empty line.
  - The emitted value is `{ $: "P", a: 1, b: "a" }`.
- **Expected** `A`. `rc2` prints `a`, `1`, `a`, `b`, `eq`. `rd5` prints `a`, `b`.
  Spec: `language.md` §0 (Elm's).
- **Root cause**
  - BIR types it right (`bir/Lower.zig:868-888`, `:958-972`), and so does the checker.
  - `js/Lower.zig`'s `ctorRepLocal` (`:1314-1329`) and `ctorRepExternal` (`:1331-1345`) never check
    for a `type_alias` owner, and `CtorRep` (`:266-273`) has no record variant.
- **Fixture** `run/RecordAliasConstructor.beni` → `A`, `a`, `1`, `a`, `b`, `a`, `b`.
- **Slice** R1. Needs a `backend.md` §4 row ("record-alias constructor → object literal in canonical
  key order"), which R1 writes.
- **Status** fixed by R1 (2026-09-24): `backend.md` §4 has the record-alias-constructor row (D12),
  and `js/Lower.zig`'s `CtorRep.record` emits the record literal, keys sorted by text and arguments
  pinned in written order like a literal's (`tests/corpus/run/RecordAliasConstructorOrder.beni`).
  The fixture is promoted to `tests/corpus/run/RecordAliasConstructor.beni`. A constructor PATTERN reads the
  alias's fields in declaration order (CK-78, supported by the manager's decision). An IMPORTED
  alias's constructor is refused at emit with `not_implemented` rather than emitted wrong
  (`build/bad/RecordAliasConstructorImported/`), because interface v2 lacks its field names (CK-39,
  R3, which `checker-v2.md` §14.2 now makes carry them).

### CK-44 — A duplicate field in a record *type* is not diagnosed

- **Severity** diagnostic-quality: an invalid program is accepted while unused, and the error
  cascades when it is used. **Area** BIR lowering. **Class** K14.
- **Sources** adv E8 (`rd4`, `rd6`, `rd7`); root-caused by **plan**.
- **Program** `type alias R = { a : Int, a : String }`, and a `main` that does not use it.
- **Observed**
  - Exit 0.
  - Used, it gives "This record does not have a `a` field: `{ a : a }` … need
    `{ a : Int, a : String }`", and the declaration dumps as `? -> String`.
- **Expected** `duplicate_field` at the second `a`. Spec: `language.md` §4. It is the same code as
  for literals.
- **Root cause**
  - `lowerTypeFields` (`bir/Lower.zig:1666-1677`) lacks the check that `lowerFields`
    (`:2627-2649`) has.
  - `Solve.zig:1099-1101`'s comment wrongly claims coverage.
- **Fixture** `check/bad/DuplicateRecordTypeField.beni`. `.codes`: `duplicate_field` at the second
  `a`.
- **Slice** R1.
- **Status** fixed by R1 (2026-09-24): `lowerTypeFields` reports `duplicate_field` at every repeat and
  drops it (so `TypeStore` keeps one field per name, as `Solve.gatherFields` assumes). Both it and
  `lowerFields` use `FieldNames`, a scan up to 16 names and a hash set past that, so a 100 000-field
  record is not n² (`tests/corpus/check/bad/DuplicateFieldWideRecord.beni`). The fixture is promoted
  to `tests/corpus/check/bad/DuplicateRecordTypeField.beni`.

### CK-45 — A float literal pattern is reported as a layout error

- **Severity** diagnostic-quality. **Area** parser. **Class** K14.
- **Sources** adv E9; re-reproduced by **plan** (`fpat`).
- **Program** `g x = case x of 1.5 -> "a"` followed by `_ -> "b"`.
- **Observed** CASE WITHOUT BRANCHES ("ran into `1.5`, which is indented to column 9") plus
  UNEXPECTED TOKEN.
- **Expected**
  - One diagnostic saying float patterns are not allowed, and suggesting a comparison. The grammar
    excludes them: `language.md` §3 `PatAtom`.
  - It needs a code. Proposed: reuse `unexpected_token` with a dedicated message. No new code.
- **Root cause** `canStartPatAtom` (`parse/Parse.zig:2641-2646`) and `parsePatAtom` (`:2711-2815`)
  have no `.float` arm.
- **Fixture** `parse/bad/FloatPattern.beni`. `.codes`: one diagnostic, contains "float".
- **Slice** R1.
- **Status** fixed by R1 (2026-09-24): a float starts a pattern atom, and `parsePatAtom` (and the `-`
  form) reports `unexpected_token` with a message of its own and consumes the literal, so the `case`
  keeps its branches. `language.md` §3 states the rule. The fixture is promoted to
  `tests/corpus/parse/bad/FloatPattern.beni`.

### CK-46 — The `let`-cycle message names the binding itself as "further down"

- **Severity** diagnostic-quality. **Area** BIR lowering. **Class** K14.
- **Sources** adv E11 (`y6`).
- **Program** `let get u = n + 1` followed by `n = get ()`.
- **Observed** "Naming `get` here reads `n`, which is bound further down this `let`, on line 8". Line
  8 is `n`'s own binding.
- **Expected** Name the cycle `n → get → n` as a self-reference through `get`.
- **Root cause**
  - `bir/Lower.zig:2422-2424` reports `.through` without checking whether the hit is the binding
    itself. The direct path distinguishes `.self` (`:2417`).
  - The text is at `bir/Diagnostics.zig:187-193`.
- **Fixture** `check/bad/LetCycleThroughFunction.beni`. `.codes`: `let_forward_reference` lacks
  "further down".
- **Slice** R1.
- **Status** fixed by R1 (2026-09-24): `checkLetOrder` reports `Forward.self_through` when the binding
  reached through a `let` function is the one being defined, with the message "`n` is defined in
  terms of itself, through `get`". The fixture is promoted to
  `tests/corpus/check/bad/LetCycleThroughFunction.beni`.

### CK-47 — A malformed `exposing (T(..))` produces a cascade

- **Severity** diagnostic-quality. **Area** parser and resolver. **Class** K14.
- **Sources** orch F9 (out of scope there); re-seen by **plan**.
- **Program** `import Holder exposing (Holder(..))`.
- **Observed** EXPECTED TOKEN, then two INVALID CHARACTERs on the same line, then one UNKNOWN
  CONSTRUCTOR per later use.
- **Expected** One diagnostic saying beni exposes constructors differently, with the correct form.
  Later uses stay quiet, per Elm's stop-at-first-phase rule, which the resolver does not follow.
- **Root cause** **suspected** the import `exposing` list parser does not recover past `(..)`. The
  line was not isolated.
- **Fixture** `parse/bad/ExposingConstructorsElmStyle.beni`. `.codes`: exactly one diagnostic.
  - *R0, as written:* `import Schema exposing (Direction(..))` plus four uses of `Decoding` and
    `Encoding`. A single-file fixture cannot import a project module, so it uses a core type. On
    7427828 that is 7 diagnostics.
  - The `.codes` assumes the one diagnostic keeps today's first code, `expected_token 9:34`. R1
    may choose another code, and says so when it blesses.
  - *R0 follow-up (review S4):* the comment is updated to D8 as amended. The `.codes` is now
    `expected_token 10:34 contains "Decoding" contains "Encoding"`, so dropping the cascade without
    D8's suggested `exposing (Direction, Decoding, Encoding)` stays red.
  - **Confirmed 2026-09-24 (planner; D8 as amended, `checker-v2.md` §21.1).** The single diagnostic
    keeps `expected_token`, at the `(` after `Direction`, which is 9:34. Its message names the
    beni form, `exposing (Direction, Decoding, Encoding)` (`language.md` §5.2), and the later
    constructor uses stay quiet. The `.codes` stands as written.
- **Slice** R1.
- **Status** fixed by R1 (2026-09-24), D8 as amended. `..` is one token (`dot_dot`, `language.md`
  §2.2), so the lexer reports nothing; the parser reports `expected_token` at the `(` and marks the
  exposed name (`Bir.Exposed.all_ctors_token`); lowering keeps unknown constructors quiet in that
  file; and resolution, which has the imported interface, rewrites that one diagnostic's text to
  `exposing (Direction, Decoding, Encoding)` (`Session.rewriteMessage`). `fmt` and the dumps print
  the parser's text, which writes `…` for the constructors. `language.md` §5.2 has the row. The
  fixture is promoted to `tests/corpus/parse/bad/ExposingConstructorsElmStyle.beni`.

---

## I. Diagnostic quality (checker)

### CK-48 — `missing_where_constraint` underlines an unrelated span

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** disp F10 (`p11`).
- **Program** `direct : a, a -> Bool` / `direct x y = [ x ] == [ y ]`.
- **Observed** MISSING CONSTRAINT underlines the annotation's `a` (1:10), or the first line of an
  unrelated `type` declaration when there is one.
- **Expected** The `==`. Spec: `static-dispatch-spike.md` §6.2 Rule U2, "at the flex's region".
- **Root cause** `checkAgainstRigid` reports at `s.region` (`Solve.zig:2624`), which `method()`
  (`:2231`) never sets.
- **Fixture** `check/bad/MissingWhereAtUse.beni`. `.codes`: `missing_where_constraint` at the `==`.
- **Slice** R6. The resolver reports at the wanted's `origin`.

### CK-49 — "does not match all the previous elements" for the first element

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E1 (`q1`, `q2`).
- **Program** `Node.printLines [ 1 ]`, and `xs : List String; xs = [ 1, 2 ]`.
- **Observed** "The 1st element of this list does not match all the previous elements … previous
  elements are String".
- **Expected** The expectation comes from context: "This list needs `String` elements (from …), and
  its 1st element is a `number`".
- **Root cause**
  - `Constrain.zig:613-622` unifies each element with the contextual element type (`:618`) and tags
    every element `list_entry` (`:620`).
  - `categoryLines` (`Diagnostics.zig:380-384`).
- **Fixture** `check/bad/ListElementFromContext.beni`. `.codes`: `type_mismatch` lacks "previous
  elements".
  - *R0, as written:* the code is `kind_mismatch` (`number` against `String`; its title is TYPE
    MISMATCH), at both lists.
- **Slice** R13.
- **Status** fixed by R13 (2026-09-27), `checker.md` §8.7 first: category `list_entry` at index 1 reads *"The 1st element of this list is not what the list needs"* / *"But this list needs its elements to be:"*. Promoted: `tests/corpus/check/bad/ListElementFromContext.beni` (with CK-50's conversion hint).

### CK-50 — The arithmetic hint appears on any String-vs-number mismatch

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** orch F9; adv E1. Also visible in CK-31 and CK-29's observed output.
- **Program** `[ 1, 2, "three" ]`, `add 1 "two"`, `Node.printLines [ 1 ]`.
- **Observed** "Hint: `+`, `-`, `*` and `/` work on numbers only. To join text use `++`." where
  there is no arithmetic. It displaces `leftToRightHint` for lists.
- **Expected** The hint only when an arithmetic operator's operand is the mismatch.
- **Root cause** `kindNotSatisfied`'s `.number` arm (`Diagnostics.zig:785-791`) and `typeHint`
  (`:516-525`).
- **Fixture** `check/bad/NoArithmeticHintWithoutArithmetic.beni`. `.codes`: lacks "work on numbers
  only".
  - *R0, as written:* `type_mismatch` ×2 (the list, `add 1 "two"`) and `kind_mismatch` (a `[ 1 ]`
    passed as `List String`), each lacking "work on numbers only".
- **Slice** R13.
- **Status** fixed by R13 (2026-09-27), `checker.md` §8 *amended by R13* and §8.7: the numbers-only hint only for an operand of `+ - * / // ^`; elsewhere Elm's conversion in the value's direction. Promoted: `tests/corpus/check/bad/NoArithmeticHintWithoutArithmetic.beni`; 25 other `.diag` goldens re-blessed for the hint (`SchemaRecursivePayloadMismatch` also for CK-49's sentence).

### CK-51 — `?` says "this is neither" about a `Maybe` or a `Result`

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E2 (`t1`, `t2`, `t5`, `t6`).
- **Program** `f : Maybe Int -> Result String Int; f m = Ok (m? + 1)`, and `Result Int Int` inside a
  `Result String Int` function.
- **Observed** "`?` needs a `Result` or a `Maybe`, and this is neither: `Maybe Int`".
- **Expected** Say which of the three unifications failed: the enclosing return shape, or the error
  types.
- **Root cause** `tryShapeOnce` (`Solve.zig:1869-1888`) returns only a bool, and `tryShape` always
  prints "neither" (`Diagnostics.zig:1613`).
- **Fixture** `check/bad/TryShapeNamesTheMismatch.beni`. `.codes`: `try_shape` ×2 lacks "neither".
  - *R0 follow-up (review S4):* the first line also has `contains "Result String Int" contains
    "Maybe Int"` (§8.6: the enclosing return shape) and the second `contains "error types"`.
- **Slice** R5, with CK-06.
- **Status** claimed by R5 (2026-09-25): `checker.md` §8.6's three legs (`neither`, `enclosing`, `errors`), specified before the code. The fixture is GREEN under `--checker=v2` and in `CLAIMED`; `tests/corpus/check/bad/TryMixedShapes.beni`, whose v1 golden pins "neither" about a `Maybe Int`, is an expected difference (`v2-expected.md`).

### CK-52 — The "module-rule clash" hint appears where there is no clash

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E3 (`c4`, `c5`, `w9c`, `rt3`, `mc2`, `u5`).
- **Program** `pub type Mod = Mod Int`, `pub eq : Mod, Int -> Bool`, `Mod 1 == Mod 2`.
- **Observed** "Hint: this is the module-rule clash of … §11. Move one of the types into a module of
  its own". The module declares one type.
- **Expected** The hint only when the module declares two or more types and the method's first
  parameter names a different one.
- **Root cause** `methodSignatureMismatch` (`Diagnostics.zig:1068-1078`) prints it unconditionally.
  Its callers are `Solve.zig:3262` and `:3311`.
- **Fixture** `check/bad/MethodSignatureNoClash.beni`. `.codes`: `type_mismatch` lacks "module-rule
  clash".
- **Slice** R13.
- **Status** fixed by R13 (2026-09-27), `static-dispatch-spike.md` §10.13 first: the clash paragraph and hint only when the method's first parameter is another type its module declares (`DispatchTexts.clashes`). Promoted: `tests/corpus/check/bad/MethodSignatureNoClash.beni`; `RequirementMethodWrongType/` re-blessed (its `K` declares one type).

### CK-53 — The missing-constraint hint suggests `where` on a `let` annotation, which the grammar forbids

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E4 (`v4`, `v5`).
- **Program** `let g : a, a -> Bool; g p q = p == q in …`.
- **Observed** "Hint: add it to the annotation: `where a.eq : a, a -> Bool`". Writing that is
  UNEXPECTED TOKEN.
- **Expected** For a `let` annotation, suggest lifting the helper to the top level with the `where`,
  or dropping the annotation.
- **Root cause** `missingWhereConstraint` (`Diagnostics.zig:1216`) is never told the rigid belongs to
  a `let` annotation.
- **Fixture** `check/bad/MissingWhereInLetAnnotation.beni`. `.codes`: `missing_where_constraint`
  lacks "add it to the annotation".
- **Slice** R13.
- **Status** fixed by R13 (2026-09-27), `static-dispatch-spike.md` §10.4 *amended by R13* first: for a variable of a `let` annotation (`Generalize.Annotated.let`), the hint says to move the binding to the top level with the `where`, or to drop the annotation. Promoted: `tests/corpus/check/bad/MissingWhereInLetAnnotation.beni`.

### CK-54 — `==` on an open record suggests a field call

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E5 (`r8`, `r9`, `r10`).
- **Program** `same : { r | x : Int }, { r | x : Int } -> Bool; same p q = p == q`.
- **Observed** NO METHODS HERE with "Hint: write `(x.eq) a` to call the field `eq`".
- **Expected** Say the record is open (A.28) and that only a closed record derives. The field-call
  hint only for a dot-call origin.
- **Root cause** `Solve.zig:3124` → `noMethodsOnShape` (`:3087-3099`). The reporter's `.record` text
  (`Diagnostics.zig:1155-1168`) ignores the origin.
- **Fixture** `check/bad/OpenRecordEquality.beni`. `.codes`: `no_methods_on_shape` lacks "(x.eq)",
  contains "open".
- **Slice** R13.
- **Status** fixed by R13 (2026-09-27), `static-dispatch-spike.md` §10.3 *amended by R13* first: `open_record` says the record is open and only a closed one derives; the field-call hint only for a dot-call's requirement (`record` against `record_required`). Promoted: `tests/corpus/check/bad/OpenRecordEquality.beni`.

### CK-55 — A `where`-clause mismatch never names the clause or the method, and its roles read backwards

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E6 (`w9d`, `w9e`, `u5`).
- **Program** `f : a, a -> Int where a.compare : a, a -> Int`, called at `Int`.
- **Observed** "Something is off here: This is: `Int, Int -> Int` But I need: `Int, Int -> Order`",
  at the argument.
- **Expected** "`f`'s `where a.compare : a, a -> Int` does not match `Int`'s `compare : Int, Int ->
  Order`", at the call.
- **Root cause** `unifyMethodType` (`Solve.zig:1417-1430`) unifies with category `.general`
  (`:1429`).
- **Fixture** `check/bad/WhereClauseMismatchNamesClause.beni`. `.codes`: contains "where a.compare".
- **Slice** R6 (the category), R13 (the text).
- **Status** text fixed by R13 (2026-09-27), `static-dispatch-spike.md` §10.13 first: *"The `where a.compare` clause of `f` does not match the `compare` of `Int`"*, the clause's type against the method's, and a hint. The clause's variable rides on the wanted (`Evidence.Wanted.receiver_name`), the clause on `Reporter.clause` around the one unification. Promoted: `tests/corpus/check/bad/WhereClauseMismatchNamesClause.beni`; `WhereClauseNumberReceiver` and `NumberBridgeRigidLyingWhere` re-blessed.

### CK-56 — A curried Elm annotation gets a confusing message, and swapped arguments get no hint

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E7 (`eq3`, `eq2`).
- **Programs**
  - `add : Int -> Int -> Int; add a b = a + b`, called as `add 1 2`.
  - `List.map String.fromInt [ 1, 2 ]`.
- **Observed**
  - The body is printed as `a, b -> c`, pointing at the `+`, followed by a TOO MANY ARGS cascade.
  - For the swap: "this is a function, so it may be missing an argument".
- **Expected**
  - A hint showing `Int, Int -> Int`. The failed annotation is poisoned so there is no cascade.
  - For the swap, a hint that core is subject-first.
- **Root cause**
  - `typeHint`'s arity arm (`Diagnostics.zig:461-467`).
  - The annotation is not poisoned (`Constrain.zig:1297-1299`), so `Solve.zig:1321-1331` cascades.
  - There is no swap detection (`Diagnostics.zig:537-543`).
- **Fixture** `check/bad/CurriedAnnotation.beni` (`.codes`: exactly 1 diagnostic, contains
  "Int, Int -> Int") and `check/bad/SubjectFirstSwap.beni` (contains "subject").
  - *R0, as written:* `CurriedAnnotation`'s position is `*`. 7427828 points at the `+`. The
    finding is the hint and the cascade, so R13 picks the region.
  - *R0 follow-up:* the position is now `11:*`, the body line, where 7427828 and Elm both report
    it. The column is left open.
- **Slice** R13.
- **Status** fixed by R13 (2026-09-27), `checker.md` §8.7 first: the curried-annotation hint prints the n-ary form, and the scheme is poisoned when read (P2, and a `let` header: `TypeStore.isCurried`), so no TOO MANY ARGS follows; the subject-first hint reads the callee's declared parameters. Promoted: `tests/corpus/check/bad/CurriedAnnotation.beni`, `…/SubjectFirstSwap.beni`; `check/args/ArgumentOrderSwap` re-blessed.

### CK-57 — INFINITE TYPE prints `a  =  … a …`

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E10 (`g7`, `g10`, `oc1`–`oc4`).
- **Program** `f r = { r | x = r }`.
- **Observed** "Here is my best effort at writing it down: `a  =  … a …`".
- **Expected** The structure with the cycle marked, e.g. `a = { a | x : a }`, as Elm does.
- **Root cause**
  - `infiniteType` (`Diagnostics.zig:807-823`) prints a literal (`:820`) and takes no type.
  - Its callers blank the variable to `err` first (`Solve.zig:735-737`, `4732-4734`) or pass
    `.none` (`:1996`).
- **Fixture** `check/bad/InfiniteTypeShowsStructure.beni`. `.codes`: `infinite_type` lacks "… a …".
  - *R0, as written:* position `*`. 7427828 reports at the body (8:5), and §8.2 reports at a
    binder: `f` or `r`, by binder order.
  - *R0 follow-up:* the position is now `7:*`, since both binders are on line 7. As a result,
    7427828's first mismatch is now the position (`why=position`), ahead of the message.
- **Slice** R4. The occurs walk returns the cycle path and it is rendered before poisoning.

### CK-58 — The constraint-cap message lists method names without their receivers

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E12 (`cap`).
- **Observed** "The first 5 are `eq`, `eq`, `eq`, `eq` and `eq`".
- **Expected** `a1.eq`, `a2.eq`, ….
- **Root cause** `capPromotion` keeps only the name (`Solve.zig:4957`) and drops the receiver
  (`:4947`). The message is built at `Diagnostics.zig:1355-1358`.
- **Fixture** existing `abuse_test.zig` cap scenario plus a pending
  `check/bad/CapNamesReceivers.beni` (70 parameters). `.codes`: contains "`a1.eq`".
  - *R0, as written:* `contains ".eq`" lacks "`eq`, `eq`"`. The receivers might be named by type
    variable (`a.eq`) or by parameter (`a1.eq`). That choice is R13's text, so the line pins only
    that each constraint carries a receiver.
- **Slice** R13.
- **Status** fixed by R13 (2026-09-27), `static-dispatch-spike.md` §10.11 *amended by R13* first: `a.eq`, `b.eq`, … named by one namer in canonical order. Promoted: `tests/corpus/check/bad/CapNamesReceivers.beni`; `TooManyInferredConstraints` re-blessed (`a.m01` …).

### CK-59 — A missing-field message loses the literal's field types, and says "a `extra`"

- **Severity** diagnostic-quality. **Class** K13.
- **Sources** adv E13 (`k6`).
- **Program** `M.describe { name = "z", n = 3 }` against `R = { name : String, n : Int, extra : Bool
  }`.
- **Observed** "This record does not have a `extra` field: `{ n : a, name : b }`".
- **Expected** `{ n : number, name : String }` and "an `extra` field".
- **Root cause**
  - The literal is unified with the expected type (`Constrain.zig:637`) before its fields are
    constrained (`:638-642`).
  - The article is fixed at `Diagnostics.zig:1876`.
- **Fixture** `check/bad/MissingFieldShowsLiteralTypes/`. `.codes`: contains "name : String",
  "an `extra`".
  - *R0, as written:* contains "{ n : number, name : String }". The expected record's own
    rendering already contains "name : String", so that substring alone passed on 7427828.
- **Slice** R5 (generation order), R13 (article).
- **Status** the generation-order half done by R5 (2026-09-25), as amended (`checker-v2.md` §6.5 *Amended by R5*): the solver constrains a literal's fields first exactly when the expectation cannot take its field names, so the message shows `{ n : number, name : String }`. The fixture stays RED under v2 for the article ("a `extra`"), R13's; its `RED` line is unchanged (`why=message`).
- **Status** the article fixed by R13 (2026-09-27), `checker.md` §8.7 first (`Diagnostics.article`, the vowel-letter rule, in the four "a `{s}`" sentences). Promoted: `tests/corpus/check/bad/MissingFieldShowsLiteralTypes/`; `FieldErrorTextOrder` re-blessed.

### CK-60 — A cons pattern inside a constructor renders with redundant parentheses

- **Severity** diagnostic-quality, **suspected** (orch could not check Elm's rendering). **Class**
  K13.
- **Sources** orch F9.
- **Observed** `Group ((Circle _) :: _)`.
- **Expected** `Group (Circle _ :: _)`.
- **Root cause** not isolated. It is in `Exhaustive`'s pattern renderer.
- **Fixture** `check/bad/MissingPatternConsRendering.beni`. `.codes`: `missing_patterns` contains
  "Group (Circle _ :: _)".
  - *R0:* confirmed, no longer suspected. Elm's `patternToDoc` prints a cons head in the `Head`
    context, which adds no parentheses (`references/elm/compiler/src/Reporting/Error/Pattern.hs`,
    lines 139-165).
- **Slice** R13.
- **Status** fixed by R13 (2026-09-27), `checker.md` §8.7 first: a constructor pattern is parenthesised only in argument position (`Render.writePat`). Promoted: `tests/corpus/check/bad/MissingPatternConsRendering.beni`.

### CK-61 — `checker.md` §6.6 says exhaustiveness runs "over the *solved* types", and it deliberately reads none

- **Severity** latent (contract drift). **Class** K15.
- **Sources** orch ("contract drift").
- **Fix** Correct the sentence to the per-declaration gate that `Exhaustive.zig`'s header argues
  for.
- **Fixture** none.
- **Slice** R2 (spec edits).
- **Status** fixed by R2a (2026-09-24): `checker.md` §6.6 now says the algorithm runs over the
  patterns alone, only in a declaration that produced no type error, and that the solved types are
  that gate's precondition and are not read — the argument `Exhaustive.zig`'s header makes.

---

## J. From the design reviews' counterexamples (added 2026-09-24)

These are the programs that the two design reviews of `checker-v2.md` used as counterexamples, and
that `7427828` gets wrong. Each was run on `B` for this catalogue (**plan**). The reviewers wrote
some of them with a nullary dot-call such as `(Box x).size`, which is a *field access* in beni
(`static-dispatch-spike.md` §11), so v1 refused them correctly. They are written here with a unit
argument, `.size ()`, which is the valid program the reviewer meant. The source files are in the
session scratchpad under `ck/r2/<name>/`, and R0 or the owning slice copies them into the fixture.

### CK-62 — A `?` is decided as `Result` before a later fact says `Maybe`

- **Severity** valid-program-rejected. **Class** K2. **Sources** design review round 1 B3
  (`b3ready`), round 2 N2 (`n2try`). The same family as CK-06.
- **Programs**:

  ```elm
  h m = let v = m? in if m == m then Just (v + 1) else Nothing

  f h = let g u = h (u?) in ( g (Just 1), Maybe.withDefault (h 5) 0 )
  ```

  `main` prints `h (Just 1)`, `h Nothing` and `f (\n -> Just (n + 1))`.
- **Observed** TYPE MISMATCH `Maybe a` vs `Result b c`, exit 1.
- **Expected** `Just 2`, `Nothing`, then the pair `Just 2` and `6`. Spec: D2 as amended
  (`checker-v2.md` §8.1, §8.6).
- **Root cause** as CK-06 (`tryShape`, `Solve.zig:1802`).
- **Fixture** `run/TryDecidedByLaterFacts.beni`.
- **Slice** R5.
- **Status** claimed by R5 (2026-09-25) through two dispatch-free fixtures, both GREEN under `--checker=v2` and in `CLAIMED`: `run/TryEscapesToLaterFact.beni` (this entry's `f`, round 2's `n2try`, and `h` with `List.isEmpty [ m ]` for the fact after `m?`) and `run/TryEscapeLowersOnlyItsOwn.beni` (round 3's N-3). `run/TryDecidedByLaterFacts.beni` itself compares with `==`, so it stays RED under v2 as `not_implemented` until R6a claims it.

### CK-63 — An own untyped method used inside a `let` or a `case` before its definition is refused

- **Severity** valid-program-rejected. **Class** K6. **Sources** round 1 B6 (`b6boxU`,
  `b6letann`), round 2 N3 (`n3box`). The same family as CK-36.
- **Programs**. `type Box a = Box a`, `type K = K Int`, all in one module:
  - `f u = let g x = (Box x).size () in ( g 1, g "s" )`, with `pub size (Box _) u = 1` written after
    `f`;
  - the same with `g : a -> Int` annotated;
  - `f u = case (K u).makeBox () of o -> let g h = o.map2 h in ( g (\x -> x + 1), g String.fromInt )`,
    with `pub makeBox (K n) u = Box n` and `pub map2 (Box v) fn = Box (fn v)` written after it.
- **Observed** METHOD NEEDS AN ANNOTATION on each, exit 1.
- **Control** Written with the methods first (`b6boxU2`, `n3boxR`), v1 accepts them, printing
  `{ a = 1, b = 1 }` and `{ a = Box 4, b = Box "3" }` for `f 3`.
- **Expected** Each checks and prints what its reordered twin prints. Spec: D3, and `checker-v2.md`
  §10.2 (nesting at demand).
- **Root cause** as CK-36 (priority groups, `Check.zig:1254-1308`; refusal at `Solve.zig:698`).
- **Fixture** `run/OwnMethodDemandedEarly.beni`.
- **Slice** R7.
- **Status** claimed by R7 (2026-09-26): `run/OwnMethodDemandedEarly` and the new `run/OwnMethodDemandedTwoLetsDeep` (a group nested three frames up, its `dump --stage=types` equal in every order), both in `scenario/PERM`.

### CK-64 — An own untyped method whose body calls a helper written after its user is refused

- **Severity** valid-program-rejected. **Class** K6. **Sources** round 1 B7 (`b7prefix`).
- **Program**:

  ```elm
  type T = T Int
  use a b = T a == T b
  eq (T x) (T y) = helper x y
  helper x y = modBy x 10 == modBy y 10
  ```

  `main` prints `use 1 11` and `use 1 2`.
- **Observed** METHOD NEEDS AN ANNOTATION at `use`, exit 1.
- **Control** In the order `eq`, `helper`, `use` (`b7R`), v1 prints `true`, `false`.
- **Expected** The same as the control. Spec: D3, `checker-v2.md` §10.2 ("nest on first
  reference").
- **Root cause** as CK-36.
- **Fixture** `run/OwnMethodValuePrefix.beni`.
- **Slice** R7.
- **Status** claimed by R7 (2026-09-26): a nested group's value reference to an unchecked group is a `demand` node that nests it (§10.8); `run/OwnMethodValuePrefix`, in `scenario/PERM`.

### CK-65 — Methods that are mutually recursive through dispatch are refused in every order

- **Severity** valid-program-rejected. **Class** K6. **Sources** round 2 N4 (`n4ambm`, `n4R`) and
  N5 (`n5sw`, `n5R`).
- **Programs**. `type K = K Int`, `type Box a = Box a`:
  - `pub am (K n) u = Maybe.withDefault ((Box (Just n)).bm (\v -> Just v)) 0`, and
    `pub bm (Box m) fn = let _ = \w -> (K 0).am () in fn (m?)`;
  - `pub size (Box _) u = let _ = \w -> (K 0).weight () in 1`, and
    `pub weight (K n) u = let g x y = ( (Box x).size (), y ) in ( g 1 "a", g 2 3 )`.
- **Observed** METHOD NEEDS AN ANNOTATION in both declaration orders, and for `n4R` also a TYPE
  MISMATCH.
- **Expected**
  - `am (K 4) ()` is `4`.
  - `weight (K 1) ()` is the pair of pairs `( 1, "a" )` and `( 1, 3 )`: `g` is generalised in `y`.
  - Spec: D11 as amended (`checker-v2.md` §10.4: only top-level frames merge; a merged frame does
    not default).
- **Root cause** as CK-36.
- **Fixture** `run/MutualDispatchMethods.beni`.
- **Slice** R7.
- **Status** claimed by R7 (2026-09-26): merges on dispatch and value back-edges (§10.4, §10.8); `run/MutualDispatchMethods` and the new `run/OwnMethodThreeCycle`, `run/OwnMethodFourCycle`, `run/OwnMethodCycleDemandedTwice`, `run/OwnMethodValueBackEdge` and `check/good/NestAfterDefault`, all in `scenario/PERM`.

### CK-66 — A variable a binding group quantifies but a caller's type does not mention

- **Severity** valid-program-rejected, currently through CK-09. Without CK-09 it is an internal error
  (round 2 N7). **Class** K4. **Sources** round 2 N7 (`n7grp`).
- **Program**:

  ```elm
  f u = if u == 0 then 1 else if g [] then 1 else 0
  g xs = case xs of
      [] -> f 0 == 1
      a :: _ -> a == a
  ```

  `main` prints `f 1` and `g [ 1 ]`.
- **Observed** TYPE MISMATCH `number -> a` vs `List b -> Bool` at `g`: CK-09's local mix-up.
- **Expected** `1`, `True`. `f`'s call `g []` passes the `undetermined` leaf for `a.eq`
  (`checker-v2.md` §12.3 case 3).
- **Root cause** CK-09 first. Then v1's group-call sites (CK-30), and the round-1 design's §12.3.
- **Fixture** `run/GroupVariableOutsideCaller.beni`.
- **Slice** R7.
- **Status** R7 (2026-09-26), its demand half: `run/GroupVariableOutsideCaller` (R6b's claim) holds in every order in `scenario/PERM` (`ck66`).

### CK-67 — A closed wrapper around an imported method that needs an own untyped method is not comparable

- **Severity** valid-program-rejected. **Class** K7. **Sources** round 2 S-new-1 (`s1n`, `s1n2`).
- **Program**. `H.beni` has `pub type Holder a = Holder a` and
  `pub eq : Holder a, Holder a -> Bool where a.key : a, () -> Int`. `Main.beni` has:

  ```elm
  pub type T = T Int
  pub type W = W (H.Holder T)
  pub key (T x) u = x                     -- unannotated
  same a b = W (H.Holder (T a)) == W (H.Holder (T b))
  ```

  In the variant `s1n2`, `key`'s own body compares `W` values, so `key` is in flight when `W`'s
  context is asked for.
- **Observed** NOT EQUATABLE `W`, exit 1, in both variants.
- **Expected** `same 1 1` is `True` and `same 1 2` is `False`. `W` is closed, so its context is
  empty whatever `key` infers (`checker-v2.md` §11.2).
- **Root cause** the capability walk (CK-26 class) decides before `key`'s scheme exists.
- **Fixture** `run/DerivedContextClosedOwnMethod/`.
- **Slice** R8.
- **Status** R8a (2026-09-26): the closed in-flight branch (§11.2) answers both variants in every declaration order (`scenario/PERM`: `ck67`, `ck67-nested`, `ck67-permuted`).

### CK-68 — `tuple_index` on an outer variable is refused with the wrong code

- **Severity** diagnostic-quality on v1: it refuses, soundly. It is a regression guard for the
  round-1 design, which would have compiled it and run `String.length` on a number (round 2 N1).
  **Class** K2. **Sources** round 2 N1 (`n1tup`).
- **Program**:

  ```elm
  snd : ( Int, Int ) -> Int
  snd ( _, b ) = b
  f p = let a = p.0 in ( a + snd p, String.length a )
  ```
- **Observed** AMBIGUOUS TUPLE at `p.0`.
- **Expected** `type_mismatch`: `a` is an `Int`. It is decided once CK-05's escape rule lets the
  obligation reach `f`'s boundary. Spec: `checker-v2.md` §4.5.
- **Fixture** `check/bad/TupleIndexOuterResult.beni`. `.codes`: one `type_mismatch`, at `a` in
  `String.length a`.
- **Slice** R5.
- **Status** claimed by R5 (2026-09-25; v1 is frozen): `p.0`'s result shares `p`'s rank (`checker-v2.md` §4.5 *As built by R5*), so `a` is not generalised, `snd p` decides it as `Int` and `String.length a` is the `type_mismatch`. The fixture is GREEN under `--checker=v2` and in `CLAIMED`.

### CK-69 — A parametric derived context that depends on an in-flight method gets the wrong refusal

- **Severity** diagnostic-quality. **Class** K7. **Sources** round 2 S-new-1 (`s1p`).
- **Program** `H` as in CK-67, and:

  ```elm
  pub type T a = T a
  pub type W a = W (H.Holder (T a))
  pub key (T x) u = if W (H.Holder (T x)) == W (H.Holder (T x)) then 0 else 1
  ```
- **Observed** NOT EQUATABLE `W a`.
- **Expected** `method_needs_annotation` naming `key`, in both declaration orders (D3 as amended,
  `checker-v2.md` §11.2).
- **Fixture** `check/bad/DerivedContextNeedsAnnotation/`. `.codes`: one `method_needs_annotation`,
  containing "`key`".
  - *R0, as written:* at `Main.beni:14:27`, the `==` that needs `W`'s context. That is where every
    `method_needs_annotation` points on 7427828.
  - *R0 follow-up:* the other order has its own fixture,
    `check/bad/DerivedContextNeedsAnnotationKeyFirst/`. With a single value declaration, that
    means `key` written before the types `T` and `W`. `.codes`: `method_needs_annotation
    Main.beni:6:27`. On 7427828 it is `not_equatable` there.
- **Slice** R8.
- **Status** claimed by R8a (2026-09-26): `method_needs_annotation` naming `key` at the `==`, in both orders (`check/bad/DerivedContextNeedsAnnotation{,KeyFirst}`; `scenario/PERM` `ck69`).

### CK-70 — A method used at two types inside a dispatch cycle gets an order-dependent refusal

- **Severity** diagnostic-quality: v1 refuses, but with a code whose premise is order. **Class** K6.
  **Sources** round 1 S17 (`s17`).
- **Program** `pub show (K n) u` compares `Box 1 == Box 2` and `Box "x" == Box "y"`. The
  unannotated `pub eq (Box a) (Box b)` contains `\w -> (K 0).show ()`.
- **Observed** METHOD NEEDS AN ANNOTATION at `(K 0).show`.
- **Expected** In every declaration order, one `type_mismatch` at the second `Box` comparison, with
  the recursive-dispatch hint (`checker-v2.md` §10.6).
- **Fixture** `check/bad/RecursiveDispatchTwoTypes.beni`. `.codes`: one `type_mismatch`,
  containing "recursive through method calls".
  - *R0, as written:* position `*`, at the second `Box` comparison. Whether the region is the
    operator or an operand is R7's to bless.
  - *R0 follow-up:* the position is now `22:*`, the line of the second comparison.
  - The finding is order-dependence, so the other order has its own fixture,
    `check/bad/RecursiveDispatchTwoTypesB.beni` (`eq` first, `.codes` `28:*`). On 7427828 it is
    also `method_needs_annotation`, at 19:24.
- **Slice** R7.
- **Status** claimed by R7 (2026-09-26): one `type_mismatch` with the recursive-dispatch hint and the cycle `eq` → `show` → `eq`, byte-identical in every order (§10.8; `scenario/PERM` `ck70`); the annotated twin is the corpus guard `run/RecursiveDispatchAnnotated`.

### CK-71 — Symbol ids depend on which worker lexed which file, so an id-ordered choice varies between runs

- **Severity** nondeterminism. **Area** `Session` (outside the checker), seen through the checker.
  **Class** K12. **Sources** R0 (2026-09-24), found while writing CK-07's fixture.
- **Program** CK-07's catalogue form. `Aaa.beni` interns `qq`, `dd` and `bb` in a `let`, and
  `Main.beni` has `f g` failing on `pp` (inner `aa`) and `qq` (inner `bb`).
- **Command** `B check --no-cache --jobs=8 --diagnostics=json Aaa.beni Main.beni`, repeated.
- **Observed**
  - At `--jobs=8` on a loaded machine, 8 of 30 runs named `aa` and 22 named `bb`. With a
    spinning thread per core, 11 of 40 flipped. On an idle machine, 0 of 40 flipped: the race
    needs the scheduler to have a choice.
  - At `--jobs=1`, 10 of 10 named `bb`.
  - Same input, same flags, different diagnostics: a CLAUDE.md rule 5 violation.
- **Expected** Byte-identical output on every run at every `--jobs`. Spec: `fast-compiler.md` §10
  ("Ids are input-derived and assigned before any parallel work starts").
- **Root cause**
  - Each worker interns into its own `InternPool.Local`, and `Session.zig:577-590` merges the
    pools in **worker** order.
  - Which worker lexes which file is the `next_file` race, so a symbol's global id depends on
    thread timing.
  - Any choice made by symbol id inherits the race. CK-07's `unifyRecord` is the one found.
- **Fixture** `scenario/CK-71` in `tests/blackbox/pending_test.zig`: 100 runs at `--jobs=8`, under
  load (one spinning thread per core), must agree. It measured 6 of 40 and 81 of 100 differing
  on 7427828. A false GREEN has odds of about 1 in 10 million.
  - *R0 follow-up:* the scenario is **report-only on GREEN**. The race cannot be forced from
    outside the binary, so on a machine that never shows it, v1 would go GREEN and fail rule (b)
    by luck. When RED it is held to rule (d).
  - It is promoted by hand, in the slice that lands the interner fix, and not by rule (b).
- **Slice** **R1** (assigned 2026-09-24): shared-code fixes, outside the checker. The durable fix is to merge
  the per-worker interners in **file (path) order**, after lexing, or to intern per file and merge in
  path order, so a symbol's id is input-derived as `fast-compiler.md` §10 requires. CK-07's
  text-order rule (R4b) is still needed: ids stay unsuitable for any user-visible choice.
- **Status** fixed by R1 (2026-09-24): `Session.mergeInterners` walks the files in index order (tokens,
  then the Bir's symbols) and interns each symbol's text into the global pool on first sight; what no
  file references is merged after, by text. Two gate tests replace `scenario/CK-71`: the in-source
  "mergeInterners numbers symbols in file order, whichever worker lexed the file", which hands the
  files to the workers backwards on purpose and is red under the old worker-order merge, and
  `blackbox_test.zig`'s "diagnostics do not depend on which worker lexed which file, under load
  (CK-71)", 36 runs at `--jobs=8` with a spinning thread per logical CPU (41 of 49 differed with
  the fix stashed; the arithmetic is in the test). CK-07's text-order rule (R4b) is
  still owed: an input-derived id still moves with every edit to an earlier file.

## K. From design review round 3 (added 2026-09-24)

The programs were run on `B`. The sources are in the session scratchpad at `ck/r3/` (the reviewer's)
and `ck/r3x/` (this catalogue's).

### CK-72 — A method call on another group member's result: accepted, then two different internal errors

- **Severity** compiler-crash-or-hang. **Class** K4, with the order-dependence of K6. **Sources**
  round 3 B-3 (`sccA`, `sccB`).
- **Program**:

  ```elm
  type Box a = Box a
  pub combine (Box a) z = Box a
  f n = let r = g n
            q z = r.combine z
        in ( q 1, q "s" )
  g n = if n > 100 then Box n else let _ = f (n + 1) in Box n
  ```

  `sccB` is the same program with `g` written first.
- **Observed**
  - `check --platform=node` exits 0 in both orders.
  - `build`: `sccA` gives INTERNAL ERROR "I cannot tell what this call dispatches to", and `sccB`
    gives INTERNAL ERROR "The hidden arguments of this call do not add up".
- **Expected**
  - **D14** (`checker-v2.md` §10.7): in both orders, one `type_mismatch` at `q "s"`, with the hint to
    annotate `g`.
  - With `g : Int -> Box Int` annotated, both orders build and print `{ a = Box 1, b = Box 1 }`.
    v1 already does this.
- **Fixture** `check/bad/RecursiveGroupReceiverNeedsAnnotation.beni` and its reordered twin
  (`checker-rewrite.md` §5.4). The guard is `run/RecursiveGroupAnnotatedReceiver.beni`.
  - *R0, as written:* the twin is `…ReceiverNeedsAnnotationB.beni`. Both `.codes` are
    `type_mismatch * contains "Annotate `g`"`: the call `q "s"` or its argument is R7's to bless.
    On 7427828 both are red as `exit=0 first=none`.
  - *R0 follow-up:* the positions are now `31:*` and `36:*`, the `q "s"` line of each file.
  - The guard holds both orders in one file (`f`/`g` and `g2`/`f2`).
- **Slice** R7.
- **Status** claimed by R7 (2026-09-26): D14 (§10.7, §10.8) refuses both orders with one `kind_mismatch` (the `.codes` amended from `type_mismatch`: `q 1` then `q "s"`) and the hint "Annotate `g`", byte-identical in every order (`scenario/PERM` `ck72`).
- **Since R2a** (2026-09-24, review S1) `check` refuses this miscount with the I7 `internal` even
  in a declaration nothing reaches: `Lower` used to meet it only on code dead-code elimination
  kept, so such a program built and ran before R2a. Kept on purpose (`checker-v2.md` §13.1 as
  amended); pinned by `tests/corpus/run/DeadMiscount.beni`.

### CK-73 — An own method used in a `case` scrutinee before its definition is refused

- **Severity** valid-program-rejected. **Class** K6. **Sources** round 3 B-1 (`rq1`, twin `rq2`).
- **Program** `f n = case ( (\y -> y.h ()) (K n), (Box 1).g () ) of ( r, _ ) -> let q z =
  r.combine z in ( q 1, q "s" )`, with `pub g (Box a) u = 0`, `pub h (K m) u = Box m` and
  `pub combine (Box a) z = a` written after `f`.
- **Observed** METHOD NEEDS AN ANNOTATION at `y.h`.
- **Control** With the methods first (`rq2`), v1 prints `{ a = 3, b = 3 }` for `f 3`.
- **Expected**
  - The control's output, in both orders. This needs per-frame `ready` queues and eager draining
    (`checker-v2.md` §9.1).
  - The merge variant (`h`'s body also calls `(K 0).f ()`, with `f` made a method) must check in
    both orders, including a second `(Box "s").g ()`: `g`'s group is in no cycle and must not be
    merged. The merge variant was **not run** on v1, which already refuses the base form.
- **Fixture** `run/ScrutineeMethodLater.beni` and `check/good/ScrutineeMethodMergeVariant/`.
  - *R0, as written:* the merge variant is two modules. `Later` writes the methods after `f`, and
    `Sooner` writes them first. Each module's `f` is a method (`pub f (K n) u`), its scrutinee adds
    `(Box "s").g ()`, and `h` calls `(K 0).f ()`.
  - Run on 7427828:
    - `Later` is METHOD NEEDS AN ANNOTATION at `y.h` and at both `g` calls;
    - `Sooner` is METHOD NEEDS AN ANNOTATION at `(K 0).f` inside `h`, because `f` comes after it.
  - The `.iface` was written by reasoning, since no build shows it. The merged `f` and `h` are
    monomorphic, so each takes `()` from the other's call, while `g` stays generic:
    - `f : K, () -> ( Int, Int )`
    - `h : K, () -> Box Int`
    - `g : Box a, b -> number`
    - `combine : Box a, b -> a`

    R7 checks it against D11 before promoting.
  - **Corrected 2026-09-24 (planner): as written, the merge variant must be refused, not checked.**
    `f` and `h` merge (D11), and `r` is `h`'s in-flight result, a group-level receiver. So **D14**
    (`checker-v2.md` §10.7) lowers `r.combine z`, `q` is monomorphic, and `( q 1, q "s" )` is a
    `type_mismatch` with the hint "annotate `h`". That holds in both orders, because the merge is
    found at `f`'s scrutinee node, before the `let`, in both. The round-3 text predates D14.
  - **The fixture is replaced by two:**
    - `check/bad/ScrutineeMethodMergeD14/`: R0's `Later` and `Sooner` as they are. `.codes`: one
      `type_mismatch` at `q "s"` in each module, containing "annotate `h`".
    - `check/good/ScrutineeMethodMergeVariant/`: the same two modules with the `let q …` and
      `( q 1, q "s" )` replaced by `( 1, 2 )`, keeping `(Box 1).g ()` and `(Box "s").g ()` in the
      scrutinee. This is the part that tests "`g` is in no cycle and is not merged".

      Its `.iface` is R0's with `f`'s result changed to the pair's type, a pair of two `number`s
      written as the interface renders them, which R7 confirms when blessing. `g : Box a, b ->
      number` must stay generic in `a`.
    - R0's current `tests/corpus/check/good/ScrutineeMethodMergeVariant/` is therefore wrong, and
      is to be split as above. That is R7's first commit, or a follow-up touch by R0.
  - *R0 follow-up: done.* `check/bad/ScrutineeMethodMergeD14/` has `.codes` `type_mismatch
    Later.beni:29:* contains "Annotate `h`"` and the same at `Sooner.beni:33:*`. D14's hint
    capitalises "Annotate" (`checker-v2.md` §10.7). On 7427828 it is `method_needs_annotation` ×4
    plus `unknown_method`.
  - `check/good/ScrutineeMethodMergeVariant/` now matches `( _, _, _ ) -> ( 1, 2 )`, and its `.iface`
    has `f : K, () -> ( number, number2 )`.
- **Slice** R7.
- **Status** claimed by R7 (2026-09-26): `run/ScrutineeMethodLater`, `check/good/ScrutineeMethodMergeVariant` (its `.iface` confirmed) and `check/bad/ScrutineeMethodMergeD14` (`kind_mismatch`, "Annotate `h`"), all in `scenario/PERM`.

### CK-74 — A derived-context query made from inside the method it depends on

- **Severity** diagnostic-quality: the right verdict (refused), for the wrong reason. **Class** K7.
  **Sources** round 3 B-2 (`reentK`, `reentS`).
- **Program** as CK-67's `s1n2` (`key`'s body compares `W`s), plus `same` comparing `W`s, plus
  `other = (T 1).key "s"`. `reentS` writes `same` first.
- **Observed** NOT EQUATABLE `W`, in both orders.
- **Expected** In both orders, one `type_mismatch` at `"s"` in `other`, because `key : T, () -> Int`.
  The re-entrant query runs a fresh fixpoint (`checker-v2.md` §11.2).
- **Fixture** `check/bad/DerivedContextReentrant/` and its twin.
  - *R0, as written:* the twin is `check/bad/DerivedContextReentrantSameFirst/`. Both are
    `type_mismatch Main.beni:29:15`, at the `"s"`.
- **Slice** R8a.
- **Status** claimed by R8a (2026-09-26): one `type_mismatch` at `"s"` in both orders; the re-entrant query runs a fresh fixpoint, the first one's result is memoised only for its generation (`scenario/PERM` `ck74`).

## L. From the review of R0 (added 2026-09-24)

### CK-75 — Checking is super-linear in the number of declarations, with no dispatch at all

- **Severity** performance. **Area** the per-module pipeline, outside constrain and solve.
  **Class** K11. **Sources** the read-only review of R0 (S1), which found it under CK-42's
  scenario; and R0's own measurements under CK-41 and CK-42.
- **Program** n declarations, each a `type T{i} = T{i} Int` and an `f{i} : Int -> Bool` whose body
  is `x == x` on an `Int`. That is CK-42's program with the nominal `==` removed.
- **Command** `B check --no-cache --jobs=1` (Debug).
- **Observed**
  - 2.6 s at 5 000 and 7.6 s at 10 000, a ratio of about 2.9 (review of R0).
  - Independent `pub type`s alone take 458 / 1 126 / 3 370 ms at 2 000 / 4 000 / 8 000, even with
    CK-40's and CK-41's scratch fixes in (R0).
  - The self-profile puts the time in the module's `check` event, outside constrain and solve.
    `dep_digest` is super-linear too: 79 → 262 ms from 4 000 to 8 000 types.
- **Expected** Linear. Budget: `fast-compiler.md` §2.
- **Root cause** not isolated. The candidates are per-type work that scans all types or the store
  (the capability settling passes of CK-26, the deriver block orch F4 left at about 0.5 s of an
  8 000-type chain) and `dep_digest`.
- **Fixture** `scenario/CK-75` in `tests/blackbox/pending_test.zig`: the program at n = 5 000,
  ratio ≤ 2.5, best of 3. It is also the control CK-42's scenario subtracts.
- **Slice** R8a (manager, 2026-09-24): R8a replaces the capability settling passes, the first
  candidate. R8a's implementer isolates the cause with a profile first; if the residue is
  `dep_digest` or another interface cost, it moves to R10 and R8a records why.
- **Status** R8a (2026-09-26), profiled first: under v2 the module's `check` event is linear (44 / 87 ms at 6 000 / 12 000, ReleaseFast), `dep_digest` too small to show, so nothing moves to R10; a v2 twin is in `perf_test.zig`. The profile found `cache_store` super-linear under both checkers: CK-107.

## L. From design review round 4 (added 2026-09-24)

The probes are the reviewer's, in the session scratchpad at `ck/r4rev/`, and each was re-run on
`B` for this catalogue.

### CK-76 — Evidence and sub-wanteds on another group member's result: one order crashes, the other runs

- **Severity** compiler-crash-or-hang. **Class** K4, with K6's order-dependence. **Sources** round
  4 R7-1 (`evA`/`evB`, `subA`/`subB`). It is in CK-72's family.
- **Programs**, with `type K = K Int` and `pub mix (K n) b = K n`:
  - **`evA`/`evB`.** `useMix : a, b -> a where a.mix : a, b -> a` (`useMix x y = x.mix y`), and
    `f n = let r = g n; q z = useMix r z in ( q 1, q "s" )`, with
    `g n = if n > 100 then K n else let _ = f (n + 1) in K n`. `evA` writes `f` first, and `evB`
    writes `g` first.
  - **`subA`/`subB`.** `combine : Box a, b -> Box a where a.mix : a, b -> a`, and
    `q z = (Box r).combine z` in the same shape.
- **Observed**
  - `evA`, `subA`: INTERNAL ERROR ("hidden arguments … do not add up"), at `build`.
  - `evB` runs and prints `{ a = K 1, b = K 1 }`. `subB` runs and prints `{ a = Box K 1, b = Box K 1 }`.
- **Expected** D14 as restated in round 4 (`checker-v2.md` §10.7): in every order, one
  `type_mismatch` at `q "s"`, with the hint to annotate `g`. With `g` annotated, all four are
  accepted.
- **Fixture** `check/bad/RecursiveGroupEvidenceReceiver/` and `check/bad/RecursiveGroupSubWanted/`,
  each holding both orders as two modules. `.codes`: one `type_mismatch` per module, containing
  "annotate `g`" (`checker-rewrite.md` §5.6).
  - *R0, as written:* the modules are `FirstF` (`evA`/`subA`) and `FirstG` (`evB`/`subB`). `main`
    and the `Node` import are dropped, because `check/bad` runs without a platform.
  - The `.codes` lines are `FirstF.beni:31:*` and `FirstG.beni:35:*` for the evidence form, and
    `35:*` and `39:*` for the sub-wanted form, at the `( q 1, q "s" )` line. They contain
    "Annotate `g`", capitalised, as the hint is written in §10.7.
  - Red on 7427828 as `exit=0 codes=none`, because `check` accepts both orders. The INTERNAL
    ERROR is at `build`; I re-ran it for `evA` and `subA`, and `evB`/`subB` run as the Observed
    line says.
- **Slice** R7.
- **Status** claimed by R7 (2026-09-26): the hooks in `Resolve.step` and on obligations make evidence and sub-wanteds pessimistic; both fixtures refused in both orders, `kind_mismatch` with "Annotate `g`", byte-identical in every order (`scenario/PERM` `evA`, `subA`).
- **Since R2a** (2026-09-24, review S1) `check` refuses this miscount with the I7 `internal` even
  in a declaration nothing reaches: `Lower` used to meet it only on code dead-code elimination
  kept, so such a program built and ran before R2a. Kept on purpose (`checker-v2.md` §13.1 as
  amended); pinned by `tests/corpus/run/DeadMiscount.beni`.

### CK-77 — A derived context that reaches an in-flight method does not merge the asker

- **Severity** diagnostic-quality on v1, which refuses with the wrong reason. It guards against the
  round-3 design, which would have accepted the program in one order (round 4 R8-3). **Class** K7.
  **Sources** round 4 R8-3 (`cbA`/`cbB`). It is in CK-67's family.
- **Program** `H` has `pub eq : Holder a, Holder a -> Bool where a.key : a, () -> Int`. `Main` has
  `type T = T Int`, `type W = W (H.Holder T)`,
  `pick x = let _ = W (H.Holder (T 1)) == W (H.Holder (T 2)) in x`, and
  `pub key (T n) u = let _ = ( pick 1, pick "s" ) in n`. `cbA` writes `pick` first, and `cbB` writes
  `key` first.
- **Observed** NOT EQUATABLE `W`, in both orders.
- **Expected** In both orders, one `type_mismatch` at `pick "s"`: `pick` and `key` merge through the
  closed in-flight branch's ordinary wanted (`checker-v2.md` §11.2). Annotating `pick` or `key`
  lifts it.
- **Fixture** `check/bad/DerivedContextMergesAsker/` (two modules, one per order). `.codes`: one
  `type_mismatch` per module, at `pick "s"`.
  - *R0, as written:* the modules are `H`, `PickFirst` (`cbA`) and `KeyFirst` (`cbB`), with no
    `main`. The `.codes` lines are `KeyFirst.beni:16:*` and `PickFirst.beni:24:*`, on the
    `pick "s"` line; whether the region is the call or its argument is R8a's to bless.
  - Red on 7427828 as `exit=1 codes=not_equatable×2 why=code`: one NOT EQUATABLE `W` per module,
    as the Observed line says.
  - The v1-green guard of §5.6, `tests/corpus/check/bad/DerivedCrossMethodCycle/` (`xm` as
    `EqFirst`, `xm2` as `CompareFirst`), is written with its `.diag` blessed from 7427828. It has
    `not_equatable` and `no_methods_on_shape` in each module, at 15:7 and 19:7.
- **Slice** R8a.
- **Status** claimed by R8a (2026-09-26): `pick` and `key` merge through the replayed wanted in both orders. The `.codes` were blessed as `kind_mismatch` at `"s"` (a number literal's kind meeting `String`, v1's rule, as R7 amended CK-72's), not R0's `type_mismatch`.

## L. Found by R1 and its review (2026-09-24)

### CK-78 — A record alias's constructor as a pattern: supported, by decision

- **Severity** none today — a decision recorded, not a defect. **Area** JS lowering. **Class** K14.
  **Sources** R1, while giving the record-alias constructor its record representation (CK-43, D12);
  R1's review (S3).
- **Program**:

  ```elm
  type alias User = { name : String, age : Int }

  nameOf : User -> String
  nameOf (User n _) = n
  ```

  Also `let (User m _) = …` and `case u of User n a -> …`.
- **History**
  - `check` accepts the pattern: it resolves to the alias's implicit constructor and types as the
    record. Elm has no such pattern.
  - On 7427828 it ran, because the constructor built a tagged object with `a`, `b` slots.
  - R1's first draft gave the constructor its record (D12) and refused the pattern at emit, since
    the record has no slots. That broke programs that ran.
- **Decision** (manager, 2026-09-24, rule 7): the pattern is irrefutable — the alias has one
  constructor — and no guarantee is at stake, so it is SUPPORTED, not refused. The earlier
  expectation "refused by `check`, as Elm does" is withdrawn.
- **Status** done by R1. Argument `i` reads the alias's field `i` in declaration order, with no
  test (`js/Lower.zig` `argName`, `Decision.Occ.via`; `backend.md` §4's row). The guard
  `tests/corpus/run/RecordAliasConstructorPattern.beni` covers a parameter, a `let` pattern, a
  `case` branch, one nested under `Just` and one under `as`, with `name` declared before `age` so
  a positional read would swap them. It prints the same on 22daa5f. An IMPORTED alias's
  constructor is still `not_implemented` at emit until interface v3 carries its field names
  (CK-39, R3).
- **Slice** R1.

### CK-79 — Derived `==` and `compare` on a record are capped at 4 096 fields

- **Severity** valid-program-rejected, with a message that says why. **Area** derivation's calling
  convention. **Class** K10 (a representation width). **Sources** R1; R1's review (S1).
- **Program** `r = { f1 = 1, …, f4097 = 1 }`, then `r == r` (or `r < r`).
- **Command** build+run.
- **Observed**
  - On 7427828 every record over 256 fields was refused, as "There is a function in there": the
    worklist overflowed (CK-17).
  - R1's growable walk first let every width through, which exposed two failures:
    - past 65 535 fields, derivation's `@intCast` into the `u16` evidence count (a panic in Debug);
    - under Node 24, a 60 000- and a 65 530-field `r == r` BUILT, exit 0, and then threw
      `RangeError: Maximum call stack size exceeded` at the derived call
      `Main$eq$r$…(ev1, …, ev60000, r, r)`. 40 000 ran.
  - R1 therefore caps a derived record `eq`/`compare` at `max_derived_record_fields` = 4 096
    (`check/Diagnostics.zig`). Past it the use is `not_equatable` (`==`) or `no_methods_on_shape`
    (`compare`), with a message naming the cap and suggesting `Basics.eq`, which is structural and
    has no width limit. Pinned by `abuse_test.zig` "== on a record runs up to the derived-field cap
    and is refused past it, never a runtime exception": 4 096 builds and runs; 4 097, 40 000,
    60 000 and 65 530 are refused before anything is written.
- **Why 4 096.** The engine's limit is not a constant. It depends on the stack depth at the call and
  on the engine: V8 threw between 40 000 and 60 000 here, and JavaScriptCore and SpiderMonkey
  (browser first) have their own limits. 4 096 is an order of magnitude under any of them.
- **Expected** No cap. Lifting it needs a derived record function that takes its evidence as ONE
  value (an array, or the record of evidence the checker-v2 evidence trees describe), not one
  parameter per field. That is a `backend.md` §9 / `static-dispatch-spike.md` §9 representation
  change, with `Dispatch.Derived.evidence_count: u16` widened or removed.
- **Fixture** the abuse scenario above. Its expectation changes with the fix.
- **Slice** R8a (manager, 2026-09-24, moved from R2a): the cap exists because a derived record function takes one evidence parameter per field. D4 (R8a) already changes the derived-function signature to one parameter per context entry; packing the evidence belongs to that change, so it is done once, not twice.
- **Status** R8a (2026-09-26), claimed under v2: the verdict has no field cap (`scenario/CK-79`: 40 000 fields, `==` and `<` built and run under v2; red under v1, whose abuse test pinned the refusal). Promoted at R11 into `abuse_wide_test.zig`, whose record `==` scenario now builds and runs at 4 096, 4 097 and 65 530 fields.
- **Note** (R2a stage 2, 2026-09-24, for the manager): the one-value representation the Expected line
  asks for now exists past 4 096 positions — `static-dispatch-spike.md` §9.2's wide form, landed for
  CK-81 and reached today only through a nominal payload. What lifting the cap still needs is the
  checker half and the `u16` (CK-82). `checker-v2.md` §11.2 keeps structural shapes "one parameter
  per field" under D4, so D4 by itself does not remove the per-field list.

### CK-80 — `==` on a value whose type is a doubling DAG takes time exponential in its depth

- **Severity** performance. **Area** solve: the derived path. **Class** K11. **Sources** R1's
  review (N2). Present on 22daa5f and on R1; not an R1 regression.
- **Program** `f x = ( x, [ x ] )`, then `w = f (f (… (f 1)))` n deep, then `w == w`.
- **Command** check.
- **Observed** Debug build of R1: n=8 0.10 s, 10 0.11 s, 12 0.14 s, 14 0.24 s, 16 0.65 s,
  18 2.31 s. That is ×4 per two levels, and all of it is in `solve`. ReleaseFast (reviewer): 16/18/20
  take 0.06/0.19/0.65 s. `Basics.eq w w` is 0.01 s.
- **Expected** Linear in n. The type has n distinct pieces; only its unfolding as a tree is 2^n.
- **Root cause (suspected)** The derived path treats the DAG as a tree. `fillPart` fills evidence
  per position recursively, and `walkDerivable`'s nested walks at boundary types take fresh marks,
  which overwrite the outer walk's, so shared sub-DAGs are walked again.
- **Fixture** `scenario/CK-80` in `tests/blackbox/pending_test.zig`: time(n=18) / time(n=9) ≤ 2.5.
  It is red on R1 as `slow` (ratio about 21).
- **Slice** R6a (the resolver rewrite: `check`). *The `build` half* (R6b's reviews, structural N6 and
  adversarial F3: the emitted JavaScript grew ×4 every two levels, 487 KB at depth 12 and 144 MB at
  20, because `Lower` expanded each evidence term at every use) is fixed by R6b: P6 writes one term
  per distinct answer of a site (a DAG, `checker-v2.md` §13.1 as amended), and `Lower` binds a
  shared evidence closure to a `const` once. v2 timing twin `perf_test.zig` "CK-80 build" (depth 9 /
  18: 6 / 11 ms; 8 / 873 ms with the binding off).

### CK-81 — A derived `eq` over a nominal type with a very wide record payload crashes the printer

- **Severity** compiler-crash-or-hang. **Area** JS printing (`js/Print.zig`). **Class** K11.
  **Sources** R1, probing CK-79's cap. Present on 22daa5f.
- **Program** `type T = T { f1 : Int, …, f60000 : Int }`, `r` a 60 000-field record, and `T r == T r`
  in `main`.
- **Command** build.
- **Observed** Segmentation fault: `Print.raw` → `expression` → `raw` recurses once per `&&` of the
  derived body, which compares every field inline as one left-nested chain 60 000 deep. At 5 000
  fields it builds and prints `eq`. The CK-79 cap does not cover it, because the nominal type's body
  is derived by the eager pass, not by the record walk at the use.
- **Expected** It builds and runs, or a named refusal. A flat `&&` chain printed iteratively, or a
  loop over the fields, would do; so would the same 4 096 cap on a derived nominal body's width.
- **Fixture** `abuse_test.zig`: "derived eq and compare over a 60 000- and a 65 535-field nominal
  payload build and run, in both builds" and "a 200 000-element list literal is EMITTED without a
  stack overflow, in both builds" (both segfault on 7fd409e); "a written operator chain runs at the
  widest Node loads, and 100 000 terms are one nesting_too_deep" guards the user's path. In-source:
  `Print.zig`'s 200 000-link chain test.
- **Slice** R2a (manager, 2026-09-24): R2a already rewrites how `Lower` builds derived bodies, and the printer's per-`&&` recursion is the same shape; R2a makes `js/Print.zig` iterate over operator chains.
- **Status** fixed by R2a stage 2 (2026-09-24). Five walkers recursed once per link of a chain the
  compiler builds as long as its input is wide: a derived record `eq`'s `&&` (one per field; a
  derived `compare` is a flat statement list and never recursed), and a list literal's nested
  `{ $: 1, a, b }` (one per element, not charged by the parser, so a 200 000-element literal also
  segfaulted `build`). They were `Print.expression`/`raw`, and under `--release`
  `Opt.countExpr`, `planExpr`, `exprUses` and `Rename.collectExpr`. Past 256 levels the printer now
  switches from recursion to an explicit work stack (bytes identical: two in-source tests, one
  generated over every expression kind, print both ways and compare, and the printers' and
  `JsIr.pushOperands`'s switches list every tag, so a new one does not compile until all three
  handle it), and the four release walks pop operands from an explicit stack (`JsIr.pushOperands`); the only recursion
  left past the limit is an `arrow`'s block body. The stack for every expression cost the emit
  phase 3–8 %, hence the hybrid; as landed, emit is 52.23 ms against 52.21 on 7fd409e. `Lower` built the chain
  in a loop already, and `Reach` and `Edges` walk dispatch terms, not `JsIr`. Two more things stood
  between the fixed printer and a program that RUNS at 60 000 fields:
  - Node threw `RangeError` at the 60 002-argument call of the derived record function from inside
    `T$$eq` (it runs with `--stack-size=3000`), and V8 refuses a function of more than 65 535
    parameters outright. Past 4 096 evidence parameters a derived function now takes ONE array,
    `$m`, and every caller packs the same count into an array literal (`static-dispatch-spike.md`
    §9.2, *The wide form*, A.87; `Lower.packEvidence`), for every shape. 4 096 is the backend's own
    ABI constant; it equals CK-79's cap today, so no golden moved.
  - `Rename.verify`'s distinctness check was all-pairs over a declaration's locals: 46 s of a Debug
    `--release` build on the 65 535-field `compare` (65 535 `$o$<i>`). It checks that the ordinals
    increase along `order` instead, linear, 9 s.
  End to end on a Debug build: 60 000 and 65 535 fields build (about 9 s each, dev and `--release`)
  and print the five answers of `T r == T r`, `T r == T s`, `T s < T r`, `T r < T s` and
  `[ T r ] == [ T r ]` correctly. 65 536 and up panic the CHECKER before the backend runs (CK-82).
  Found on the way, outside the backend's recursion: CK-83 (Node rejects the nesting several
  accepted programs lower to). Red proof on the Debug harness binary (a ReleaseSafe 7fd409e builds
  the 60 000-field program without crashing).

### CK-82 — A nominal payload record wider than 65 535 fields panics the checker, compared or not

- **Severity** compiler-crash-or-hang. **Area** derivation's evidence count (`check/Solve.zig`).
  **Class** K10 (a representation width). **Sources** R2a stage 2, probing CK-81 at 200 000 fields.
  Present on 7fd409e.
- **Program** `type T = T { f1 : Int, …, f65536 : Int }` and nothing else (a `module … exposing
  (T(..))` header, no `==`, no `main`).
- **Command** check.
- **Observed** `panic: integer does not fit in destination type` at `Solve.derivedUse`'s
  `@intCast(positions.len)` into the `u16` evidence count, reached from
  `settleOrdinaryCapabilities` → `targetFor` → `recordTarget`: the eager pass probes every type's
  derived `eq`/`compare` whether or not anything compares it. A ReleaseFast build (measured by
  R2a stage 2's review at 65 536, 65 540 and 70 000 fields) does not crash: `check` alone exits 0
  at 65 536, and `build` exits 1 with a false NOT EQUATABLE on `T` plus NO METHODS HERE, so a
  shipping compiler rejects a valid program with a wrong message. CK-79's cap stops a record `==` at 4 096 before derivation, but a nominal
  payload is derived by the eager pass and never meets the cap (CK-81's route). At 65 535 fields the
  program checks, builds and runs (`abuse_test.zig`, CK-81).
- **Expected** It checks; and built, it runs, which the wide form of `static-dispatch-spike.md` §9.2
  already makes possible past 65 535 positions once the count fits. Or a named refusal at the use,
  never at a declaration nothing compares (rule 7).
- **Fixture** `pending_test.zig` scenario `CK-82` (65 536 fields, `T r == T r` built and run).
- **Slice** R8a (manager, 2026-09-24), with CK-79. R8a owns CK-79 and `Dispatch.Derived`'s context, where the `u16`
  lives.
- **Status** R8a (2026-09-26), claimed under v2: `Dispatch.ContextEntry.param` is a `u32` (dispatch format 4), and `scenario/CK-82` builds and runs under v2. R8a's review round moved the scenario to 65 537 fields, one past what a `u16` entry INDEX holds (CK-109).

### CK-83 — Programs the compiler accepts lower to JavaScript nested deeper than Node will load

- **Severity** unsound-runtime (a build that exits 0 and throws at load). **Area** JS lowering and
  the parser's depth budget. **Class** K14. **Sources** R2a stage 2, measuring CK-81's user path.
  Present on 7fd409e.
- **Program** any of: a list literal of 1 700 elements; `x + x + …` or `x ++ x ++ …` of 1 700
  terms; 2 000 nested calls `f (f (… 1))`.
- **Command** build+run.
- **Observed** `beni build` exits 0 and `node out/_main.mjs` throws `RangeError: Maximum call stack
  size exceeded` while V8 PARSES the module. The emitted JavaScript nests as deep as the source
  chain: a list literal is one `{ $: 1, a: x, b: { … } }` per element, `+` is
  `Basics$add(Basics$add(…))`, `++` is `Basics$append(x, Basics$append(…))`, and `&&` prints as
  `a && (b && (…))`. Node 24's parser gives out between 1 500 and 1 700 levels (measured: 1 500
  runs, 1 700 throws, for all three). The parser's budget (`Parse.max_depth`, 4 096 charges per
  declaration) sits above that for `+`/`++` and does not charge a list's elements at all, so a
  list literal of any length past about 1 700 builds and throws. `&&` over `x == 3` is refused by
  the budget at 1 366 terms first, and runs up to it. Deeper still, a 200 000-element list used to
  segfault the printer (CK-81); it now builds and throws the same `RangeError`.
- **Expected** Every program the compiler accepts loads (rule 7: the guarantee is no runtime
  exception). A list literal long enough to matter needs a flat form — built from an array, or in
  chunks — and a long operator chain a flat one (`&&`, `||` and `++`'s strings are associative;
  `Basics$add` chains could be bound to temporaries). Or a budget the engines can meet, which a
  list's elements would then have to count against.
- **Fixture** `pending_test.zig` scenario `CK-83` (a 2 000-element list literal and 2 000-term `+`
  and `++` chains, each built and run).
- **Slice** R2c (manager, 2026-09-24): a small backend slice after R2b, spec first in `backend.md` §4. It is a `backend.md` §4 representation question (the list
  literal's shape), not the checker's.
- **Status** fixed by R2c (2026-09-25), spec first: `backend.md` §4, *Emitted JavaScript nests only
  as deep as the source*, with the engines measured — Chrome 153, Firefox 144 and WebKit (WPE)
  headless, Node 24, the SpiderMonkey 140 shell and Bun 1.3.13 — and a second limit found:
  SpiderMonkey refuses a 252nd nested scope whatever its stack. A form the source writes flat is
  emitted flat: a list literal past 32 elements is one array whose cells `reduceRight` builds; `&&`
  and `||` chains are one run; `+`, `++`, `::`, pipelines and nested calls are bound to a `const`
  every `nesting.spill` units by `Lower.expr` (the hoist machinery `?` uses, so written order
  holds); `else if` chains of 16 `if`s or more, and `if`s nested in `then` branches, are flat in
  tail and expression position; evidence closures 20 deep are bound ahead of the call; a derived
  `&&` runs in groups of 1 024 for JavaScriptCore. What the source nests itself is measured per
  declaration and refused past 2 048 units or 128 scopes as `nesting_too_deep`, at least two and a
  half times under the scarcest browser: 119 nested functions run, 120 are refused (and a `view` of about 65 `List.map`s runs; see the review round in R2c's As built). Promoted: the
  scenario is `abuse_wide_test.zig` "CK-83: a 2 000-element list and 2 000-term + and ++ chains
  build and run"; the 4 000-nested-call abuse test runs now in both builds, as do the 200 000-element
  list and the widest operator chains the parser admits, and the blackbox evidence test of 1 024
  levels. Every existing `run/` and `emit/` golden is byte-identical. Found on the way: CK-87, CK-88.

### CK-84 — An imported constrained function whose type is written through an alias is read as a constant

- **Severity** unsound-runtime. **Area** evidence calling convention (backend). **Class** K4.
  **Sources** R2b, probing CK-33's cross-module route. Present on 84e3cb1.
- **Program**:

  ```elm
  -- M.beni
  pub type alias Pred a =
      a -> Bool

  pub same : Pred a
      where a.eq : a, a -> Bool
  same x =
      x == x

  -- Main.beni
  main = Node.printLines [ String.fromInt (List.length (List.filter [ 1, 2 ] M.same)) ]
  ```
- **Command** build+run.
- **Observed** Exit 0, then `TypeError: isGood$2 is not a function`. `M.same` in value position is
  lowered as `M$same(Main$eq$prim)`: `Lower.externalArity` read the interface scheme's body, found
  an `alias` term rather than a `func` one, and answered arity 0, so the eta-expansion degenerated
  into A.85's thunk read. Inside `M` the same value was right: its arity came from its parameter
  count (and `TypeStore.paramCount` looks through aliases).
- **Expected** `2`. The importer's arity is the exporter's.
- **Root cause** the fourth reading of CK-33's class: an importer's arity computed without looking
  through `alias`.
- **Fixture** `tests/corpus/run/ConstrainedAliasFunctionImported/` (`M.same`, a lambda-bodied
  `M.sameL` and a point-free `M.sameP`, used as values, partially applied and called, and a local
  `mine = M.sameP`) → `2`, `t`, `1`, `f`, `2`, `t`, `2`, `t`. Red on 84e3cb1 (the `TypeError`).
- **Slice** R2b.
- **Status** fixed by R2b (2026-09-24): `Convention.importArity` follows an `alias` term to its
  expansion; it is the only arity an importer reads.

### CK-85 — A constrained value with no parameters recomputes its body at every read or call

- **Severity** performance (latent: observable only through `Debug.log` and cost). **Area** evidence
  calling convention (backend). **Class** K4. **Sources** R2b's review, S1. Present since queue
  row 57 for thunks, and since R2b for function-typed values.
- **Program**:

  ```elm
  lookup : a -> a
      where a.eq : a, a -> Bool
  lookup =
      let
          table =
              Debug.log (List.range 1 3) "table"
      in
      \x -> …
  ```
- **Command** build+run.
- **Observed** Three calls of `lookup` print `table: [1,2,3]` three times; the same value without
  the `where` prints it once, at load. `lookup` is `applied` (`checker-v2.md` §12.5): defined
  `($m$0, $p$1) => { const table = …; return (…)($p$1); }`, so its body runs per call. A thunk
  (`blank : List a where …`) likewise runs per read, which inside a function body is per call.
- **Expected** Not a defect by the current spec (`language.md` §6 *Evaluation order* now says so),
  but a cost the language could avoid: a table, regex or `Dict` precomputed by such a value is
  rebuilt per use.
- **Proposal** hoisting once per CALL SITE (or per instantiation): where every evidence argument is
  a module-level name — the common case — emit `const Main$lookup$ev0 = Main$lookup$make(ev…)` at
  module level and call that. It needs a "make" entry point `($m…) => body` beside the flat one,
  and an importer cannot tell from the type whether the body is a lambda (where the two coincide),
  so the exporter would publish that bit in its interface. Memoising per evidence tuple is not
  possible in general: evidence arguments are closures with no stable key.
- **Fixture** `tests/corpus/run/EvidenceFunctionBodyPerCall.beni` pins today's count (three and
  one), so a change is deliberate.
- **Slice** R8a (owner, 2026-09-25): `language.md` promises a top-level value is computed once, and R8a already changes the derived-function signature. Its guard `run/EvidenceFunctionBodyPerCall.beni` changes deliberately there.
- **Status** fixed by R8a (2026-09-26), for both checkers (the emitter is shared), differently from the proposal: the value is kept per evidence in two module-level `let`s (`static-dispatch-spike.md` A.85 as amended by R8a; `language.md` §6). `run/EvidenceFunctionBodyPerCall` prints one `table (where)` line; `run/EvidenceThunkOncePerEvidence` shows the recompute on new evidence.

### CK-86 — The `exposing (T(..))` hint suggests `exposing (T, T)` when a constructor shares the type's name

- **Severity** diagnostic-quality. **Area** resolve diagnostics (`resolve/Diagnostics.zig`, CK-47's
  hint). **Class** K14. **Sources** R2b's review, N7. Present on 84e3cb1.
- **Program** `M`: `pub type Box = Box Int`; `Main`: `import M exposing (Box(..))`.
- **Command** check.
- **Observed** One `expected_token` whose hint is `exposing (Box, Box)`, and that suggestion is
  itself refused as DUPLICATE EXPOSED NAME. The message prints the type's name and then every
  constructor in `available`.
- **Expected** `exposing (Box)`, which exposes the type and its same-named constructor
  (`language.md` §5.2): a constructor whose name equals the type's is not listed again.
- **Fixture** `tests/pending/check/bad/ExposingSameNameConstructor/` (`.codes`: `expected_token` at
  `Main.beni:2:23`, contains "exposing (Box)", lacks "Box, Box").
- **Slice** R13.
- **Status** fixed by R13 (2026-09-27), `checker.md` §8.7 first: a constructor with the type's name is not listed again, and the message says naming the type exposes it. Promoted: `tests/corpus/check/bad/ExposingSameNameConstructor/`. CK-129 is the same finding.

### CK-87 — `==` on a record type nested more than 32 deep is an INTERNAL ERROR at build

- **Severity** valid-program-rejected. **Area** JS lowering (`Lower.derivedValue`). **Class** K14.
  **Sources** R2c, measuring deep evidence. Present on 7ae452f.
- **Program** `a = { x = { x = … { x = 1 } … } }` 40 deep, unannotated, and `a == a` in `main`.
- **Command** build.
- **Observed** `check` exits 0; `build` stops with two INTERNAL ERROR "I cannot tell what this
  call dispatches to". The derived `eq` of each level hands the next level's to it as a part, and
  `Lower.derivedValue` reports and stops past `max_part_depth` (32) — a cap whose comment says a
  type that deep is past what an annotation can say, which is true and beside the point: an
  unannotated record literal infers one. At 20 levels it builds and prints `eq`.
- **Expected** It builds and runs, printing `eq` and `ne`. The part tree cannot point back at
  itself (checker-v2.md §13.1), so the cap is no cycle guard; with R2c's evidence hoisting
  (`backend.md` §4) depth no longer threatens the emitted module either.
- **Fixture** `tests/pending/run/DerivedEqDeepRecord.beni` (red: `dev: exit=1 codes=internal×2`;
  oracle twin at 20 levels prints `eq`, `ne` on 7ae452f).
- **Slice** R8a (manager, 2026-09-25): R8a rewrites derived contexts, and with them the last per-part depth cap.
- **Status** fixed by R8a (2026-09-26) and promoted: `Lower`'s 32-level part cap is gone; `run/DerivedEqDeepRecord` builds and runs under both checkers (1 900 levels checked by hand).

### CK-88 — One `case` of many literal branches: emit is quadratic, and past 65 046 Firefox refuses the `switch`

- **Severity** performance. **Area** JS lowering (`case`, `backend.md` §7). **Class** K14.
  **Sources** R2c, measuring long forms. Present on 7ae452f.
- **Program** `g k = case k of 0 -> 0; 1 -> 1; … ; _ -> -1` with n integer literal branches.
- **Command** build.
- **Observed** `check` takes 18 ms at n = 10 000 and `build` 2.2 s, 8.6 s at 20 000 (ReleaseFast;
  29 s and 113 s on Debug), all of it in the emit phase: quadratic. The one `switch` it writes has
  n cases, and SpiderMonkey — Firefox 144 and the 140 shell alike — refuses a `switch` of more than
  65 046 (`backend.md` §4's table), so from there the build would also exit 0 and the module throw
  at load in Firefox; the quadratic emit makes that about 100 s of ReleaseFast build first.
- **Expected** Emit linear in n, and a `switch` of at most a bounded number of cases (split into a
  two-level `switch`, or `if` ranges over sorted keys). The source is flat, so under `backend.md`
  §4's rule its JavaScript may not grow in anything an engine bounds.
- **Fixture** `pending_test.zig` scenario `CK-88` (`test-pending-perf`; n = 3 000 / 6 000:
  204 / 789 ms, ratio 3.86, on R2c's ReleaseFast build).
- **Cause** (R2c's review round) `Decision.compile` is quadratic three times over for one literal
  column: the key de-duplication (`sameHead` against every key so far), `chooseColumn`'s distinct
  count (against every row above), and the specialisation of every row once per key. A fix groups
  rows by literal through the matrix code.
- **Slice** R12 (manager, 2026-09-25): a backend cleanup once v1 is deleted — group rows by literal throughout `Decision`'s matrix code; the `switch` size limit is split into bounded `switch`es in the same change.
- **Status** fixed by R12 (2026-09-27). `js/Decision.zig` groups a column's rows by head in one pass
  (`group`, a head table keyed by what a head is — a constructor's order, a literal's spelling)
  and specialises each key over its own rows and the wildcard rows only; the column choice's
  distinct count is the table's size; the key sort is a stable block sort over indices. `js/Lower.zig`
  writes a fan of more than `max_switch_cases` = 16 384 labels as consecutive `switch`es over the
  same discriminant, `default:` in the last (`backend.md` §7 *added by R12*). ReleaseFast, `build`
  CPU: 0.19 / 0.80 s at 3 000 / 6 000 branches before, 8.9 s at 20 000; after, the process floor at
  both sizes and 0.04 s at 20 000. Fixtures: the pending scenario moved verbatim to `perf_test.zig`
  (`test-perf`, CK-88), and `abuse_wide_test.zig`'s "CK-88: a case of 70 000 literal branches builds
  as switches of at most 16 384 labels and runs, in both builds" (five `switch`es, the largest
  exactly 16 384 labels; the program's answers at each chunk's edges, the default and a miss).
  Emitted JavaScript is byte-identical for every fan under the bound (the `emit/` and `run/`
  goldens did not move).

### CK-89 — A private type's derived context is published nowhere, though an importer can compare it

- **Severity** latent (a spec gap v2 would turn into a refused valid program or a miscount; v1 is
  right today). **Area** interface record, D4. **Class** K10.
  **Sources** R3, while writing interface v3's derived rows.
- **Program** `A.beni`: `type Hidden a = H a` (private) and `pub make : a -> Hidden a`.
  `Main.beni`: `A.make 1 == A.make 1`.
- **Observed** on R3 (and 3487c12): builds and prints `same` — v1 resolves the `==` as
  `ext_derived` to `A`'s derived `Hidden` function and counts its evidence from the type's arity
  in the session table. `A`'s interface has NO row for `Hidden`: `checker-v2.md` §14.2 publishes
  derived contexts and `payload_params` "per exported nominal type", and `Hidden` is in no `types`
  table, only in a `type_refs` row.
- **Expected** v2's importer "resolves `ext_derived` against the published context" (§14.2, D4,
  I10) and so needs a context for every type it can reach, which is every type a `type_refs` row of
  a record it reads names — the set the dependency digest already closes over (`checker.md` §7).
  Under D4 the context is inferred, not the arity, so v1's fallback does not carry over.
- **Fixture** none yet: v1 is correct, and the program above is the guard to write in the slice
  that reads the rows (it should build and print `same` under both checkers).
- **Slice** R8a, manager 2026-09-25: amend §14.2 so derived rows cover every nominal type
  reachable from a published scheme, before R8a reads them. The spec amendment comes first, in its
  own commit (rule 1); the text to amend is §14.2's "per exported nominal type", for both rows.
- **Status** R8a (2026-09-26): §14.2 amended first (hidden rows, three-word entries); `run/HiddenTypeDerivedRow` is the guard (both checkers print the same).

### CK-90 — A `let` function that uses a later `let` pattern's variable is generalised before the pattern

- **Severity** unsound-runtime. **Area** core: the `let` SCC. **Class** K8.
  **Sources** R4b, while making generation resolve `.local` references (I11, `checker-v2.md` §6.2).
- **Program**:

  ```elm
  f p =
      let
          c u =
              a

          ( a, b ) =
              p
      in
      ( c 1, String.length a )

  bad =
      f ( 5, 0 )
  ```
- **Command** check; `dump --stage=types`.
- **Observed** on 986b2c5: exit 0, `f : ( a, b ) -> ( c, Int )`. `c`'s result is unrelated to `a`,
  and `f`'s argument does not have to hold a `String`, so `f ( 5, 0 )` checks and `String.length`
  runs on `5`.
- **Expected** `f : ( String, a ) -> ( String, Int )`, and `bad` is a mismatch at `5`
  (`kind_mismatch 24:9`). v2 (R4b) gives exactly that.
- **Root cause** `Constrain.sccOfLet` gives an edge only to a `let_def` binding (`local_of` is `none`
  for a `let_pattern`). A function is hoisted, so lowering allows it to use a variable a later
  pattern binds; with no edge, `c`'s group is solved and generalised first, over a variable the
  pattern constrains afterwards.
- **Fixture** `check/bad/LetFunctionUsesLaterPattern.beni`. `.codes`: `kind_mismatch 24:9`.
- **Slice** R4b: `check2/constrain/Decl.zig`'s `let` SCC has an edge to a pattern binding for every
  variable it binds (`checker-v2.md` §6.2, *As built by R4b*). Claimed (green under v2 only); v1 is
  frozen.

### CK-91 — A `let` of more than about 4 200 bindings loses its last constraints in silence

- **Severity** unsound-runtime. **Area** core: the solver's recursion guard. **Class** K3.
  **Sources** R4b, while driving a 100 000-deep type through every walk (I4).
- **Program** `tests/corpus/check/bad/LetOfManyBindings.beni`: `f x0 = let x1 = negate x0 … x5000 =
  negate x4999; bad = String.length x5000 in bad` (one binding per line, generated).
- **Observed** on 986b2c5: exit 0, `f : number -> a` — the result promises any type, so
  `String.toUpper (f 1)` checks. Each of a `let`'s groups is a `let` node nested in the previous
  one's body, `Solve.let_` solves the body by recursion, and past `Parse.max_depth + 104` levels
  `Solve.solve` returns without a word: every later group is unconstrained. The guard's comment
  says an accepted file cannot reach it; the parser bounds nesting, not a `let`'s binding count.
  The same program with `[ xN ]` bindings, 5 000 deep and `pub`, publishes `deep : a -> b` instead
  of `nesting_too_deep`.
- **Expected** `kind_mismatch` at `x5000` in `bad` (10010:29).
- **Fix (v2, R4b)** `Solve.let_` returns the body and `solve` continues with it in a loop — a
  `let`'s groups are a tail chain — and the guard reports `nesting_too_deep` instead of returning
  (I4). The generator's guards note the instruction for the same message.
- **Fixture** `check/bad/LetOfManyBindings.beni`. `.codes`: `kind_mismatch 10010:29`.
- **Slice** R4b (claimed; v1 is frozen).

### CK-92 — A mismatch over a shared or cyclic type prints hundreds of megabytes

- **Severity** compiler-hang / output blow-up (a two-line program writes 300 MB of stderr in about
  11 s). **Area** `Render`, shared by both checkers. **Class** K13. **Sources** R4b's adversarial
  review (F1).
- **Program** `h x y z = [ x, ( y, z ), ( z, x ), ( x, 0 ) ]`; also a doubling `let`
  `x1 = ( x0, x0 ) … x40 = ( x39, x39 ) in String.length x40`.
- **Observed** on 986b2c5, both checkers: one TYPE MISMATCH of 301 990 289 bytes (604 MB for a
  variant). `Render.write` truncates at depth 24 but prints a DAG as a tree: `x = ( x, x )` is 2^24
  leaves.
- **Expected** a bounded message.
- **Fix (R4b's review)** `Render.Namer.budget`: at most `message_budget` (4 096) nodes per message,
  `…` past it; the dumps set `unlimited` (`checker.md` §8.2's third bound). The message is now
  37 KB on both checkers. A shared change to a kept file, contained, and no golden moved.
- **Fixture** `blackbox_test.zig` "CK-92: a mismatch over a shared or cyclic type prints a bounded
  message" (both checkers, stderr < 64 KB; red on 986b2c5 — the harness's 64 MB stream limit).
- **Slice** R4b (fixed, in the gates).

### CK-93 — A `let` chain whose types grow is quadratic in its length

- **Severity** performance. **Area** the boundary's walks. **Class** K11. **Sources** R4b's
  adversarial review (F6); R4b's structural review (N8, doubt 3).
- **Program** `foo x0 = let x1 = [ x0 ] … xN = [ xN-1 ] in List.length xN`, one binding a line.
- **Observed** under `--checker=v2` (R4b): N = 2 500 / 5 000 / 10 000 / 20 000 take 2.1 / 7.8 /
  29.6 / 119.8 s, almost all in `solve` — about 600 ns per node visit per boundary: each `let`
  boundary's occurs walk, rank adjustment and error scan revisit the whole type built so far. v1
  plateaus only because it gives up in silence (CK-91). A `let` of 100 000 bindings whose types
  nest 100 000 deep takes about 75 s under both checkers (R4b's own probe). The independent chain
  (CK-91's shape) is linear.
- **Expected** linear: the nodes an older boundary generalised or proved acyclic need not be
  walked again (for occurs, black marks that persist across boundaries for generalised nodes).
- **Fixed** by R8c (2026-09-26): an occurs check at a boundary records what it proves (every node
  it blackens and every leaf it meets, `TypeStore.acyclic`), a later walk stops at a proved node,
  and any write that gives a proved leaf successors voids every proof (`checker-v2.md` §8.2
  *restated by R8c's review*: its first form voided them only on a flex bound in `Unify.bind`,
  and missed an `err` class given structure by a merge — review B1; its second review found two more
  holes through `err` — a record row end absorbing fields, an interior node turned `err` — closed
  by the `err` rule: a node with successors turned `err` voids them) The unify pair stack's scan is bounded
  and deep pairs hashed (§7.3 *amended by R8c*). At R8c's parent the chain's `check` took 166 / 635 /
  2 520 ms at N = 4 000 / 8 000 / 16 000; now 6 / 9 / 15 ms. Lowering the `let` stays quadratic:
  that is the frontend's, CK-127. v1 is still quadratic (frozen).
- **Fixture** `test-perf` "CK-93" (8 000 / 16 000, on the module's `check` event).
- **Slice** R6a (manager, 2026-09-25), with the resolver's boundary work. Also measure there the coinductive `Unify.active` pair stack, which scans linearly per pair of non-variables and is quadratic in depth on a very deep acyclic unification; replace it with a hashed set if it shows. Taken by R8c (manager, 2026-09-26), and fixed there.

### CK-94 — A `number` variable is printed as `a`

- **Severity** diagnostic-quality. **Area** unification of names, `Render`. **Class** K13.
  **Sources** R4b's adversarial review (F7); shared with v1.
- **Program** `pub g = 1 :: []` and `pub h = List.singleton 2`: `dump --stage=interface` prints
  `List a`; `f u = let p1 = [] in 1 :: p1` prints `f : a -> List a2`.
- **Observed** the kind survives (sound: `String.toUpper (Maybe.withDefault (List.head g) "")` is
  refused), but a message then reads "This argument is: `List a` … One of those has to be a number",
  which contradicts itself. flex ⊓ flex keeps the scheme's name (`a` from `cons`) over the literal's
  unnamed `number` flex, and the printer prints the name without the kind.
- **Expected** `List number`: a named variable of a non-`any` kind prints as its kind unless its
  name already says it.
- **Fixture** none yet (a `check/good` interface golden and a `check/bad` message).
- **Slice** R13.
- **Also** (R5's adversarial review, F8, 2026-09-25): which name survives depends on the order of
  merges, so in a recursive group the published quantifier's name — `number` or `a`, the kind
  and the flag identical — follows the order the members are written in
  (`f u = let v = u? in g v`, `g x = if Basics.eq x 0 then …`, `h y = Just "${y}"`: `g : number
  -> Maybe String` in three orders, `g : a -> Maybe String` in the other three). The types are
  equal and the choice is a function of the source, not of ids, so no program checks differently;
  but the interface's name hint (and so its bytes) follows the order. R13's rule above removes it.
- **Status** fixed by R13 (2026-09-27), `checker.md` §8.7 first: `Render.preferredName` prints a kinded variable as its kind unless its name starts with the kind's text, and `Schemes.Writer` publishes no such name (so F8's bytes no longer follow member order). New, red on `3ff3ac5`: `tests/corpus/check/good/NumberVariableNamedByKind.beni` (interface) and `tests/corpus/check/bad/NumberVariableNamedByKind.beni` (message); `EagerDrainInnerLet.iface`, `MethodInstantiatedPerUse/_expected.iface` and five `.diag`s re-blessed (`number` where `a`/`b` printed).

### CK-95 — BIR lowering is quadratic in a `let`'s binding count

- **Severity** performance. **Area** `bir/Lower.zig`, outside the checker. **Class** K14.
  **Sources** R4b's adversarial review (F8).
- **Observed** `dump --stage=bir` alone: 1.0 / 3.8 / 14.6 s at 10 000 / 20 000 / 40 000 chained
  bindings, and 0.37 → 1.27 s (10k → 20k) for independent ones; a 100 000-binding `let` times out
  (> 60 s) on both checkers before either checks it. v2's `constrain` + `solve` at 40 000 is 3.4 s
  and linear.
- **Expected** linear lowering.
- **Fixture** none yet.
- **Slice** R12 (the manager).
- **Status** fixed by R12 (2026-09-27), with its duplicate CK-127. Four scans in `bir/Lower.zig`
  were each linear in the block per binding: the shadowing check (`bindVar`) and every lookup
  (`lookupLocal`) walked the scope stack, which holds the whole block from phase 1 on;
  `localOfInst` searched the declaration's locals backwards per `let_def`; and `checkLetOrder`
  reset its visited set and scanned every edge once per binding (and `bindingOfLocal` scanned the
  bindings per edge). The scope is indexed by name past 64 entries (`scope_index`, each entry
  chained to the one it shadows; the same reports as the scans, the earliest duplicate of a pattern
  set included), the local is recorded in phase 1, and the order check walks each binding's own
  run of edges and resets what it set. `dump --stage=bir` is byte-identical. ReleaseFast `check`,
  CPU: 0.12 / 0.47 / 1.92 s at 10 000 / 20 000 / 40 000 chained bindings before, 0.01 / 0.02 /
  0.04 s after. Fixture: `perf_test.zig`'s "CK-95: a let of n chained bindings lowers in time
  linear in n" (CK-93's generator, the `lower` event, 20 000 / 40 000).

### CK-96 — Obligation rows riding on one variable cost quadratic time (checker v2)

- **Severity** performance. **Area** `check2/Obligations.zig`, `Unify.zig`. **Class** K11.
  **Sources** R5's adversarial review (F1), on R5's uncommitted tree.
- **Program** `pub f p = "${p}${p}…" ++ String.fromInt p`, and `( [ p.0, p.0, … ], snd p )`.
- **Observed** 8 000 `${p}` took 31 s under `--checker=v2`, against v1's 0.15 s. Every merge of a
  fresh part variable with `p` re-lowered every row on `p`, and the sets were copied on attach.
- **Fixed by R5** (2026-09-25): sets are in-place lists, and a merge re-lowers only the rows of a
  side whose rank strictly dropped (`checker-v2.md` §4.5 *As built by R5, after its review*).
- **Fixture** `tests/blackbox/perf_test.zig` "CK-96" (`zig build test-perf`): 2 000 / 4 000, a
  ratio of 3.86 before, 1.12 after.
- **Slice** R5 (fixed).

### CK-97 — Merging variables that carry rows costs O(rows × merges) (checker v2)

- **Severity** performance. **Area** `Unify.zig`, `Obligations.zig`. **Class** K11.
  **Sources** R5's adversarial review (F2); structural review (S3).
- **Program** `pub f x1 … xn = ( [ "${x1}", … ], [ x1, …, xn, 1 ] )`, and the same with
  `Basics.eq [ xi ] []` or `xi.0`.
- **Observed** n = 4 000: 8.2 s under v2, 0.22 s under v1. Every merge copied both sets and
  re-lowered every row of the survivor.
- **Fixed by R5** (2026-09-25): union by size, and lowering only on a strict rank drop.
- **Fixture** `perf_test.zig` "CK-97": 2 000 / 4 000, a ratio of 3.72 before, 1.81 after.
- **Slice** R5 (fixed).

### CK-98 — The `?` default step scans every open `?` at every boundary (checker v2)

- **Severity** performance. **Area** `check2/Decide.zig` (`defaults`), `Generalize.Frame`.
  **Class** K11. **Sources** R5's adversarial review (F3); structural review (S4).
- **Program** `pub f u = let a1 = u? … an = u? in Ok [ a1, …, an ]`.
- **Observed** n = 4 000: 33 s under v2, 0.47 s under v1. Step 3 scanned every open `try` of the
  module at every `let` boundary, and the subject `u`, which decides n rows it does not own, was
  walked through all of them by rank adjustment at every boundary.
- **Fixed by R5** (2026-09-25):
  - a per-frame open-`?` list, which a row leaves once, for the frame its target escaped to;
  - a variable's set keeps the rows it owns apart from the rows it only decides, so rank
    adjustment walks the owned ones alone.
- **Fixture** `perf_test.zig` "CK-98": 1 500 / 3 000, a ratio of 3.71 before, 1.90 after.
- **Slice** R5 (fixed).

### CK-99 — A `?` target was made monomorphic in its own success type (checker v2)

- **Severity** valid-program-rejected. **Area** `check2/Decide.zig`, the I15 rule for
  obligations. **Class** K2. **Sources** R5's adversarial review (F4), on R5's uncommitted tree.
- **Program**:

  ```elm
  f u =
      let
          g k =
              k (u?)
      in
      ( g (\v -> Ok v), g (\v -> Ok (String.fromInt v)) )
  ```

- **Observed** v2 said TYPE MISMATCH at `String.fromInt v`. v1 builds it and prints
  `{ a = Ok 1, b = Ok "1" }`.
- **Cause.** The spec text said all variables of one obligation share one rank. So the `?` target,
  `g`'s own result, was lowered to the outer subject's rank, and `g` stopped being generalised over
  its result's success type, which a `?` never constrains.
- **Fixed by R5** (2026-09-25), spec first. `checker-v2.md` §4.5 *Amended by R5's review*, I15 and
  §21.1's new D2 row say that every obligation has an owner and ranks run from the owner to its
  dependants. A `?`'s owner is its target, as D2 as amended already said.
- **Fixture** `tests/corpus/run/TryTargetKeepsItsSuccessType.beni`. Green on v1 and on v2, it is in
  `v2-green.txt`.
- **Slice** R5 (fixed).

### CK-100 — A method's result is left untied when its receiver becomes known later (checker v1)

- **Severity** unsound-runtime. **Area** v1's deferred method obligations (`Solve.zig`'s
  `dischargeMethod` against a receiver bound after the call). **Class** K2. **Sources** R6a
  (2026-09-25), writing the eager-draining fixture its reviewer focus asked for.
- **Program**:

  ```elm
  pub h : K, () -> Box Int
  pub combine : Box a, z -> a

  pair n =
      case (\y -> y.h ()) (K n) of
          r ->
              let
                  q z =
                      r.combine z
              in
              ( q 1, q "s" )

  bad : Int
  bad =
      String.length (pair 3).0
  ```

- **Observed** on 68186fa, v1 publishes `pair : Int -> ( a, b )` and `bad` checks clean; built, it
  hands an `Int` to `String.length`. `inner b = let u = b.unbox () … in ( u + 1, … )`, with `b`
  bound inside a nested `let`, is published `Box a -> ( a2, List (Box a) )`: `u` is not `b`'s
  element. `run/ScrutineeMethodFirst` prints the right numbers only because nothing reads the
  type.
- **Expected** `pair : Int -> ( Int, Int )`, and `bad` is a `type_mismatch` at `(pair 3).0` — what
  the annotated twin reports on v1.
- **Fixed by** v2's resolver (R6a): the wanted rides on the receiver, is resolved when it is bound
  (eager draining, `checker-v2.md` §9.1), and matching unifies the method's instantiated scheme
  with the call's method type, so the result is the method's.
- **Fixtures** `tests/corpus/check/bad/MethodResultTooGeneral.beni` and
  `tests/corpus/check/good/EagerDrainInnerLet.beni`, both claimed.
- **Slice** R6a (claimed).
- **Added by R6a's review (2026-09-25):** `tests/corpus/check/bad/MethodResultMismatchOnce` (a call's result mismatch is one message; the callee's requirements fail in silence: review F6), claimed.

### CK-101 — A derivability walk through alternating method boundaries recurses without end (checker v1)

- **Severity** compiler-crash-or-hang. **Area** v1's `walkDerivable` (`Solve.zig`), and R6a's first
  round of v2's walk. **Class** K3. **Sources** R6a's structural review (2026-09-25, B2, probe
  `cyc/`).
- **Program** (three modules):

  ```elm
  -- Pa
  pub type A a = A a
  pub eq : A a, A a -> Bool
      where a.compare : a, a -> Order

  -- Pb
  pub type B a = B a
  pub compare : B a, B a -> Order
      where a.eq : a, a -> Bool

  -- Main
  f x =
      if List.isEmpty [ x, A (B x) ] then ( x, 1 ) == ( x, 1 ) else False
  ```

- **Observed** on 68186fa, v1 overflows its stack: `walkDerivable` recurses into a method boundary's
  argument for the method the boundary's requirement names, with fresh marks, so a cycle through
  `A`'s `eq` (asking `compare`) and `B`'s `compare` (asking `eq`) is never met twice under the same
  method. R6a's first round coloured per node for one method and recursed at a boundary: the same
  overflow. Without the cycle, a doubling DAG through the same two boundaries is exponential in
  v1 (`f x = ( A (B x), [ A (B x) ] )` nine deep does not finish).
- **Expected** one `infinite_type` at the `==`, written `a = A (B a)`, and a DAG linear in its
  distinct nodes.
- **Fixed by** R6a's review: `Instances.derivability`, one iterative walk over `(node, method)`
  pairs coloured per pair (`checker-v2.md` §9 *As built by R6a*).
- **Fixtures** `tests/corpus/check/bad/DerivabilityAlternatingCycle` (claimed) and the v2 timing
  scenario `perf_test.zig` "CK-101".
- **Slice** R6a (claimed).

### CK-102 — A derived shape refused at a position is accepted in silence (checker v2)

- **Severity** unsound-runtime. **Area** v2's `Instances.refuseDerived`. **Class** K2. **Sources**
  R6b (2026-09-25), found when P6's first run met a `failed` wanted in a module that had reported
  nothing (`check/bad/SpecializedEqWrongReceiver`, which `v2-expected.md` described as refused).
- **Program**:

  ```elm
  type Holder a = Holder a

  eq : Holder Int, Holder Int -> Bool
  eq _ _ = True

  badRecord : { value : Holder String }, { value : Holder String } -> Bool
  badRecord left right = left == right
  ```

- **Observed** on e763e12, `check --checker=v2` exits 0: the record's `eq` derives, its position
  `Holder String` meets `Holder`'s `eq` (the module rule), the match fails, and `refuseDerived`
  rejects the position — which fails its whole lineage, the use's wanted included — and then asks
  whether the use's wanted had already failed, to say its message once. It always had, so it never
  said it. v1 reports `not_equatable` at the `==`.
- **Expected** one `not_equatable` per comparison, as v1.
- **Fixed by** R6b: the lineage root's state is read before the rejection.
- **Fixtures** `tests/corpus/check/bad/DerivedPositionMethodMismatch.beni` (v1 passes; in
  `v2-green.txt`), and `check/bad/SpecializedEqWrongReceiver`'s record and tuple comparisons.
- **Slice** R6b (fixed).

### CK-103 — An `undetermined` leaf answers a `compare` slot with `Basics.eq` (checker v1)

- **Severity** latent. **Area** v1's `Dispatch.finish` converter (an `err` part is the
  `undetermined` leaf) and `Lower.termValue`, which reads the leaf's method off the nearest derived
  ancestor. **Class** K4. **Sources** R6b's structural review (B1b, probe `r6b/p4`).
- **Program** (two modules):

  ```elm
  -- S
  pub type Sorted a = Sorted (List a)
  pub eq : Sorted a, Sorted a -> Bool
      where a.compare : a, a -> Order

  -- Main
  … { s = S.Sorted [ [] ] } == { s = S.Sorted [ [] ] } …
  ```

- **Observed** on e763e12: `ext S eq (ext List compare (undetermined))` under the record's derived
  `eq`, emitted `List$compare(Basics$eq, …)` — a `Bool`-valued function in an `Order` slot. It runs
  correctly only because no value of the element type exists (the list is empty), so the function
  is never called: a table that is wrong by its own contract, not a wrong answer.
- **Expected** the structural `compare` (`primitive num_compare`) in that slot.
- **Fixed by** R6b's review: P6 writes the leaf only below a derived ancestor of the SAME method,
  and the structural function for the slot's method everywhere else (`checker-v2.md` §13.1 as
  amended by R6b's review); the I7 assert now checks each leaf's place against its slot's method,
  so v1's `check` refuses the program with `internal`.
- **Fixtures** `tests/corpus/run/UndeterminedCompareSlot` (claimed; red on v1 as `internal`).
- **Slice** R6b (claimed).

### CK-104 — A constant that calls a derived row whose body names a later own value throws at load (backend)

- **Severity** unsound-runtime. **Area** `js/Lower.emissionOrder` and `check/Cycles.zig`, through
  `Edges.declEdges`. **Class** K14. **Sources** R6b's reviews (structural S5, adversarial F2).
- **Program**: `run/DerivedRowBodyEmissionOrder` — `main` compares two `W (H.Holder T)`, where
  `H.eq` asks `T`'s `key`, and `pub key` is declared after `main`.
- **Observed** on e763e12, under both checkers: exit 0, then `ReferenceError: Cannot access
  'Main$key' before initialization` at load. Emission order walked `refs` and the sites' own
  terms, not the bodies of the derived rows they name, so `Main$key` was emitted after `main`.
- **Expected** `T`.
- **Fixed by** R6b's review: `Edges.termsEdges` walks through this module's derived rows for a
  declaration's edges, which both emission order (`Lower.siteTops`) and the value-cycle check read.
- **Fixtures** `tests/corpus/run/DerivedRowBodyEmissionOrder` (fails on e763e12 under both
  checkers), and `tests/corpus/run/DerivedContextClosedOwnMethodPermuted` (CK-67's program with each
  `key` last; claimed, red on v1 for CK-67's reason).
- **Slice** R6b (fixed).

### CK-105 — A dot-call is a field call or a method depending on whether its record receiver arrived first

- **Severity** valid-program-rejected, and order-dependent (I9). **Area** dispatch: a dot-call's
  resolution (`Instances.onRecord`). **Class** K6. **Sources** R7's adversarial review, F1 (`p/Rec1`,
  `Rec1c`, `Rec2`, `Rec1v`, `pt/T104`).
- **Program** `run/FieldCallThroughMember.beni`: `ma`'s `x.combine 1` where `x` is typed only by
  `mb`'s in-flight call `(K 1).ma { combine = \z -> z + 1 }`, `ma` and `mb` recursive through
  dispatch.
- **Observed** on R7's first cut (and on v1 for the value-recursive `fa`/`fb` shape): accepted,
  printing `5`, in the orders where the record arrived before `x.combine 1` was solved;
  `no_methods_on_shape` in the others. static-dispatch-spike.md §1.2/§11 decided "field call or
  method" by whether the receiver was known when the call was first solved, which inside a
  recursive group is the declaration order.
- **Expected** `5` in every order.
- **Fixed by** R7's review round: the *Deferred receiver* rule amended (static-dispatch-spike.md §11,
  2026-09-26) — a dot-call's own requirement whose receiver becomes a record before the constraint
  is generalised is the field call.
- **Fixtures** `run/FieldCallThroughMember`, `…MemberCycle`, `…ValueRecursion`, `…ValueDemand`,
  `run/DeferredReceiverFieldCall`, `check/bad/RecursiveGroupFieldCallTwoTypes` and
  `…RefusalRendering`, each in `scenario/PERM`; the round-2 review added `check/bad/DeferredReceiverJoinedRequirement/`
  and `…JoinedInGroup` (a dot-call joined with a scheme's requirement, X1), the corpus guard
  `check/bad/DeferredReceiverGeneralised` and `run/DeferredReceiverRecursiveTwin`, which v1 miscompiles
  (it passes `f` evidence `f` does not take and prints `EQ` for `2`).
- **Slice** R7 (claimed).

### CK-106 — A `number` receiver's method inside a recursive group is an internal error

- **Severity** compiler-crash-or-hang (an `internal` refusal of a program that should be an ordinary
  error). **Area** promotion and §12.3's group calls. **Class** K4. **Sources** R7's round-2
  review, S3 (the in-flight fuzzer, 8 of 300 programs in every order; `pr/n2`, `pr/t161`).
- **Program** `check/bad/NumberReceiverMethodInGroup.beni`: `ma n x = if n > 0 then mb n else
  x.size ()`, `mb n = ma 0 3`.
- **Observed** v2 (R7's first round): two `internal`s at `ma 0 3` — §12.3's case 3 has no
  structural answer for `size`, then I7. v1: one `internal` (I7) at `x.size ()`. Outside a group
  both checkers give the correct `unknown_method` at the caller.
- **Expected** one `unknown_method` at `x.size ()`, in every order.
- **Fixed by** R7's round-2 fix: `Resolve.undeterminedInGroup` at step 7 (`checker-v2.md` §10.8).
- **Fixtures** `check/bad/NumberReceiverMethodInGroup.beni` and `…Dispatch.beni`, in `scenario/PERM`.
- **Slice** R7 (claimed).

### CK-107 — Writing a module's cache entry is super-linear in the number of its types

- **Severity** performance. **Area** the cache (`cache_store`), both checkers. **Class** K11.
  **Sources** R8a, profiling CK-75 under v2 as its brief asks (2026-09-26).
- **Program** CK-75's: n declarations, each a `type T{i} = T{i} Int` and an `f{i} : Int -> Bool`
  comparing two `Int`s.
- **Command** `B check --cache-dir=<fresh> --jobs=1 --self-profile=<trace> X.beni` (ReleaseFast).
- **Observed** the `cache_store` event takes 19.5 / 72.6 ms at 6 000 / 12 000 (v2), 19.9 / 73.7 ms
  (v1): a ratio of 3.7, where the module's `check` event is linear under v2 (44 / 87 ms). The
  entry is 4.7 / 9.1 MB, linear, so the time is not the bytes.
- **Expected** Linear. Budget: `fast-compiler.md` §2 and §8.
- **Root cause** isolated by R10: `dispatch_bytes.Writer.typeRef` searched the sidecar's
  `type_refs` table linearly for every derived row's `nominal` shape (and `moduleRef` its
  `module_refs` for every `ext` term), so a module of n types wrote n rows against a table of up
  to n entries: O(n²). Nothing else in the entry's writers scans.
- **Fixture** `tests/blackbox/perf_test.zig`'s `CK-107` scenario (`zig build test-perf`): the
  program at 12 000 / 24 000 into a fresh cache directory every run, the `cache_store` event,
  best of 3, ratio ≤ 2.5, under both checkers. Red on `6097799`, green on R10.
- **Slice** R10 (incrementality).
- **Status** fixed by R10 (2026-09-27): both reference tables are indexed by a hash map from the
  row to its index; the rows keep their first-occurrence order, so no entry's bytes move.
  `cache_store` at 6 000 / 12 000: 20 / 72 ms → 4.4 / 8.1 ms (ReleaseFast), both checkers.
  (R12 dropped the scenario's v1 run with v1; its v2 half is unchanged.)

### CK-108 — A derived context drops a payload's `equatable` requirement: v2 compared functions

- **Severity** unsound-runtime. **Area** derived contexts (`Contexts.collect`), v2 only; an R8a
  regression inside the slice. **Class** K7. **Sources** R8a's structural review, B1 (2026-09-26).
- **Program** a payload whose method's scheme asks `equatable` of a parameter without a `where`
  entry for `eq`. `H.beni`: `pub type Holder a = Holder a` and an unannotated
  `pub eq (Holder x) (Holder y) = Basics.eq x y` (so its scheme carries the flag, not an `a.eq`
  clause); `Main.beni`: `type W a = W (H.Holder a)`, `f : Int -> Int`, and
  `W (H.Holder f) == W (H.Holder f)`.
- **Observed** R8a's first draft: v2 builds it and runs `==` on two functions. The marker of `a`
  carried `flags.equatable` (or an open equatable obligation row), not an open `eq` wanted, and
  `collect` read only wanteds, so `W`'s context was empty. v1 refuses with `not_equatable`.
- **Expected** v1's refusal: an equatable marker is the entry `(i, eq)`, so `W (Int -> Int)`
  asks `eq` of a function and is refused at the use.
- **Fixed by** R8a's review round: `collect` adds `(i, eq)` for a distinct marker carrying
  `flags.equatable` or an open equatable row (`checker-v2.md` §11.2 *as built by R8a*).
- **Fixtures** `check/bad/DerivedContextEquatableFlag/`, `…Published/` (through an intermediate
  module's published row) and `…Compare/` (the `compare` side), all in `v2-green.txt`.
- **Slice** R8a (fixed).

### CK-109 — A derived row of more than 65 535 context entries panicked the v2 checker

- **Severity** compiler-crash-or-hang (Debug panic; in ReleaseFast the index wrapped silently to the
  wrong evidence). **Area** P5/P6 and Lower, v2 only; an R8a regression inside the slice.
  **Class** K10. **Sources** R8a's adversarial review F1 and structural review S1 (2026-09-26).
- **Program** `pub type W p0 … p655 = W (H.Holder p0) … (H.Holder p655)` where `H.eq` asks
  `a.m0 … a.m99` (65 600 entries), or 32 769 parameters each a bare position and a `Holder`
  whose `eq` asks `compare` (65 538 entries); also a record of 65 537 fields (`r == r`).
- **Observed** `panic: integer does not fit in destination type` at `Eager.marker`
  (`Dispatch.Param.k` was a `u16`), or in Lower's `evidenceCall`/`ownEvidence(k: u16)`.
  `Eager.marker`'s lookup was also O(entries × (markers + entries)): 74 s and 3.1 GB on a Debug
  build.
- **Expected** builds and runs; D4 lets entries outrun parameters, so an entry index is 32-bit.
- **Fixed by** R8a's review round: `Param.k` and every Lower index are `u32` (dispatch format 4's
  term row carries it in bytes 8–12), and `Eager.markerKeys` builds one map per row (3.4 s, v1
  8.9 s, for the 656 × 100 shape).
- **Fixtures** `abuse_wide_test.zig` "CK-109: …" (both shapes, `--checker=v2`); `scenario/CK-82`
  moved to 65 537 fields.
- **Slice** R8a (fixed).

### CK-110 — v2 read the v1-ABI fallback for a record v2 wrote

- **Severity** latent (an ABI mismatch with no runtime path found). **Area** interface v4's hidden
  rows, v2 only; an R8a regression inside the slice. **Class** K10. **Sources** R8a's structural
  review, S2 (2026-09-26).
- **Program** `A`: `type Hidden a b = Hidden b Int` and `pub type alias Pub a = Hidden a Int`;
  `Main`: `pub same : A.Pub String, A.Pub String -> Bool`, `same x y = x == y`, built with
  `--library --checker=v2`.
- **Observed** `A` defines `A$Hidden$$eq = ($m$0, $x, $y) => …` (D4: `a` is phantom), and `Main`
  calls it with two evidence arguments. An alias body is in no record, so `Hidden` had no hidden
  row, and "no row" read as "the old checker wrote this record".
- **Expected** one answer (I10): `Main` passes what `A` takes.
- **Fixed by** R8a's review round: `Publish.typeFacts` closes the hidden set over own alias
  bodies, as `cache/Digest.zig` does, and the fallback reads v1's ABI only for a record of
  another package (`Context.oldCheckerWrote`); a v2 record with no row is `internal`.
- **Fixture** `blackbox_test.zig` "a private type reached only through a pub alias body …".
- **Slice** R8a (fixed).

### CK-111 — Derived `==` on a deeply nested record is quadratic per use site in v2

- **Severity** performance. **Area** the derivability verdict (`Derivable`), v2 only; predates R8a,
  which adds about 30% memory. **Class** K11. **Sources** R8a's adversarial review F2 and
  structural review item 6 (2026-09-26).
- **Program** `mk = { x = { x = … { x = 1, y = 0 } …, y = n-1 }` (unannotated, depth d) and k
  uses of `mk == mk`.
- **Observed** ReleaseSafe, d = 1 500: k = 1 / 4 / 16 take 0.57 / 2.2 / 8.9 s and 115 MB /
  418 MB / 1.63 GB (v1: 0.02 / 0.05 / 0.13 s, ≤ 43 MB). A Debug build at d = 20 000 passed
  18 GB. 25% of the time is `wyhash` on `Derivable`'s `colours` map under nested
  `Resolve.position`: a `number` flex keeps every nested position non-ground, so
  `resolver.derivable` never caches it, and each position re-walks its subtree.
- **Expected** linear in the type's size per use, as v1 is.
- **Fixed** by R8c (2026-09-26). Three quadratics, each a walk per nested position: the derivability
  walk (a verdict over variables is now kept until a leaf anywhere is given successors,
  `Resolve.State.derivable_open`), the §9.5 cycle test (it proves, and a position is a node it
  proved — the first form "inherited" the parent's proof across joins and user-instance
  unifications that could close a cycle, review B2), and — once those were
  gone — the unify pair stack's hash map, whose removals left tombstones (an array hash map popped
  in stack order; `checker-v2.md` §7.3, §8.2 *amended by R8c*). ReleaseFast, 64 uses: d = 1 000 /
  2 000 took 9.6 / 40 s at R8c's parent; now 0.26 / 0.53 s (v1 0.10 / 0.20 s).
- **Fixture** `test-perf` "CK-111" (d = 1 000 / 2 000, 64 uses).
- **Slice** R8c.

### CK-112 — A type of n parameters costs O(n²) in lowering and in the type reader

- **Severity** performance. **Area** `bir.Lower.lowerTypeVarMarked` and `Types.Builder.typeVar`,
  both checkers. **Class** K11. **Sources** R8a, profiling CK-109's 32 769-parameter shape
  (2026-09-26).
- **Program** `pub type W p0 … p32768 = W p0 (H.Holder p0) … p32768 (H.Holder p32768)`.
- **Observed** Debug `check`: v2 18 s, v1 362 s. The v2 profile is 45% `lowerTypeVarMarked` (a
  linear scan of the declaration's parameters per type variable) and 28% `Builder.typeVar` (the
  same, per read).
- **Expected** linear: a map from parameter name to index, built once per declaration.
- **Fixed** by R8c (2026-09-26) in shared code: lowering indexes a declaration of more than 8
  parameters by name (`Lower.type_param_index`), and the type reader takes a parameter's scope slot
  from the index lowering recorded (`TypeVarInfo.param`), checked, falling back to the scan. v2,
  ReleaseFast: 16 000 / 32 000 parameters took 0.21 / 0.8 s; now 41 / 78 ms. v1 keeps a quadratic
  of its own beyond these two (1.3 / 5.1 / 21 s at 8 000 / 16 000 / 32 000) and is frozen.
- **Fixture** `test-perf` "CK-112" (v2).
- **Slice** R8c.

### CK-113 — Evidence built at a use defeats CK-85's one-slot memo

- **Severity** performance (latent). **Area** Lower's evidence arguments, both checkers.
  **Class** K4. **Sources** R8a's adversarial review F3 (2026-09-26).
- **Program** `blank : List a where a.eq : …`, `blank = Debug.log [] "blank"`, read three times
  at `List (List Int)` from one call site in a loop.
- **Observed** `blank: []` printed three times. The evidence for `List Int` is an arrow built at
  each read (`($p$1, $p$2) => List$eq(Main$eq$prim, $p$1, $p$2)`), so `memoArrow`'s identity key
  never hits. The same holds for records, tuples and a nominal type with a non-empty context, and
  for one instantiation read from two modules (each has its own `$eq$prim`).
- **Expected** R8a narrowed `language.md` §6 to what is built: the memo is keyed on evidence
  identity. Once per instantiation needs closed evidence hoisted to module level (it is closed
  when every leaf is a module-level name), and a shared name for a primitive's evidence across
  modules.
- **Fixture** none yet: a `run/` fixture counting `Debug.log` lines when the slice takes it.
- **Slice** unassigned — the perf slice proposed.

### CK-114 — v2 refuses a record literal nested more than about 2 100 deep

- **Severity** valid-program-rejected. **Area** `Unify.max_depth` (`Parse.max_depth + 104`), v2
  only; predates R8a. **Class** K10. **Sources** R8a's adversarial review F5 (2026-09-26).
- **Program** `mk = { x = { x = … 1 … }, y = … }` 3 000 deep, unannotated, with no comparison.
- **Observed** v2: `NESTING TOO DEEP … more than 4200 levels deep`, twice; 2 099 deep passes.
  v1: exit 0.
- **Expected** v1's acceptance, or one refusal at the parser's own depth limit.
- **Cause** (R8c): not `Unify.max_depth` but the solver's per-declaration depth guard
  (`Solve.solve`, `Tree.Generator.max_depth`): a record literal cost two depth units a level — its
  node and its fields' conjunction — where every other expression costs one.
- **Fixed** by R8c (2026-09-26): the literal's fields are solved from its own frame
  (`Solve.solveFields`), one unit a level. The parser's limit is now the one limit: 4 095 levels
  check and compare under both checkers, 4 096 is the parser's single `nesting_too_deep`. (Running
  such a comparison overflows node's stack at about 4 000 levels, both checkers: the emitted
  derived `eq` nests a call a level: CK-128.)
- **Fixture** `abuse_test.zig` "a record literal nested to the parser's limit … (CK-114)".
- **Slice** R8c.

### CK-115 — An extra UNKNOWN METHOD follows a TYPE MISMATCH at the same call

- **Severity** diagnostic-quality. **Area** the solver's error cascade, v2 only. **Class** K13.
  **Sources** R8a's adversarial review, *Also seen* (2026-09-26).
- **Program** a call `same3 (T.T 1 "a") …` whose argument is already a TYPE MISMATCH, where the
  callee asks `a.key`.
- **Observed** v2 adds `UNKNOWN METHOD … I cannot tell which type \`key\` is being asked of` at the
  same call; v1 reports only the mismatch.
- **Expected** the mismatch alone: a poisoned receiver asks nothing.
- **Fixture** none yet.
- **Slice** R13.
- **Status** not reproduced on `3ff3ac5` by R13 (2026-09-27): every shape tried (a call argument that is a TYPE MISMATCH, a TOO MANY ARGS inside an argument, the receiver pinned or left open) gives the one message. Guard added, green before and after: `tests/corpus/check/bad/CallArgMismatchNoUnknownMethod.beni`; the rule is written down in `checker.md` §8.7.

### CK-116 — NOT EQUATABLE blames "a function anywhere inside it" when a payload method's requirement failed

- **Severity** diagnostic-quality. **Area** the use-site message of an absent derived context,
  both checkers (v2's `absent_other` falls back to v1's text). **Class** K7. **Sources** R8a's
  adversarial review F4 (2026-09-26).
- **Program** `H.eq : Holder a, Holder a -> Bool where a.key : a, () -> Int`; `S.key : S, () ->
  String`; `type Hid a = Hid (H.Holder a)` private in `A` with `pub mk`; `A.mk (S 1) == A.mk (S 2)`.
  Also `X Fe` where `H.eq` asks `compare` of `Fe`, which has none.
- **Observed** `NOT EQUATABLE … a function anywhere inside it rules the whole type out`. No
  function is involved. The direct `H.Holder (S 1) == …` gets the precise TYPE MISMATCH naming
  `S.key`.
- **Expected** name the payload method and the requirement that failed: the pass knows it when it
  fails, and §11.2 keeps "the reason … for the use-site message". Not trivial: the reason must
  ride on the answer (and on the published row) to reach an importer.
- **Fixture** none yet.
- **Slice** R13.
- **Also** (R8b's adversarial review F6, 2026-09-26, same cause): `A` declares `pub type T = T Int`
  and `pub eq : Int, Int -> Bool`; `B` has `pub type Wrap = Wrap A.T`; `Main` compares `B.Wrap`s.
  `not_equatable` with the "function or foreign type" hint, where the direct `A.T == A.T` is the
  precise `type_mismatch` (the module-rule clash). Both checkers.
- **Status** fixed by R13 (2026-09-27), `static-dispatch-spike.md` §10.13, `checker-v2.md` §11.2 and §14.2 *amended by R13* first: a failed requirement inside a derived `==`/`compare` names the method and, when the use decided it, both types; a fixpoint pass records it as `absent_requirement`, published as the row status `requirement` (`iface_bytes.format_version` 6). Both programs, and the answer and row paths, in the new `tests/corpus/check/bad/RequirementFailedInsideEq/` (red on `3ff3ac5`); five `.diag`s re-blessed.


### CK-117 — A fixpoint pass's variables can join a merged group below its frame

- **Severity** latent (no wrong output found). **Area** the derived-context fixpoint
  (`Contexts`) and group merging (§10.4), v2 only. **Class** K7. **Sources** R8a's review round,
  building the linear frame assert the structural review proposed (2026-09-26).
- **Program** `tests/corpus/check/bad/DerivedContextMergesAsker/` (CK-77), `…ReentrantSameFirst`
  (CK-74), `run/DerivedContextClosedOwnMethodPermuted` (CK-104), and orders in `scenario/PERM`.
- **Observed** with a Debug assert at `popFrame` of a `.fixpoint` frame ("every young variable's
  class is at the frame's rank or deeper, or generalized"): young variables of the pass end in
  classes at rank 1, the asker's group, below the fixpoint frame at rank 3. A pass demands an
  unchecked method group (not in flight, so not the in-flight branch); that group, checked nested,
  links to the asker's and merges down, and takes the pass's variables with it. §11.2's "not
  built … by construction" does not hold for this channel. The fixtures' outputs are right.
- **Expected** either an argument that such a pass is sound (its answer is `generational` or
  `partial` and read nowhere else), or the pass made `partial` or routed through replay when a
  group it demanded merges below it — then the assert, which is O(pool).
- **Fixture** the assert itself, once decided (three claimed fixtures and `scenario/PERM` trip it).
- **Slice** unassigned — R8b proposed (the fixpoint's owner next).
- **Status** R8b (2026-09-26), fixed and claimed. The observation above was two things. (1) What
  tripped the pool-rank assert on the three fixtures and `scenario/PERM` is benign: a pass that
  instantiates a DONE method's scheme shares its ground structure (a `T` node the generaliser left
  at rank 1; `Instantiate.copy` copies only what is generalised), so a pass variable unified with
  it lands in a rank-1 class holding no variable. (2) The channel the entry names is real, but
  none of those fixtures reached it: a pass that demands an unchecked group which, checked nested,
  merges down into the asker's now meets a method IN FLIGHT, and `Instances.ownMethod` unified
  the pass's method type with the member's variable. `run/DerivedContextPassMergesDown` reaches it
  (`key`'s unused `u` was bound from inside the discarded frame). Fixed by routing that case through
  §11.2's in-flight branch (closed: replay in the asker's frame; parametric:
  `method_needs_annotation`). The assert shipped is the linear form that tells the two apart, at
  the point of change: while a fixpoint frame is current, no unification may change a flex of an
  older frame (`Unify.assertContained`) and no wanted may ride on one (`Resolve.attach`), O(1)
  each, Debug only. Without the fix it panics on the new fixture; with it, every fixture,
  `test-v2` and `scenario/PERM` pass under it (`checker-v2.md` §11.2 *as amended by R8b*).


### CK-118 — The old checker refuses a type that wraps a record schema endpoint

- **Severity** valid-program-rejected. **Area** capability × schema, v1 only. **Class** K7.
  **Sources** R8b's probes (2026-09-26).
- **Program** `pub schema Rec = f : Int via conv` (or `f : Int`, no `via`), `type HoldsRec =
  HoldsRec Rec.Type`, `sameHolds a b = a == b` on `HoldsRec`.
- **Observed** NOT EQUATABLE `HoldsRec`, exit 1. Writing the endpoint's expansion out, `type HoldsRec
  = HoldsRec { f : Mine }`, checks.
- **Expected** exit 0: a record endpoint is an alias, and a type that holds one compares through its
  expansion (`schema.md` §4; `checker-v2.md` §11.5).
- **Root cause** v1 answers the wrapper from the alias endpoint's session capability bits, which the
  interleaved settle (CK-24's root cause) leaves refusing, instead of from its expansion.
- **Fixture** `check/good/SchemaRecordViaWrapped.beni`; `check/good/SchemaViaMutualOwnType.beni`
  (the `via` fixpoint accepted in every declaration order, `scenario/PERM`).
- **Slice** R8b, claimed (2026-09-26): v2 walks the alias's expansion; v1 is frozen.

### CK-119 — A ring of types closed through a `via` re-runs exponentially, then says a false `not_equatable`

- **Severity** performance (and a wrong refusal at the budget). **Area** the derived-context
  fixpoint over schema endpoints, v2 only, R8b's first build. **Class** K3. **Sources** R8b's
  structural review B1 and adversarial review F1 (2026-09-26).
- **Program** `M0 → M1 → … → M(n-1) → S.Type` and `S`'s `via conv : Conversion Int M0`, one `==`
  on `M0` (structural review's generator); or a ring of n schemas, each with a `via` to its own
  `type` holding the next schema's endpoint (adversarial review's).
- **Observed** each ring member about 6–8× the one before (Debug: 1.3 s at n = 5, 8.4 s at 6; the
  schema ring 16.5 s and 1.3 GB at 5); from 5–7 on the step budget ran out inside a quiet run, its
  message was dropped, and the entry became `absent_other`: a false `not_equatable` on a valid
  program. v1 answers in about 150 ms.
- **Root cause** the unit graph could not see a `via` target's mentions; R8b joined them lazily
  (a cross-run read marked the runs above `partial`, never memoised, so each level re-ran the one
  above); and `sayInternals` dropped `nesting_too_deep`. Also found: a run nested in another run's
  pass said its internals into the same quiet list it was reading, losing them.
- **Fixed** in R8b's review round: `Contexts.complete` makes the unit graph exact before a unit
  runs (`checker-v2.md` §11.5 *amended by R8b's review round*); a budget in a pass is
  `absent_budget`, `nesting_too_deep` at the use; the worklist asserts it climbs and caps at 2²²
  passes; nested internals are said by the outermost run.
- **Fixture** `test-perf`'s "CK-119" (n = 4 000 / 8 000, ratio 1.86; with `complete` disabled
  it is red, `internal` at the ring); `tests/corpus/check/good/SchemaViaRing.beni` (six schemas),
  in `scenario/PERM`.
- **Slice** R8b (found and fixed).

### CK-120 — The `equatable` marker's gate of a `type` cannot see a `via` target

- **Severity** unsound-runtime (no runtime path until schemas emit). **Area** §11.4's marker
  walk, both checkers. **Class** K7. **Sources** R8b's structural review S1 (2026-09-26).
- **Program** `conv : Conversion Int Mine`, `type Mine = Mine (Int -> Int)`, `Loop` with
  `payload : Int via conv`, `type Holds = Holds Loop.Type`; `Basics.eq` on two `Holds`.
- **Observed** `==` on `Holds` is `not_equatable` (the derived contexts), `Basics.eq` on it is
  accepted (the table-build bit "no function in its declaration"): two answers to one question.
  An importer's side has the same hole.
- **Fixed** in R8b's review round: the gate of an `adt` is `Marker.functionFree`, published as
  `no_function` (§11.4, §14.2 *amended by R8b's review round*).
- **Fixed again** in R8b's round-2 review (its B1): the first fix did not demand the schemas it
  walked, so an unchecked schema's unfilled `via` target read as "no function" — order-dependent,
  and an in-flight one was accepted where `==` refused. `functionFree` now completes the graph
  around the type (demanding every reached schema) and is UNKNOWN while one is in flight, deferred
  to P5 (`checker-v2.md` §11.4 *amended by R8b's round-2 review*). Fixtures
  `check/bad/EquatableMarkerUncheckedSchema.beni` (the use first) and `…InFlightSchema.beni`, and
  the local fixture in `scenario/PERM` with both uses counted.
- **Fixture** `check/bad/EquatableMarkerThroughWrappedEndpoint/` (importer) and
  `…Local.beni`, claimed.
- **Slice** R8b (found and fixed; v1 frozen).

### CK-121 — Checker v2 panics on a bodyless annotation with a `where` clause

- **Severity** compiler-crash-or-hang. **Area** P6 (`Module.elaborate`), v2 only. **Class** K9.
  **Sources** R8b's adversarial review F4 (2026-09-26); pre-existing at b64342b.
- **Program** `less x y = x < y`, then a separate `less : a, a -> Bool where a.compare : …`; or
  the annotation given twice.
- **Observed** exit 134, "an annotated declaration's `where` clause registered a different number
  of givens". v1 reports `annotation_without_definition` and `duplicate_declaration`.
- **Root cause** a declaration with no body has no rigid reading, so no givens; P6 asserted it had.
- **Fixed** in R8b's review round: a bodyless declaration's requirement roots are its scheme's.
- **Fixture** `tests/corpus/check/bad/WhereAnnotationAfterDefinition.beni`,
  `…/WhereAnnotationRepeated.beni` (v1's diagnostics; `v2-green.txt`).
- **Slice** R8b (found and fixed).

### CK-122 — Comparing through a `type alias` of a schema endpoint is `internal`

- **Severity** compiler-crash-or-hang (an `internal` on a valid program) and valid-program-
  rejected. **Area** alias expansion of schema endpoints, both checkers. **Class** K7.
  **Sources** R8b's adversarial review F2 (2026-09-26); pre-existing.
- **Program** `schema R tagged "k" of A as "a" v : Int`, `type alias RW = R.Type`, `z : RW, RW ->
  Bool`, `z p q = p == q`.
- **Observed** v2: two `internal`s at `==` ("a wanted of this site failed, but nothing was
  reported", I7); v1 one. Tagged and record schemas, `.Type` and `.Encoded`, `==`/`<`/`List.sort`,
  in one module or across modules. `type H = H RW` compared is a false `not_equatable` in both.
  With other errors in the module the internal is suppressed, and in one probe the bad comparison
  went unreported. The interface prints `alias RW` with no body row.
- **Expected** exit 0: an alias of an endpoint answers as the endpoint (`schema.md` §4,
  `checker-v2.md` §11.5).
- **Slice** proposed: an R8b follow-up before R9 (the manager's call). Reasoning: it is v2's
  derived-context territory (a type alias whose body is a schema endpoint must expand to the
  endpoint's nominal app, in the annotation reader and in the interface's alias body), R9 makes v2
  check everything and must not start with an `internal` on valid code, and it is small and
  separable from R8c's performance work.
- **Root cause** (R8c, 2026-09-26): `Types.Builder.aliasBody`, the shared reader of an alias's
  body, built its inner reader with no schema lookup and no interfaces, so an endpoint in the body
  read as a silent `err`. Worse than the internals: an `err` unifies with anything, so `r + 1` on
  an `RW` checked clean in both checkers (a hole). The interface's `alias RW` with no body row is
  not part of it: no alias row prints a body.
- **Fixed** in R8c (its own commit): the body of the checked module's own alias is read with the
  caller's schema lookup; another module's alias body reads the endpoint from that module's
  interface (`Types.schemaMemberOfDecl`, a per-declaration index built with the table), and a
  private tagged schema's endpoint as its nominal type (`checker-v2.md` §11.5 *amended by R8c*).
  Fixtures `check/good/SchemaEndpointAlias`, `check/good/SchemaEndpointAliasAcrossModules`,
  `check/bad/SchemaEndpointAliasKeepsItsType` (all red before: `internal`, a false refusal, or
  exit 0). The residue — a private RECORD schema through another module's alias — is CK-126.

### CK-123 — A polymorphic `via` target leaks a free type variable into an endpoint

- **Severity** unsound-runtime (no runtime path until schemas emit). **Area** the schema checker
  (`Schema.State`, the `via` group), both checkers. **Class** K1. **Sources** R8b's adversarial
  review F3 (2026-09-26); pre-existing.
- **Program** `conv : Conversion Int a`, `schema L tagged "k" of X as "x" v : Int via conv`,
  `cast n = case L.X { v = n } of L.X r -> r.v` at `Int -> String`.
- **Observed** exit 0 in both checkers: an `Int` becomes a `String`. The interface shows
  `ctor type.X/1 : { v : a } -> L.Type` with `a` free in a type of no parameters (v1 attaches
  `where a.compare …, a.eq …` too). Under v2 a wrapper of such an endpoint is a misleading
  `not_equatable` ("a function anywhere").
- **Expected** a `via` whose target is not closed over the schema's parameters is refused.
- **Slice** the schema slices' owner (S3/S4): the schema checker's elaboration rule
  (`schema.md` §4), not the derived contexts.

### CK-124 — Lowering and resolution of many schemas are quadratic

- **Severity** performance. **Area** frontend (`bir.Lower.couldBeSchemaQualified`,
  `resolve.Resolve.localSchema`). **Class** K14. **Sources** R8b's review round (2026-09-26),
  profiling CK-119's schema ring.
- **Program** n schemas in one module, each referenced (CK-119's schema-ring generator).
- **Observed** ReleaseFast, checker v2: 1 600 / 3 200 / 6 400 / 12 800 schemas take 0.09 / 0.26
  / 0.95 / 3.5 s; `perf record` at 6 400 puts 28 % in `mem.eqlBytes` under
  `couldBeSchemaQualified` and 14 % in `Resolve.localSchema`, both linear scans per reference.
- **Also** (R8b's round-2 review, 2026-09-26): at 16 000 schemas lowering spends 4.5 s and
  resolution 1.2 s in `Lower.couldBeSchemaQualified` / `mem.eqlBytes`, and the `check` phase grows
  2.5–2.9× per doubling in `SchemaPlanBuild.Builder.*`, `Schemes.Writer.typeRefOf` (a scan of
  the writer's type references per mention — made a map in R8b's round-2 review, shared code) and
  `Types.find` from `Types.resolveRefs` (a scan of the module's types per reference, still
  quadratic).
- **Slice** unassigned (frontend; CK-40 and CK-41's family).

### CK-125 — A derived context's step budget was its asker's

- **Severity** valid-program-rejected (order-dependent). **Area** the derived-context fixpoint,
  v2 only, R8b's first review round. **Class** K12. **Sources** R8b's round-2 review S1
  (2026-09-26).
- **Program** `type alias R` of 4 000 `Int` fields, `type T = T R`; `g` makes 262 comparisons of
  `R`s and then `t == u` on `T`; `h t u = t == u`.
- **Observed** with `g` first, `T`'s context ran out of `g`'s per-group step budget inside `g`, was
  memoised permanently as `absent_budget`, and `h` was refused with `nesting_too_deep`; with `h`
  first both checked. v1 and b64342b's v2 accept both orders.
- **Fixed** in R8b's round-2 review: a run has a budget of its own (saved, zeroed, restored); a
  result with `absent_budget` is never memoised; one surviving to P8 is `internal`
  (`checker-v2.md` §11.5 *amended by R8b's round-2 review*).
- **Fixture** `test-perf` "CK-125" (both orders, a Debug build takes 26 s an order): red with the
  budget shared (exit 1), green now.
- **Slice** R8b (found and fixed).

### CK-126 — A private record schema's endpoint has no shape through another module's alias

- **Severity** unsound-runtime (a silent hole; no runtime path until schemas emit). **Area** the
  shared alias reader (`Types.Builder.aliasBody`) and the interface, both checkers. **Class** K7.
  **Sources** R8c, fixing CK-122 (2026-09-26); pre-existing.
- **Program** `Models`: `schema PrivRec = z : Int` (private), `pub type alias PrivRecW =
  PrivRec.Type`. `Main`: `bump : Models.PrivRecW -> Int`, `bump r = r + 1`.
- **Observed** exit 0 under both checkers: the importer reads `PrivRecW`'s body in `Models`, where
  `PrivRec.Type` names a schema that is in no interface, so the expansion is an `err` and unifies
  with `Int`. A tagged private schema is read as its nominal type since R8c; a record endpoint's
  shape exists only in its module's schema state.
- **Expected** `PrivRecW` is `{ z : Int }` in the importer as in `Models`: `r.z` checks, `r + 1`
  is a TYPE MISMATCH. The oracle twin (`PrivRec` made `pub`) says exactly that.
- **Fix** an interface row, not a reader rule: the interface carries no alias bodies
  (`checker.md` §7's `alias_body`) and lists `pub` schemas only, so the importer has nothing to
  expand. A hidden endpoint row for a private schema a `pub` alias body names, or `alias_body`.
- **Fixture** `tests/pending/check/bad/PrivateRecordSchemaAliasAcrossModules` (red under both).
- **Slice** unassigned: the schema slices' owner or R9 (interface work).
- **Note** (R15-fix-C, 2026-09-28) the Debug check `Module.assertErrorsReported` (§12.2 *amended
  by R15-fix-C*) catches this silent `err`: the fixture's red is `crash=ABRT` in Debug; release
  still accepts it.
- **Status** fixed by R15-fix-D (2026-09-28), `checker-v2.md` §11.5 *amended by R15-fix-D*: not an
  interface row — the endpoint is read from the declaring module's schema plan, which holds
  private schemas and is installed on a cache hit (`Types.Builder.planEndpoint`). The digest had
  the same hole one level down (an alias body digested a schema endpoint as `err`, so editing the
  private schema moved no digest and a cached importer kept its verdict): `type_body` now names
  endpoints (`digest_test.zig`, "row 13 for a schema"). Promoted into `tests/corpus/check/bad/`.

### CK-127 — Lowering a `let` of many bindings is quadratic

- **Severity** performance. **Area** frontend (`bir.Lower.lowerBindings`, `resolveValue`,
  `bindVar`), both checkers. **Class** K14. **Sources** R8c, measuring CK-93 (2026-09-26).
- **Program** CK-93's: `foo x0 = let x1 = [ x0 ] … xN = [ xN-1 ] in List.length xN`.
- **Observed** ReleaseFast, the `lower` event: 16 / 61 / 249 ms at N = 4 000 / 8 000 / 16 000
  (`check` under v2 after R8c: 6 / 9 / 15 ms). `perf record` at 16 000: 49 % in `lowerBindings`,
  16 % `resolveValue`, 13 % `bindVar` — a scan of the scope per name bound or read — and 15 %
  `memset`.
- **Expected** linear: a scope lookup that does not scan every binding of the block.
- **Fixture** none yet: a `test-perf` scenario on the `lower` event (`perf_test.zig`'s
  `eventRatio`), CK-93's generator.
- **Slice** unassigned (frontend; CK-124's family).
- **Status** fixed by R12 (2026-09-27) as a duplicate of CK-95 (the same defect, found twice): see
  CK-95. Its fixture is CK-95's scenario, which is the one this entry asked for.

### CK-128 — Derived `==` and `<` recurse once per level of the data, and overflow node's stack

- **Severity** unsound-runtime (a runtime exception on a program the compiler accepts; the owner
  decided on 2026-09-26 that it must never throw). **Area** the emitted derived
  `eq` and `compare` (backend), both checkers. **Class** K14. **Sources** R8c, testing CK-114;
  measured by R8c's review (2026-09-26).
- **Program** two shapes, built for node (node 24, default stack), the emitted JavaScript the same
  under both checkers and in development and `--release`:
  - CK-114's record literal nested d deep, `u0 = mk == mk`, printed by `main`;
  - a user linked list built by a tail-recursive loop, `type L = Cons Int L | Nil`, compared with
    derived `==` and `<`.
- **Observed**
  - The record passes at 3 746 levels and throws `RangeError: Maximum call stack size exceeded` at
    3 747 (the parser accepts 4 095): two frames a level, `Main` and the evidence closure.
  - The linked list — the realistic case — throws on `==` at **8 940 cells** (8 939 pass), and on
    `<` at 10 000. Any user recursive type of modest length is exposed.
  - Core `List.eq` on 10⁶ elements is fine: it is a loop.
- **Precedent** Elm's `_Utils_eqHelp` (`elm/core`, `Utils.js`) recurses to depth 100 and then
  defers the rest to an explicit stack, so Elm's `==` does not throw here. Its `_Utils_cmp`
  recurses (only a list's spine is a loop), so Elm's `<` on a user linked list would. (Elm
  compares only tuples, lists and primitives with `<`, so the case does not arise there.)
- **Expected** the comparison's answer: a derived `eq`/`compare` that does not grow the native
  stack with the data (the owner, 2026-09-26: as Elm does, an explicit stack past a depth
  threshold).
- **Fixture** `run/DerivedDeepData`, `run/DerivedDeepPaths`, `run/DerivedDeepOrder/`,
  `run/DerivedDeepAcrossModules/`, `abuse_test.zig` (CK-128).
- **Slice** R8d (owner 2026-09-26: fix as Elm does — no RangeError on deep data; black-box run/ and
  abuse tests required).
- **Status** R8d (2026-09-27), fixed, both checkers (the emitter is
  shared), with one stated exclusion: recursion THROUGH a hand-written method (`type T = T (Box T)
  | E` with a hand-written `Box.eq … where a.eq`) still throws on deep data, because the method
  cannot hand back steps; `abuse_test.zig` pins it. A derived function that can recurse takes `$d = 0`, recurses to 400 units and continues
  in a `function* <base>$$steps` twin on the module's `derived$deep` engine; leaves are emitted as
  before (`backend.md` §4, *Derived comparisons do not grow the native stack*, which has the
  measurements in Chrome 153, Firefox 144, WebKit and Node 24). Fixtures `run/DerivedDeepData`,
  `run/DerivedDeepPaths`, `run/DerivedDeepOrder/`, `run/DerivedDeepAcrossModules/`, and
  `abuse_test.zig` "a record literal nested to the parser's limit compares and RUNS …" and "a
  recursive type of 4 096 and 4 097 parameters …", all red before (`RangeError`); `DerivedDeepOrder`'s
  ORDER claim is shown by a 5 000-deep variant printing byte-identical output on `e86883a`. The
  exclusion: `abuse_test.zig` "recursion THROUGH a hand-written parametric method …".
  R8e (2026-09-27) reshaped the cost, not the guarantee: tail self-calls loop, forwarders (every
  depth-taking call in tail position) have no steps, and one runtime file `_core/_derived.mjs`
  replaces the per-module engine and `core/List.js`'s changes (`backend.md` §4). Fixtures added:
  `abuse_test.zig` "a chain of forwarders … `Just` nested 4 095 deep" and "… 50 nested wrappers a
  level …", both red before.

### CK-129 — The hint for `exposing (T(..))` suggests `exposing (T, T)`, which is refused

- **Severity** diagnostic-quality. **Area** the parser's hint for Elm's `(..)`, frontend. **Class**
  K13. **Sources** R8d, writing `run/DerivedDeepOrder/` (2026-09-27).
- **Program** `Key.beni` declares `pub type Key = Key Int`; `Main.beni` writes
  `import Key exposing (Key(..))`.
- **Observed** EXPECTED TOKEN: "list the constructors you use by name, beside the type.
  `exposing (Key, Key)`". Following it gives DUPLICATE EXPOSED NAME ("`Key` is already exposed");
  `exposing (Key)` is what works — it exposes the type and its same-named constructor.
- **Expected** a hint that builds: when a constructor shares its type's name, `exposing (Key)`.
- **Fixture** none yet.
- **Slice** unassigned (frontend).
- **Status** fixed by R13 (2026-09-27) as CK-86 (the same finding): `tests/corpus/check/bad/ExposingSameNameConstructor/`.

### CK-130 — Under v2 checking `core`, `Order` has no `compare` and `Never` no `eq` or `compare`

- **Severity** valid-program-rejected. **Area** derived contexts and publication (§11.2, §14.2),
  v2 only. **Class** K7. **Sources** R9, the first build with v2 checking `core` (2026-09-27).
- **Program** any module outside `Basics` writing `LT < GT`, `Just LT < Just EQ`, `List.sort` over
  `Order`s, or `==`/`<=` on a `Maybe Never`.
- **Observed** `no_methods_on_shape` at each use: "This type has no `compare`: Order". `Basics`'
  record, now written by v2, said `own_method` for `Order`'s `compare` and for both of `Never`'s
  methods, and wrote no derived row: `Contexts.module_has` (the module rule, §11.3) saw `Basics`'
  `pub compare : number, number -> Order` and `pub foreign eq`, and `Contexts.peek`, the fixpoint's
  first approximation, `Derivable.headNeedsRun` and `Publish.derived` read it without asking the
  well-known table first. Resolution (`Instances.onApp`) consults the table before the module rule
  and answered `derived` — from a row the record did not have.
- **Expected** v1's rows: `Order` `eq=primitive compare=present`, `Never` `eq=present
  compare=present`, each with its derived function (`static-dispatch-spike.md` §3.2).
- **Fix** (R9) `Contexts.moduleRuleAnswers`: the module rule answers a type's method unless §3.2's
  table derives it (`Contexts.tableDerives`: `Order`'s `compare`, both of `Never`'s), read at all
  four places. `core`'s records under v2 are then v1's but for the `no_function` bit (§14.2 *as
  amended by R8b*).
- **Fixture** `tests/corpus/run/NeverAndOrderDerived.beni` (every use outside `Basics`: direct, in
  a `Maybe`, a tuple, a record, a list, a type of the module, through a `where` clause, and a
  `Maybe Never` / own `Never`-holding type), and the existing `run/OrderValues.beni` and
  `dispatch/Primitives.beni`; all three red under `test-v2` before the fix, green after.
- **Slice** R9 (fixed).

### CK-131 — v2's check of a derived comparison at a use costs about 1.6× v1's (`s_tup6000`)

- **Severity** performance. **Area** the resolver's derived path (`Instances.derivedPositions`,
  `importedMethod`, `Derivable.derivability`), v2 only. **Class** K11. **Sources** R9, measuring
  `checker-v2.md` §18's three medians, which no slice had re-measured since the diary's
  2026-09-24 entry (2026-09-27).
- **Program** `s_tup6000`: 6 000 declarations `fN : Int, Int -> Bool`, `fN a b = ( a, [ b ] ) <
  ( b, [ a ] )`, one module (R9's scratch generator; the diary's program of 2026-09-24 was not kept).
- **Observed** ReleaseFast, `--self-profile`, the sum of `check` events, median of 7: v1 29.4 ms,
  v2 55.6 ms at `ed61b07` (1.89×; whole process 1.53× in cycles); 47.0 ms after R9's two changes
  (1.58×). `s_int6000` (`a < b`) is 1.07×, and the tuple of two `Int`s alone
  (`( a, b ) < ( b, a )`) 1.66×: the cost is per derived position. The profile of `ed61b07`: the
  imported `List.compare` instantiated from its interface bytes at every position
  (`Schemes.instantiate`, `Reader.read`, `orderWalk`, about 5 % of v2's check), the derivability
  walk's two hash maps (about 6 %, halved by R9), the store's growth (about 6 %, gone with R9's
  reserve), and a sub-wanted created and stepped per position.
- **Expected** §18's rule: ≤ 1.10× v1 on each of the three medians at R9 and at the cut-over.
- **Fix** done by R9b (below, *Status*). v1's answer to the same program was row 72's `plainMethodMask` (diary
  2026-09-24 00:17): an imported method whose scheme is `T a1 … an, T a1 … an -> Bool|Order` with
  exactly its own name required of its parameters answers without instantiating. v2's analogue must
  create each position's sub-wanted with the requirement's own `kind`, and ready it on the frame's
  queue as the unification of the instantiated scheme would (`Unify.readyWanted`), so the
  resolution order and every diagnostic stay the same; beyond that the per-position wanted itself
  is the next cost.
- **Fixture** `tests/blackbox/perf_test.zig`'s `CK-131` scenario (`zig build test-perf`): not a
  size ratio but v2 against v1 on one binary, the file's own `check` event, best of 5, bound
  1.25× — red on `919f8be` (167 %), green on R9b (107 %); `a < b` over `Int` is its control.
  The budget itself (1.10× on medians) is `checker-v2.md` §18 *as measured by R9b*.
- **Slice** R9b (2026-09-27), the manager's: fixed.
- **Status** fixed by R9b. Five changes, each measured on its own (§18 *as measured by R9b*): a
  table primitive whose method type already is `root, root -> Bool|Order` is answered in
  `Resolve.step` without the unification that could only succeed, and `unifyWellKnown` skips it
  on that shape everywhere; the plain-method fast path (`Instances.plainImported`, v1's
  `plainMethodMask`: `List.compare`'s requirement made directly, readied as the binding would
  ready it); the ground derivability memo a dense column instead of a hash map; a per-module memo
  of derivability keyed by the ground shape's STRUCTURE (`Derivable.Shapes`,
  `Walk.encodeGround`); and P6's unit memo searched inline for small units. (A sixth, skipping
  the cycle test for a bounded ground encoding, was measured at −1 % and declined.)
  `s_tup6000` 1.60× → 1.06–1.10× v1 (summed `check` events, medians of 7), whole process
  1.10× in cycles; `s_int6000` 0.95×. A differential
  over the corpus, `tests/pending/`, `core` and `bench/` against `919f8be` found no byte of
  difference.
- *Fixture converted by R12 (2026-09-27).* The `test-perf` scenario compared v2 with v1 on one
  binary (≤ 1.25× v1), and v1 is gone. It is now the same program against its control
  (`s_int6000`, `a < b`) on the one checker, ≤ 250 % (`perf_test.zig`, "CK-131: a derived
  comparison per declaration checks within 2.5× its a < b control"). Three rounds, ReleaseFast:
  `919f8be` under `--checker=v2` (the defect) 287 / 292 / 299 %, red; R12 213–224 %, green; v1
  178–190 %.

### CK-132 — v1's cutoff key cannot see a private `eq` or `compare`: a warm check accepts what a cold one refuses

- **Severity** nondeterminism (the answer depends on the cache's history). **Area** v1's
  interface record and dependency digest (`cache/Digest.zig`, v1's settled bits), v1 only.
  **Class** K7. **Sources** R10, running the reviewer-focus scenarios under both checkers
  (2026-09-27).
- **Program** `Leaf.beni` of `cutoff_test.zig`'s project (a private `type Hidden` a `pub make`
  returns; `Mid` compares `Leaf.make x == Leaf.make y`) gains a private
  `eq : Hidden, Hidden -> Bool`. Or: `M.beni` holds `pub schema S tagged "kind" of V as "v"`
  with `payload : Int via conv` into a private `type Target = Target Int`, `N.beni` compares two
  `M.S.Type`s, and `M` gains a private `eq : Target, Target -> Bool`.
- **Command** `B check --checker=v1 --cache-dir=c src` before the edit, then again after it, then
  `B check --checker=v1 --no-cache src`.
- **Observed** the cold check reports `private_method` at the importer's `==` (D1, §11.3) and
  exits 1; the warm one exits 0. Under v1 the edit moves neither `M`'s interface hash nor its
  dependency digest (`--iface-hash`, `--dep-digest`: both byte-identical), so the importer's key
  does not move and its clean entry is read back.
- **Expected** Warm and cold agree (`fast-compiler.md` §8's acceptance). Under v2 they do: the
  module rule makes `Hidden`'s and the endpoint's derived rows `private_method` (§14.2 *as amended
  by R8b*), so `M`'s interface hash moves and the importer is re-checked.
- **Root cause** v1 publishes no derived row that states the module rule, and its digest carries
  the `equatable`/`comparable`/`has_function` bits, not "the module declares a private method of
  this name". The rows exist for v1 too (R3) but v1 writes `present` for them.
- **Fixture** v2's side, which is the checker that stays: `cutoff_test.zig`'s "add a private eq
  (§11.3, D1)" row, run under v2 only, and `cache_test.zig`'s schema case of "checker v2: an edit
  that moves a dependency's derived context …". Both are red under v1 (shown by R10; the row
  fails `ExitCodeDiffers`, exit 1 cold and 0 warm).
- **Slice** none: v1 is frozen (`checker-rewrite.md` §1). Closed when v1 is deleted (R12); from
  R11 no build reaches v1's path by default.
- **Status** closed by R12 (2026-09-27): v1 is deleted. Its v2 side stays in the gates
  (`cutoff_test.zig`'s row, no longer `v2_only`, and `cache_test.zig`'s schema case).
  *2026-09-28:* the `cutoff_test.zig` row is gone — that file now keeps one edit per branch of the
  cut-off decision, and a private `eq` moves the module's interface hash, the branch its pub
  signature edit covers. `cache_test.zig`'s schema case and its private-method evidence cases are
  the regression.

### CK-133 — The Debug check of an acyclicity proof re-walks the proved graph at every stop: 31 s on a 4 095-level record

- **Severity** performance (safe builds only: Debug, and ReleaseSafe, where
  `std.debug.runtime_safety` also holds). **Area** `check/Walk.zig`'s `assertProved`
  (R8c's review rounds). **Class** K11. **Sources** R12, running `test-blackbox` (2026-09-27).
- **Program** `abuse_test.zig`'s CK-128 scenario: two record literals nested 4 095 deep, compared
  with `==` and `<`.
- **Command** `build --platform=node --no-cache` on the Debug binary.
- **Observed** 31.5 s at `ebec203` (and on R12 before the fix), where ReleaseFast takes 0.13 s;
  `perf record`: the time is `assertProved`'s hash map, reached from `Resolve.position` through
  `Occurs.check` at every stop at a proved node, each re-walking up to `assert_cap` = 1 024 nodes
  of the proved graph. Under `test-blackbox`'s parallel load the build passed the harness's 60 s
  timeout: the scenario failed 2 of 4 R12 runs with `CompilerTimeout` (it did before R12's changes
  too, in the first run).
- **Expected** a Debug check that costs at most a constant factor over the check it guards.
- **Fixture** `abuse_test.zig`'s CK-128 scenario (its timeout; red only under load).
- **Slice** R12 (found and fixed).
- **Status** fixed by R12: the walks share a budget per store — 16 visits per store variable, plus
  a floor of 2²⁰ — so every corpus program is still checked in full (a store under 65 536
  variables never reaches the floor) and a pathological one until the budget runs out. The
  scenario's Debug build: 31.5 s → 9.9 s idle.

### CK-134 — The check phase on the dispatch-shaped bench corpus is 1.12× `7427828`'s

- **Severity** performance. **Area** the checker as a whole (v2 against v1's baseline). **Class**
  K11. **Sources** R12's exit measurement (2026-09-27).
- **Program** `zig build bench -- --generate=100000 --dispatch` (and the plain corpus beside it).
- **Observed** ReleaseFast, check phase, five interleaved rounds, medians: plain 92.98 ms at
  `7427828`, 101.83 at `ebec203` (R11), 101.05 at R12 — **1.087×**; dispatch 101.05, 114.16,
  113.38 — **1.122×**. Whole process (`perf stat -r 7`, `check --no-cache --jobs=1` of the same
  generated trees, user cycles): plain 458 M → 486 M (1.06×), dispatch 485 M → 534 M (1.10×).
  R12 itself moved nothing (R11 → R12 within noise in both); the gap is v2's against v1's
  7427828 figure, which R11 measured at 1.01× only because it compared the two checkers on ONE
  binary built from R11's tree.
- **Expected** `checker-rewrite.md` R12's exit: ≤ 1.0× the `7427828` figure the target, over 1.10×
  a finding. Plain is inside; dispatch is over.
- **Fixture** none: the bench is the instrument (`checker-v2.md` §18).
- **Slice** R14b (the manager, 2026-09-27).
- **Status** **fixed by R14b** (2026-09-27). The bench's check line, medians of 7 interleaved
  rounds: dispatch 100.0 ms at `7427828`, 110.1 at `881e23d`, **76.0** at R14b (0.76×); plain 93.7,
  99.5, **67.1** (0.72×). The per-operation gap (an interface-sized memo cleared per imported
  instantiation, rank adjustment re-entering walked roots, out-of-line empty-case tests on the
  unify path) was closed first; the largest change was not v2's own: each module's store mapped
  and unmapped its own pages (v1's did too, with a third of the reservation), and is now carved
  out of the worker's scratch arena. Output byte-identical over the whole
  corpus; each change measured alone (`checker-v2.md` §18 *as measured by R14b*).

## R15's audit (2026-09-27)

Four read-only audits of the finished checker at `8b98464`, all on 2026-09-27: the inference core
(**core-r15**), static dispatch re-run (**disp-r15**), orchestration re-run (**orch-r15**) and an
adversarial black-box campaign of about 32 000 generated and mutated programs (**adv-r15**).
Duplicates are folded (core's F1 and disp's first finding are CK-135; core's emit blow-up and
disp's second are CK-136). **Observed** is at `8b98464`; `B` is its Debug binary and `R` its
ReleaseFast one (`zig-out/perf/bin/beni`). Every behavioural entry has a red fixture or scenario
under `tests/pending/`, written before any fix and recorded in `tests/pending/RED`; a structural
entry says so and has none. Every entry's slice is **R15-fix**, the slices that follow the audit.

### CK-135 — `Schemes.orderWalk` stops silently at depth 512, dropping requirements

- **Severity** compiler-crash-or-hang (Debug panic; `INTERNAL ERROR` in release; a spurious
  mismatch inside a `let`). **Area** `Schemes.quantifierOrder` (Schemes.zig:606–655), read by
  `Evidence.requirements`, `Resolve.holdLet` and `closeLet`. **Class** K3 (I4, I2). **Sources**
  core-r15 F1, disp-r15 CK-135.
- **Program** `w1 x = ( x, x )`, `u1 ( p, _ ) = p`, `w{k} x = w{k-1} (w{k-1} x)`,
  `u{k} t = u{k-1} (u{k-1} t)` up to 10; `g t = t == w10 (u10 t)`; `v = g (w10 1)`. `g`'s `eq`
  sits on a variable 2^10 levels down.
- **Observed** `B check`: panic "an instantiation's requirement is paired with no wanted"
  (Solve.zig:256). `R`: `INTERNAL ERROR`s. At `w9` it checks. Core's `let` variant (515 nested
  applications) is a spurious TYPE MISMATCH at 515 and clean at 505: acceptance depends on depth.
- **Expected** the module checks; the canonical order is an explicit-stack walk with no depth cap
  (or `too_deep` reported for every declaration).
- **Fixture** `check/good/RequirementBelowDepth512.beni` (`.iface`: `module Main`), red
  `crash=ABRT`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-A (2026-09-28). `Schemes.orderWalk` is an explicit-stack preorder
  with no depth cap (marked when popped, successors pushed reversed: the recursive order
  exactly). A type too deep to WRITE is still the writer's `nesting_too_deep`, so the two orders
  can differ only for a scheme that is never published. Promoted:
  `tests/corpus/check/good/RequirementBelowDepth512.beni`. Core's `let` variant was not
  reproduced: a `let` helper comparing a type 515 and 700 written applications deep checks clean
  on the base too, so it is no fixture.

### CK-136 — The backend and the `dispatch` dump walk the shared evidence DAG as a tree

- **Severity** compiler-crash-or-hang (a hang). **Area** `src/js/Lower.zig`
  (`Lowerer.derivedBodiesExist`, 4379–4389, recurses with no visited set, suspected), and
  `dump --stage=dispatch`'s printer. **Class** K11 (K14: backend). **Sources** core-r15 (outside its
  scope), disp-r15 CK-136.
- **Program** CK-135's `w{k}` to 6; `main = Node.printLines [ if w6 1 == w6 2 then "T" else "F" ]`.
- **Observed** `check` 70 ms at every depth; `build` does not finish in 60 s at `w6` (32 levels),
  81 ms at `w5`. `dump --stage=dispatch` at `w7` wrote about 2 GB in 20 s. Core's variant (`let
  a0 = ( x, x )`, … `a23 == a23`) builds in 1.1 s at 24 levels (`emit` 1 247 ms) and not in 60 s at
  40, although the emitted JavaScript is linear.
- **Expected** it builds and prints `F`; a term memo in the walk, and shared terms printed once by
  index in the dump (the dispatch goldens come from that printer). A `test-perf` scenario at depth
  64 once fixed.
- **Fixture** `run/EvidenceDagBuildDepth32.beni`, red `timeout`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-B (2026-09-28). The suspect was the whole cause: `derivedBodiesExist`,
  the I7 re-check `refuseEvidence` runs per site, recursed into every argument with no visited set.
  `readTable` now judges it for every term once, from the last (the pre-order rule
  `termOkLocal` already used), so it is linear in the table. The dump prints a shared term with
  arguments in full once, `<term> #<n>`, and `<term> = #<n>` after (`checker-v2.md` §13.2 *amended
  by R15-fix-B*); no existing golden moved. Promoted to `tests/corpus/run/EvidenceDagBuildDepth32`
  (dev and `--release`; red on `1bec73c` by timeout), plus `dispatch/SharedEvidenceDag` and the
  `test-perf` scenario "CK-136" at depth 32 / 64, build and dump: `1bec73c` builds this
  generator's depth 20 / 22 / 24 in 21 / 57 / 196 ms CPU (×4 per two levels); fixed, depth 32 /
  64 build in 8 / 9 ms and dump in 22 ms.

### CK-137 — `==` on a type reuses a sibling type's resolution of its module's `eq`

- **Severity** **unsound-runtime, critical**: a type-confused call at run time, and acceptance
  depends on declaration order (I9). **Area** well-known method resolution (a memo of `(module,
  method)` keyed without the type constructor, for zero-argument types, suspected). **Class** K7.
  **Sources** adv-r15 F2.
- **Program** `Two`: `pub type A = A Int`, `pub type B = B String`, `pub eq : A, A -> Bool`,
  `eq (A x) (A y) = modBy x 2 == modBy y 2`. `Main`: `f : Two.A -> Bool`, `f a = a == a`, then
  `Two.B "x" == Two.B "x"`.
- **Observed** exit 0 in dev, `--release` and `--jobs=1 --no-cache`; the program calls
  `Two$eq({ $: "B", a: "x" }, …)` (A's arithmetic on a String, NaN) and prints `different`. The
  same with `compare` (a reversed `pub compare` makes `B 1 < B 3` False), nested in lists and
  tuples, inside a `where a.eq` function at `B`, after a dot-call `a.eq a`, and for an all-nullary
  sibling. Not with parameterised siblings, non-well-known methods, or a first use in another
  module.
- **Expected** the module-rule clash, TYPE MISMATCH at the B comparison — what `8b98464` reports
  when `f` comes after, and when the types are in the comparing module.
- **Fixture** `check/bad/SiblingTypeEqResolution/`, red `exit=0 codes=none`.
- **Slice** R15-fix (first: it is the one unsound finding).
- **Status** fixed by R15-fix-A (2026-09-28). The key was `Resolve.State.plain`, the memo of the
  plain-method fast path (CK-131): `(module, value, compare?)`, without the receiver's type, which
  `readPlain`'s verdict depends on. It is now `Instances.PlainKey`, every input of the verdict
  (module, value, type, method). No other memo in `src/check/` keys a type-dependent answer
  without the type (the derived-answer memo keys the receiver's root, `Elaborate.own` the type,
  the contexts' units a type × method). Promoted:
  `tests/corpus/check/bad/SiblingTypeEqResolution/`; added `…/SiblingTypeCompareResolution/`
  (`compare`, all-nullary sibling).

### CK-138 — An arrow body that starts with a record or tuple literal is parsed as a block

- **Severity** unsound-runtime (a build that exits 0 emits a module that does not load). **Area**
  `src/js` arrow printing. **Class** K14. **Sources** adv-r15 F1 (about 2 % of generated programs).
- **Program** `first n = ( n, 1 ).0`; `name s = { name = s }.name`; `\s -> { v = s }.v` passed to
  `List.map`; also `f n = { r | x = n }.x`.
- **Observed** `const Main$first = (n$1) => { a: n$1, b: 1 }.a;` — `SyntaxError: Unexpected token
  ':'` at load; `--release` the same (`(d)=>{name:d}.name`). Bodies that start with a call
  (`( n, 1 ).0 + 0` → `Basics$add(…)`) are fine.
- **Expected** parenthesise any arrow body whose printed text starts with `{`; the program prints
  `3`, `ok`, `a,b`.
- **Fixture** `run/ArrowBodyStartsWithRecord.beni`, red `dev: exit=0 program-exit=1`.
- **Slice** R15-fix (backend).
- **Status** fixed by R15-fix-B (2026-09-28), `backend.md` §4 *An arrow body or a statement that
  would begin with `{`* first: the printer brackets an arrow's concise body, and an expression
  statement or assignment target, when its LEFTMOST printed token is an object literal's `{`,
  following the left spine (callee, member/index object, binary left operand, conditional test)
  through every unbracketed child. Promoted to `tests/corpus/run/ArrowBodyStartsWithRecord`, plus
  `run/ArrowBodyLeftmostBrace` (record update, field call, field of a field, `===` operand, `if`
  test; both red on `1bec73c` with a `SyntaxError`, dev and `--release`) and two `Print.zig` unit
  tests for the statement position, which no lowering reaches today.

### CK-139 — A parameterised type used bare in a constructor crashes the checker

- **Severity** compiler-crash-or-hang. **Area** `Instances.derivedNominal` (Instances.zig:594,
  `args[e.param]` on an empty argument list), from `Contexts.resolvePayloads`. **Class** K10 (the
  arity check does not guard a constructor payload before capability reads it). **Sources**
  adv-r15 F3 (mut2, 7 hits).
- **Program** `type K = K Foo` with `type Foo a = Box a`. Also `K (Foo)`, `K Int Foo`,
  `K { f : Foo }`, `K (List Foo)`, either order, `type Trip a b c = Trip a b c Trip`, and a local
  `type Int a`.
- **Observed** `B`: panic "index out of bounds: index 0, len 0"; `R`: segmentation fault (139).
- **Expected** WRONG TYPE ARITY at `Foo`, as in an annotation, an alias, `K (Foo Int Int)` or an
  imported `K Other.Foo`.
- **Fixture** `check/bad/BareParameterisedTypeInConstructor.beni`, red `crash=ABRT`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-A (2026-09-28). `Types.Builder.apply` builds `err` for an argument
  count that is not the type's arity — resolution has reported `wrong_type_arity` — so no `app`
  in the store is a partial application, and derivation never indexes past its arguments.
  Promoted: `tests/corpus/check/bad/BareParameterisedTypeInConstructor.beni`; added
  `…/BareParameterisedTypeVariants.beni` (`K (Foo)`, `K Int Foo`, `{ f : Foo }`, `List Foo`,
  `Trip a b c Trip`, a local `type Int a`, each compared).

### CK-140 — A recursive alias with two self-references is expanded once used: OOM

- **Severity** compiler-crash-or-hang (memory exhaustion). **Area** alias expansion in
  annotations after `recursive_alias` has been reported. **Class** K3. **Sources** adv-r15 F4.
- **Program** `type alias A = ( A, A )`, `f : A -> Int`, `f p = 0`. Also the mutual forms
  `A = { x : B, y : B }` / `B = { p : A }` and `( B, B )` / `{ p : A }`.
- **Observed** `R`: 16 s and 21 GB RSS (`OutOfMemory` under `ulimit -v 4000000`); `B`: past 20 s at
  5.5 GB. Without the annotation, or with one reference per step, RECURSIVE ALIAS is reported at
  once.
- **Expected** one RECURSIVE ALIAS (1:12) and no expansion of a poisoned alias.
- **Fixture** `scenario/CK-140` (fast step; a scenario only so the run can be killed at 3 s
  rather than grow for the walker's 20 s), red `timeout`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-A (2026-09-28). `Types.Builder` carries the aliases being
  expanded around a read (`expanding`), and an alias met inside its own expansion is `err`: it is
  recursive, which resolution reported. The depth bound alone had let `( A, A )` double per level.
  `scenario/CK-140` promoted into `abuse_test.zig` (the tuple and both mutual forms, 3 s limit,
  one whole `recursive_alias` each).

### CK-141 — Comparing an imported `<error>` value is an INTERNAL ERROR (a Debug panic)

- **Severity** compiler-crash-or-hang (Debug); a cascade of INTERNAL ERRORs in release. **Area**
  P6 and the I7 assert's gate: `Resolve.zig:206` rejects a wanted on an `err` receiver silently,
  `Elaborate.zig:434` and `Module.zig:265`/505 read "no error in this module" as "nothing
  poisoned". **Class** K9. **Sources** orch-r15 N1.
- **Program** `A`: `pub f = 1 + "x"`. `T`: `import A`, `g = A.f == 1`.
- **Observed** `B`: panic "I7: 1 instruction(s) whose evidence tree does not add up"; `R`: A's
  error plus two INTERNAL ERRORs at `T.beni:5:9`. Also `<`, lists, `Just`, records, tuples,
  `x == A.f` in a function or `let` helper, `List.sort [ A.f ]`, `A.f.eq 1`, and a NAMING ERROR in
  `A` — the ordinary state of a project being edited.
- **Expected** exactly A's error; nothing in `T` (a `poisoned` wanted state that P6 and I7 skip).
- **Fixture** `check/bad/ImportedErrorValueCompared/`, red `crash=ABRT`.
- **Slice** R15-fix (it blocks calling the rewrite finished, orch-r15's verdict).
- **Status** fixed by R15-fix-A (2026-09-28), `checker-v2.md` §12.2 *amended by R15-fix-A*
  first. A wanted that meets `err` is a new state, `poisoned` (`Evidence.State`), with its
  lineage — `Resolve.step`'s `err` row, `Solve.poison`, a published row whose scheme is
  `<error>`, and a dependency's `unchecked` row — distinct from `failed`, which means this module
  reported. P6 writes no site for a poisoned wanted and returns the instruction in
  `Output.poisoned`; `Module.assertEvidence` does not hold those instructions to I7. Promoted:
  `tests/corpus/check/bad/ImportedErrorValueCompared/`; added
  `…/ImportedErrorValueComparedEverywhere/` (`<`, lists, `Just`, records, tuples, a function, a
  `let` helper, `List.sort`, `A.f.eq 1`, either side) and `…/ImportedNamingErrorCompared/`.

### CK-142 — Derived-row templates bypass the one publication routine

- **Severity** compiler-crash-or-hang (in a dependent; a silent `<error>` in the publisher).
  **Area** `Publish.zig:402–414` `Facts.templateScheme` calls `writer.add` directly: no
  `Walk.hasError`, and on `too_deep` `addError()` with no `noteDeepDecl`; `ctorTerms`
  (`Publish.zig:144`) has no error scan either. **Class** K9 (CK-13's shape, a fifth path), K15
  (§14.1 names `fillCtorTerms` as a client of the one routine). **Sources** orch-r15 N2.
- **Program** `A`: `pub type Box a = Box a`, `pub eq : Box a, Box a -> Bool where a.foo : a,
  <509-deep tuple> -> Bool`. `B`: `pub type W b = W (A.Box b)`. `C`: `type X = X Int`, `pub foo`
  at the same type, `bad = B.W (A.Box (X 1)) == B.W (A.Box (X 2))`.
- **Observed** `check A B` exits 0, B's `W` row silently `<error>`; with `C`, `R` reports two
  INTERNAL ERRORs at `C.beni:15:23` and `B` panics on I7. At 508 it checks.
- **Expected** B's row goes through `Publisher.scheme`: B reports NESTING TOO DEEP (region open),
  C is silent. Decide whether `ctorTerms` scans for errors and amend §14.1 either way.
- **Fixture** `check/bad/DerivedRowTemplateTooDeep/` (`.codes`: `nesting_too_deep B.beni:*`), red
  `crash=ABRT`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-A (2026-09-28), `checker-v2.md` §14.1 *amended by R15-fix-A*
  first. `Facts.templateScheme` publishes through `Publisher.scheme` at the type's declaration:
  B reports NESTING TOO DEEP (`B.beni:5:10`, the declaration's region) and the row's scheme is
  `<error>`; an importer's use of a row whose scheme reads as `err` is `poisoned`
  (`Instances.publishedMethodTypes`), so C is silent. `ctorTerms` scans too (decided: an argument
  that reads as `err` or too deep keeps `no_terms`), through the same `Publisher.clean`/`written`.
  Promoted: `tests/corpus/check/bad/DerivedRowTemplateTooDeep/`.

### CK-143 — `Types.find` is a linear scan: publication and the dependency digest are quadratic

- **Severity** performance. **Area** `Types.find` (Types.zig:385–398) called per `type_refs` row by
  `Types.resolveRefs` (P8 on a miss, `install` on a hit) and per exported type by `Digest.collect`
  (`pushId`, whose `push` also deduplicates with a linear `contains`, Digest.zig:466–473). **Class**
  K11. **Sources** orch-r15 N3 (the original orchestration review's "an index, not a scan", still
  owed; CK-107 fixed `cache_store` only).
- **Program** `pub type A{i} = A{i} Int | B{i}` (independent), and `pub type A{i} = A{i} Int A{i-1}
  | B{i}` (a chain).
- **Observed** `R`, `--no-cache --jobs=1`, events of the file: independent 8 000 / 16 000 / 32 000,
  `dep_digest` 38 / 149 / 571 ms (check 29 / 57 / 115); chain 16 000 / 32 000, `publish` 53 / 183
  ms, `dep_digest` 223 / 867. At 16 000 independent types the digest is 3× the whole check.
- **Expected** linear: a per-module `name → TypeId` index built with `Types`, and a hash set in
  `Digest.push`.
- **Fixture** `scenario/CK-143` (`dep_digest`, n = 8 000) and `scenario/CK-143-publish`
  (`publish`, chain, n = 16 000), both `test-pending-perf`, red `slow` (3.8 and 3.8 on the red
  pass).
- **Slice** R15-fix.
- **Status** fixed by R15-fix-D (2026-09-28), `checker-v2.md` §18 *amended by R15-fix-D*:
  `Types.by_name` (each module's range sorted by `(name, id)`) makes `find` a binary search, and
  `Digest.IdSet` is a bit per type of the module (not a hash set: `fast-compiler.md` §5 rule 5). 8
  000 / 16 000 types: `dep_digest` 5.1 / 10.1 ms; a 16 000 / 32 000 chain: `publish` 15.0 / 31.4
  ms. Both scenarios promoted into `perf_test.zig` (`test-perf`).

### CK-144 — Interface terms expand every alias body: an alias chain is quadratic in bytes

- **Severity** performance (and a false hint). **Area** the interface writer (`Schemes.Writer`)
  and the cache entry. **Class** K11 (representation; related to K10). **Sources** orch-r15 N4;
  not a regression (`7427828` writes the same).
- **Program** `pub type alias R{i} = { x : Int, p : R{i-1} }` with `pub get{i} : R{i} -> Int`;
  likewise a `pub schema S{i}` chain.
- **Observed** `dump --stage=raw` 1 021 435 / 4 140 731 bytes at 60 / 120 aliases (ratio 4.05),
  17.1 MB at 240 with a 4.9 MB cache entry; 240 schemas write a 22 MB entry and `publish` goes 44 →
  492 → 3 896 ms for 200 → 800 → 3 200 schemas. Past about 254 levels every later declaration is
  its own NESTING TOO DEEP (545 for 800 aliases), and the schema chain is newly refused (CK-13's
  guard): `7427828` accepted `schemachain-800` in 24.9 s with truncated members. The message's hint
  "Give the inner part a `type alias` of its own" is wrong when the inner part already is one
  (K13).
- **Expected** alias references by name in terms, each body written once per record: linear
  bytes. The hint follows the fix (if the chain stops being refused, the hint has nothing to say).
- **Fixture** `scenario/CK-144` (fast step; the byte ratio of `dump --stage=raw` at 60 / 120, one
  run each, exact), red `superlinear`. The hint has no fixture of its own: whether a 255-level
  chain is still refused after the fix is the fix's to decide.
- **Slice** R15-fix.
- **Status** fixed (2026-09-28), `checker-v2.md` §14.2 *amended 2026-09-28* (interface format 7,
  plan format 2, entry format 4, §14.3): an `alias` term holds its arguments and the alias's body
  is on its `type_refs` row, written once per record; the importer expands a row once per `(row,
  argument roots)` per read. 60 / 120 / 240 links: 49 507 / 101 460 / 209 385 bytes of `dump
  --stage=raw` (ratio 2.04), from 1 021 435 / 4 140 731 / 17 252 635. Scenario promoted into
  `perf_test.zig` ("an alias chain's interface is linear in its length"); `iface_test.zig` holds
  the cross-module half (16 / 32 links named by another module: 16 501 / 33 674 bytes, master
  74 519 / 284 974). **The chain past about 254 links is still refused**, by the annotation reader
  (`Types.Builder.max_depth`), which is where the expansion is real (the store holds it), so the
  message's hint is unchanged and still wrong for an inner part that is already an alias; that
  half (K13) is not addressed here.

### CK-145 — A record mismatch's text depends on the other files of the project

- **Severity** diagnostic-quality (deterministic per file set; no verdict changes). **Area**
  `Unify.gather` (Unify.zig:775) merge-joins shared fields in symbol-id order; ids follow file
  order (CK-71's fix). **Class** K12 (CK-07's family). **Sources** orch-r15 N5.
- **Program** `M`: `f : { zp : Int, zq : String } -> Int`, `sameRec y = { zp = y, zq = y }`,
  `h y = f (sameRec y)`. `Aaa` (imported by nothing): `pub y = { zq = 1, zp = 2 }`.
- **Observed** `check M.beni`: the argument is `{ zp : Int, zq : Int }`; `check Aaa.beni M.beni`:
  `{ zp : String, zq : String }`.
- **Expected** the single-file text in both: fields walked in name-text order, or the mismatch
  rendered from the pre-unification types.
- **Fixture** `check/bad/RecordUnifyFieldOrderOtherFile/`, red `why=message`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-D (2026-09-28), `checker-v2.md` §7.2 *amended by R15-fix-D*: shared
  fields are unified in name-text order (`Unify.record`), so the first failure is the smallest by
  text and the message does not depend on other files. Promoted into `tests/corpus/check/bad/`.

### CK-146 — Residue of the region- and code-keyed recovery

- **Severity** latent. **Area** `Report`, `Contexts`, `Incremental`. **Class** K9. **Sources**
  orch-r15 N6.
- **What** (1) `Report.failed` is written and never read (Report.zig:54); §15.2 says the P9 gate
  reads the bits. (2) `Report.hasErrorAt` (Report.zig:401) answers "already refused?" by scanning
  for an equal region (linear; no quadratic measured: 16 000 refused uses, 265 ms). (3) the
  fixpoint's quiet `Report` is read back as facts: `Contexts.zig:1123` decides `absent_budget` by
  finding a `nesting_too_deep` in `quiet_items` — CK-14's retired pattern; it should be a flag.
  (4) `Incremental.verifyReads` appends to `per_module` directly (Incremental.zig:224), a second
  append path §15.1 says does not exist. (5) attribution to `Report.current` relies on every
  save/restore (all correct today).
- **Fixture** none: structural, none reachable as a wrong result today.
- **Slice** R15-fix.
- **Note** (R15-fix-D, 2026-09-28) item (1) is closed: `Publish.publishedRoot` reads
  `Report.failed` (CK-147's fix). Items (2) to (5) stand.
- **Status** closed by R15-fix-J (2026-09-28). All four remaining items were still present.
  (2) `Report.error_regions`, a `U32Set` filled wherever the list grows (seeded at `init` from
  what the list already holds, then in `emit` for what is kept), answers `hasErrorAt`; the scan is
  gone. Breaking it turns `check/bad/LetHelperRecordOneError` red. (3) **Was a live defect, not
  only a pattern**: the quiet report DROPS every message but `internal`, so no
  `nesting_too_deep` ever reached `quiet_items` and `absent_budget` from a refusal inside a pass
  was dead. A pass that needed a nested check refused at demand read on, and the comparison got
  NOT EQUATABLE's claim of "a function anywhere inside it" — catalogued as CK-201. Now
  `Report.too_deep` counts the `nesting_too_deep`s emitted, dropped ones included, and
  `Contexts.pass` compares it; the use says `Messages.derivedBudget` (the step budget's text named
  1 048 576 steps, false for a refusal). (4) `Incremental.verifyReads` appends through
  `Report.appendTo`. (5) kept as a review watch: every `at` that is not a group's own is paired
  with `defer at(saved)` in the same scope (`Contexts`, `Instances`, `Resolve.step`, `Groups`),
  which is the scoped guard; no helper would add a check.

### CK-147 — A failed declaration is published with its partially solved, order-dependent type

- **Severity** valid-program-rejected (a dependent's verdict follows a failed module's
  declaration order). **Area** `Publish.fill` (Publish.zig:65–69) publishes every `decl_scheme`
  that is not `err`, failure bit or not. **Class** K9. **Sources** orch-r15 N7 (the only interface
  difference over 451 corpus files × 5 permutations).
- **Program** `check/bad/DeferredReceiverJoinedInGroup.beni` with its declarations reversed, as
  `Lib`, and `Main`: `v : Int`, `v = Lib.ma (K 1) { combine = \z -> z + 0.5 }`.
- **Observed** source order publishes `ma : K, { combine : number -> number } -> number2`
  (Main checks); reversed, `… -> number`, and Main gets a TYPE MISMATCH (`Float` for `Int`).
- **Expected** an unannotated declaration whose failure bit is set is published as `<error>`
  (CK-146's (1) gives the bit a reader); an annotated one keeps its P2 scheme. Lib's one error, Main
  silent.
- **Fixture** `check/bad/FailedDeclarationPublishedType/`, red `why=code`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-D (2026-09-28), `checker-v2.md` §14.1 *amended by R15-fix-D*: an
  unannotated value whose failure bit is set publishes `<error>` (`Publish.publishedRoot`, the
  reader of `Report.failed` CK-146 (1) asked for); an annotated one keeps its P2 scheme. Promoted
  into `tests/corpus/check/bad/`.

### CK-148 — A parse error in a schema body publishes the recovered schema

- **Severity** diagnostic-quality (one mistake, two messages, the second about a type nobody
  wrote). **Area** parser recovery of schema bodies, and publication of a schema whose body did not
  parse. **Class** K14 / K9. **Sources** orch-r15 N8.
- **Program** `Sch`: `pub schema P =` / `x : Int` / `y : Int -> Int`. `Use`: `p : Sch.P.Type`,
  `p = { x = 1, y = "a" }`.
- **Observed** UNEXPECTED TOKEN at `y`'s `->`, and a TYPE MISMATCH in `Use` saying `y` must be
  `Int` (the recovery kept `y : Int`). orch-r15 said the `type alias` twin (`{ x : Int, y : String
  ) }`) poisons the alias; on the red pass it recovers the fields as written and its user's genuine
  mismatch is reported, which is not this defect.
- **Expected** the UNEXPECTED TOKEN only: a schema whose body did not parse is poisoned.
- **Fixture** `check/bad/SchemaParseErrorRecovered/`, red `why=code`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-D (2026-09-28), `checker-v2.md` §14.1 *amended by R15-fix-D*: a
  schema field whose value does not end where a field ends has the parser placeholder as its value
  (`Parse.parseSchemaField`, `parseLayoutSchemaField`; message and position unchanged), so the
  schema reads `err` and publishes `<error>`, consistently with an annotation that did not parse.
  The fixture gained the brace form (`Q`). Promoted into `tests/corpus/check/bad/`.

### CK-149 — The I15 Debug assert does not exist

- **Severity** latent. **Area** `Generalize.adjustRanks`/`enter` (Generalize.zig:339, 460).
  **Class** K2 (I15). **Sources** core-r15 F2.
- **What** §2 I15 requires a debug assert on each boundary's generalisation walk (S-new-6), and
  §4.1 lists "the I15 assert" as an `owned` walk; `grep I15 src/check` finds comments only. The
  invariant holds by construction at the four lowering sites and no probe broke it (E6, E7, E14,
  P1), but the one mechanical check K2 relies on is absent. Fix: under `runtime_safety`, for a
  non-generalised receiver, assert each method-type successor's rank ≤ the receiver's.
- **Fixture** none: structural (an assert has no black-box face until it fires).
- **Slice** R15-fix.
- **Status** fixed by R15-fix-J (2026-09-28); still absent on `d90ab5f`.
  `Generalize.assertOwnedWithin`, called where the rank walk finalises a variable (a popped frame,
  and a node whose successors were all answered at once): every `Walk.owned` successor's root —
  a requirement's method type, an open obligation's dependant — has rank ≤ the variable's; a
  generalised variable is skipped (the contract's exemption). Linear: the successors are read once
  more, and a structure's rank is already the maximum of its successors'. Proved live by setting a
  young leaf's rank one above its group's: 30 `run/` fixtures panicked with the I15 message.
  Every black-box program exercises it.

### CK-150 — A fixed 64-slot stack in `Diagnostics.monomorphicMethod`

- **Severity** latent (letter of I4). **Area** Diagnostics.zig:258–296 (`var stack: [64]Var`,
  pushes dropped past 64, a 4 096-step budget). **Class** K3. **Sources** core-r15 F3.
- **What** it only picks the A.30 hint, so giving up means "no hint", never "yes". Replace with
  `Walk.variables`/`reaches`, or document the exemption in §2.
- **Fixture** none: structural.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-J (2026-09-28); still present. The search walks `Walk.child`'s
  `structural` successors (aliases and a record's extension included, which the old one skipped)
  on a growing stack, each root once, no budget. It was visible after all: a `let` value whose
  held variable is its type's 65th parameter lost the hint for the argument-order one. New
  `check/bad/LetValueConstrainedWideType.beni`, red before (the plain hint), green after.

### CK-151 — v1's `quiet` checks survive in `Diagnostics.Reporter`

- **Severity** latent (letter of I12). **Area** Diagnostics.zig:92 (`quiet`) and about 14 `if
  (r.quiet) return;` guards. **Class** K9. **Sources** core-r15 F4.
- **What** Report.zig:12–14 says its reporter is never quiet; the guards are dead but are a second
  place `quiet` is enforced. Delete them, so "quiet once" is literally true.
- **Fixture** none: structural (dead code).
- **Slice** R15-fix.
- **Status** fixed by R15-fix-J (2026-09-28); still present (13 guards in `Diagnostics`, 19 in
  `DispatchTexts`, 4 in `PatternTexts`, and one each at the top of `Exhaustive.run` and
  `Cycles.run`, whose caller already skips them for a quiet module). The field is gone; the one
  reporter is `Report`'s staging one, and `internalAlways` merged into `internal` (`Report.emit`
  keeps an `internal` in a quiet module). Goldens unchanged.

### CK-152 — The speculation journal has no caller

- **Severity** latent. **Area** `TypeStore` snapshot/commit/rollback, `broken`, `rollbacks`, and
  the `record` on every `setContent`/`setRank` (TypeStore.zig:300–360, 850–930). **Class** K15.
  **Sources** core-r15 F5.
- **What** nothing calls `snapshot` (§7.5's diagnostic probe was never built; `?` is an
  obligation), so the four I14 asserts and `GroundMemo`'s rollback guard protect an impossible
  state, and `Snapshot` lacks §7.5's per-frame `ready`/`touched` lengths — the first real use would
  break I14. Delete it, or complete it before its first use.
- **Fixture** none: structural (dead code).
- **Slice** R15-fix.
- **Status** fixed by R15-fix-J (2026-09-28) by deletion, `checker-v2.md` §7.5 and I14
  *amended 2026-09-28*; still present (only `TypeStore`'s own tests opened a snapshot).
  `Snapshot`, the journal, `depth`, `broken`, `rollbacks`, `beginSpeculation`/`commit`/`rollback`,
  the `record` on every write, the four "inside a speculation" checks (`Unify` ×2, `Groups`,
  `Resolve.step`) and `Derivable`'s rollback guards (`GroundMemo.generation`, `Shapes.last`) are
  gone, with the four journal unit tests. The first probe builds the journal to §7.5's full
  `Snapshot`, per-frame lengths included.

### CK-153 — `unify` depends on its caller's position

- **Severity** latent (a re-accretion watch). **Area** Unify.zig:565: an `equatable` obligation
  only when `u.argument and u.depth == 1`, a message-placement rule (§11.4 *As built by R5*).
  **Class** K13. **Sources** core-r15 F6.
- **What** documented and harmless, but `unify` is no longer a function of its two types alone —
  the pattern the v1 review flagged. Keep it the only one; a review rule, not a fix.
- **Fixture** none: structural.
- **Slice** R15-fix (a review watch).
- **Status** fixed by R15-fix-J (2026-09-28); still present. The rule is the callee's contract
  now: `Unify.unifyArgument` is its own entry point, documented as "`unify`, plus the top pair
  asks a comparison's question at `region`"; `go` hands the question to the first pair it
  examines and clears it, so no deeper pair can ask, and `unify` depends on its two types alone
  (`argument` and the `depth == 1` read are gone). `Solve.unify` picks the entry by category.
  Behaviour unchanged; disabling the question turns `check/bad/EqRecordFieldFunctionAtComparison`
  red.

### CK-154 — A rigid escape also reports an ambiguous interpolation it caused

- **Severity** diagnostic-quality (a cascade). **Area** the solver's report of an undecided
  interpolation obligation after a `rigid_mismatch` left its variable unconstrained. **Class** K13.
  **Sources** core-r15 (F6's related observation).
- **Program** `f x = let s = "${x}"; g : a -> a; g y = if True then y else x in ( s, g 1 )`.
- **Observed** `rigid_mismatch` at `x` in `g`, and AMBIGUOUS INTERPOLATION at `"${x}"`; without the
  annotation `x` is a number and the interpolation is fine.
- **Expected** only the `rigid_mismatch`.
- **Fixture** `check/bad/InterpolationAfterRigidEscape.beni`, red `why=code`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-E (2026-09-28), `checker-v2.md` §8.3 *amended by R15-fix-E*: the
  cause was not F6's equatable row but the order of two decisions. Binding the outer `x` to `g`'s
  rigid readied the `${x}` row, which was decided at once against the rigid (AMBIGUOUS) before
  `g`'s boundary reported the escape. A `${…}` whose value is a non-`number` rigid not yet
  generalised is now held on the rigid (`Decide.interpolatable`): step 7 reports it at the
  rigid's own boundary, or step 6 finds the rigid escaped, reports that, and poisons it, which
  settles the row in silence (`Solve.poison` now settles a rigid's rows). Step 6 also poisons
  EVERY escaped rigid of the binding, the message still once. Promoted to
  `tests/corpus/check/bad/`.

### CK-155 — `Instances.plainImported`/`readPlain` map argument i to quantifier i by position

- **Severity** latent. **Area** Instances.zig:326–354, 380–410. **Class** K4. **Sources** disp-r15
  R-a.
- **What** a second creator of an instantiation's evidence, correct only because `Schemes.Writer`
  numbers `T q₀…qₙ`'s arguments 0..n; `readPlain` never checks `v0.lhs == i`. Fix: refuse (`return
  null`) or assert.
- **Fixture** none: structural.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-J (2026-09-28); still present. `readPlain` refuses (the slow path)
  unless argument `i` is quantifier `i`, which also makes its duplicate check redundant (removed).
  No test: the writer numbers first appearance, so no source reaches the refusal; it keeps the
  fast path right if the interface's numbering changes.

### CK-156 — `Schemes.Writer.writeVar` and `quantifierOrder` must agree, by convention

- **Severity** latent. **Area** Schemes.zig:555–567. **Class** K4. **Sources** disp-r15 R-b.
- **What** the callee orders with one walk, an importer reads the other; they agree today (by
  hand), pinned by one hand test, and the randomized round-trip does not compare orders. Fix: a
  Debug assert at publication that the writer's `pending_roots` equal `quantifierOrder` for every
  scheme with requirements. (CK-135's rewrite of `quantifierOrder` is the moment.)
- **Fixture** none: structural.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-J (2026-09-28); still present. `Schemes.Writer.add` calls
  `Evidence.assertWrittenOrder` in a safe build (one line in `Schemes.zig`, which is at its
  1 500-line cap): for a scheme with a requirement, the writer's `pending_roots` must equal
  `quantifierOrder`'s list, else a panic. Proved live by visiting a function's result before its
  parameters in `orderWalk`: 68 `check/good` fixtures panicked.

### CK-157 — `Module.elaborate` pairs requirements and givens by index across two readings

- **Severity** latent. **Area** Module.zig:396–418. **Class** K4. **Sources** disp-r15 R-c.
- **What** an annotated declaration's requirements come from the scheme reading and its givens
  from the rigid reading; only the count is asserted. Alias argument swaps and tuple parameter
  patterns stay correct (`Unify.alias` keeps alias nodes). Fix: assert each pair has the same method
  and quantifier index.
- **Status** fixed by R15-fix-J (2026-09-28); still present. Each pair must agree on the given's
  `k`, its method and the variable name the annotation spelled (the rigid's and the scheme root's):
  `Solve.expect`, a panic in a safe build and `internal` otherwise. Proved live by pairing the
  givens in reverse: 4 `run/` fixtures panicked.
- **Fixture** none: structural.
- **Slice** R15-fix.

### CK-158 — The `rules_test.zig` capability fences are textual and incomplete

- **Severity** latent. **Area** `rules_test.zig`. **Class** K7. **Sources** disp-r15 R-d.
- **What** `entries[i].equatable`, `t.equatable` and `info.equatable` spell the same read and are
  not caught; only `src/check` is scanned, not `src/js` or `src/cache`. Nothing violates the rule
  today.
- **Fixture** none: structural (the fence is itself the test to widen).
- **Slice** R15-fix.
- **Status** fixed by R15-fix-J (2026-09-28); still present. The rule now counts any field read
  of `equatable`, `comparable` or `has_function` (the receiver ends in a name, `]` or `)`, no
  call follows) as the table's unless the receiver is a variable's flags or a quantifier (`flags`,
  `fa`, `fb`, `joined`, `flagged`, `f`, `q`, `info`), and reads `src/check`, `src/js` and
  `src/cache` from their directories at test time; `cache/Digest.zig` is a listed reader of all
  three. A renamed field would be the complete fix, but it reaches the cache digest's reflection
  and the interface writer, which were being changed in parallel. Unit test "a table-bit read is
  told from a variable's marker by its receiver"; a probe line in `src/js/Reach.zig` turned the
  rule red.

### CK-159 — A derived type over a specialised custom `eq` is refused at the specialised type

- **Severity** valid-program-rejected (rule 7: no guarantee at stake), with a false message.
  **Area** derivability over a payload whose `eq` binds a marker (`Holder Int`). **Class** K7.
  **Sources** disp-r15 R-e.
- **Program** `H`: `pub type Holder a = Holder a`, `pub eq : Holder Int, Holder Int -> Bool` (mod
  10). `Main`: `type W a = W (H.Holder a) a`, `same : W Int, W Int -> Bool`, `same l r = l == r`.
- **Observed** NOT EQUATABLE, `absent_other`'s text ("a function anywhere inside it" — there is
  none). The same comparison through a tuple `( H.Holder Int, Int )` builds and prints `equal`.
  CK-116's `absent_requirement` does not cover it; the corpus golden
  `check/bad/SpecializedEqWrongReceiver` encodes this text for a `Generic String`.
- **Expected** (taking rule 7's side) `W Int` is accepted and prints `equal`. If the owner keeps the
  refusal, the fallback is a message naming `H.eq`, and the fixture becomes a `check/bad`.
- **Fixture** `run/DerivedOverSpecialisedEq/`, red `dev: exit=1 codes=not_equatable×1`.
- **Slice** R15-fix (the owner's decision first).
- **Status** fixed by R15-fix-E (2026-09-28), `checker-v2.md` §11.2 and §14.2 *amended by
  R15-fix-E*. Checked against D1–D14 first: no decision refuses it, and D10's promise
  ("comparable exactly when everything it can hold is") takes rule 7's side — `W Int` holds a
  `Holder Int` and an `Int`, both comparable; the refusal was R8's as-built rule ("a marker a
  specialised instance bound is `absent`"), not an owner's. A marker bound to a GROUND type by
  a payload's specialised method is now a PIN of the context (`Contexts.Pin`): no entry, no
  evidence parameter (D4 unchanged), its type an element of the answer's template; the derived
  body is the pass's own (`H.eq` at the position, `===` at the pinned `Int`). A use unifies each
  pinned argument with its type first; a mismatch is NOT EQUATABLE (or NO METHODS for
  `compare`) writing the type as it derives (`W Int`) and, locally, the specialised method.
  Publication writes the pinned parameter as its type in the row's scheme, so an importer's
  unification of the parameters is the check and the record's format is unchanged. The
  `Generic String` case of `check/bad/SpecializedEqWrongReceiver` gains that text. Promoted
  to `tests/corpus/run/`, with `run/DerivedPinnedAcrossModules/` and
  `check/bad/DerivedPinnedRefused/` new.

### CK-160 — `Unit.newWanted` uses `.undetermined`, a real answer, as its placeholder

- **Severity** latent. **Area** Unit.zig:116; `Elaborate.caseThree`'s guard. **Class** K5.
  **Sources** disp-r15 R-f.
- **What** every node is filled before `emit` today (`fillUnit` drains `pending`), but "a hole is
  never a structural answer" holds by that drain, not by construction. Related: `caseThree`'s guard
  uses `Walk.reaches` (structural successors) while the lists come from `quantifierOrder` (which
  also follows method types); a variable reachable only through another requirement's method type
  would get the default instead of `internal` — unreachable today because both come from the same
  walk. Fix: a dedicated placeholder, or an assert in `emit`.
- **Fixture** none: structural.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-J (2026-09-28); both halves still present. `Unit.emit` panics in a
  safe build while `pending` is not empty (a placeholder variant would change `Dispatch.Term`,
  which the dispatch bytes serialise); proved live by leaving one pending node, which 502 `run/`
  cases hit. `caseThree`'s guard walks `Walk.reachesThroughRequirements`, new: `reaches`
  through `Walk.owned` with no obligation table, the closure `quantifierOrder` lists from. Unit
  test "a variable met only in a requirement's method type is reached through requirements
  alone".

### CK-161 — An unannotated dot-call `x.compare y` never derives

- **Severity** valid-program-rejected (rule 7), with a false message. **Area** dot-call
  resolution on an unannotated receiver: checker-v2.md's "kind decides derivation" — an operator or
  a `where` derives, a dot-call does not. **Class** K7. **Sources** adv-r15 O1.
- **Program** `type Colour = Red | Blue`, `before x y = x.compare y == LT`, `before Red Blue`.
- **Observed** "`Colour` has no method called `compare`" at the call. Adding `before : a, a -> Bool
  where a.compare : a, a -> Order` builds and prints `T`; `Red < Blue` works directly.
- **Expected** — **by the owner's rule 7**, a refusal with no guarantee behind it is dropped: the
  program builds and prints `T`. This is a change to the design as written (by design at
  `8b98464`); if the owner keeps the rule, the fallback is a warning or at least a message that
  says derivation needs an operator or a `where` annotation, and the fixture becomes a `check/bad`.
- **Fixture** `run/DotCallCompareDerivedUnannotated.beni` (expects ACCEPTANCE), red `dev: exit=1
  codes=unknown_method×1`.
- **Slice** R15-fix (the owner's decision first).
- **Status** OPEN for the owner; the message is fixed by R15-fix-E (2026-09-28). Acceptance
  contradicts an owner-adopted rule: `static-dispatch-spike.md` §1.3 rule 2 and A.56 ("a
  hand-written `x.eq y` stays `unknown_method` … *Alternative:* let a `dot_call` derive too,
  which is §1.3 rule 2 reversed"), adopted with static dispatch on 2026-09-18 and restated by
  `checker-v2.md` §9.3 step 5; `before`'s promoted requirement keeps its dot-call's kind, so the
  rule reaches it through the call. Behaviour is unchanged. The UNKNOWN METHOD for a dot-call
  `x.eq`/`x.compare` now says that a derived method is reached only by an operator or a `where`
  clause, and the hint writes the fix: `x < y` there, or an annotation with `where a.compare :
  a, a -> Order` (naming `before` when the refusal comes through it). The fixture moved to
  `tests/corpus/check/bad/DotCallCompareDerivedUnannotated.beni` with that `.diag`. **The
  owner's decision:** may a dot-call of `eq`/`compare` reach a derived method — (a) keep §1.3
  rule 2 (today); (b) let a dot-call derive whenever the type has no own method of the name,
  directly and through promotion (A.56's rejected alternative); (c) as (b), but only through a
  promoted requirement, so `(Red).compare Blue` stays refused while `before Red Blue` builds.
  Recommendation: **(b)** — rule 2 guards no guarantee (the derived `compare` is the one `<`
  already calls, so no answer can be silently different), `x.compare y` is the natural
  spelling of an `Order`-returning comparison, and (c) would make an annotation change what a
  program means. If (b) is taken, the fixture returns to `run/` expecting `T`.
- **Status** fixed by R15-fix-I (2026-09-28): the owner took (b) that day (`checker-v2.md` §21.1
  D15; `static-dispatch-spike.md` §1.3 rule 2 and A.56 amended). `Resolve.derives` no longer asks
  the surface; a dot-call's own wanted on a record is still the field call
  (`Instances.onRecord`), and a promoted one derives on a closed record. R15-fix-E's dot-call
  UNKNOWN METHOD text is gone. Promoted: `run/DotCallCompareDerivedUnannotated.beni` (back from
  `check/bad/`), and new `run/DotCallDerivedDirect.beni`, `run/DotCallDerivedThroughHelper.beni`
  (also in `ordering_test.zig`'s PERM), `run/DotCallDerivedAcrossModules/` and the guard
  `run/DotCallOwnMethodWins.beni` (a type with its own `eq`/`compare` keeps them).

### CK-162 — `f -1` has no hint that it is `f - 1`

- **Severity** diagnostic-quality. **Area** the arithmetic mismatch's hint. **Class** K13.
  **Sources** adv-r15 O3.
- **Program** `dec : Int -> Int`, `v = dec -1`.
- **Observed** TYPE MISMATCH on `(-)`, hint "this is a function, so it may be missing an argument".
  (adv-r15's case was `( i -1, "m" )` in an `Int32` tuple.)
- **Expected** the same mismatch, hinting `dec (-1)` (Elm has this hint).
- **Fixture** `check/bad/NegativeLiteralArgumentHint.beni` (`contains "(-1)"`), red `why=message`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-E (2026-09-28): a function where a number is wanted, as the left
  operand of a binary `-` whose right is a number literal and whose left is a named value,
  hints "`dec -1` is a subtraction, `dec - 1`. To pass a negative number as an argument, put it
  in parentheses: `dec (-1)`" (`DispatchTexts.negativeArgumentHint`). The checker sees no
  whitespace, so the hint is also given for `dec - 1`, where the sentence is still true; telling
  the two apart needs a lowering bit (frontend, not worth a BIR change). Promoted to
  `tests/corpus/check/bad/`.

### CK-163 — `build --out` leaves an earlier build's files behind

- **Severity** latent (stale modules beside a build that never wrote them; not the checker).
  **Area** the build driver's output writing. **Class** K14. **Sources** adv-r15 O3.
- **Program** build `Main` importing `Half` and `Dict` into `out/`, then a `Main` using neither
  into the same `out/`.
- **Observed** `out/Half.mjs`, `out/_core/Dict.mjs`, `_core/Basics.mjs`, `_core/String.mjs` and the
  two foreign siblings survive.
- **Expected** `out/` holds exactly what a build of the second program into an empty directory
  writes. `backend.md` §2 does not say; the owner decides (removing only files the compiler itself
  wrote is the conservative form).
- **Fixture** `scenario/CK-163` (fast step), red `stale-files`.
- **Slice** R15-fix (backend).
- **Status** fixed by R15-fix-F (2026-09-28), the conservative form: `backend.md` §2, *The output
  directory holds what the last build wrote* (added by the slice). A build records what it wrote in
  `--out/_manifest.txt` (path and content hash) and removes what the previous record lists and it
  did not write — only while its bytes still match, never a path leaving `--out` — and the
  directories that leaves empty; a refused build touches nothing. Promoted into `build_test.zig`,
  with a user file that survives, an edited output that survives, a hostile record line, and a
  refused rebuild.

### CK-164 — Frontend `resolve` is quadratic in a module's qualified references

- **Severity** performance. **Area** frontend `resolve`. **Class** K14. **Sources** orch-r15 N9.
- **Program** `pub s{i} : List Int -> List Int` / `s{i} xs = List.map xs negate`.
- **Observed** `R`, the file's `resolve` event: 15 / 60 / 239 ms at 4 000 / 8 000 / 16 000 (the
  audit: 492 ms at 16 000 with `check` at 80); `check` 16 / 32 / 63. With `where` clauses and no
  qualified reference, 8 ms.
- **Expected** linear.
- **Fixture** `scenario/CK-164` (`test-pending-perf`, n = 8 000), red `slow` (4.0).
- **Slice** R15-fix (frontend).
- **Status** fixed by R15-fix-F (2026-09-28). Every qualified reference asked `schemaFromRoot`,
  a scan of the module's declarations and every `exposing` list; `resolveSelf` scanned too.
  `Resolve.Tables` holds the current module's names per namespace and its exposed schemas, sorted,
  built once per module. With it, the perf study's item 4: `Graph.lookup` is an array indexed by
  the module-name symbol with the package precedence precomputed (`name_rows`, `rows`), not three
  hash probes. `resolve` at 8 000 / 16 000: 51.9 / 204.8 ms on 01d0f21, 3.5 / 6.5 ms fixed
  (ReleaseFast, best of 3); the whole check 99 / 293 → 57 / 104 ms CPU. Promoted into
  `perf_test.zig`.

### CK-165 — `lower` is super-linear in a module's imports and their uses

- **Severity** performance. **Area** BIR lowering (`bir.Lower`). **Class** K14. **Sources**
  orch-r15 N9.
- **Program** `Main` importing n one-value modules `M{i}` and listing each `M{i}.v` once.
- **Observed** `R`, `Main`'s `lower` event: 28 / 131 / 265 ms at 2 000 / 4 000 / 8 000 modules
  (8 000 with the imports alone: 80 ms); `resolve` is quadratic beside it (7 / 27 / 54).
- **Expected** linear.
- **Fixture** `scenario/CK-165` (`test-pending-perf`, n = 2 000), red `slow` (4.5).
- **Slice** R15-fix (frontend).
- **Status** fixed by R15-fix-F (2026-09-28). Lowering keeps the explicit imports by alias and by
  module (`import_by_alias`, `import_by_module`) and cuts a qualified token at its dots to probe
  them, and a declaration past 64 import edges dedupes them through a key set (`import_refs`);
  `Graph.build`'s per-module edge and prelude-use sets are stamps; resolution is CK-164's.
  `Main`'s `lower` at 2 000 / 4 000 modules: 24.4 / 121.3 ms on 01d0f21, 0.8 / 1.5 ms fixed
  (ReleaseFast, best of 3); the whole check 79 / 230 → 51 / 95 ms CPU. Promoted into
  `perf_test.zig`.

### CK-166 — The parser's per-declaration budget reports once per offending expression

- **Severity** diagnostic-quality (and a false text). **Area** the parser's 4 096-links budget.
  **Class** K14. **Sources** orch-r15 N9.
- **Program** `foo x0 = let x1 = x0 + 1 … x5000 = x4999 + 1 in x5000`.
- **Observed** 907 NESTING TOO DEEP (`B`, the scenario; 11 906 at 16 000 bindings), each "nested
  more than 4096 levels deep" about a flat `let`. CK-91's fixture passes at 5 000 bindings only
  because its bodies are `negate x{i}`.
- **Expected** at most one message for the declaration; accepting it (rule 7: a flat `let`
  endangers no stack) is green too.
- **Fixture** `scenario/CK-166` (fast step), red `exit=1 codes=nesting_too_deep×907`.
- **Slice** R15-fix (frontend).
- **Status** fixed by R15-fix-F (2026-09-28), the accepting form (rule 7). A `let`'s bindings and
  body and a `case`'s scrutinee and branches are siblings (`Parse.Siblings`): each starts from the
  parent's depth and the parent keeps the deepest one's charge, so the budget bounds the tree's
  height and not a sum over siblings. 5 000 and 16 000 bindings check with no diagnostic (01d0f21:
  907 and 11 907), and 16 000 build and run in both modes; one binding past the budget is still
  one `nesting_too_deep`. Promoted into `abuse_test.zig`.

### CK-167 — A flat `case` over 2 000 constructors is CASE TOO BIG TO CHECK

- **Severity** valid-program-rejected. **Area** `Exhaustive` (the 5 M-step budget). **Class** K11.
  **Sources** orch-r15 N9.
- **Program** `type T = C0 Int | … | C1999 Int`, `f t = case t of C0 x -> x … C1999 x -> x`.
- **Observed** `pattern_budget_exhausted`; 1 000 constructors check in 9 ms (`R`); 4 000 fail the
  same way. The audit found it at 4 000; the red pass found it already at 2 000.
- **Expected** it checks: one column of distinct constructors is one split, O(n log n) at most.
- **Fixture** `scenario/CK-167` (fast step), red `exit=1 codes=pattern_budget_exhausted×1`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-F (2026-09-28). A constructor whose arguments are all wildcards
  (`C x`) is a key of `Flat`'s lookup table, as a nullary one is; and `ColumnIndex` answers the
  general relation's column-zero questions in one pass — `collect`'s set is a bitset, `split` sorts
  the rows by head once for "specialise by every alternative", and `Heads` gives each new branch
  only the rows sharing its head. `C{i} x` over 2 000 / 4 000 / 8 000 constructors checks (Debug,
  CPU: 0.22 / 0.43 / 1.3 s; 01d0f21 refused all three, in 2.3–3.2 s); a missing constructor, a
  redundant branch and `C{i} 0 -> … _ ->` (the general path) are answered at that width too. The
  budget is unchanged. Promoted into `abuse_test.zig`, with those variants.

### CK-168 — A wrong own-method signature is reported once per use

- **Severity** diagnostic-quality. **Area** well-known method resolution's report of a method whose
  type is not `T, T -> Bool`. **Class** K13. **Sources** orch-r15 N9.
- **Program** `type T = T Int`, `pub eq : T, Int -> Bool`, and two `==` on `T`.
- **Observed** two identical TYPE MISMATCHes ("`Main.eq` is not the method this call needs"), n for
  n uses.
- **Expected** one (at the method or at its first use: the spec does not say, so the `.codes`
  leaves the position open).
- **Fixture** `check/bad/OwnMethodSignatureReportedOnce.beni`, red `why=count`.
- **Slice** R15-fix.
- **Status** fixed by R15-fix-E (2026-09-28), `checker-v2.md` §9.3 *amended by R15-fix-E*: an
  OWN method met by a use that asks the well-known `T …, T … -> Bool|Order`, whose type fits no
  use of `T` (two parameters, each a variable or an application of `T`, the result a variable or
  `Bool`/`Order`), is reported once per (method, type), at the method's declaration, against the
  use-independent `T a…, T a… -> Bool|Order` (`Instances.signatureOnce`): the text and position
  are the same in every declaration order (I9). Every other use is rejected with it and
  attributed the failure. A specialised method (`Holder Int, …` used at `Holder String`) still
  fails at the use, where the use is the mistake; so does another module's method (its
  declaration is not in this file). The module-rule clash moves to the declaration too
  (`check/bad/ModuleRuleClash`, `MethodSignatureNoClash` re-blessed). Promoted to
  `tests/corpus/check/bad/`.

### CK-169 — An alias chain past 1 024 links is a silent `<error>`

- **Severity** compiler-crash-or-hang (`check` exits 0 over a program `build` refuses with INTERNAL
  ERROR). **Area** `TypeStore.resolved` (TypeStore.zig:654), whose guard answered `err` past 1 024
  alias links; since R15-fix-A a wanted meeting `err` is `poisoned` and reports nothing (§12.2).
  **Class** K3 (a walk that stops at a fixed depth), K5 (the stop answered by default). **Sources**
  R15-fix-A's review, D1.
- **Program** `deep : a -> Id (Id (… 400 … a))`, `p = deep (deep (deep String.length))`, `p == p`.
  Also a `let` of 1 100 bindings `a{i} = wrap a{i-1}` through `wrap : a -> Id a`, then
  `a1100 == a1100` (valid). 1 023 links check correctly; 1 024 are silent.
- **Observed** the first: `check` exits 0, `build` INTERNAL ERROR "I cannot tell what this call
  dispatches to". The second (valid): `check` exits 0, `build` the same INTERNAL ERROR.
- **Expected** an alias chain is as long as it is: NOT EQUATABLE for the first, `T` for the second.
  Every `err` has a message wherever it was made (§12.2 *amended by R15-fix-A*), and nothing
  answers `err` for a type it did not finish reading.
- **Fixture** `check/bad/AliasChainNotEquatable.beni` (red `exit=0 codes=none`) and
  `run/AliasChainThroughLet.beni` (red `dev: exit=1 codes=internal×1`).
- **Slice** R15-fix-C.
- **Status** fixed by R15-fix-C (2026-09-28), `checker-v2.md` §7.1 and §12.2 *amended by
  R15-fix-C*. `TypeStore.resolved` has no bound and compresses the chain it walks; `Unify` never
  closes a cycle through an alias's `actual` (`throughAlias`), which is what makes the walk finite.
  `Module.assertErrorsReported` (Debug) holds a clean module to no `poisoned` wanted and no `err` in
  its declarations' and locals' types, and fires on both fixtures at 346268b's `resolved`. Promoted:
  `tests/corpus/check/bad/AliasChainNotEquatable.beni`, `tests/corpus/run/AliasChainThroughLet.beni`.

### CK-170 — An alias chain past 1 024 links unifies with anything (unsound)

- **Severity** unsound-runtime. **Area** CK-169's guard: the `err` it answered unifies with any
  type, so a wrong use of the value checks and builds. **Class** K3, K5. **Sources** R15-fix-A's
  review, D1b; not a regression (the guard predates R15-fix-A).
- **Program** `p = deep (deep (deep ( 2, 7 )))` with CK-169's `deep`, then `String.isEmpty p.0`.
- **Observed** builds and runs, calling `String.isEmpty` on the number 2.
- **Expected** the TYPE MISMATCH two calls (800 links) report at `p.0`.
- **Fixture** `check/bad/AliasChainKeepsItsType.beni`, red `exit=0 codes=none`.
- **Slice** R15-fix-C.
- **Status** fixed by R15-fix-C with CK-169. The TYPE MISMATCH is `kind_mismatch` at `.0`, as
  the two-call oracle twin reports (the pending `.codes` guessed `type_mismatch`). Promoted:
  `tests/corpus/check/bad/AliasChainKeepsItsType.beni`.

### CK-171 — An alias DAG is expanded as a tree: exponential in its depth

- **Severity** performance. **Area** `Types.Builder.aliasBody`, which reads an alias's body once
  per USE, so `A{i} = ( A{i-1}, A{i-1} )` costs 2^n expansions for n declarations. **Class** K11.
  **Sources** R15-fix-A's review, D3; related to CK-144 (the same chain, bytes of the interface).
- **Program** `type alias A0 = Int`, `type alias A{i} = ( A{i-1}, A{i-1} )`, `f : A18 -> A18`.
- **Observed** 18 s of CPU in Debug; 535 ms against 7 ms at depth 9 in ReleaseFast (ratio 76).
- **Expected** each alias expanded once per (alias, arguments) and annotation: linear in the depth.
- **Fixture** `scenario/CK-171` (`test-pending-perf`, depth 9 / 18), red `slow`.
- **Slice** R15-fix-C.
- **Status** fixed by R15-fix-C (2026-09-28), `checker-v2.md` §7.4 *amended by R15-fix-C*:
  `Types.Builder.aliases` expands each `(alias, argument roots)` once per read, shared by the
  builders of alias bodies. Depth 18 checks in 0.13 s in Debug (18 s before); `==` over the
  depth-64 DAG builds in 0.2 s. `scenario/CK-171` promoted into `perf_test.zig` (`test-perf`).

### CK-172 — A variable unified with an alias of itself is an INFINITE TYPE

- **Severity** valid-program-rejected. **Area** `Unify.flex` against an alias: it binds the variable
  to the alias's content, and when the alias expands to that same variable the binding closes a
  cycle through the alias's expansion — `a = Id a`, which the binder's occurs check then reports.
  The same cycle is what `TypeStore.resolved`'s guard was "belt and braces" against. **Class** K3.
  **Sources** R15-fix-C, writing CK-169's fixtures.
- **Program** `wrap : a -> Id a`, `g x = [ x, wrap x ]`.
- **Observed** INFINITE TYPE "`a = Id a`" at `g`'s parameter.
- **Expected** `Id a` is `a`: it builds. Unifying two types whose aliases expand to the same
  variable is a no-op.
- **Fixture** `run/AliasOfItselfUnifies.beni`, red `dev: exit=1 codes=infinite_type×1`.
- **Slice** R15-fix-C.
- **Status** fixed by R15-fix-C (2026-09-28), `checker-v2.md` §7.1 *amended by R15-fix-C*
  (`Unify.throughAlias`). Promoted into `tests/corpus/run/`.

### CK-173 — A rigid variable does not unify with an alias that expands to it

- **Severity** valid-program-rejected. **Area** `Unify.rigid`, whose `.alias` row answered "no"
  without looking through the alias. **Class** K5. **Sources** R15-fix-C, writing CK-169's fixtures.
- **Program** `unwrapId : Id a -> a`, `unwrapId x = x`.
- **Observed** TYPE MISMATCH "The body is: `Id a` … should be: `a`" (`rigid_mismatch`).
- **Expected** it checks: `Id a` is `a`.
- **Fixture** `run/RigidMeetsAliasOfItself.beni`, red `dev: exit=1 codes=rigid_mismatch×1`.
- **Slice** R15-fix-C.
- **Status** fixed by R15-fix-C (2026-09-28), `checker-v2.md` §7.1 *amended by R15-fix-C*
  (`Unify.throughAlias`). Promoted into `tests/corpus/run/`.

### CK-174 — A kinded variable meeting an alias of a variable is a kind mismatch

- **Severity** valid-program-rejected. **Area** `Unify.flex`'s `.alias` row: a `number` flex
  meeting an alias tests its kind against the alias's expansion, and when that is itself a variable
  (the literal's own `number`) the test says no. **Class** K5. **Sources** R15-fix-C, writing
  CK-169's fixtures.
- **Program** `wrap : a -> Id a`, `a0 = wrap 1`, `a0 == a0`.
- **Observed** TYPE MISMATCH "`Id number, Id number -> Bool` … But I need: `number, number ->
  Bool`" (`kind_mismatch`).
- **Expected** it builds and prints `T`: a variable meeting an alias of a variable is the two
  variables meeting.
- **Fixture** `run/NumberUnderAliasCompared.beni`, red `dev: exit=1 codes=kind_mismatch×1`.
- **Slice** R15-fix-C.
- **Status** fixed by R15-fix-C (2026-09-28), `checker-v2.md` §7.1 *amended by R15-fix-C*
  (`Unify.throughAlias`). Promoted into `tests/corpus/run/`.

### CK-175 — An alias that drops a parameter is unified by its arguments

- **Severity** valid-program-rejected, and nondeterminism (I9: the verdict depends on declaration
  order). **Area** `Unify.throughAlias`: two aliases of one name unify their ARGUMENTS and keep the
  name. For an alias whose expansion drops a parameter (`type alias Tagged t = Int`) two uses can
  expand to one type while their arguments differ. **Class** K5 (a shortcut answered for a case it
  does not cover). **Sources** R15-fix-E's review.
- **Program** `a : Tagged String`, `b : Tagged Bool`, `c : Int`; mutually recursive `f n = if n ==
  0 then a else g (n - 1)` and `g n = if n == 0 then c else f (n - 1)`; `k = [ f 1, b ]`. Also
  `[ a, b ]`, and `retag : Tagged x -> Tagged y` with body `x`.
- **Observed** `[ f 1, b ]` is TYPE MISMATCH "`Tagged Bool` … `Tagged String`" with `f` above `g`
  and checks with the two swapped (whichever of `a` and `c` the group meets first is what `f`'s
  result absorbs); a three-way version fails in 4 of 6 orders. `[ a, b ]` is refused while `[ c,
  a, b ]` is accepted; `retag` is refused.
- **Expected** every one checks, in every order: both expand to `Int`.
- **Fixture** `run/PhantomAliasUnifiesByExpansion.beni`, red `dev: exit=1 codes=type_mismatch×3`.
- **Slice** R15-fix-G.
- **Status** fixed by R15-fix-G (2026-09-28), `checker-v2.md` §7.1 *amended by R15-fix-G*:
  arguments are unified only for an INJECTIVE alias (`Types.Entry.injective`, `Injective.zig`);
  otherwise the expansions meet. Promoted: `tests/corpus/run/PhantomAliasUnifiesByExpansion.beni`;
  new `run/PhantomAliasNested.beni`, `run/PhantomAliasMutualGroup.beni` (PERM) and the guard
  `check/bad/PhantomTypeAliasKeepsArguments.beni`. The inferred NAME of such a type can still
  depend on order: CK-179.

### CK-176 — A message prints an alias of a variable as the variable

- **Severity** diagnostic-quality (a regression from R15-fix-C). **Area** `Unify.throughAlias`'s
  flex row: a flex meeting an alias whose expansion is a variable meets the expansion instead, so a
  declaration's parameter and result variables lose the name the annotation wrote; and
  `Solve.rigidOf` does not look through an alias for the rigid variable its hint names. **Class**
  K13. **Sources** R15-fix-E's review.
- **Program** `type alias Id a = a`; `bad : a -> Id b` with body `x`; `f5 : Id a -> Name` with
  body `x` (`type alias Name = String`).
- **Observed** "the type annotation says it should be: `b`" and "The body is: `a`". Before
  R15-fix-C: `Id b` and `Id a`.
- **Expected** `Id b` and `Id a`, and the rigid hint naming `b` and `a`.
- **Fixture** `check/bad/AliasOfVariableKeepsItsName.beni` (`.codes`), red `exit=1
  codes=rigid_mismatch×2 why=message`.
- **Slice** R15-fix-G.
- **Status** fixed by R15-fix-G (2026-09-28), `checker-v2.md` §7.1 *amended by R15-fix-G*: a flex
  nothing rides on absorbs an alias of a variable by name, and `Solve.rigidOf` looks through an
  alias. Promoted: `tests/corpus/check/bad/AliasOfVariableKeepsItsName.beni`.

### CK-177 — A mismatch against a cyclic type prints the cycle, 37 KB of it

- **Severity** diagnostic-quality (an output blow-up). **Area** `Solve.reportFailureText`: only a
  `too_deep` failure looked for a cycle first; `Render.write` prints a cyclic graph as a tree until
  its node budget runs out. **Class** K13, K3. **Sources** R15-fix-E's review; pre-existing.
- **Program** `f x = [ x, ( x, x ), { zb = x, za = "s" } ]`.
- **Observed** a 37 KB TYPE MISMATCH: `zb` a tuple unrolled to 4 096 nodes, the other side `…`.
- **Expected** one INFINITE TYPE, `a = ( a, a )`: the cycle is the mistake and the mismatch its
  consequence. And the printer never renders a cycle by unrolling it.
- **Fixture** `check/bad/InfiniteTypeBeforeMismatch.beni` (`.codes`), red `exit=1
  codes=type_mismatch×1 why=code`.
- **Slice** R15-fix-G.
- **Status** fixed by R15-fix-G (2026-09-28), `checker-v2.md` §7.3 *amended by R15-fix-G*: every
  failure looks for a cycle on both sides first (`Solve.reportFailureText`), and `Render` elides a
  cycle where it repeats. The INFINITE TYPE is at the failing unification (10:20). Promoted:
  `tests/corpus/check/bad/InfiniteTypeBeforeMismatch.beni`; `blackbox_test.zig`'s CK-92 scenario
  now expects it.

### CK-178 — A payload's reported `err` refuses its type's derived `==`

- **Severity** diagnostic-quality (a cascade with a false hint). **Area** `Contexts.collect`: a
  payload wanted POISONED by an `err` (whose message was said where it was made, §12.2) read as a
  failed one, `absent_other`, which the use reports as NOT EQUATABLE. **Class** K9. **Sources**
  R15-fix-E's review; pre-existing.
- **Program** `schema Shape tagged "kind" of Circle as "circle" v : Int Int Int`, then `c == c` on
  a `Shape.Type`.
- **Observed** WRONG TYPE ARITY, then NOT EQUATABLE "a function anywhere inside it rules the whole
  type out" — there is no function.
- **Expected** the arity error alone.
- **Fixture** `check/bad/SchemaPayloadArityNoCascade.beni` (`.codes`), red `exit=1
  codes=not_equatable×1,wrong_type_arity×1 why=code`.
- **Slice** R15-fix-G.
- **Status** fixed by R15-fix-G (2026-09-28), `checker-v2.md` §12.2 *amended by R15-fix-G*:
  `Contexts.Status.poisoned`, a pass over a poisoned payload with nothing failed is no answer and
  no message; published as `unchecked`. Promoted: `tests/corpus/check/bad/SchemaPayloadArityNoCascade.beni`.

### CK-179 — An inferred type names whichever alias its group meets first

- **Severity** nondeterminism (I9's scope: "for an accepted program its types"). **Area**
  `Unify`: a flex binds to what it meets first — an alias by name, or a structure — and a later
  meeting of an equal type under another name writes nothing to it. Inside a recursive group the
  members' result is one flex, met in declaration order. Elm behaves the same. **Class** K12.
  **Sources** R15-fix-G, writing CK-175's permutation program; pre-existing (`8a68e12`).
- **Program** `type alias Name = String`, `x : Name`, `y : String`, and a recursive group `f n =
  if n == 0 then x else g (n - 1)`, `g n = if n == 0 then y else f (n - 1)`.
- **Observed** with `f` above `g`, `dump --stage=types` says `f : number -> Name` and `g : number
  -> Name`; with `g` above `f`, both `number -> String`. Every order checks and runs alike.
- **Expected** one type in every order. Which one — the first met (Elm's rule, not
  order-independent here), the expansion whenever two names meet, or a canonical choice — is the
  owner's decision: dropping the name on a conflict would print `String` where a message says
  `Name` today, after `String.length p` on a `p : Name`.
- **Fixture** `scenario/CK-179` (`test-pending`), red `order-dependent`.
- **Slice** unassigned (owner's decision first).
- **Status** fixed by R15-fix-I (2026-09-28) under the owner's decision of that day, "agree or
  expand" (`checker-v2.md` §21.1 D16, §7.1 *amended 2026-09-28*): a flex takes an alias's name
  into a class marked inferred (`TypeStore.inferred_alias`) — joining an inferred class, copying a
  written one — and an inferred name that meets another name or an unnamed type shows its
  expansion (`Unify.expand`); written names (annotation readings, instantiation copies) never
  change. `f` and `g` are `number -> String` in both orders and `x : Name` prints as written.
  Promoted into `ordering_test.zig`; `run/PhantomAliasUnifiesByExpansion.beni` joins PERM. The
  accepted cost: a parameter that took its annotation's name shows the expansion after meeting it
  (`blackbox_test.zig`'s types dump now prints `p : { x : Int, y : Int }` under `shift : Point ->
  Point`).

*CK-190 to CK-192 were added on 2026-09-28 from the review of R15-fix-F, and CK-193 by R15-fix-H's
own audit of the budgets in `src/js`. They start at 190 because R15-fix-G was cataloguing
concurrently (it took CK-175 to CK-179); CK-180 to CK-189 are unused.*

### CK-190 — `--release` prints a dropped binding past 64 chained substitutions (unsound)

- **Severity** unsound-runtime. **Area** the release optimiser: `Opt` inlines each single-use alias
  and drops its binding; `Printer.resolve` follows the substitution chain for at most 64 steps
  (and `Opt.chainBase` likewise), then prints the name it stopped at, whose binding is gone, and
  `Rename` spells it as whatever short name a live top-level holds. **Class** K14. **Sources**
  review of R15-fix-F, H1.
- **Program** `v x0 = let x1 = x0 … x130 = x129 in x130`, beside a top-level `k = 7`.
- **Observed** dev prints `42`; `--release` prints `7` (emitted `const c=7,d=(a)=>c`). At 129 links
  it prints a function's source; at 1 000 it throws `ReferenceError`; up to 128 it is right.
- **Expected** both builds print `42` at every length. A budget whose exhaustion yields output is
  only acceptable where the output is the conservative, unoptimised program.
- **Fixture** `run/ReleaseAliasChain{129,130,1000}.beni`, red `release: exit=0 stdout-differs`
  (1000: `program-exit=1`); `ReleaseAliasChain{64,65,128}` are green and went straight into
  `tests/corpus/run/` as the boundary.
- **Slice** R15-fix-H.
- **Status** fixed by R15-fix-H (2026-09-28), `backend.md` §9 item 1 *amended by R15-fix-H*:
  substitutions are path-compressed when recorded (`Opt.compress`), so the printer's `resolve` is
  one lookup with no budget; `markAssigned` lost its unsafe budget in the same audit. Promoted into
  `tests/corpus/run/`.

### CK-191 — The output record's stale pass can delete the file just written, on APFS and NTFS

- **Severity** latent (low-medium: a missing module after a rename by case only, on macOS or
  Windows). **Area** `OutputRecord.removeStale`. **Class** K14. **Sources** review of R15-fix-F,
  H2.
- **Program** build a `Main` importing `Zz` into `out/`, then one importing `ZZ` (identical bytes
  under `--release`; `Ab`/`AB` are not, their exports get different short names).
- **Observed** the stale pass compares paths byte for byte: `Zz.mjs` is not written, so it is
  read, its hash matches the old record, and it is deleted — on a case-folding file system, the
  very file `ZZ.mjs` just wrote. Reproduced on Linux by making `ZZ.mjs` a hard link of `Zz.mjs`
  before the second build, which is how the two names behave on APFS.
- **Expected** a stale path equal to a written one under ASCII case folding (as
  `output_path_collision` folds, `backend.md` §2) is not removed when it is the same file. Where
  it is another file (a case-sensitive file system), it is stale like any other, so `--out` still
  matches a fresh build — which the harness's own folding check requires.
- **Fixture** `scenario/CK-191` (fast step), red `removed`.
- **Slice** R15-fix-H.
- **Status** fixed by R15-fix-H (2026-09-28), `backend.md` §2 rule 4: a folded match is removed
  only when `statFile` reports another inode. Promoted into `build_test.zig` (the same-file case
  by hard link, and the two-files case, which must still equal a fresh build).

### CK-192 — A `_manifest.txt` beni did not write is silently overwritten

- **Severity** latent (low: a user's file of that name is lost). **Area** `OutputRecord.read`.
  **Class** K14. **Sources** review of R15-fix-F, H3.
- **Program** `out/_manifest.txt` holding `my own notes`, then `build --out=out`.
- **Observed** exit 0; the file is replaced by beni's record.
- **Expected** a `_manifest.txt` that does not parse as beni's record refuses the build with a
  diagnostic naming the file, and nothing is written.
- **Fixture** `scenario/CK-192` (fast step), red `overwritten`.
- **Slice** R15-fix-H.
- **Status** fixed by R15-fix-H (2026-09-28), `backend.md` §2 *amended by R15-fix-H*: the new
  code `unknown_output_record` (`language.md` §10), before the first byte is written. Promoted
  into `build_test.zig`.

### CK-193 — The `foreign` shape check admits a polymorphic value when its type is wide

- **Severity** unsound-runtime (a platform package only: rule 6 keeps `foreign` there). **Area**
  `Emit.firstTypeVar`, `boundary.md` §4's check 1: it walked the type on a 64-slot stack under a
  4 096-node budget and answered null — "concrete", the admitting answer — when either ran out.
  **Class** K14. **Sources** R15-fix-H's audit of the budgets in `src/js` (CK-190's kind).
- **Program** `pub foreign wide : { f1 : Int, …, f64 : Int, g : a }` in a platform package.
- **Observed** the build exits 0; `Bad.wide.g` is a value of any type the caller picks.
- **Expected** `foreign_bad_shape`, exactly as for `foreign anything : a`.
- **Fixture** `build/bad/ForeignBadShapeWideRecord/`, red `BuildDidNotFail`.
- **Slice** R15-fix-H.
- **Status** fixed by R15-fix-H (2026-09-28): the walk is total, on a growing stack. Promoted into
  `tests/corpus/build/bad/`.

*CK-194 to CK-197 were added on 2026-09-28 by R15-fix-I, from the manager's residues of R15-fix-H's
review; written red on `275b203` before any fix (their own commit).*

### CK-194 — A chain of bindings each wrapping the last is quadratic, and ends in OutOfMemory

- **Severity** compiler-crash-or-hang (exit 2 with no diagnostic). **Area** instantiation and the
  boundary's walks over an inferred type that grows by one level per binding. **Class** K3.
  **Sources** the manager (residue of R15-fix-H's review).
- **Program** `x0 = 0`, then `x{i} = Just x{i-1}` for i up to n: `x{n}`'s type is `n` levels deep.
- **Observed** at `275b203`, ReleaseFast, `check --jobs=1`: 5 000 links 2.0 s, 10 000 links 8.4 s
  (ratio 4.1: quadratic); 20 000 links `beni: OutOfMemory`, exit 2, no diagnostic. Debug: 1 000 /
  2 000 / 4 000 links 2.0 / 7.5 / 29.4 s. **Where** (perf): `Instantiate.copy` 61 % (each use of
  `x{i-1}` copies its whole generalised type — every node of a top-level type is quantified, the
  closed ones too, because a top-level frame's rank is `outermost`, which is also the floor an
  application's rank is folded from), the binder's occurs check 17 % and `adjustRanks` 16 %, each
  over the copy: O(i) per link, O(n²) in time and in the store's memory. The same with `x0 = "s"`.
- **Expected** linear-ish, or §7.3's documented `nesting_too_deep` — never an out-of-memory exit.
- **Fixture** `scenario/CK-194` (`test-pending-perf`), red `slow`.
- **Slice** R15-fix-I.
- **Status** fixed by R15-fix-I (2026-09-28), `checker-v2.md` §7.3 *amended 2026-09-28*: the
  boundary's occurs run is bounded by `Unify.max_depth` (`Walk.Occurs.limit`); a binder past it is
  one `nesting_too_deep` (`Messages.inferredTooDeep`) and poisoned, later links holding its poison
  poisoned in silence. ReleaseFast: 5 000 / 10 000 / 20 000 links 1.1 / 2.1 / 4.6 s CPU, one
  message each (was 2.0 / 8.4 s / OutOfMemory). Promoted into `perf_test.zig`. The quadratic's
  roots are unchanged below the guard: a top-level frame's rank is `outermost`, so every node of a
  top-level type is quantified and copied per use; making closed types unquantified would need
  the frames re-ranked, left for a perf slice.
- **Decision** (R15-fix-J, 2026-09-28): the re-ranking is recorded as a **perf idea, not done as
  structural work**. What it would change: top-level frames at `outermost + 1`, so a closed
  structure (whose rank folds from the `outermost` floor) stays below the young rank, is never
  quantified and is shared rather than copied at each use. Why not now: (1) it is a change to
  the rank model itself — every frame's rank, §8.1's boundary, §10.2's nesting ranks, the
  quantify/escape split and what `Instantiate` shares — so it needs a spec amendment of §8 and
  §10.2 before code (rule 1), and Elm's `outermostRank` has the same property, so it is a
  departure to argue, not a defect; (2) no program is wrong or crashes today: the guard bounds the
  chain (one `nesting_too_deep` past `Unify.max_depth`), and below it the copies are quadratic
  only in a chain of ever deeper types, which `perf_test.zig`'s CK-194 scenario times; (3) no
  corpus or bench profile shows `Instantiate.copy` of closed types as a cost worth the change.
  Owed: a perf slice that measures `bench/corpus` with and without, amends §8/§10.2, and keeps
  ordering and determinism tests green.

### CK-195 — A wrong own-method signature is reported once per use in every importer

- **Severity** diagnostic-quality. **Area** CK-168's report across modules. **Class** K13.
  **Sources** the manager (residue of CK-168).
- **Program** `M`: `pub type T = T Int`, `pub eq : T, Int -> Bool`, no use of `==`. `Main`: two
  `M.T 1 == M.T 1`.
- **Observed** `M` checks clean (CK-168's report is made by a use, and `M` has none); `Main` gets
  one TYPE MISMATCH "`M.eq` is not the method this call needs" per use.
- **Expected** one message, at the method, in `M`: the mistake is the method's, and it is `M`'s
  exported API.
- **Fixture** `check/bad/OwnMethodSignatureAcrossModules/` (`.codes`), red `exit=1
  codes=type_mismatch×2 why=count`.
- **Slice** R15-fix-I.
- **Status** fixed by R15-fix-I (2026-09-28), `checker-v2.md` §9.3 *amended 2026-09-28*:
  `Instances.ownSignatures` says a `pub eq`/`compare` written for a type of its module (first
  parameter) that fits no use of it at the declaration, used or not; an importer's use of such a
  method, judged off the interface by the same tests (`reportedAtDeclaration`), is `poisoned`.
  Promoted: `tests/corpus/check/bad/OwnMethodSignatureAcrossModules/`.

### CK-196 — Two types refusing one own method print in the order their uses were checked

- **Severity** nondeterminism (I9: what a refused program prints). **Area**
  `Instances.signatureOnce` (CK-168). **Class** K12. **Sources** the manager (confirm-or-refute).
- **Program** `type T = T Int`, `type V = V Int`, `pub eq : T, Int -> Bool`, a `==` on a `T` and
  one on a `V`; then the same declarations in the reverse order.
- **Observed** *Refuted as stated, confirmed in part.* The SET of codes and positions is the same in
  both orders: two TYPE MISMATCHes, both at `eq`'s declaration ("cannot be the `eq` of `T`" and
  "… of `V`", the module-rule clash). But the two share one position, so they print in the order
  the uses were checked, which follows declaration order: `T`'s first in one order, `V`'s in the
  other. And it is two messages for one mistake (`eq`'s type).
- **Expected** one message per method, the same in every order.
- **Fixture** `scenario/CK-196` (`test-pending`), red `order-dependent`.
- **Slice** R15-fix-I.
- **Status** fixed by R15-fix-I (2026-09-28), `checker-v2.md` §9.3 *amended 2026-09-28*: the
  messages are recorded in P4 and said after it, once per method — the type it is written for
  when that failed, else the first by name. Promoted into `ordering_test.zig` (each order its own
  project, so the module name in the message is the same).

### CK-197 — A pinned type refused through a recursive payload does not say which payload

- **Severity** diagnostic-quality. **Area** `Messages.requirementFailed`'s text when a context's
  answer is `absent_requirement` with no types (CK-116, CK-159). **Class** K13. **Sources** the
  manager (minor residue of R15-fix-E).
- **Program** `H.eq : Holder Int, Holder Int -> Bool`; `type S a = SLeaf a | SNode (S (H.Holder
  a))`; `SLeaf 1 == SLeaf 1`.
- **Observed** NOT EQUATABLE "`S number` … It holds a `Holder`, and comparing that needs the `eq` of
  `Holder` at a type that `H.eq` does not have." Correct (no `S` can be compared: the recursion
  asks for `Holder (Holder a)`), but it names neither the payload nor the type it is asked at.
- **Expected** the constructor and payload that fail, and the type the method is asked at.
- **Fixture** `check/bad/DerivedPinnedRecursive/` (`.codes`), red `exit=1 codes=not_equatable×1
  why=message`.
- **Slice** R15-fix-I.
- **Status** fixed by R15-fix-I (2026-09-28): `Contexts.Answer.payload` records the first failed
  payload of an `absent_requirement` answer, `Contexts.payloadAt` reads it, and
  `Messages.requirementFailed` names the constructor and the type it holds (local types; an
  imported row still has the older text). Four `check/bad` goldens re-blessed with it. Promoted:
  `tests/corpus/check/bad/DerivedPinnedRecursive/`.

### CK-198 — `==` on a record of 65 530 fields is over the test budget

- **Severity** performance. **Area** the derived function of a wide record, its emit, and the
  copies of its type at each use. **Class** K11. **Sources** the test budget (2026-09-28): every
  gated test must retire at most 4 300 million user-space instructions, what one second of CPU
  retires on this code.
- **Program** `r = { f1 = 1, …, f65530 = 65530 }`, `main` printing `r == r`: the width that threw
  `RangeError` under Node 24 before the wide form, which builds and runs now.
- **Observed** on the self-hosted ReleaseSafe beni the gates run, one `build --no-cache`: 5 323
  million instructions against the budget of 4 300 (it was 10 203 before the budget work cut it).
  **Where** (perf): emitting the record's derived function and literal, about 5 MB of JavaScript
  (lowering and printing about 1.7 billion); the checker about 2.7 billion, much of it re-copying
  the record's generalised type at each use (`Instantiate.copy`, `Types.Builder.read`, record
  unification) and elaborating its 65 530 positions; the front end on the 1 MB source the rest.
  The profile is flat: no quadratic is left, and the self-hosted backend inlines nothing.
- **Expected** under the budget, so the scenario can go back into `abuse_wide_test.zig`.
- **Fixture** `scenario/CK-198` (`test-pending`), red `over-budget`.
- **Slice** open.
- **Status** fixed by resizing (2026-09-28), the owner's decision: the 65 530 width is not needed.
  The compiler's branch is `Convention.derivedEvidence`'s switch from positional evidence to one
  array past `max_positional_evidence` (4 096), and 4 097 reaches it; what 65 530 added was an
  engine's claim (V8 loading a function of several MB), not a branch of the compiler, and the
  checker's 16-bit index at 65 535 is the check-only payload test's. The scenario is gone;
  `abuse_wide_test.zig`'s "`==` and `<` on a record one field past the positional evidence limit
  build and run" already built and ran 4 097 fields, and now also reads the emitted module: two
  derived functions taking `($m, $x, $y)` and three uses each passing one array literal. With
  the limit moved to 4 097 the program still runs and the test is red on that shape. 860 million
  instructions against the budget of 4 300, development build only (`--release` lowers the same
  calls and has no branch of its own at the switch).

### CK-199 — A type of 4 097 parameters compared across modules is over the test budget

- **Severity** performance. **Area** the derived `eq` and `compare` of a wide nominal type, emitted
  in both forms, and an importer checked against its record. **Class** K11. **Sources** the test
  budget (2026-09-28), as CK-198.
- **Program** `Wide.beni`: `pub type T a0 … a4096 = Mk a0 … a4096`; `Main.beni` compares two values
  of it with `==` and `<`. Three builds over one cache directory, one per place the importer's
  packed evidence count comes from: cold, warm under `--release`, and `Main` edited.
- **Observed** on the self-hosted ReleaseSafe beni: 4 802 million instructions for the three builds
  against the budget of 4 300 (the eight builds it ran before came to 20 666). **Where**: about
  70% is emitting `T`'s derived `eq` and `compare`, in both the positional and the wide form, about
  2 MB of JavaScript per build; checking `Main` against the loaded record and re-reading `T`'s
  constructor type at each use most of the rest.
- **Expected** under the budget, so the scenario can go back into `cache_test.zig`. A per-module
  emit cache would make the warm builds nearly free; it needs a spec first.
- **Fixture** `scenario/CK-199` (`test-pending`), red `over-budget`.
- **Slice** open.
- **Status** fixed by resizing (2026-09-28): 4 097 stays, since it is the narrowest count that
  takes the array, and the builds are cut to the ones whose claim is a cached record stating that
  count. A `check` of both modules fills the cache (the cold build's count came from the
  interface in memory, which no record states), then two development builds: warm, nothing
  checked, the count from `Main`'s cached dispatch table; and `Main` edited, `Main` checked
  against `Wide`'s loaded interface. Each runs its program and reads `Main.mjs` for the packed
  calls; the `--release` build went, as it has no branch of its own at the switch. Back in
  `cache_test.zig` as "an imported type of 4 097 parameters compares in the wide form from a warm
  cache and with only the importer edited": 3 503 million instructions against 4 300 (the check
  about 890, the warm build about 950, the edited build about 1 160). With the limit moved to
  4 097 it is red on the packed calls.

### CK-200 — A mismatch on a string literal underlines its opening quote alone

- **Severity** diagnostic-quality. **Area** the span of a diagnostic whose region is a string
  literal: `Session.tokenSpan` measures the one token an instruction came from, and a literal is
  three or more tokens (`str_start`, chunks, interpolations, `str_end`); `Lower.lowerString`
  stamps an interpolated literal's `interp` instruction with the token its last part left.
  **Class** K14. **Sources** reported by a user of the compiler (2026-09-28).
- **Program** `label : Int`, `label = "not an int"`; and `greeting : Int`, `greeting = "hello
  ${1} and ${2}!"`.
- **Observed** the TYPE MISMATCH at `label` spans column 5 to 6, the `"`; the one at `greeting`
  starts at the `2`, one column.
- **Expected** each spans its whole literal, opening quote to closing quote.
- **Fixture** `check/bad/StringLiteralMismatchSpan.beni`, red `why=diag`.
- **Slice** R15-fix-J.
- **Status** fixed by R15-fix-J (2026-09-28): `Lower.lowerString` stamps `string`, `interp` and each `chunk`
  with its own token (the literal's opening quote for the first two), and `Session.tokenSpan`
  spans a `str_start` to its `str_end` (`stringLiteralEnd`; a literal the lexer never closed
  keeps the quote's extent). Every diagnostic whose region is a string literal is affected, not
  only a mismatch: 25 goldens under `tests/corpus/check/` were wrong the same way and were
  re-blessed, each a pure widening of one span over a literal (message text unchanged). A
  multiline `\\` literal still spans its first line only. Promoted into `tests/corpus/check/bad/`.

### CK-201 — A derived `eq` whose pass is refused a nested check says the type holds a function

- **Severity** diagnostic-quality (a false message; the program is refused either way). **Area**
  `Contexts.pass`: it looked for a `nesting_too_deep` in the quiet report's list, which keeps
  only `internal`s, so the refusal was never seen. **Class** K9 (CK-14's pattern, CK-146 (3)).
  **Sources** R15-fix-J, while closing CK-146 (3).
- **Program** `H`: `pub type Holder a = Holder a`, `pub eq : Holder a, Holder a -> Bool where
  a.key : a, () -> Int`. `Main`: `type W = W (H.Holder K)`, a chain of 600 own methods on another
  type each calling the next, written before the one it calls, the last comparing two `W`, and
  `K`'s own `key` written last (still unchecked when `W`'s pass needs it).
- **Observed** NOT EQUATABLE at the `==`: "a function anywhere inside it rules the whole type
  out" — there is none.
- **Expected** one NESTING TOO DEEP at the `==`, saying the derivation went deeper than the
  checker follows, with the hint to annotate the methods it reaches.
- **Fixture** `ordering_test.zig` "a derived eq whose pass is refused a nested check says so at the
  comparison" (a generated 600-link chain; 319 million instructions), red before the fix with
  `not_equatable`.
- **Slice** R15-fix-J.
- **Status** fixed by R15-fix-J (2026-09-28): `Report.too_deep`, `Contexts.pass`, and
  `Messages.derivedBudget` at the use (also for a pass out of steps, whose text said "took more
  than 1048576 steps" of a group).

*CK-202 to CK-209 were added on 2026-09-29 from the final review of the checker, each written
with a red fixture on `b8b289a` before its fix.*

### CK-202 — Alias names inside a structure keep the first name met

- **Severity** nondeterminism (I9's scope: an accepted program's types; D16 "agree or expand" held
  only at the top of a type). **Area** `Unify.throughAlias`: two WRITTEN names — an annotation's
  reading or an instantiation's copy — that meet are both left unexpanded, so a flex bound to the
  structure around one of them shows whichever copy the structure's merge kept. **Class** K12.
  **Sources** the final review of the checker (2026-09-29).
- **Program** `type alias Name = String`, `type alias Label = String`, `x : List Name`, `y : List
  Label`, a recursive group `f n = if n == 0 then x else g (n - 1)`, `g n = if n == 0 then y else f
  (n - 1)`; also `if c then x else y` against the branches swapped, `Maybe Name` against `Maybe
  String`, and `Pair Name` against `Pair Label` for an injective `type alias Pair a = ( a, a )`.
- **Observed** `dump --stage=types` says `f : number -> List Name` with `f` above `g` and `List
  Label` with `g` above `f`; the two branch orders print `List Name` and `List Label`; `Maybe
  Name`; `Pair Name`. The interface prints the same when the declarations are `pub`.
- **Expected** `List String`, `Maybe String` and `Pair String` in every order: when two different
  names meet anywhere in a type, written or inferred, the result shows the expansion; the same name
  with the same arguments keeps it; an annotation still prints as written.
- **Fixture** `check/good/AliasNamesInsideStructures.beni` (red `exit=0 iface-differs`),
  `scenario/CK-202` (the recursive group in both orders) and `scenario/CK-202-branches` (both
  branch orders), red `order-dependent`.
- **Slice** the final review's fixes.
- **Status** fixed (2026-09-29), `checker-v2.md` §7.1 *amended 2026-09-29*: the written/inferred
  distinction is gone (`TypeStore.inferred_alias` deleted). Every alias a unification reaches may
  expand, at any depth; a flex joins the class of the alias it meets (`Unify.takeName`); two
  uses of one injective name merge. An annotation prints as written because what prints it is
  never unified: the interface prints the scheme, and `dump --stage=types` a second reading over
  the rigid reading's variables (`Decl.Member.display`, made only when the run keeps its tables).
  A generalised alias — a schema endpoint's shared type — is never rewritten. No corpus message
  changed. Promoted: `tests/corpus/check/good/AliasNamesInsideStructures.beni`; the two scenarios
  into `ordering_test.zig` ("alias names inside a structure show the expansion with the group
  reversed", "alias names met by an if show the expansion in either branch order").

### CK-203 — An alias DAG whose uses differ in their arguments is expanded as a tree

- **Severity** performance (and a false message). **Area** `Types.Builder.apply`: an alias is
  expanded once per `(alias, argument roots)`, but every read of a body builds its applied types
  afresh, so `A{i-1} (List a)` meets a new `List a` root each time and no pair repeats. **Class**
  K11 (CK-171's DAG, with arguments). **Sources** the final review of the checker (2026-09-29).
- **Program** `type alias A0 a = Maybe a`, `type alias A{i} a = ( A{i-1} a, A{i-1} (List a) )`,
  `f : A{N} Int -> Int`; or `type Box = Box (A{N} Int)`; or `==` on two `A{N} Int`.
- **Observed** (ReleaseFast) N = 20: 3.7 s and 2.3 GB for the annotation, 7.8 s and 3.4 GB for
  `Box`; ×4 every two levels. `==` at N = 18 is NESTING TOO DEEP: "took more than 1048576 steps …
  The types their method calls are made on nest deeper and deeper as I follow them" — the type is
  finite and does not grow.
- **Expected** each distinct type built once (about N²/2 of them), so the read is polynomial and
  the check near the process floor; and the step-budget message says what is true of a finite
  type too — that the types were too many or too large to follow — not that they keep growing.
- **Fixture** `scenario/CK-203` (`test-pending-perf`, depth 16 / 32), red `slow`.
- **Slice** the final review's fixes.
- **Status** fixed (2026-09-29), `checker-v2.md` §7.4 *amended 2026-09-29*: `Types.Builder.apply`
  keeps an applied nominal type in the read's alias memo by `(type, argument roots)`, so the
  aliases over one `List a` meet one root. ReleaseFast: depth 16 and 32 check in 6 ms each (144 ms
  and a kill before); at depth 20 the annotation, `Box` and `==` all take under 10 ms, and `Box` at
  depth 80 checks in about 20 ms. Promoted into `perf_test.zig` ("an annotation over an alias DAG
  whose uses differ in their arguments is not exponential"). The step-budget text
  (`Messages.resolutionBudget`) now says the types are "too many, or too large … they may keep
  growing … or simply be very big", and the derived-budget text says "too many or keep growing".
  No program within the test budget reaches the group step budget with a finite type now that
  the DAG is shared (a three-way DAG of 37 000 distinct types stays under it), so the new text
  has no black-box test; `ordering_test.zig` holds the derived-budget one's. A ReleaseSafe build
  is much slower than ReleaseFast on such DAGs (7 s against 0.07 s for the three-way DAG at depth
  40): its safety-only proof re-walks, not a defect users meet.

### CK-204 — A field of the wrong type is reported as a missing field

- **Severity** diagnostic-quality (a false message). **Area** `Diagnostics.categoryLines`'
  `field_access` lines, which assume the record lacks the field. **Class** K13. **Sources** the
  final review of the checker (2026-09-29).
- **Program** `f : { count : Int } -> String`, `f x = x.count`; the same through another
  module's `pub type alias Counter = { count : Int, label : String }`.
- **Observed** "This is not a record with a `count` field: It is: `{ count : Int }` But I need a
  record like: `{ count : String }`" — the field is there.
- **Expected** the message says the record has the field, shows the field's type, and the type
  the code needs it to be.
- **Fixture** `check/bad/RecordFieldType.beni`, red `why=message`;
  `check/bad/RecordFieldTypeAcrossModules/`, red `why=message`.
- **Slice** the final review's fixes.
- **Status** fixed (2026-09-29): `Diagnostics.Reporter.mismatch` looks the field up in both
  records (through aliases and extension chains, `recordField`) and, when the found record has
  it, says "This record has a `count` field, but not of the type I need", shows the field's type
  against the needed one, and takes its hint from those two types. A record that lacks the field
  keeps `missing_field`, and a value that is no record the old lines. No other golden changed.
  Promoted: `tests/corpus/check/bad/RecordFieldType.beni`, `…/RecordFieldTypeAcrossModules/`.

### CK-205 — Two different types with one name print alike in one message

- **Severity** diagnostic-quality (low). **Area** `Render.writeNamed` prints a type's bare name.
  **Class** K13. **Sources** the final review of the checker (2026-09-29).
- **Program** `Shapes` declares `pub type T` and `pub type alias Name = { n : Int }`; `Main`
  declares its own `T` and `Name = { n : Bool }`, and passes each where `Shapes`'s is wanted.
- **Observed** "This argument is: `T` But `f` needs the 1st argument to be: `T`", and the same for
  `Name`.
- **Expected** when two distinct types or aliases in one message share a name, both are qualified
  by module: `Main.T` against `Shapes.T`.
- **Fixture** `check/bad/SameNameTypesQualified/`, red `why=message`.
- **Slice** the final review's fixes.
- **Status** fixed (2026-09-29), `checker-v2.md` §15.3 *amended 2026-09-29*: before a
  `type_mismatch` prints its two types, `Render.qualifyClashes` walks what the message will print
  and marks every type or alias whose name another distinct one shares; `Render.writeNamed`
  prints those as `Module.Name`. Other messages print as before. No other golden changed.
  Promoted: `tests/corpus/check/bad/SameNameTypesQualified/`.

### CK-206 — A mismatch on a multiline string spans its first line only

- **Severity** diagnostic-quality (low). **Area** `Session.tokenSpan`'s string-literal extent,
  which CK-200 widened for a quoted literal and left alone for `\\` lines. **Class** K14.
  **Sources** the final review of the checker (2026-09-29); CK-200's Status named it.
- **Program** `label : Int`, `label =` a three-line `\\` literal.
- **Observed** the TYPE MISMATCH spans `\\one`, the first line.
- **Expected** it spans the whole literal, the first `\\` to the end of the last line.
- **Fixture** `check/bad/MultilineStringMismatchSpan.beni`, red `why=diag`.
- **Slice** the final review's fixes.
- **Status** fixed (2026-09-29): `Session.tokenSpan` spans a `multiline_line` to the end of the
  last line of its run (`multilineLiteralEnd`: consecutive lines, the parser's rule). Every
  diagnostic whose region is a multiline literal is affected; no other golden had one. Promoted:
  `tests/corpus/check/bad/MultilineStringMismatchSpan.beni`.

### CK-207 — A pinned derived `==` reached through a helper blames the wrong function

- **Severity** diagnostic-quality (low; the program is refused either way). **Area**
  `Instances.derivedNominal`'s pins: resolution runs eagerly, when the receiver's head is known,
  and a pin unifies the use's argument even while it is still undetermined — before the argument
  expression that decides it is read. **Class** K13. **Sources** the final review of the checker
  (2026-09-29).
- **Program** `H.eq : Holder Int, Holder Int -> Bool`; `type W a = W (H.Holder a)`; `mk : a -> W
  a`; unannotated `same l r = l == r`; `same (mk "a") (mk "a")`.
- **Observed** TYPE MISMATCH "`mk` needs the 1st argument to be: `Int`" — `mk` takes any type.
  The direct `mk "a" == mk "a"` is NOT EQUATABLE naming the pinned payload.
- **Expected** the pin is the refusal: NOT EQUATABLE at the use of `same`, "`W` has `==` only as
  `W Int`", as the direct comparison says.
- **Fixture** `check/bad/DerivedPinnedThroughHelper/`, red `why=code`.
- **Slice** the final review's fixes.
- **Status** fixed (2026-09-29), `checker-v2.md` §11.2 and §15.3 *amended 2026-09-29*: a use's own
  wanted whose pinned argument is still a flex waits on its queue's `deferred` list for the
  frame's next boundary (`Instances.deferPinned`, `Solve.at_boundary`), locally and through a
  published row (`publishedMethodTypes`); there the pin holds, is refused as the direct
  comparison's is, or decides a still-open argument before generalisation. Both uses now say
  NOT EQUATABLE, "`W` has `==` only as `W Int`", at the use. No other golden changed. Promoted:
  `tests/corpus/check/bad/DerivedPinnedThroughHelper/`; new
  `…/DerivedPinnedThroughHelperImported/` (the published row's path, red before the fix with the
  same TYPE MISMATCH, and `same (M.mk 1) (M.mk 2)`, whose literals the pin decides, checks).

### CK-208 — A refused dot-call `.eq` names `==`, which the program never wrote

- **Severity** diagnostic-quality (low). **Area** the NOT EQUATABLE texts
  (`DispatchTexts.notEquatable`), which name the operator whatever the use was. **Class** K13.
  **Sources** the final review of the checker (2026-09-29); D15 made a dot-call derive.
- **Program** `type F = F (Int -> Int)`; `(F f).eq (F f)`; `(\y -> y + 1).eq (\y -> y)`; `h x =
  x.eq x` and `h (F f)`.
- **Observed** "I cannot compare these values with `==`" at each.
- **Expected** each names the dot-call it refuses, `.eq`.
- **Fixture** `check/bad/DotCallEqRefusal.beni`, red `why=message`.
- **Slice** the final review's fixes.
- **Status** fixed (2026-09-29), `checker-v2.md` §15.3 *amended 2026-09-29*: `not_equatable`'s
  texts (`DispatchTexts.notEquatable`, and `Messages.pinnedDerived` and
  `Messages.requirementFailed`, which share its first line) take whether the refused wanted is a
  dot-call (`Evidence.Kind.dot_call`, which a promoted requirement keeps at its uses) and name
  `.eq` for one: "I cannot compare these values with `.eq`", "That type does not support `.eq`".
  No other golden changed. Promoted: `tests/corpus/check/bad/DotCallEqRefusal.beni`.

### CK-209 — An unreadable `_manifest.txt` is reported as one beni did not write

- **Severity** diagnostic-quality (low). **Area** `OutputRecord.read`, which answers
  `unrecognised` for any read error but a missing file. **Class** K14. **Sources** the final
  review of the checker (2026-09-29).
- **Program** `build --out=out` with `out/_manifest.txt` at mode 000.
- **Observed** UNKNOWN FILE IN THE OUTPUT DIRECTORY: "This file does not begin with
  `beni-manifest 1` …" — which nobody could tell, the file being unreadable.
- **Expected** the read failure, as for any file beni cannot read: "beni: cannot read
  'out/_manifest.txt': AccessDenied", exit 2, nothing written.
- **Fixture** `scenario/CK-209` (`test-pending`), red `exit=1 codes=unknown_output_record×1`.
- **Slice** the final review's fixes.
- **Status** fixed (2026-09-29): `OutputRecord.read` answers `unreadable` with the error for a
  record that exists and cannot be read, and the build reports it as `beni: cannot read
  'out/_manifest.txt': AccessDenied`, exit 2, before anything is written
  (`Emit.Error.OutputRecordUnreadable`). A file that reads and is not the record is still UNKNOWN
  FILE IN THE OUTPUT DIRECTORY. Promoted into `build_test.zig` ("an unreadable _manifest.txt
  refuses the build as a read failure and nothing is written").

*CK-210 to CK-214 were added on 2026-09-29 from the last review of the checker, each written
with a red fixture on `8f78224` before its fix.*

### CK-210 — A schema endpoint that meets itself shows its expansion

- **Severity** diagnostic-quality (a display regression: D16's "the same name with the same
  arguments keeps it" broken for one kind of alias). **Area** `Unify.throughAlias`:
  `Types.Entry.injective` is never settled for a schema endpoint (`Injective.settle` reads plain
  aliases only), so two uses of one endpoint took the non-injective row and both expanded.
  **Class** K12. **Sources** the last review of the checker (2026-09-29).
- **Program** `schema A = x : Int`; `la : List A.Type`; `two c = if c then la else la`; the same
  over `Maybe A.Type`; a recursive pair `h`/`k` that both return `la`.
- **Observed** `dump --stage=types` and the interface print `two : Bool -> List { x : Int }`,
  `Maybe { x : Int }`, and `List { x : Int }` for `h` and `k`.
- **Expected** `List A.Type`, `Maybe A.Type`: one name met twice with the same arguments agrees.
- **Fixture** `check/good/SchemaEndpointMeetsItself.beni`, red `exit=0 iface-differs`.
- **Slice** the last review's fixes.
- **Status** fixed (2026-09-29), `checker-v2.md` §7.1 and §21.1's D16 *amended 2026-09-29*: two
  uses of one name keep it when their arguments unify (an injective alias) or are already the
  same types for good — the same classes or copies with the same heads and no flex below
  (`Unify.sameArguments`, at most 64 pairs). A zero-argument alias, an endpoint included, always
  agrees; the general rule also keeps `Tagged String` met twice for a non-injective `Tagged`,
  which printed `List Int`. No corpus message changed. Promoted:
  `tests/corpus/check/good/SchemaEndpointMeetsItself.beni`, with `Tagged` added (twice the same
  arguments, and two different).

### CK-211 — A safety build re-walks a proved receiver's whole graph per wanted

- **Severity** performance (safety builds only: the tests' beni). **Area** `Resolve.step`'s check
  of an acyclicity proof: an untrusting occurs walk to 64 levels per wanted, with no budget, so it
  covered the whole graph reachable from each receiver. **Class** K11. **Sources** the last review
  of the checker (2026-09-29); CK-203's Status named the symptom.
- **Program** `type alias A0 a b = ( a, b )`, `type alias A{i} a b = ( A{i-1} a b, A{i-1} (List
  a) b, A{i-1} a (List b) )`, `type Box = Box (A{N} Int Int)`.
- **Observed** N = 60: ReleaseFast 0.38 s, ReleaseSafe 14.3 s. N = 26: 9.3 billion instructions
  on the ReleaseSafe beni, twice the test budget.
- **Expected** the safety check within the store-wide budget every other proof check has, so a
  safety build costs a constant factor over ReleaseFast.
- **Fixture** `scenario/CK-211` (`test-pending`, N = 26), red `over-budget`.
- **Slice** the last review's fixes.
- **Status** fixed (2026-09-29), `checker-v2.md` §8.2 *amended 2026-09-29*: `Resolve.step`
  checks a proved receiver with `Walk.assertProved`, the check every walk that stops at a proof
  makes, under its one budget per store; the untrusting occurs walk and `Occurs.trusts` are
  deleted. N = 60: 4.8 s ReleaseSafe (14.3 s before); the rest is the self-hosted backend's code
  and the other safety checks, linear in the graph. Promoted into `abuse_test.zig` ("a wide alias
  DAG checks on a safety build without re-walking its graph per comparison"), resized to N = 24:
  6.5 billion instructions before the fix, 2.3 billion after, against a budget of 4.3.

### CK-212 — A symbolic link in `--out` is written through

- **Severity** latent (a write outside `--out`). **Area** `OutputRecord.read` answers a dangling
  `_manifest.txt` link as no record, and `OutputRecord.write` and `Emit.writeOutputs` follow any
  link they meet. **Class** K14. **Sources** the last review of the checker (2026-09-29).
- **Program** `build --out=out` with `out/_manifest.txt` a link to `../elsewhere/manifest`, which
  does not exist; or `out/_main.mjs` a link to a file anywhere.
- **Observed** exit 0; the record is written at `elsewhere/manifest`, or the entry file over the
  link's target.
- **Expected** beni creates no link, so one in `--out` is somebody else's: the build is refused,
  naming the link, before anything is written.
- **Fixture** `scenario/CK-212` (`test-pending`), red `exit=0 codes=none`.
- **Slice** the last review's fixes.
- **Status** fixed (2026-09-29), `backend.md` §2 *amended 2026-09-29*: before anything is
  written, `Emit.refuseLinks` examines every path the build writes — the record, then each
  output — under `--out` component by component without following links
  (`OutputRecord.firstLink`), and refuses the first link on each with `unknown_output_record`,
  naming it (and, for a directory, the file it would write inside); `--out` itself may be a
  link. Promoted into `build_test.zig` ("a _manifest.txt that is a symbolic link refuses the
  build …", and "an output directory that is a symbolic link …" for `out/_platform`), both red on
  the base.

### CK-213 — A record that cannot be written is reported by the directory's name

- **Severity** diagnostic-quality (low). **Area** `Emit.writeRecord` names `--out` for every
  failure of `OutputRecord.write`, which also writes the file. **Class** K14. **Sources** the last
  review of the checker (2026-09-29).
- **Program** `build --out=out` with `out` at mode 555.
- **Observed** `beni: cannot write 'out': AccessDenied` (with `--out=o1` and a link into a missing
  directory, `'o1'`).
- **Expected** `beni: cannot write 'out/_manifest.txt': AccessDenied`: the file that failed, as
  for every other output.
- **Fixture** `scenario/CK-213` (`test-pending`), red `exit=2 codes=unparsed`.
- **Slice** the last review's fixes.
- **Status** fixed (2026-09-29): `Emit.writeRecord` creates `--out` itself and names it only for
  that failure; `OutputRecord.write` writes the file it is given, whose path a failure names.
  Promoted into `build_test.zig` ("a _manifest.txt that cannot be written is reported by its own
  path").

### CK-214 — A refused `where` requirement or `Basics.eq` call names `==`

- **Severity** diagnostic-quality (low). **Area** the NOT EQUATABLE texts, which name `.eq` for a
  dot-call and `==` for everything else. **Class** K13. **Sources** the last review of the checker
  (2026-09-29); CK-208 fixed the dot-call.
- **Program** `type F = F (Int -> Int)`; `h : a -> Bool where a.eq : a, a -> Bool` and `h (F f)`;
  `Basics.eq (F f) (F f)`; `Basics.neq (F f) (F f)`.
- **Observed** "I cannot compare these values with `==`" at each.
- **Expected** the requirement (`.eq`, and the function that requires it) or the function called
  (`Basics.eq`, `Basics.neq`). A body that uses both `x.eq x` and `x == x` promotes the first in
  source order, and its uses name that one.
- **Fixture** `check/bad/EqRefusalNamesTheUse.beni`, red `exit=1 codes=not_equatable×5
  why=message`.
- **Slice** the last review's fixes.
- **Status** fixed (2026-09-29), `checker-v2.md` §15.3 *amended again 2026-09-29*: the texts take
  what the use was written as (`DispatchTexts.EqUse`) instead of a dot-call flag, and name it
  (`eqName`, `eqRequirer`): a method call by its spelling, a `where` requirement "`.eq`, which
  `h` requires", the marker by the `Basics.eq`/`Basics.neq` call its question records
  (`Obligations.Row.call`, set by `Unify.unifyArgument`), or `Basics.eq` "which `same2` requires"
  at a call of a function that inherited the marker. Fourteen goldens moved, each from `==` to
  `Basics.eq` (or the requirement). Writing the fixture found the same fault in `type_mismatch`:
  `Basics.eq 1 "a"` said "the 2nd argument to (==)"; `Reporter.operatorCallee` no longer maps the
  six comparisons, which lower to method calls. Promoted:
  `tests/corpus/check/bad/EqRefusalNamesTheUse.beni`; new `check/bad/BasicsEqCalledByName.beni`,
  red on the base.

*CK-215 to CK-220 were added on 2026-09-29 from the review of markup's type-checking, each
written with a red fixture on `fc4b31e` before its fix.*

### CK-215 — A markup obligation deferred past a `let` meets a generalised variable (unsound)

- **Severity** unsound-runtime. **Area** the `handler`, `renderable` and `row` obligations
  (`checker-v2.md` §25.4): their only owner-ranked slot was the owner itself, so the root's
  message variable, an event's payload and a row's item were free to be generalised by a `let`
  whose markup raised the obligation on an enclosing parameter. **Class** K2. **Sources** the
  review of markup's type-checking (2026-09-29).
- **Program** `input g = let v = <input onInput={g} /> in ( v, g "x" )`, used as
  `case input Oops of ( v, _ ) -> v` in a `view : Html Msg` with `Oops : String -> Other`.
- **Observed** checks: `input : (String -> a) -> ( Html b, a )`, so `Html Other` is accepted as
  `Html Msg`. With `z = g "x"` as a later `let` binding, `input : (String -> a) -> ( Html b, c )`,
  and `case input (\s -> s) of ( _, k ) -> k + 1` checks with `k` a `String`. The same for a
  hole (`{h}`, `h` fixed later) and a `For` row function. Writing `z` before `v` was correct.
- **Expected** `input : (String -> a) -> ( Html a, a )`: the obligation holds what its decision
  will unify at its owner's rank, as a `tuple_index` holds its result and a `?` its subject, so
  the `let` does not generalise it; the view is a `type_mismatch`.
- **Fixture** `check/bad/markup/LetMarkupObligationHeld.beni`, red `exit=0 codes=none`;
  `check/good/markup/LetMarkupObligationLater.beni`, red `exit=0 iface-differs`.
- **Slice** the fixes to markup's type-checking.
- **Status** fixed (2026-09-29), `checker-v2.md` §4.5's table and §25.4 *amended 2026-09-29*:
  `renderable`'s message variable, `handler`'s payload and message variable, and `row`'s item
  and message variable are the rows' dependants, lowered to the owner's rank at attachment and
  on every drop of it, so a `let` that does not own the row cannot generalise them. Promoted:
  both fixtures into `tests/corpus/`; `ordering_test.zig` "a let's markup and the call that
  decides its handler infer one type in either binding order", red on the base.

### CK-216 — `markup_type_in_foreign` misses a markup type in a record or custom type

- **Severity** latent (a `foreign` that reads one lowering's markup accepted in a platform that
  names none). **Area** `Vocab.mentionsType`, which walked applications, tuples and functions
  only, and answered "no markup" when it had visited 4 096 positions. **Class** K5. **Sources**
  the review of markup's type-checking (2026-09-29).
- **Program** a platform layered on `node` declaring `pub foreign f : { h : Html () } -> String`,
  `Rec -> String` with `type alias Rec = { h : Html () }`, `Wrap -> String` with
  `type Wrap = W (Html ())`, or `( Html (), W13 ) -> String` with `W13` an alias whose expansion
  is 2¹⁴ positions.
- **Observed** the build succeeds.
- **Expected** `markup_type_in_foreign` at each: §25.2 asks whether the declared type mentions
  the markup type after aliases, which a record field and a constructor's payload do, and a
  search that cannot finish must not answer no.
- **Fixture** `build/bad/MarkupTypeInForeignNested/`, red `BuildDidNotFail`.
- **Slice** the fixes to markup's type-checking.
- **Status** open.

### CK-217 — A component's markup children are typed at the enclosing root's messages

- **Severity** valid-program-rejected. **Area** `constrain/Markup.zig`'s component, which
  walked children written as markup as nodes of the enclosing root, sharing its message
  variable. **Class** K15. **Sources** the review of markup's type-checking (2026-09-29).
- **Program** `Wrap.view : { children : Html Inner } -> Html Outer`, and in a view of `Html
  Outer`, `<Wrap><button onClick={Clicked}>x</button></Wrap>` with `Clicked : Inner`.
- **Observed** two `type_mismatch`es, while `Wrap.view { children = <button …>x</button> }`
  checks.
- **Expected** checks: `language.md` §11.13 makes the two forms one program, so the children
  are a markup value of their own, typed at the `children` prop's message type.
- **Fixture** `check/good/markup/ComponentChildrenOwnMessages/`, red `exit=1
  codes=type_mismatch×2`.
- **Slice** the fixes to markup's type-checking.
- **Status** open.

### CK-218 — Children that do not fit the `children` prop are said to send other messages

- **Severity** diagnostic-quality. **Area** the category the component's children met their
  prop under, `markup_child`, whose text is about a hole's messages. **Class** K13. **Sources**
  the review of markup's type-checking (2026-09-29).
- **Program** `Label.view : { children : String } -> Html msg`, used as
  `<Label><b>x</b></Label>`.
- **Observed** "This markup does not produce the same messages as the markup around it".
- **Expected** a message naming the `children` prop and its type.
- **Fixture** `check/bad/markup/ComponentChildrenNotMarkup/`, red `exit=1
  codes=type_mismatch×1 why=message`.
- **Slice** the fixes to markup's type-checking.
- **Status** open.

### CK-219 — Markup nested past the checker's depth is worded as a type, and cascades

- **Severity** diagnostic-quality. **Area** the generator's depth guard: its note printed the
  written-type text, and the expression it gave up on was left an unconstrained variable, which
  a hole's `renderable` then reported as unknown. **Class** K13. **Sources** the review of
  markup's type-checking (2026-09-29).
- **Program** 1 400 nested `<div>{…}</div>`, which the parser accepts.
- **Observed** `nesting_too_deep` saying "This type is nested more than 512 levels deep … Give
  the inner part a `type alias`", and `child_not_renderable` "I cannot tell what type this
  hole's value has".
- **Expected** one `nesting_too_deep` worded for markup; the unread part is poisoned, so nothing
  cascades from it.
- **Fixture** `check/bad/markup/MarkupTooDeepToCheck.beni`, red `exit=1
  codes=child_not_renderable×1,nesting_too_deep×1 why=code`.
- **Slice** the fixes to markup's type-checking.
- **Status** open.

### CK-220 — `unkeyed_for` suggests `keyed={.id}` for items that have no `id`

- **Severity** diagnostic-quality. **Area** `MarkupTexts.unkeyedFor`'s hint, which was one
  sentence for every item type. **Class** K13. **Sources** the review of markup's type-checking
  (2026-09-29).
- **Program** a `For` over `List (List Int)`, or over records with no `id` field, with no
  `keyed`.
- **Observed** "Hint: key the rows, `keyed={.id}`, …" for both.
- **Expected** a field the record has, `id` when it has one; for an item that is not a record,
  a key function.
- **Fixture** `check/good/markup/UnkeyedForHint.beni`, red `GoldenMismatch`.
- **Slice** the fixes to markup's type-checking.
- **Status** open.

## Summary table

*Slice splits of 2026-09-24 (review round 3).* R2 became R2a/R2b, R4 became R4a/R4b, R6 became
R6a/R6b, and R8 became R8a/R8b. The slice named in each entry below is the unsplit one.
`checker-rewrite.md` §4 is the authoritative CK → slice index.

| ID | Severity | Class | Fixture (under `tests/pending/`) | Slice |
|---|---|---|---|---|
| CK-01 | unsound-runtime | K1 | `check/bad/LetAnnotationRigidEscape.beni`, `…RowEscape.beni` | R4 |
| CK-02 | unsound-runtime | K2 | `check/bad/OuterReceiverConstraintLevels.beni` | R6a (claimed) |
| CK-03 | compiler-crash-or-hang | K3 | `check/bad/CyclicReceiverResolution.beni` + `scenario/CK-03` | R6a (claimed; v2 timing twin in `perf_test.zig`) |
| CK-04 | unsound-runtime | K3 | `check/bad/InfiniteTypeAtBinder.beni` | R4 |
| CK-05 | valid-program-rejected | K2 | `run/ObligationEscapesInnerLet.beni` | R5 (claimed) |
| CK-06 | valid-program-rejected (D2) | K2 | `run/TryDefersShape.beni` | R5 (claimed) |
| CK-07 | nondeterminism | K12 | `check/bad/FieldErrorTextOrder.beni` (single file, R0) | R4 |
| CK-08 | valid-program-rejected | K3 | `run/ClosedRecordAfterFieldAccess.beni` | R6b (claimed) |
| CK-09 | unsound-runtime | K8 | `check/bad/MutualGroupLocals.beni`, `check/good/MutualGroupLocalTypes.beni`, `check/good/MutualGroupFiveMembers.beni` | R4b, R5, R6a (claimed) |
| CK-10 | latent | K3 | — (structural) | R4 (closed with v1; v2 checked by R15-fix-J) |
| CK-11 | unsound-runtime | K9 | `check/bad/WarningKeepsExhaustiveness.beni` | R1, R4 |
| CK-12 | latent | K9 | — (unit test) | R1 |
| CK-13 | unsound-runtime (no runtime path yet) | K9 | `check/bad/SchemaMemberTooDeep/` | R4 |
| CK-14 | latent | K9 | — (structural) | R4 (closed by R15-fix-J with CK-146, CK-151) |
| CK-15 | latent | K9 | — (structural) | R4, R9 |
| CK-16 | unsound-runtime | K5 | `check/bad/BasicsEqThroughStructure.beni` | R5 (claimed) |
| CK-17 | unsound-runtime | K5 | `check/bad/WideRecordEqFunction.beni` | R1, R5 |
| CK-18 | latent | K2 | — (deleted) | R5 (structural, v2) |
| CK-19 | unsound-runtime | K7 | `run/EquatableMarkerIsNotEq.beni` | R1, R8 |
| CK-20 | unsound-runtime | K5 | `check/bad/RigidInsideDerivedShape.beni` | R2, R6a (claimed) |
| CK-21 | unsound-runtime | K5 | `check/bad/WhereClauseNumberReceiver.beni` | R6a (claimed; `NumberBridgeRigidLyingWhere.beni` the rigid half) |
| CK-22 | unsound-runtime (D1) | K7 | `check/bad/PrivateEqOutsideModule/`, `…/PrivateEqThroughThirdModule/`, `…Shapes/`; guard `tests/corpus/run/PrivateEqInsideModule/` | R8b (claimed; cross-module half by R8a) |
| CK-23 | valid-program-rejected (D4) | K7 | `run/PhantomParameterEq.beni` | R8a (claimed; + `run/DerivedContextAcrossModules/`) |
| CK-24 | unsound-runtime (no runtime path yet) | K7 | `check/bad/SchemaWrapperExclusion.beni`, `…ThroughOwnType.beni`, `check/bad/SchemaEndpointInFlight.beni` | R8b (claimed; first half early by R8a) |
| CK-25 | valid-program-rejected (D4) | K4 | `run/GenericDerivationNestedRequirement/` | R8a (claimed) |
| CK-26 | latent | K7 | — (structural) | R8a (closed, structural) |
| CK-27 | unsound-runtime | K4 | `run/CustomEqHeadMatching/` | R6b (claimed) |
| CK-28 | valid-program-rejected | K4 | `run/CustomEqTupleHead/` | R6b (claimed) |
| CK-29 | compiler-crash-or-hang | K2 | `run/LetHelperJoinedMethod.beni` | R6b (claimed) |
| CK-30 | compiler-crash-or-hang | K4 | `run/RecursionWithComparison.beni`, `run/DeadMiscount.beni` | R7 (fixtures claimed by R6b) |
| CK-31 | compiler-crash-or-hang (latent) | K4 | `run/MutualGroupEvidenceOrder.beni` | R7 (fixture claimed by R6b) |
| CK-32 | compiler-crash-or-hang | K4 | `run/OperatorSectionApplied.beni` | R6b (claimed) |
| CK-33 | unsound-runtime | K4 | promoted: `run/ConstrainedFunctionConstant/` | R2b (fixed) |
| CK-34 | unsound-runtime | K4 | promoted: `check/bad/EvidenceConstantCycle.beni` | R2b (fixed) |
| CK-35 | latent | K4 | — (structural) | R6 (closed: no speculation, journal deleted by R15-fix-J) |
| CK-36 | valid-program-rejected (D3) | K6 | `run/OwnMethodBeforeDefinition/` | R7 |
| CK-37 | latent | K3 | guards `tests/corpus/check/bad/CyclicReceiverReportedOnce.beni`, `…/RejectedReceiverDoesNotSilence.beni` | R6, R14 |
| CK-38 | valid-program-rejected | K10 | promoted: `check/good/WideTypeArity/`; new `run/WideTypeArityEq/` | R3 (fixed) |
| CK-39 | valid-program-rejected | K10 | promoted: `run/RecordAliasConstructorImported/` | R3 (fixed) |
| CK-40 | performance | K11 | `scenario/CK-40` (400 schemas) | R8a (v2: `perf_test.zig` "CK-40", `test-perf`) |
| CK-41 | performance | K11 | promoted: `perf_test.zig` "CK-41: …" (`test-perf`) | R3 (fixed) |
| CK-42 | performance (reproduced in R0) | K11 | `scenario/CK-42` (extra cost of own `==` over `x == x`; v1 × 4 000, v2 × 16 000 best of 7 since R8c) | R6a (v2 timing twin in `perf_test.zig`) |
| CK-43 | unsound-runtime | K14 | `run/RecordAliasConstructor.beni` | R1 |
| CK-44 | diagnostic-quality | K14 | `check/bad/DuplicateRecordTypeField.beni` | R1 |
| CK-45 | diagnostic-quality | K14 | `parse/bad/FloatPattern.beni` | R1 |
| CK-46 | diagnostic-quality | K14 | `check/bad/LetCycleThroughFunction.beni` | R1 |
| CK-47 | diagnostic-quality | K14 | `parse/bad/ExposingConstructorsElmStyle.beni` | R1 |
| CK-48 | diagnostic-quality | K13 | `check/bad/MissingWhereAtUse.beni` | R6a (claimed) |
| CK-49 | diagnostic-quality | K13 | `check/bad/ListElementFromContext.beni` | R13 |
| CK-50 | diagnostic-quality | K13 | `check/bad/NoArithmeticHintWithoutArithmetic.beni` | R13 |
| CK-51 | diagnostic-quality | K13 | `check/bad/TryShapeNamesTheMismatch.beni` | R5 (claimed) |
| CK-52 | diagnostic-quality | K13 | `check/bad/MethodSignatureNoClash.beni` | R13 |
| CK-53 | diagnostic-quality | K13 | `check/bad/MissingWhereInLetAnnotation.beni` | R13 |
| CK-54 | diagnostic-quality | K13 | `check/bad/OpenRecordEquality.beni` | R13 |
| CK-55 | diagnostic-quality | K13 | `check/bad/WhereClauseMismatchNamesClause.beni` | R6, R13 |
| CK-56 | diagnostic-quality | K13 | `check/bad/CurriedAnnotation.beni`, `…/SubjectFirstSwap.beni` | R13 |
| CK-57 | diagnostic-quality | K13 | `check/bad/InfiniteTypeShowsStructure.beni` | R4 |
| CK-58 | diagnostic-quality | K13 | `check/bad/CapNamesReceivers.beni` | R13 |
| CK-59 | diagnostic-quality | K13 | `check/bad/MissingFieldShowsLiteralTypes/` | R5, R13 |
| CK-60 | diagnostic-quality (confirmed in R0) | K13 | `check/bad/MissingPatternConsRendering.beni` | R13 |
| CK-61 | latent (doc) | K15 | — | R2 |
| CK-62 | valid-program-rejected | K2 | `run/TryDecidedByLaterFacts.beni` (R6a), `run/TryEscapesToLaterFact.beni`, `run/TryEscapeLowersOnlyItsOwn.beni` | R5 (claimed), R6a → R6b (claimed) |
| CK-63 | valid-program-rejected | K6 | `run/OwnMethodDemandedEarly.beni` | R7 |
| CK-64 | valid-program-rejected | K6 | `run/OwnMethodValuePrefix.beni` | R7 |
| CK-65 | valid-program-rejected | K6 | `run/MutualDispatchMethods.beni` | R7 |
| CK-66 | valid-program-rejected | K4 | `run/GroupVariableOutsideCaller.beni` | R7 (fixture claimed by R6b) |
| CK-67 | valid-program-rejected | K7 | `run/DerivedContextClosedOwnMethod/` | R8a (every order in `scenario/PERM`) |
| CK-68 | diagnostic-quality | K2 | `check/bad/TupleIndexOuterResult.beni` | R5 (claimed) |
| CK-69 | diagnostic-quality | K7 | `check/bad/DerivedContextNeedsAnnotation/` (+ `…KeyFirst/`) | R8a (claimed) |
| CK-70 | diagnostic-quality | K6 | `check/bad/RecursiveDispatchTwoTypes.beni` (+ `…B.beni`) | R7 |
| CK-71 | nondeterminism | K12 | `scenario/CK-71` (100 loaded runs at `--jobs=8`); promoted by R1 into the gates | R1 |
| CK-72 | compiler-crash-or-hang | K4 | `check/bad/RecursiveGroupReceiverNeedsAnnotation.beni` (+ twin) | R7 |
| CK-73 | valid-program-rejected | K6 | `run/ScrutineeMethodLater.beni`, `check/good/ScrutineeMethodMergeVariant/`, `check/bad/ScrutineeMethodMergeD14/` | R7 |
| CK-74 | diagnostic-quality | K7 | `check/bad/DerivedContextReentrant/` (+ twin) | R8a (claimed) |
| CK-75 | performance | K11 | `scenario/CK-75` (5 000 declarations, no dispatch) | R8a (v2: `perf_test.zig` "CK-75"; residue CK-107) |
| CK-76 | compiler-crash-or-hang | K4 | `check/bad/RecursiveGroupEvidenceReceiver/`, `check/bad/RecursiveGroupSubWanted/` | R7 |
| CK-77 | diagnostic-quality | K7 | `check/bad/DerivedContextMergesAsker/` | R8a (claimed) |
| CK-78 | decision (supported) | K14 | guard `tests/corpus/run/RecordAliasConstructorPattern.beni` | R1 |
| CK-79 | valid-program-rejected | K10 | — (`abuse_test.zig` pins the 4 096 cap) | R8a (v2: `scenario/CK-79`, claimed) |
| CK-80 | performance | K11 | `scenario/CK-80` (`( x, [ x ] )` n deep, n = 9 vs 18) | R6a (v2 timing twin in `perf_test.zig`); the `build` half R6b (`perf_test.zig` "CK-80 build") |
| CK-81 | compiler-crash-or-hang | K11 | promoted: `abuse_test.zig` (two scenarios) | R2a (fixed) |
| CK-82 | compiler-crash-or-hang | K10 | `scenario/CK-82` | R8a (claimed) |
| CK-83 | unsound-runtime | K14 | promoted: `abuse_wide_test.zig` "CK-83: …" | R2c (fixed) |
| CK-84 | unsound-runtime | K4 | promoted: `run/ConstrainedAliasFunctionImported/` | R2b (fixed) |
| CK-85 | performance (latent) | K4 | guard `tests/corpus/run/EvidenceFunctionBodyPerCall.beni` | R8a (fixed, both checkers) |
| CK-86 | diagnostic-quality | K14 | `check/bad/ExposingSameNameConstructor/` | R13 |
| CK-87 | valid-program-rejected | K14 | `run/DerivedEqDeepRecord.beni` | R8a (fixed, promoted to `tests/corpus/run/`) |
| CK-88 | performance | K14 | `perf_test.zig` (`test-perf`, CK-88), `abuse_wide_test.zig` (CK-88) | R12 (fixed) |
| CK-89 | latent | K10 | — (v1 is right; the guard program is in the entry) | R8a (§14.2 amended; guard `run/HiddenTypeDerivedRow/`) |
| CK-90 | unsound-runtime | K8 | `check/bad/LetFunctionUsesLaterPattern.beni` | R4b (claimed) |
| CK-91 | unsound-runtime | K3 | `check/bad/LetOfManyBindings.beni` | R4b (claimed) |
| CK-92 | compiler-crash-or-hang (output blow-up) | K13 | `blackbox_test.zig` "CK-92: …" (in the gates) | R4b (fixed) |
| CK-93 | performance | K11 | `test-perf` "CK-93" (v2, `check` event) | R8c (fixed) |
| CK-94 | diagnostic-quality | K13 | `check/good/NumberVariableNamedByKind.beni`, `check/bad/NumberVariableNamedByKind.beni` | R13 (fixed) |
| CK-95 | performance | K14 | `perf_test.zig` (`test-perf`, CK-95) | R12 (fixed, with CK-127) |
| CK-96 | performance | K11 | promoted: `perf_test.zig` "CK-96" (`test-perf`) | R5 (fixed) |
| CK-97 | performance | K11 | promoted: `perf_test.zig` "CK-97" (`test-perf`) | R5 (fixed) |
| CK-98 | performance | K11 | promoted: `perf_test.zig` "CK-98" (`test-perf`) | R5 (fixed) |
| CK-99 | valid-program-rejected | K2 | guard `tests/corpus/run/TryTargetKeepsItsSuccessType.beni` | R5 (fixed) |
| CK-100 | unsound-runtime | K2 | `check/bad/MethodResultTooGeneral.beni`, `check/good/EagerDrainInnerLet.beni` | R6a (claimed) |
| CK-101 | compiler-crash-or-hang | K3 | `check/bad/DerivabilityAlternatingCycle` + `perf_test.zig` "CK-101" (v2) | R6a (claimed) |
| CK-102 | unsound-runtime | K2 | `check/bad/DerivedPositionMethodMismatch.beni` (v2) | R6b (fixed) |
| CK-103 | latent | K4 | `run/UndeterminedCompareSlot/` | R6b (claimed) |
| CK-104 | unsound-runtime | K14 | `run/DerivedRowBodyEmissionOrder/`, `run/DerivedContextClosedOwnMethodPermuted/` | R6b (fixed) |
| CK-105 | valid-program-rejected (order-dependent) | K6 | `run/FieldCallThroughMember.beni` and five more | R7 (claimed) |
| CK-106 | compiler-crash-or-hang | K4 | `check/bad/NumberReceiverMethodInGroup.beni`, `…Dispatch.beni` | R7 (claimed) |
| CK-107 | performance | K11 | `perf_test.zig` (`test-perf`, CK-107) | R10 (fixed; found by R8a) |
| CK-108 | unsound-runtime | K7 | promoted: `check/bad/DerivedContextEquatableFlag*` (v1's text) + `blackbox_test.zig` "CK-108: …" (v2) | R8a (fixed; found by its review) |
| CK-109 | compiler-crash-or-hang | K10 | promoted: `abuse_wide_test.zig` "CK-109: …" (v2); `scenario/CK-82` at 65 537 | R8a (fixed; found by its review) |
| CK-110 | latent | K10 | promoted: `blackbox_test.zig` "a private type reached only through a pub alias body …" | R8a (fixed; found by its review) |
| CK-111 | performance | K11 | `test-perf` "CK-111" (v2) | R8c (fixed; found by R8a's review) |
| CK-112 | performance | K11 | `test-perf` "CK-112" (v2; shared code) | R8c (fixed; found by R8a) |
| CK-113 | performance (latent) | K4 | — | unassigned — perf slice proposed (found by R8a's review) |
| CK-114 | valid-program-rejected | K10 | `abuse_test.zig` "a record literal nested to the parser's limit …" | R8c (fixed; found by R8a's review) |
| CK-115 | diagnostic-quality | K13 | `check/bad/CallArgMismatchNoUnknownMethod.beni` (a guard) | R13 (not reproduced; found by R8a's review) |
| CK-116 | diagnostic-quality | K7 | `check/bad/RequirementFailedInsideEq/` | R13 (fixed; found by R8a's review) |
| CK-117 | latent | K7 | `run/DerivedContextPassMergesDown` (and the Debug frame assert) | R8b (claimed; found by R8a's review round) |
| CK-118 | valid-program-rejected | K7 | `check/good/SchemaRecordViaWrapped.beni`, `…/SchemaViaMutualOwnType.beni` | R8b (claimed; found by R8b) |
| CK-119 | performance | K3 | `test-perf` "CK-119"; `tests/corpus/check/good/SchemaViaRing.beni` | R8b (found and fixed by its review round) |
| CK-120 | unsound-runtime (no runtime path yet) | K7 | `check/bad/EquatableMarkerThroughWrappedEndpoint/`, `…Local.beni` | R8b (claimed; found by its review round) |
| CK-121 | compiler-crash-or-hang | K9 | `tests/corpus/check/bad/WhereAnnotationAfterDefinition.beni`, `…Repeated.beni` | R8b (fixed; found by its review round) |
| CK-122 | compiler-crash-or-hang | K7 | `check/good/SchemaEndpointAlias.beni`, `…AcrossModules/`, `check/bad/SchemaEndpointAliasKeepsItsType.beni` | R8c (fixed, its own commit) |
| CK-123 | unsound-runtime (no runtime path yet) | K1 | — | schema S3/S4 owner |
| CK-124 | performance | K14 | — | unassigned (frontend) |
| CK-125 | valid-program-rejected | K12 | `test-perf` "CK-125" | R8b (found and fixed by its round-2 review) |
| CK-126 | unsound-runtime (no runtime path yet) | K7 | promoted: `check/bad/PrivateRecordSchemaAliasAcrossModules/`; `digest_test.zig` "row 13 for a schema" | R15-fix-D (fixed; found by R8c) |
| CK-127 | performance | K14 | CK-95's | R12 (fixed as CK-95's duplicate; found by R8c) |
| CK-128 | unsound-runtime (a runtime exception on deep data) | K14 | `tests/corpus/run/DerivedDeep*`, `abuse_test.zig` (CK-128) | R8d (fixed; owner 2026-09-26; found by R8c) |
| CK-129 | diagnostic-quality | K13 | `check/bad/ExposingSameNameConstructor/` (CK-86's) | R13 (fixed as CK-86; found by R8d) |
| CK-130 | valid-program-rejected (v2 only) | K7 | promoted: `run/NeverAndOrderDerived.beni` | R9 (fixed) |
| CK-131 | performance (v2 only) | K11 | `perf_test.zig` (`test-perf`, CK-131) | R9b (fixed; found by R9) |
| CK-132 | nondeterminism (v1 only) | K7 | v2 side: `cutoff_test.zig` "add a private eq" row, `cache_test.zig` schema case | R12 (closed with v1; found by R10) |
| CK-133 | performance (Debug only) | K11 | `abuse_test.zig` CK-128 scenario (timeout under load) | R12 (found and fixed) |
| CK-134 | performance | K11 | — (the bench) | R14b (fixed; found by R12) |
| CK-135 | compiler-crash-or-hang | K3 | `check/good/RequirementBelowDepth512.beni` | R15-fix (found by R15's core and dispatch audits) |
| CK-136 | compiler-crash-or-hang | K11 | promoted: `run/EvidenceDagBuildDepth32.beni`; new `dispatch/SharedEvidenceDag.beni`, `perf_test.zig` "CK-136" (`test-perf`) | R15-fix-B (fixed) |
| CK-137 | unsound-runtime (critical) | K7 | `check/bad/SiblingTypeEqResolution/` | R15-fix |
| CK-138 | unsound-runtime | K14 | promoted: `run/ArrowBodyStartsWithRecord.beni`; new `run/ArrowBodyLeftmostBrace.beni` | R15-fix-B (fixed) |
| CK-139 | compiler-crash-or-hang | K10 | `check/bad/BareParameterisedTypeInConstructor.beni` | R15-fix |
| CK-140 | compiler-crash-or-hang | K3 | `scenario/CK-140` | R15-fix |
| CK-141 | compiler-crash-or-hang | K9 | `check/bad/ImportedErrorValueCompared/` | R15-fix |
| CK-142 | compiler-crash-or-hang | K9 | `check/bad/DerivedRowTemplateTooDeep/` | R15-fix |
| CK-143 | performance | K11 | `perf_test.zig` "CK-143", "CK-143-publish" (`test-perf`) | R15-fix-D (fixed) |
| CK-144 | performance | K11 | promoted: `perf_test.zig` "an alias chain's interface is linear in its length"; new `iface_test.zig` cross-module chain | R15-fix-K (fixed) |
| CK-145 | diagnostic-quality | K12 | promoted: `check/bad/RecordUnifyFieldOrderOtherFile/` | R15-fix-D (fixed) |
| CK-146 | latent | K9 | — (structural); item (3) was CK-201 | R15-fix-J (closed) |
| CK-147 | valid-program-rejected | K9 | promoted: `check/bad/FailedDeclarationPublishedType/` | R15-fix-D (fixed) |
| CK-148 | diagnostic-quality | K14 | promoted: `check/bad/SchemaParseErrorRecovered/` | R15-fix-D (fixed) |
| CK-149 | latent | K2 | — (a safe-build assert every black-box program runs) | R15-fix-J (fixed) |
| CK-150 | latent | K3 | new `check/bad/LetValueConstrainedWideType.beni` | R15-fix-J (fixed) |
| CK-151 | latent | K9 | — (dead code deleted) | R15-fix-J (fixed) |
| CK-152 | latent | K15 | — (dead code deleted) | R15-fix-J (fixed; §7.5 amended) |
| CK-153 | latent | K13 | — (structural; `check/bad/EqRecordFieldFunctionAtComparison` reaches the rule) | R15-fix-J (fixed) |
| CK-154 | diagnostic-quality | K13 | `check/bad/InterpolationAfterRigidEscape.beni` | R15-fix |
| CK-155 | latent | K4 | — (unreachable from source) | R15-fix-J (fixed) |
| CK-156 | latent | K4 | — (a safe-build assert) | R15-fix-J (fixed) |
| CK-157 | latent | K4 | — (a safe-build assert) | R15-fix-J (fixed) |
| CK-158 | latent | K7 | `rules_test.zig` (widened, with a unit test) | R15-fix-J (fixed) |
| CK-159 | valid-program-rejected | K7 | `run/DerivedOverSpecialisedEq/` (expects acceptance; rule 7) | R15-fix (owner's decision first) |
| CK-160 | latent | K5 | — (a safe-build assert; `Walk.zig` unit test) | R15-fix-J (fixed) |
| CK-161 | valid-program-rejected | K7 | `run/DotCallCompareDerivedUnannotated.beni` (expects acceptance; rule 7) | R15-fix-I (fixed under D15, promoted with three new `run/` fixtures and a guard) |
| CK-162 | diagnostic-quality | K13 | `check/bad/NegativeLiteralArgumentHint.beni` | R15-fix |
| CK-163 | latent | K14 | promoted: `build_test.zig` "CK-163" | R15-fix-F (fixed, promoted) |
| CK-164 | performance | K14 | promoted: `perf_test.zig` "CK-164" (`test-perf`) | R15-fix-F (fixed, promoted) |
| CK-165 | performance | K14 | promoted: `perf_test.zig` "CK-165" (`test-perf`) | R15-fix-F (fixed, promoted) |
| CK-166 | diagnostic-quality | K14 | promoted: `abuse_test.zig` "CK-166" | R15-fix-F (fixed, promoted) |
| CK-167 | valid-program-rejected | K11 | promoted: `abuse_test.zig` "CK-167" | R15-fix-F (fixed, promoted) |
| CK-168 | diagnostic-quality | K13 | `check/bad/OwnMethodSignatureReportedOnce.beni` | R15-fix |
| CK-169 | compiler-crash-or-hang | K3 | `check/bad/AliasChainNotEquatable.beni`, `run/AliasChainThroughLet.beni` | R15-fix-C (fixed, promoted) |
| CK-170 | unsound-runtime | K3 | `check/bad/AliasChainKeepsItsType.beni` | R15-fix-C (fixed, promoted) |
| CK-171 | performance | K11 | promoted: `perf_test.zig` "CK-171" (`test-perf`) | R15-fix-C (fixed, promoted) |
| CK-172 | valid-program-rejected | K3 | `run/AliasOfItselfUnifies.beni` | R15-fix-C (fixed, promoted) |
| CK-173 | valid-program-rejected | K5 | `run/RigidMeetsAliasOfItself.beni` | R15-fix-C (fixed, promoted) |
| CK-174 | valid-program-rejected | K5 | `run/NumberUnderAliasCompared.beni` | R15-fix-C (fixed, promoted) |
| CK-175 | valid-program-rejected | K5 | promoted: `run/PhantomAliasUnifiesByExpansion.beni`; new `run/PhantomAliasNested.beni`, `run/PhantomAliasMutualGroup.beni` (PERM) | R15-fix-G (fixed) |
| CK-176 | diagnostic-quality | K13 | promoted: `check/bad/AliasOfVariableKeepsItsName.beni` | R15-fix-G (fixed) |
| CK-177 | diagnostic-quality | K13 | promoted: `check/bad/InfiniteTypeBeforeMismatch.beni` | R15-fix-G (fixed) |
| CK-178 | diagnostic-quality | K9 | promoted: `check/bad/SchemaPayloadArityNoCascade.beni` | R15-fix-G (fixed) |
| CK-179 | nondeterminism | K12 | `scenario/CK-179` | R15-fix-I (fixed under D16, promoted into `ordering_test.zig`) |
| CK-190 | unsound-runtime | K14 | `run/ReleaseAliasChain129.beni`, `…130.beni`, `…1000.beni` | R15-fix-H (fixed, promoted) |
| CK-191 | latent | K14 | promoted: `build_test.zig` "CK-191" (two scenarios) | R15-fix-H (fixed, promoted) |
| CK-192 | latent | K14 | promoted: `build_test.zig` "CK-192" | R15-fix-H (fixed, promoted) |
| CK-193 | unsound-runtime | K14 | `build/bad/ForeignBadShapeWideRecord/` | R15-fix-H (fixed, promoted) |
| CK-194 | compiler-crash-or-hang | K3 | `scenario/CK-194` | R15-fix-I (fixed, promoted into `perf_test.zig`) |
| CK-195 | diagnostic-quality | K13 | `check/bad/OwnMethodSignatureAcrossModules/` | R15-fix-I (fixed, promoted) |
| CK-196 | nondeterminism | K12 | `scenario/CK-196` | R15-fix-I (fixed, promoted into `ordering_test.zig`) |
| CK-197 | diagnostic-quality | K13 | `check/bad/DerivedPinnedRecursive/` | R15-fix-I (fixed, promoted) |
| CK-198 | performance | K11 | `scenario/CK-198` | fixed by resizing to 4 097 fields, into `abuse_wide_test.zig`'s existing test |
| CK-199 | performance | K11 | `scenario/CK-199` | fixed by resizing to a check and two builds, promoted into `cache_test.zig` |
| CK-200 | diagnostic-quality | K14 | promoted: `check/bad/StringLiteralMismatchSpan.beni` | R15-fix-J (fixed, promoted) |
| CK-201 | diagnostic-quality | K9 | `ordering_test.zig` "a derived eq whose pass is refused a nested check …" | R15-fix-J (found and fixed) |
| CK-202 | nondeterminism | K12 | promoted: `check/good/AliasNamesInsideStructures.beni`; `ordering_test.zig` (two tests) | the final review's fixes (fixed) |
| CK-203 | performance | K11 | promoted: `perf_test.zig` "an annotation over an alias DAG whose uses differ …" | the final review's fixes (fixed) |
| CK-204 | diagnostic-quality | K13 | promoted: `check/bad/RecordFieldType.beni`, `check/bad/RecordFieldTypeAcrossModules/` | the final review's fixes (fixed) |
| CK-205 | diagnostic-quality | K13 | promoted: `check/bad/SameNameTypesQualified/` | the final review's fixes (fixed) |
| CK-206 | diagnostic-quality | K14 | promoted: `check/bad/MultilineStringMismatchSpan.beni` | the final review's fixes (fixed) |
| CK-207 | diagnostic-quality | K13 | promoted: `check/bad/DerivedPinnedThroughHelper/`; new `…Imported/` | the final review's fixes (fixed) |
| CK-208 | diagnostic-quality | K13 | promoted: `check/bad/DotCallEqRefusal.beni` | the final review's fixes (fixed) |
| CK-209 | diagnostic-quality | K14 | promoted: `build_test.zig` "an unreadable _manifest.txt refuses the build …" | the final review's fixes (fixed) |
| CK-210 | diagnostic-quality | K12 | promoted: `check/good/SchemaEndpointMeetsItself.beni` | the last review's fixes (fixed) |
| CK-211 | performance | K11 | promoted: `abuse_test.zig` "a wide alias DAG checks on a safety build …" | the last review's fixes (fixed) |
| CK-212 | latent | K14 | promoted: `build_test.zig` (two symbolic-link tests) | the last review's fixes (fixed) |
| CK-213 | diagnostic-quality | K14 | promoted: `build_test.zig` "a _manifest.txt that cannot be written …" | the last review's fixes (fixed) |
| CK-214 | diagnostic-quality | K13 | promoted: `check/bad/EqRefusalNamesTheUse.beni`; new `check/bad/BasicsEqCalledByName.beni` | the last review's fixes (fixed) |
| CK-215 | unsound-runtime | K2 | promoted: `check/bad/markup/LetMarkupObligationHeld.beni`, `check/good/markup/LetMarkupObligationLater.beni`; `ordering_test.zig` | the fixes to markup's type-checking (fixed) |
| CK-216 | latent | K5 | `build/bad/MarkupTypeInForeignNested/` | the fixes to markup's type-checking |
| CK-217 | valid-program-rejected | K15 | `check/good/markup/ComponentChildrenOwnMessages/` | the fixes to markup's type-checking |
| CK-218 | diagnostic-quality | K13 | `check/bad/markup/ComponentChildrenNotMarkup/` | the fixes to markup's type-checking |
| CK-219 | diagnostic-quality | K13 | `check/bad/markup/MarkupTooDeepToCheck.beni` | the fixes to markup's type-checking |
| CK-220 | diagnostic-quality | K13 | `check/good/markup/UnkeyedForHint.beni` | the fixes to markup's type-checking |

Totals:
- 208 entries (CK-215 to CK-220 added 2026-09-29 from the review of markup's type-checking; CK-210 to CK-214 added 2026-09-29 from the last review of the checker; CK-202 to CK-209 added 2026-09-29 from the final review of the checker; CK-201 added 2026-09-28 by R15-fix-J, found closing CK-146; CK-200 added 2026-09-28 from a user's report; CK-194 to CK-197 added 2026-09-28 by R15-fix-I from the manager's residues; CK-190 to CK-193 added 2026-09-28 by R15-fix-H, the first three from the review of R15-fix-F and CK-193 from its own audit, numbered from 190 with 180–189 unused; CK-179 added 2026-09-28 by R15-fix-G; CK-175 to CK-178 added 2026-09-28 by R15-fix-G, from R15-fix-E's review; CK-169 to CK-174 added 2026-09-28 by R15-fix-C, the first three from R15-fix-A's review; CK-135 to CK-168 added 2026-09-27 from R15's four audits; CK-62 to CK-70 and CK-72 to CK-74 added 2026-09-24 from the design reviews; CK-71 by R0; CK-75 by the review of R0; CK-76 and CK-77 from design review round 4; CK-78 to CK-81 by R1 and its review; CK-82 and CK-83 by R2a stage 2; CK-84 by R2b; CK-85 and CK-86 by R2b's review; CK-87 and CK-88 by R2c; CK-89 by R3; CK-90 and CK-91 by R4b; CK-92 to CK-95 by R4b's reviews; CK-96 to CK-99 by R5's reviews, found and fixed in R5; CK-100 by R6a; CK-101 by R6a's review; CK-102 by R6b; CK-103 and CK-104 by R6b's reviews; CK-105 and CK-106 by R7's reviews; CK-107 and CK-112 by R8a; CK-108 to CK-111 and CK-113 to CK-117 by R8a's reviews and its review round, CK-108 to CK-110 found and fixed in R8a; CK-118 by R8b; CK-119 to CK-124 by R8b's review round, CK-119 to CK-121 fixed in it; CK-125 by its round-2 review, fixed; CK-126 to CK-128 by R8c; CK-129 by R8d; CK-130 and CK-131 by R9, CK-130 fixed in it and CK-131 by R9b; CK-132 by R10; CK-133 and CK-134 by R12). Counted from the summary table (R9b; the severities below had drifted by one each for crashes and rejections; R10 added CK-132 to nondeterminism). CK-78 records a decision, not a defect, and is counted under none of the severities below.
- unsound-runtime: 35 (CK-215 from the review of markup's type-checking; CK-190 and CK-193 from R15-fix-H; CK-170 from R15-fix-C; CK-137 and CK-138 from R15; CK-83, CK-84, CK-90, CK-91, CK-100, CK-102, CK-104, CK-108, CK-120, CK-123, CK-126 and CK-128 among them). Five of them (CK-13, CK-24, CK-120, CK-123, CK-126) have no runtime path until schemas emit.
- compiler-crash-or-hang: 23 (CK-194 from R15-fix-I; CK-169 from R15-fix-C; CK-135, CK-136 and CK-139 to CK-142 from R15; CK-92, CK-101, CK-109, CK-121 and CK-122 among them).
- valid-program-rejected: 33 (CK-217 from the review of markup's type-checking; CK-175 from R15-fix-G; CK-172 to CK-174 from R15-fix-C; CK-147, CK-159, CK-161 and CK-167 from R15; CK-87, CK-99, CK-114, CK-118, CK-125 and CK-130 among them).
- nondeterminism: 6 (CK-202 from the final review; CK-196 from R15-fix-I; CK-179 from R15-fix-G; CK-132 among them, v1 only).
- performance: 31 (CK-211 from the last review; CK-203 from the final review; CK-198 and CK-199 from the test budget; CK-171 from R15-fix-C; CK-143, CK-144, CK-164 and CK-165 from R15; CK-85, CK-88, CK-93, CK-95, CK-96 to CK-98, CK-107, CK-111 to CK-113, CK-119, CK-124, CK-127, CK-131, CK-133 and CK-134 among them).
- diagnostic-quality: 52 (CK-218 to CK-220 from the review of markup's type-checking; CK-210, CK-213 and CK-214 from the last review; CK-204 to CK-209 from the final review; CK-201 from R15-fix-J; CK-200 from a user's report; CK-195 and CK-197 from R15-fix-I; CK-176 to CK-178 from R15-fix-G; CK-145, CK-148, CK-154, CK-162, CK-166 and CK-168 from R15; CK-86, CK-94, CK-115, CK-116 and CK-129 among them).
- latent: 29 (CK-216 from the review of markup's type-checking; CK-212 from the last review; CK-191 and CK-192 from R15-fix-H; CK-146, CK-149 to CK-153, CK-155 to CK-158, CK-160 and CK-163 from R15; CK-89, CK-103, CK-110 and CK-117 among them).
- Outside the checker (K14): 30 (CK-212 and CK-213; CK-206 and CK-209; CK-200; CK-190 to CK-193 from R15-fix-H; CK-138, CK-148, CK-163 to CK-166 from R15; CK-78, CK-83, CK-86, CK-87, CK-88, CK-95, CK-104, CK-124, CK-127 and CK-128 among them).
