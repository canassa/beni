# parse/good

Programs that parse clean. Each `X.beni` has an adjacent `X.ast` golden: the
output of `beni dump --stage=ast X.beni` (no positions). One idea per fixture,
stated in a comment inside it.

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`. M1b (the parser)
produces the goldens; `tests/blackbox/corpus_test.zig` walks it regardless.

A fixture under a `core/` subdirectory here is run with `--core` (`foreign`
declarations legal, language.md §5.4); its goldens sit next to it.
