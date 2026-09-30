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

**Every fixture is built and run TWICE**, once as a development build and
once with `--release`, against the same `.expected` — unless it carries a
`.release-expected`, which no fixture does since 2026-09-30: `ReleaseDeadDebug`
was the one, until the release optimiser stopped dropping a binding that
may be impure (`backend.md` §9 item 1). The release pass also carries the hidden, test-only
**`--allow-debug`**, uniformly: since 2026-09-19 a `--release` build that
reaches `Debug` is refused (§9's *`Debug` is refused, not pinned*), and
`Debug.log` is this directory's only instrument for observing evaluation
order — 24 of the 121 fixtures use it, among them every `EvalOrder*`,
`CallbackOrder*`, `QuestionOrder` and `SortByKeyOnce`, and the `--release`
run of exactly those is what proved the wide inliner unsafe. Uniformly
rather than per fixture, because a fixture can reach `Debug` through a
module it imports. **The refusal itself is `build/bad-release/`'s**, which
passes no such flag; nothing here asserts it, and a `Debug.log` in a fixture
here is therefore not a claim that a user could build that program with
`--release`.

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`, narrowed with
`BENI_BLESS_ONLY=run/`.
