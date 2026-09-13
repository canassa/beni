# `run/` — the second boundary

Compile the fixture for the Node platform, run the emitted JavaScript, and
compare its **stdout** with the `.expected` file beside it.

This is the boundary that proves codegen is *correct* rather than merely
*stable* (`docs/design/backend.md` §12, and the reason `boundary.md` §8 puts
the Node platform before the optimiser). A change that alters the emitted
shape but not its behaviour must leave every fixture here green; a change
that alters behaviour must fail one, by name.

Each fixture is one `.beni` module with a `main : Program`, compiled on its
own in a temporary project directory. A fixture that fails to compile, that
produces any diagnostic, or whose program exits non-zero is a failure —
there is no "it at least ran" pass.

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`, narrowed with
`BENI_BLESS_ONLY=run/`.
