# Checker findings — the bug catalogue for the rewrite

Written 2026-09-24 against `master` = `7427828`. This is the input to the ground-up rewrite of the
type checker ([`docs/design/checker-v2.md`](../docs/design/checker-v2.md) is the architecture,
[`checker-rewrite.md`](checker-rewrite.md) the slice plan, queue row 78 the tracker).

**IDs are stable.** `CK-NN` is never renumbered or reused. A finding that turns out to be wrong
is marked *withdrawn* in place. A new finding takes the next free number at the end.

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
- **Since R2a** (2026-09-24, review S1) `check` refuses this miscount with the I7 `internal` even
  in a declaration nothing reaches: `Lower` used to meet it only on code dead-code elimination
  kept, so such a program built and ran before R2a. Kept on purpose (`checker-v2.md` §13.1 as
  amended); pinned by `tests/pending/run/DeadMiscount.beni`.

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
- **Since R2a** (2026-09-24, review S1) `check` refuses this miscount with the I7 `internal` even
  in a declaration nothing reaches: `Lower` used to meet it only on code dead-code elimination
  kept, so such a program built and ran before R2a. Kept on purpose (`checker-v2.md` §13.1 as
  amended); pinned by `tests/pending/run/DeadMiscount.beni`.

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
    - R0's current `tests/pending/check/good/ScrutineeMethodMergeVariant/` is therefore wrong, and
      is to be split as above. That is R7's first commit, or a follow-up touch by R0.
  - *R0 follow-up: done.* `check/bad/ScrutineeMethodMergeD14/` has `.codes` `type_mismatch
    Later.beni:29:* contains "Annotate `h`"` and the same at `Sooner.beni:33:*`. D14's hint
    capitalises "Annotate" (`checker-v2.md` §10.7). On 7427828 it is `method_needs_annotation` ×4
    plus `unknown_method`.
  - `check/good/ScrutineeMethodMergeVariant/` now matches `( _, _, _ ) -> ( 1, 2 )`, and its `.iface`
    has `f : K, () -> ( number, number2 )`.
- **Slice** R7.

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
- **Since R2a** (2026-09-24, review S1) `check` refuses this miscount with the I7 `internal` even
  in a declaration nothing reaches: `Lower` used to meet it only on code dead-code elimination
  kept, so such a program built and ran before R2a. Kept on purpose (`checker-v2.md` §13.1 as
  amended); pinned by `tests/pending/run/DeadMiscount.beni`.

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
- **Slice** R6a (the resolver rewrite).

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

## Summary table

*Slice splits of 2026-09-24 (review round 3).* R2 became R2a/R2b, R4 became R4a/R4b, R6 became
R6a/R6b, and R8 became R8a/R8b. The slice named in each entry below is the unsplit one.
`checker-rewrite.md` §4 is the authoritative CK → slice index.

