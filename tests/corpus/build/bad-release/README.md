# `build/bad-release/` — a project that builds in dev and is refused in release

Added 2026-09-19 with [`backend.md`](../../../../docs/design/backend.md) §9's
*The release optimiser*: **a `--release` build in which any `pub` value of
`core/Debug` survives reachability elimination is refused**.

A fixture here is a directory holding a whole project, exactly as in
[`build/bad/`](../bad/README.md), and it gets **four** assertions rather than
three:

1. the same sources build **clean** with no `--release` — exit 0, empty stderr;
2. with `--release` the build **fails**, exit 1;
3. `_expected.diag` is the whole diagnostic list, byte for byte;
4. no `out/` is written.

Assertion 1 is why this kind exists as a directory rather than a flag file in
`build/bad/`: `debug_in_release` is the one code in the catalogue that a
development build does not have, so a fixture that is merely broken would pass
the other three and claim to be about the flag.

**No `--allow-debug` here, and that is the point.** The hidden flag
(`src/Cli.zig`) turns the refusal off, and `tests/corpus/run/`'s `--release`
second pass passes it uniformly so that `Debug.log` keeps working as the
corpus's instrument for evaluation order. This directory is the one place the
refusal itself is under test.

The conventions are `build/bad/`'s: every file under the directory is copied
into the world, the top-level `.beni` files sorted are the build's arguments,
and a `platform/` subdirectory means `--platform=platform`.
