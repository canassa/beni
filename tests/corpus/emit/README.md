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

## `--library`, and why an `emit/` golden is not contingent on a call

Reachability elimination (`backend.md` §9) is always on, and an application
build is rooted at `main` alone. **So an `emit/` golden is a claim about the
shape of a declaration and must not be contingent on something calling it**:
the harness appends `--library` to every fixture directly under `emit/`, the
same per-fixture mechanism `core/` already uses for `--core`, which roots the
build at every name the module exports instead.

Without that flag all seventeen goldens here would be gutted rather than
merely re-blessed. `DerivedCompareNominal.js` is the sharpest case: 115 lines
of which 114 are derived code and one is `main`, and its intent comment says
in so many words that *nothing below uses these and they are all emitted
anyway* — a claim about eager derivation in the declaring module that is
still true and that a `main`-only build would delete the evidence for.

## `emit/app/` — the goldens whose claim IS what elimination removes

A fixture under `emit/app/` is built as an **application**, with no
`--library`, because what it pins is what a `main`-rooted build drops. Those
are `backend.md` §9's own goldens and nothing else belongs there.

A fixture there may also be a **directory**, which is a multi-module project:
every `.beni` in it is copied and handed to one build, the entry module is
the one named after the directory, and `_expected.js` is that module's
emitted file. An optional `_expected.absent` lists output paths the build
must **not** have written, one per line — the only way to assert that a whole
module vanished, there being no file to golden. It is never blessed.

## `emit/release/` — the goldens whose claim IS what `--release` changes

A fixture under `emit/release/` keeps `--library` and gains **`--release`**,
so its golden is a shape claim about §9's release optimiser: short names,
compact whitespace, a folded temporary. It has its own README.

Behaviour under the flag is not its business: every `run/` fixture is already
built and run a second time with `--release`, against the same `.expected`,
so the corpus covers what a release build COMPUTES without one file being
added here (`backend.md` §9's *Testing*).

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`, narrowed with
`BENI_BLESS_ONLY=emit/`, and **read the blessed golden** before committing:
a wrong golden here pins wrong JavaScript.