| ID | Severity | Class | Fixture (under `tests/pending/`) | Slice |
|---|---|---|---|---|
| CK-01 | unsound-runtime | K1 | `check/bad/LetAnnotationRigidEscape.beni`, `…RowEscape.beni` | R4 |
| CK-02 | unsound-runtime | K2 | `check/bad/OuterReceiverConstraintLevels.beni` | R6 |
| CK-03 | compiler-crash-or-hang | K3 | `check/bad/CyclicReceiverResolution.beni` + `scenario/CK-03` | R6 |
| CK-04 | unsound-runtime | K3 | `check/bad/InfiniteTypeAtBinder.beni` | R4 |
| CK-05 | valid-program-rejected | K2 | `run/ObligationEscapesInnerLet.beni` | R5 |
| CK-06 | valid-program-rejected (D2) | K2 | `run/TryDefersShape.beni` | R5 |
| CK-07 | nondeterminism | K12 | `check/bad/FieldErrorTextOrder.beni` (single file, R0) | R4 |
| CK-08 | valid-program-rejected | K3 | `run/ClosedRecordAfterFieldAccess.beni` | R6 |
| CK-09 | unsound-runtime | K8 | `check/bad/MutualGroupLocals.beni`, `check/good/MutualGroupLocalTypes.beni` | R5, R6 |
| CK-10 | latent | K3 | — (structural) | R4 |
| CK-11 | unsound-runtime | K9 | `check/bad/WarningKeepsExhaustiveness.beni` | R1, R4 |
| CK-12 | latent | K9 | — (unit test) | R1 |
| CK-13 | unsound-runtime (no runtime path yet) | K9 | `check/bad/SchemaMemberTooDeep/` | R4 |
| CK-14 | latent | K9 | — (structural) | R4 |
| CK-15 | latent | K9 | — (structural) | R4, R9 |
| CK-16 | unsound-runtime | K5 | `check/bad/BasicsEqThroughStructure.beni` | R5 |
| CK-17 | unsound-runtime | K5 | `check/bad/WideRecordEqFunction.beni` | R1, R5 |
| CK-18 | latent | K2 | — (deleted) | R5 |
| CK-19 | unsound-runtime | K7 | `run/EquatableMarkerIsNotEq.beni` | R1, R8 |
| CK-20 | unsound-runtime | K5 | `check/bad/RigidInsideDerivedShape.beni` | R2, R6 |
| CK-21 | unsound-runtime | K5 | `check/bad/WhereClauseNumberReceiver.beni` | R6 |
| CK-22 | unsound-runtime (D1) | K7 | `check/bad/PrivateEqOutsideModule/`; guard `tests/corpus/run/PrivateEqInsideModule/` | R8 |
| CK-23 | valid-program-rejected (D4) | K7 | `run/PhantomParameterEq.beni` | R8 |
| CK-24 | unsound-runtime (no runtime path yet) | K7 | `check/bad/SchemaWrapperExclusion.beni` | R8 |
| CK-25 | valid-program-rejected (D4) | K4 | `run/GenericDerivationNestedRequirement/` | R8 |
| CK-26 | latent | K7 | — (structural) | R8 |
| CK-27 | unsound-runtime | K4 | `run/CustomEqHeadMatching/` | R6 |
| CK-28 | valid-program-rejected | K4 | `run/CustomEqTupleHead/` | R6 |
| CK-29 | compiler-crash-or-hang | K2 | `run/LetHelperJoinedMethod.beni` | R6 |
| CK-30 | compiler-crash-or-hang | K4 | `run/RecursionWithComparison.beni`, `run/DeadMiscount.beni` | R7 |
| CK-31 | compiler-crash-or-hang (latent) | K4 | `run/MutualGroupEvidenceOrder.beni` | R7 |
| CK-32 | compiler-crash-or-hang | K4 | `run/OperatorSectionApplied.beni` | R6 |
| CK-33 | unsound-runtime | K4 | promoted: `run/ConstrainedFunctionConstant/` | R2b (fixed) |
| CK-34 | unsound-runtime | K4 | promoted: `check/bad/EvidenceConstantCycle.beni` | R2b (fixed) |
| CK-35 | latent | K4 | — (structural) | R6 |
| CK-36 | valid-program-rejected (D3) | K6 | `run/OwnMethodBeforeDefinition/` | R7 |
| CK-37 | latent | K3 | guards `tests/corpus/check/bad/CyclicReceiverReportedOnce.beni`, `…/RejectedReceiverDoesNotSilence.beni` | R6, R14 |
| CK-38 | valid-program-rejected | K10 | `check/good/WideTypeArity/` | R3 |
| CK-39 | valid-program-rejected | K10 | `run/RecordAliasConstructorImported/` | R3 |
| CK-40 | performance | K11 | `scenario/CK-40` (400 schemas) | R8 |
| CK-41 | performance | K11 | `scenario/CK-41` (one type, 14 000 constructors) | R3 |
| CK-42 | performance (reproduced in R0) | K11 | `scenario/CK-42` (extra cost of own `==` over `x == x`, × 5 000) | R6 |
| CK-43 | unsound-runtime | K14 | `run/RecordAliasConstructor.beni` | R1 |
| CK-44 | diagnostic-quality | K14 | `check/bad/DuplicateRecordTypeField.beni` | R1 |
| CK-45 | diagnostic-quality | K14 | `parse/bad/FloatPattern.beni` | R1 |
| CK-46 | diagnostic-quality | K14 | `check/bad/LetCycleThroughFunction.beni` | R1 |
| CK-47 | diagnostic-quality | K14 | `parse/bad/ExposingConstructorsElmStyle.beni` | R1 |
| CK-48 | diagnostic-quality | K13 | `check/bad/MissingWhereAtUse.beni` | R6 |
| CK-49 | diagnostic-quality | K13 | `check/bad/ListElementFromContext.beni` | R13 |
| CK-50 | diagnostic-quality | K13 | `check/bad/NoArithmeticHintWithoutArithmetic.beni` | R13 |
| CK-51 | diagnostic-quality | K13 | `check/bad/TryShapeNamesTheMismatch.beni` | R5 |
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
| CK-62 | valid-program-rejected | K2 | `run/TryDecidedByLaterFacts.beni` | R5 |
| CK-63 | valid-program-rejected | K6 | `run/OwnMethodDemandedEarly.beni` | R7 |
| CK-64 | valid-program-rejected | K6 | `run/OwnMethodValuePrefix.beni` | R7 |
| CK-65 | valid-program-rejected | K6 | `run/MutualDispatchMethods.beni` | R7 |
| CK-66 | valid-program-rejected | K4 | `run/GroupVariableOutsideCaller.beni` | R7 |
| CK-67 | valid-program-rejected | K7 | `run/DerivedContextClosedOwnMethod/` | R8 |
| CK-68 | diagnostic-quality | K2 | `check/bad/TupleIndexOuterResult.beni` | R5 |
| CK-69 | diagnostic-quality | K7 | `check/bad/DerivedContextNeedsAnnotation/` (+ `…KeyFirst/`) | R8 |
| CK-70 | diagnostic-quality | K6 | `check/bad/RecursiveDispatchTwoTypes.beni` (+ `…B.beni`) | R7 |
| CK-71 | nondeterminism | K12 | `scenario/CK-71` (100 loaded runs at `--jobs=8`); promoted by R1 into the gates | R1 |
| CK-72 | compiler-crash-or-hang | K4 | `check/bad/RecursiveGroupReceiverNeedsAnnotation.beni` (+ twin) | R7 |
| CK-73 | valid-program-rejected | K6 | `run/ScrutineeMethodLater.beni`, `check/good/ScrutineeMethodMergeVariant/`, `check/bad/ScrutineeMethodMergeD14/` | R7 |
| CK-74 | diagnostic-quality | K7 | `check/bad/DerivedContextReentrant/` (+ twin) | R8a |
| CK-75 | performance | K11 | `scenario/CK-75` (5 000 declarations, no dispatch) | unassigned — manager |
| CK-76 | compiler-crash-or-hang | K4 | `check/bad/RecursiveGroupEvidenceReceiver/`, `check/bad/RecursiveGroupSubWanted/` | R7 |
| CK-77 | diagnostic-quality | K7 | `check/bad/DerivedContextMergesAsker/` | R8a |
| CK-78 | decision (supported) | K14 | guard `tests/corpus/run/RecordAliasConstructorPattern.beni` | R1 |
| CK-79 | valid-program-rejected | K10 | — (`abuse_test.zig` pins the 4 096 cap) | unassigned — manager |
| CK-80 | performance | K11 | `scenario/CK-80` (`( x, [ x ] )` n deep, n = 9 vs 18) | R6a |
| CK-81 | compiler-crash-or-hang | K11 | promoted: `abuse_test.zig` (two scenarios) | R2a (fixed) |
| CK-82 | compiler-crash-or-hang | K10 | `scenario/CK-82` | R8a (with CK-79) |
| CK-83 | unsound-runtime | K14 | promoted: `abuse_wide_test.zig` "CK-83: …" | R2c (fixed) |
| CK-84 | unsound-runtime | K4 | promoted: `run/ConstrainedAliasFunctionImported/` | R2b (fixed) |
| CK-85 | performance (latent) | K4 | guard `tests/corpus/run/EvidenceFunctionBodyPerCall.beni` | unassigned — manager |
| CK-86 | diagnostic-quality | K14 | `check/bad/ExposingSameNameConstructor/` | R13 |
| CK-87 | valid-program-rejected | K14 | `run/DerivedEqDeepRecord.beni` | unassigned — manager |
| CK-88 | performance | K14 | `scenario/CK-88` | unassigned — manager |

Totals:
- 88 entries (CK-62 to CK-70 and CK-72 to CK-74 added 2026-09-24 from the design reviews; CK-71 by R0; CK-75 by the review of R0; CK-76 and CK-77 from design review round 4; CK-78 to CK-81 by R1 and its review; CK-82 and CK-83 by R2a stage 2; CK-84 by R2b; CK-85 and CK-86 by R2b's review; CK-87 and CK-88 by R2c). CK-78 records a decision, not a defect, and is counted under none of the severities below.
- unsound-runtime: 19 (CK-83 and CK-84 among them). Two of them (CK-13, CK-24) have no runtime path until schemas emit.
- compiler-crash-or-hang: 9.
- valid-program-rejected: 18 (CK-87 among them).
- nondeterminism: 2.
- performance: 7 (CK-85 and CK-88 among them).
- diagnostic-quality: 23 (CK-86 among them).
- latent: 9.
- Outside the checker (K14): 10 (CK-78, CK-83, CK-86, CK-87 and CK-88 among them).
