## 2026-11-24 06:26 CET — a closure names a local after a suspension

**What I did.** #2663: a lambda made before a local of its block, with a
suspension point between them (a `Io.sleep 1` statement, or a callee that
sleeps while it builds the value), named a `const` that `Suspend` had moved
into the `Task$andThen` continuation. Development threw `ReferenceError`;
`--release` renaming printed `undefined 1` with no diagnostic, because the
free name's short spelling read another binding.

- `Suspend.hoistNamed` replaces `liftFunctions` and runs at every split: the
  closure-mode marker, the loop-mode marker (fast path and slow copy), and
  both join modes. A declaration of the rest that the statements in front,
  the call or the joined tree name (through any function they make, and
  through any `let` function lifted for them) becomes `let name;` in front
  of the split and `name = value;` where its `const` stood. A `let` function
  is lifted as before, and now in a join and a loop too. Nothing else moves,
  so evaluation order is unchanged, and a rest whose declarations nothing in
  front names is emitted as before: every `emit/` golden is unchanged.
- `Rename.verifyBound`, a safety-build check: every place a declared local is
  written has a declaration in its scope or one around it, or the build stops
  with an `internal` diagnostic that names it. The whole release corpus passed
  it on the first run.
- Spec: `transparent-effects-proposal.md` §16.3 and `backend.md` §9 item 2,
  each an *Amended 2026-11-24 (#2663)* paragraph.
- Fixtures: `run/ClosureNamesLocalAfterSuspension` (with `.in-place`) and
  `browser/inline/ClosureNamesLocalAfterSuspension` (four command bodies). With
  `src/js/Suspend.zig` put back as it was, the run fixture fails in development
  (`p$3 is not defined`) and in release (the new internal error), and so does
  the page.

**What I learned.** In the beni source, a closure in a nested block (an `if`
arm, or the value of an item) that names a later local of the outer block is
already `let_forward_reference`. So only the top-level declarations of the
rest list can be named from in front of a split. The v3 prototype
(`ownership-v2-design-review`, `87e622129c`) shares the lowering and is
exposed: the issue's `slept` program, with `--ownership=v3` and with or
without `--records-in-place`, throws `ReferenceError` there.
