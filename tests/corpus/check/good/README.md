# check/good

Modules and projects that resolve cleanly, and the interface each one
produces (`docs/design/checker.md` §3, §7). Two claims per fixture:

- `beni check <fixture>` exits 0 with **no diagnostic at all** — the names
  resolved against this project and against the embedded core package;
- `beni dump --stage=interface <fixture>` equals the `.iface` golden — what
  the module now offers its dependents, INCLUDING every value's inferred or
  annotated scheme (checker.md §7). The schemes are rendered by
  `check/Render.zig`, the same code every diagnostic prints types with, so
  these goldens are also the test for the type text in every message.

Two shapes:

| Shape | The compiler runs | Compared against |
|---|---|---|
| `X.beni` | `check X.beni`, then `dump --stage=interface X.beni` | `X.iface` |
| `X/` (a directory) | `check X`, then `dump --stage=interface X` | `X/_expected.iface` |

A directory is a **project**: every `.beni` under it is a module of the
package `app`, and the golden is every module's interface concatenated in
path order. That is where cross-module resolution — imports, `exposing`
lists, qualified names, the topological order — is actually exercised, and
where cross-module INFERENCE is: `SharedType` puts one type in three
dependents, `InferredExport` makes the importer instantiate a scheme nobody
wrote down, `AliasAcrossModules` carries an alias over a boundary without
expanding it, `Diamond` gives the DAG scheduler (checker.md §4.4) two
modules that may run at once, `CtorByName` imports constructors by name and
matches on them exhaustively, `OpaqueAcrossModules` hides constructors from
an importer, and `QualifiedAcrossModules` reaches a dotted module through an
`as` alias.

A fixture under `core/` is run with `--core`, so `foreign` and the
`equatable` marker are legal (`language.md` §5.4, checker.md Appendix B).

`TypeOwnerEdges` carries a third golden, `_expected.graph`, which the
corpus runner knows nothing about: the scenario in `blackbox_test.zig` that
compares `dump --stage=graph` at `--jobs=1` and `--jobs=8` reads it, because
what that fixture is about is the module graph's EDGES
(`static-dispatch-spike.md` §6.8) and not its interfaces. It blesses with
the same switch.

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`; check the blessed
golden against the fixture's intent comment before committing it.

The inferred scheme of every value is in these goldens; the interface dump
is kept narrow so that a change to it is readable.

