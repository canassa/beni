# fmt

Formatter goldens. Each `X.beni` has an adjacent `X.expected`: the output of
`beni fmt --stdout X.beni`. The walker also checks that formatting
`X.expected` again is a fixed point and that both parse to the same AST.

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`.

A fixture under a `core/` subdirectory here is run with `--core` (`foreign`
declarations legal, language.md §5.4); its goldens sit next to it.
