# check/bad

Modules and projects that must fail resolution, each with the **whole**
diagnostic list as its golden (`docs/design/checker.md` §4.3, §4.5). A
fixture without a `.diag` is a failure, not a pass.

| Shape | The compiler runs | Compared against |
|---|---|---|
| `X.beni` | `check --diagnostics=json X.beni` | `X.diag` |
| `X/` (a directory) | `check --diagnostics=json X` | `X/_expected.diag` |

The codes this kind covers are the M2a half of checker.md §8.1 —
`unknown_module`, `import_cycle`, `unknown_import_name`, `private_name`,
`opaque_constructor`, `wrong_type_arity`, `recursive_alias` — plus the two
`equatable` codes of Appendix A. The type codes arrive with M2b.

Several of these need more than one module to be reachable at all, which is
why the directory form exists: `private_name` is only a different message
from `unknown_import_name` when there is a second module to be private *in*.

A fixture under `core/` is run with `--core`.
