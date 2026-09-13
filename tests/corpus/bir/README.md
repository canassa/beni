# bir

Lowering goldens. Each `X.beni` has an adjacent `X.bir`: the output of
`beni dump --stage=bir X.beni`, which must show every desugaring in
`docs/design/language.md` §8 legibly.

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`. M1c produces the goldens.

A fixture under a `core/` subdirectory here is run with `--core` (`foreign`
declarations legal, language.md §5.4); its goldens sit next to it.
