# Ideas from Roc's compiler

Features that Roc's Zig compiler (read 2026-09-28, while comparing its type-checking
pipeline's size with beni's) has and beni does not, and that could be worth adopting. Nothing
here is decided or specified: each item needs a design pass (rule 1) and the owner's decision
before any code. They are listed roughly by value for the effort.

Each item is tested against rule 7: a new error only if it protects a guarantee; anything else
is a warning or nothing.

## 1. Unused-name warnings

**What.** A warning for a `let` binding, a pattern variable or a parameter that is never read,
and a second one for a name starting with `_` that *is* read (the underscore promised it would
not be).

**In Roc.** `unused_variable` and `used_underscore_variable`, raised from canonicalisation.

**Why for beni.** None of beni's 122 diagnostic codes covers it, and dead bindings are one of the
commonest leftovers after a refactor. Elm has no such warning, so this is an improvement over the
language beni follows, not a departure from it.

**Shape.** Warnings, never errors (rule 7: no guarantee is at stake). Root package only, like the
ambiguous-receiver warning, so a dependency's leftovers never reach the user. `_` and `_name`
silence it. Resolution already knows every binder and every use, so the cost should be one pass
over data that exists.

**Open questions.** Unused top-level values that are not exposed, and unused imports: include
them, or keep to locals? Does the formatter or a future LSP offer the fix?

## 2. Hints on a type mismatch: constructor typos, arity, missing fields

**What.** When two types fail to unify, compare them and say *how* they differ: a constructor
name one edit away from the expected one, a function given one argument too many or too few, a
record missing one field or carrying a misspelt one.

**In Roc.** `check/snapshot/diff.zig` diffs the two types' snapshots and feeds the hints to
`check/report.zig`.

**Why for beni.** beni already hints on misspelt fields and methods. Constructor typos and arity
differences get only the bare TYPE MISMATCH today, and with n-ary functions and no currying an
arity mistake is a common first error.

**Shape.** Message text only; no change to what is accepted. Needs the two types at the failure
point, which the checker has when it reports.

## 3. Compile-time evaluation of top-level constants

**What.** Evaluate a top-level value that depends only on constants at build time, and emit the
result instead of the computation.

**In Roc.** Top-level constants are evaluated by an interpreter while checking (`eval/`,
`check/const_store.zig`), and conditions it can decide are reported as warnings.

**Why for beni.** Output size and start-up time in the browser (the browser comes first): a
lookup table or a derived configuration computed once at build time ships as a literal. It is not
a correctness gap.

**Shape.** A `--release` optimisation in the backend, not a checker feature, and never a warning:
Roc's "unconditional condition" warning turns correct programs into failed checks (the benchmark
generator had to avoid whole shapes of code because of it), which rule 7 rules out. It needs a
budget that declines the optimisation, never a result, when evaluation runs long or does not
terminate, and it must not change a program's behaviour, including what it does on a `Debug` call
or a crash.

**Open questions.** Is the size win large enough on real programs? Measure on `bench/corpus` and
the browser examples before specifying.

## 4. Inline `expect` tests

**What.** `expect` declarations beside the code they test, run by a test command and removed from
builds.

**In Roc.** `expect` at top level and inside functions; `dbg` for debug printing.

**Why for beni.** A test runner is something every beni user will need, and one the language can
provide without `foreign` (rule 7's "a capability gap is filled inside the wall"). beni has
`Debug.log` already, so `dbg` adds little.

**Shape.** Top-level `expect` only at first; a `beni test` command that builds the expects and runs
them on the platform. Needs a design pass on how failures are reported (values printed through
the derived or own `show`-like method?).

## 5. Record-field defaults

**What.** A record type whose fields may be omitted at construction, taking a declared default.

**In Roc.** The `??` default operator on record fields (`DefaultCycles`, `default_omissions`).

**Why for beni.** Component props in the browser UI: a JSX element with twenty optional attributes
is the everyday case, and today every record literal must spell every field. It overlaps the JSX
and browser-platform decisions (`plans/browser-decisions.md`), so it belongs in that discussion,
not on its own.

**Open questions.** Does JSX's attribute vocabulary, declared by the platform package, already
cover the need? What does a default look like in the type, and in an interface?

## Looked at and not proposed

- **Mutable variables, loops, early return.** beni is a pure Elm-like language; `?` already
  covers the early-exit case that matters.
- **Open tag unions and a full numeric tower.** Large surfaces with their own error-quality cost;
  `Int32` covers the numeric gap found so far.
- **Compiling programs that have errors** (Roc's runtime-error nodes). beni refuses to build a
  program with a type error, as Elm does; that is a guarantee, not a limitation.
