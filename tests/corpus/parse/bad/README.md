# parse/bad

Programs that must fail. Each `X.beni` has an adjacent `X.diag` golden: the
whole diagnostic list as `beni check --diagnostics=json X.beni` prints it —
code, severity, span, title and message, never just "it failed".

A `.beni` here WITHOUT a `.diag` is a test failure (the Elm gap, closed
mechanically). Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`.
Every code in `docs/design/language.md` §10 gets at least one fixture in M1.

A fixture under a `core/` subdirectory here is run with `--core` (`foreign`
declarations legal, language.md §5.4); its goldens sit next to it.
