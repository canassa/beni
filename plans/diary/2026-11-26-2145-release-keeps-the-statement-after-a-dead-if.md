## 2026-11-26 21:45 CET — release keeps the statement after a dead if

**What I did**

- Reduced issue #2706's 8-module, 565-line program from the blind rounds to
  one function of 20 lines. A `case` on a `Maybe` holds a second `case` on
  the same subject, and its arms hold only a `Ref.make` that nothing reads.
  The `case` comes after a suspension, and a `return` follows it.
- Found the cause in `Print.zig`. Under `--release`, `Opt` drops the
  bindings. Spec keeps the inner `if`, and the printer then writes nothing
  for it (an `if` with no live arm and a test that only reads). But
  `skipped` did not count such an `if`. So `onlyLive` picked it as the one
  statement of the outer arm, and `armBody` wrote that arm unbraced. The
  result was `if(c)` followed by nothing, so the next statement, the
  function's `return`, became the arm: `if(b.$===0)return …`. For
  `Nothing` the function returned `undefined`, and the caller read
  `.length` of it.
- Fix: `skipped` now counts an `if` that prints nothing, by the same test
  `statement` uses to print nothing. `anyLive`, `onlyLive`, `jumps`, the
  loop shapes and `compactIf` all ask `skipped`, so they all agree with what
  is printed. If such an `if` is still written as a single arm body, it
  prints `;` and does not swallow the next statement.
- `run/ReleaseDeadInnerIf`: the dead inner `case` as the then arm, as the
  else arm, two levels deep, and under an `if` with a live test. On a beni
  built from master, each of the four crashes on its own under `--release`
  with the issue's `TypeError`. With the fix, release prints what
  development prints. The fixture uses `Ref.make`, because specialisation
  folds a pure call or a list literal away before the printer sees it. So
  `ownership-v2-known.txt` gets four parity lines.
- With the fix, cw12.310, cw12.533 and the four blindCZ mutants print the
  same in both builds.

**What I learned**

- The printer has one rule: "a statement that `skipped` does not skip
  prints something". Every shortcut (an unbraced body, `else` splicing, the
  `while` header) depends on it. Any new way of printing nothing must go
  into `skipped`. If it does not, the statement after it takes its place.
