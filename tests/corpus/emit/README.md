# `emit/` — the shape corpus

Compile the fixture for the Node platform and compare the **module's own
`.mjs`** with the `.js` file beside it (`docs/design/backend.md` §12).

`run/` is the default and proves behaviour. A fixture belongs here only when
two different emissions would behave the same and the difference is the
point: that a `where`-constrained declaration grew a hidden parameter, that
a call passed one, that `<` on an `Int` is `<` and on a `String` is a call,
that a constrained value in value position is a closure and not a name.

The golden is the **fixture's module** and not the whole build. Core and the
platform are somebody else's output, and a golden holding them would fail on
every unrelated change to `core/`. §12 asks for an extracted declaration;
one module of one deliberately tiny fixture is that extract, with no
extractor to get wrong.

Each fixture is one `.beni` module with a `main : Program`, compiled on its
own in a temporary project directory, exactly like `run/`. `main` is
`Node.printLines []` throughout — an entry point is required and this is the
smallest one that says nothing.

A fixture that fails to compile, or that produces any diagnostic, is a
failure.

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`, narrowed with
`BENI_BLESS_ONLY=emit/`, and **read the blessed golden** before committing:
a wrong golden here pins wrong JavaScript.
