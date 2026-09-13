# check/bad

Modules and projects that must fail resolution, each with the **whole**
diagnostic list as its golden (`docs/design/checker.md` §4.3, §4.5). A
fixture without a `.diag` is a failure, not a pass.

| Shape | The compiler runs | Compared against |
|---|---|---|
| `X.beni` | `check --diagnostics=json X.beni` | `X.diag` |
| `X/` (a directory) | `check --diagnostics=json X` | `X/_expected.diag` |

The codes this kind covers are checker.md §8.1's, minus the arity family,
which has its own kind (`check/args`, §8.3):

- **M2a, the module graph and names** — `unknown_module`, `import_cycle`,
  `unknown_import_name`, `private_name`, `opaque_constructor`,
  `wrong_type_arity`, `recursive_alias`, plus the two `equatable` codes of
  Appendix A.
- **M2b, inference** — `type_mismatch`, `rigid_mismatch`, `infinite_type`,
  `kind_mismatch`, `missing_field`, `unknown_field`, `record_not_closed`,
  `not_equatable`, `not_interpolatable`, `ambiguous_interpolation`,
  `ambiguous_tuple`, `tuple_index_out_of_range`, `not_a_tuple`, `try_shape`.
- **M2c, pattern usefulness** — `missing_patterns` and `redundant_pattern`
  (checker.md §6.6). These two are reported only for a declaration that
  type-checked, so a fixture for them must be otherwise correct — a `case`
  whose branches disagree produces `type_mismatch` and nothing else.

A module that an earlier phase already reported on is checked SILENTLY (see
`check/Check.zig`'s `Options.quiet`), so a fixture for a type code must be
free of syntax and name errors — otherwise it produces the earlier
diagnostic and nothing else.

Several of these need more than one module to be reachable at all, which is
why the directory form exists: `private_name` is only a different message
from `unknown_import_name` when there is a second module to be private *in*.

A fixture under `core/` is run with `--core`.
