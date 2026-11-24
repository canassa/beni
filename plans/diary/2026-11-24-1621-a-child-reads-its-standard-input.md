## 2026-11-24 16:21 CET — A child reads its standard input

**What I did**

I gave `ChildProcess.run` a standard input for its child (#2023, PR #2692), as the worker `child-stdin`.

- **The check on master first.** `186237c2b4` passed `stdio: ["ignore", "pipe", "pipe"]`, and `Command` had no field for an input. A program with `input = "hello\n"` did not build.
- **The contract before the code.** `boundary.md` §9.14 got part (k) in a commit of its own: a `Command` field `input : String`, written as UTF-8 on Node's `spawn` event, and then the pipe is closed. `""` keeps `/dev/null`.
- **The code.** `platforms/node/ChildProcess.beni`: `started` writes, `inputFailed` takes `EPIPE` by its name and throws every other error again, and `closePipes` destroys the input pipe too.
- **The fixtures.** `run/ChildProcessInput` (16 cases with real children), `run/ChildProcessInputFaults` (a test platform's children: what `spawn` is asked for, `EPIPE`, a start that failed, a child that never reads) and `run/ChildProcessInputUnknownCode` (`ENOMEM` on the input pipe is a defect).
- **The skill.** `skills/beni/references/child-process.md` has a part *Send input*.
- **The owner question `child-stdin-q1`**: `input : String`, or `stdin : Input` with cases. The code has the recommended first answer. The question was open when I wrote this entry.
- **Two issues on the way.** #2690: the sibling check refuses a JavaScript method shorthand. #2691: the macOS measurement that this work owes.

**What I learned**

- **`EPIPE` cannot be a value that a program sees.** Three things can happen to the text that a child does not read. The kernel's buffer takes it (10 bytes give no error). The write fails with `EPIPE`. Or the child exits first and Node destroys the pipe with no error. Which one happens depends on the length of the text and on the order of two events. So the answer is `Ok` for all three, and `Output` has no field for it.
- **A child's pipe from Node is a socket, not a FIFO.** `/dev/null` is a character device. A child can see the difference, so an empty `input` must not become an empty pipe.
- **Node destroys `child.stdin` at the child's exit.** A descendant that still reads gets an early end of file: 146 176 of 8 388 608 bytes in one run. The platform's own destroy matters only before the exit, which is the `OutputTooLarge` path.
- **A real child cannot pin every claim.** `cat; echo end` prints the same with `/dev/null` and with an empty pipe. The review found two more claims of this kind. A fake `spawn` that notes what the platform does to the child's standard input pins them with no race. I checked each by a mutation of the emitted JavaScript.
- **A listener body can be pinned.** `ChildProcess.listen` is in `tests/corpus/ownership/word-bodies.txt` for P-sync. A change of its body fails `check_test` until the reason in `ownership-v2.md` §2.13.7 and the hash follow.
- **A sibling `.js` file must use arrow properties.** The scanner of check 3 reads `write(chunk, encoding, callback) {` as four names that the file never imports. `setImmediate` is not a web timer, so a sibling imports it from `node:timers`.
- **`SKILL.md` has 8 000 bytes and was at 7 991.** A new line there must take the place of other words.
- **The first automatic review said "No issues found" in one minute.** An `@claude` comment with four exact questions gave a review that found the weak fixtures.
