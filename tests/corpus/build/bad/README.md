# build/bad

Whole projects that must fail to **build**, each with the whole diagnostic
list as its golden. A fixture without an `_expected.diag` is a failure, not
a pass.

| Shape | The compiler runs | Compared against |
|---|---|---|
| `X/` (a directory) | `build --diagnostics=json --platform=… --out=out <its .beni files>` | `X/_expected.diag` |

Three things are asserted, and the third is why the kind is a *build* one:

1. the build exits **1**;
2. stderr is the golden, byte for byte;
3. **no `out/` is written** — a refused build leaves nothing behind
   (`boundary.md` §4), which no diagnostic golden can state.

## Why this kind exists

Nine diagnostic codes had no corpus fixture and could only be reached from
`tests/blackbox/`, for two structural reasons (`plans/coverage-audit.md`
Part A):

- **six boundary codes need a platform package to check.** `boundary.md`
  §4's four sibling checks are checks *of* a package that may write
  `foreign`, and no other corpus kind can carry one:
  `foreign_bad_shape`, `foreign_sibling_missing`, `foreign_export_mismatch`,
  `foreign_unbound_reference`, `foreign_arity_mismatch` and the
  `not_implemented` a relative import in a sibling `.js` raises.
- **three entry-point codes need a build.** `check --platform` runs §4's
  sibling checks but deliberately does not look for `main`
  (`src/check/Command.zig` returns before `Emit.findEntry`), so
  `missing_main`, `main_not_program` and `duplicate_main` are reachable
  only through `build`.

## The shape of a fixture

**The fixture directory IS the project.** Every file under it is copied into
a temporary project — not only the `.beni` files, because a platform package
is a manifest, modules and their sibling `.js` — and the `.beni` files at
its top level, sorted, are the build's arguments. A fresh temporary project
per fixture, unlike the kinds that write one file: the previous fixture's
platform would otherwise still be there and its modules would be compiled
into this build.

**The platform is a convention, not a flag file.** A `platform/`
subdirectory means `--platform=platform`; without one the build takes the
embedded `--platform=node`, which is all the entry-point codes need. So a
fixture is still one directory and one golden, and there is nothing to
configure.

The smallest platform a fixture can carry is four files — this is what
`mk_plat` writes into the six that have one:

```
platform/beni.json     { "platform": true, "name": …, "program": "Prog.Program", "runtime": "run.js" }
platform/Prog.beni     pub foreign type Program;  pub foreign say : String -> Program
platform/Prog.js       export const say = (line) => ({ text: line });
platform/run.js        export const run = (program) => { … };
```

A fixture then breaks exactly one of §4's rules — a missing sibling, a
polymorphic `foreign`, an export that does not match, a name the sibling
never imported, an arity that disagrees, a relative import — and the golden
is what the compiler said about it.

Paths in the golden are relative to the temporary project (`Main.beni`,
`platform/Prog.beni`) because the fixture is copied there, for the reason
`run/` copies: a build writes an `out/` that has no business in the
repository.

## What is here

| fixture | code |
|---|---|
| `MissingMain/` | `missing_main` |
| `MainNotProgram/` | `main_not_program` |
| `DuplicateMain/` | `duplicate_main` |
| `ForeignSiblingMissing/` | `foreign_sibling_missing` |
| `ForeignBadShape/` | `foreign_bad_shape` (§4 check 1) |
| `ForeignExportMismatch/` | `foreign_export_mismatch` (§4 check 2), both directions in one golden |
| `ForeignUnboundReference/` | `foreign_unbound_reference` (§4 check 3) |
| `ForeignArityMismatch/` | `foreign_arity_mismatch` (§4 check 4) |
| `SiblingRelativeImport/` | `not_implemented` (`backend.md` §2) |

## What still cannot live here

Three codes stay blackbox-only, and the reason is the argv rather than the
fixture:

- `internal` — reachable only through `Lower.missingCoreValue`, which needs
  a `--core-root` pointing at a mutilated core package; a fixture is a
  project, not a replacement core.
- `duplicate_module` — needs TWO root paths in one argv, and a project
  fixture is one root, so its relative paths are unique by construction.
- the usage errors — a bad flag or a missing argument is an argv, not a
  project.

The blackbox scenarios for the nine codes above **stay**, because they
assert what a golden cannot: exit codes across `check` and `build`, that
`check --platform` and `build` print the same bytes, and that the second
site of `foreign_sibling_missing` (asset copying) is reached.
