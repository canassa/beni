## 2026-11-10 18:21 CET — a block takes its result off the pending operands

**What I did**

- The fix of #2449, on branch `own2-let-result-pending`, from `master` (it does not depend on the #1018
  stack).
- I read the record lines that checker v2 refuses in `browser/tea/BallMachine`. Two were `held-operand`: "the
  value at 411:13, evaluated before it, holds it until its consumer runs". The value was a tuple that an `if`
  arm returns, and a pattern had taken it apart many lines before.
- A probe with the list twin gave the same refusal on `master`. So it was no defect of the record pass: it was
  a list line that refused a valid program.
- The arm had a `let` of its own. Without that line the probe was accepted. The walker's `.let` returned its
  body's value and left the body on the stack of pending operands. A `case` removes each arm's operand.
- The fix is one statement. Fixture `ownership/ArmLetResult`; mutant `block_result_pending`.

**What I learned**

- Reduce the program until one line decides the verdict. My first probe had no `let` in the arm and was
  accepted, and I almost filed the page's lines under "a limit of the list domain".
- A refusal with an odd reason is worth a probe of its list twin. Three times today the twin showed that a
  record line was the list domain's. This time it showed a defect that `master` has.
- A fix that does not need the stack goes on a branch from `master`. It can merge today, and ten pull requests
  do not wait in front of it.
