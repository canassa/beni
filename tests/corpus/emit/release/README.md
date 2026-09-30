# `emit/release/` — shape claims about the release optimiser

Same mechanism as `emit/app/` and `core/`, a third time (`backend.md` §9's
*Testing*, §12): every `.beni` here is built with `--library` **and
`--release`**, and its own emitted `.mjs` is the golden.

A fixture belongs here only when the claim is something running the program
cannot observe — a short name, a dropped space, a folded temporary. Anything
about what a program COMPUTES is `run/`'s, and every `run/` fixture already
runs a second time under `--release`, so behaviour is covered there without a
single file being added here.

**`--allow-debug` rides with `--release` here**, as it does on `run/`'s
release pass: since 2026-09-19 a `--release` build that reaches `Debug` is
refused (`backend.md` §9's *`Debug` is refused, not pinned*), and the corpus
applies the hidden flag uniformly to both release passes so that a shape
golden can be about a `Debug`-using program the day one is wanted. No fixture
here uses `Debug` today. The refusal itself lives in `build/bad-release/`,
which passes no such flag.

A directory is a multi-module project, exactly as under `emit/app/`: every
`.beni` in it is copied into one build and `_expected.js` is the module named
after the directory. That is how a claim about two files agreeing — an
`import` specifier and the `export` it reads — is goldened at all.

**`app/` holds release APPLICATIONS** — `--release` without `--library`,
rooted at `main` — and their golden is the whole of `_main.mjs`, because a
release application is one scope-hoisted file (`backend.md` §9, *One
scope-hoisted file under `--release`*): every module, sibling and runtime
of the program in ES module evaluation order, in one module scope. A
directory there is a project as above, its entry module named after it.

**`core/` is built with `--core` as well**, like `emit/core/`: the shapes of
code only core and platform packages may write (`Js`), under the release
optimiser, where the claim is usually "the same JavaScript the hand-written
runtime writes for this" (`plans/browser-decisions.md`, R47-3).
