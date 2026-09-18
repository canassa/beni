# `emit/release/` — shape claims about the release optimiser

Same mechanism as `emit/app/` and `core/`, a third time (`backend.md` §9's
*Testing*, §12): every `.beni` here is built with `--library` **and
`--release`**, and its own emitted `.mjs` is the golden.

A fixture belongs here only when the claim is something running the program
cannot observe — a short name, a dropped space, a folded temporary. Anything
about what a program COMPUTES is `run/`'s, and every `run/` fixture already
runs a second time under `--release`, so behaviour is covered there without a
single file being added here.

A directory is a multi-module project, exactly as under `emit/app/`: every
`.beni` in it is copied into one build and `_expected.js` is the module named
after the directory. That is how a claim about two files agreeing — an
`import` specifier and the `export` it reads — is goldened at all.
