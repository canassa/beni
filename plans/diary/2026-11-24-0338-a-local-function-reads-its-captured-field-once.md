## 2026-11-24 03:38 CET — a local function reads its captured field once

**What I did**

- #2620. A local function made in the holder's frame, `g s = s ++ String.fromInt p.n`, read
  `p.n` when it ran. A call after `q = { p | n = … }` wrote the field in place read the new
  value (`x1` where value semantics prints `x0`).
- I found a second defect in the same code, a crash. #2617 carried a read out to the
  lambda around the function. When the record was bound after the function inside that
  lambda, `const $t = p.n` came before `const p`, so the program threw `ReferenceError`.
- The read is now made once in the block (`Walker.resolveLate`). It is made at the block's
  entry when the record is bound by then, else just after the `let` item that binds it. That
  is a new placement phase, 2, "after the item", in Hoists format 2. The read is also a use
  there, so a write before the block hoists it before that write. `Lower.letBindings` writes
  the function after that item when the read is placed later (JavaScript hoists a
  `function`, so no call changes).
- Fixtures `run/RecordReadLocalFunction` (eight shapes, `.in-place`) and
  `browser/inline/RecordReadLocalFunction` (four arms, one after a sleep). Both fail with
  the fix disabled. Spec: `ownership-checker.md` §31.6, §31.10 and §31.14, amended
  2026-11-24.

**What I learned**

- The reviewer found that a lambda bound before its record crashes the same way. That
  case is on master too, and the fix does not reach it, because a lambda is a `const`. It
  is #2658.
- `--ownership=v3` refuses these programs (`later-use` at the call), so it does not
  miscompile them.
- Do not use `\|` in a `perl -e 's|…|…|'` pattern. The delimiter turns it into an
  alternation, and the substitution writes somewhere else in the file.
