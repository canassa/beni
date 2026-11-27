## 2026-11-27 09:34 CET — A child's input is a type of cases

**What I did**

The owner answered `child-stdin-q1` (Cesar, 2026-11-27 08:14:53 UTC) with the option I did not recommend. I changed #2023's work (PR #2692) to that answer, as the worker `child-stdin`.

- **The answer.** The `Command` field is `stdin : Input`, with `type Input = NoInput | Text String`. `command` gives `NoInput`. The entry of 2026-11-24 16:21 describes the first shape, `input : String`, which is gone.
- **The contract before the code.** `boundary.md` §9.14 (a), (h), (i), (j) and (k) have the new shape, in a commit of their own. (k) has a new rule: `Text ""` is an empty pipe, and not `NoInput`.
- **A correction in (f).** The first text said that a write that fails does not fail Effect's `string` or `exitCode`. Effect's source shows only a fork with no join, and its tests have no such case. The text says that now.
- **The code.** `options` asks Node for a pipe for each `Text`. `started` matches on the input and ends the pipe for each `Text`, also an empty one.
- **The fixtures.** `ChildProcessInput` has three new cases with real children: `Text ""` to a child that exits and reads nothing, and what `[ -c /dev/stdin ]` says for `NoInput` (a device) and for `Text ""` (not a device). `ChildProcessInputFaults` expects `pipe` for `Text ""`.
- **Two new mutations of the emitted JavaScript**, each of which fails the two fixtures: `ignore` for `Text ""`, and no `end` for an empty text.

**What I learned**

- **A second option can change behaviour, not only a name.** With `input : String`, an empty text never made a pipe. With `Text ""` it does, so `child.stdin.end("")` on a real pipe was new and I had to measure it.
- **Node writes an empty text.** `end("", "utf8")` calls the stream's write with no bytes. On a child's pipe that gives no error (four scripts, 150 runs each). It gives `EPIPE` when the child has exited, or has closed its standard input, before the `spawn` event is handled (60 of 60 runs with the event held back for 200 ms). The listener that takes `EPIPE` covers the empty text too.
- **The same 10 bytes can be two of (k)'s three cases.** With the `spawn` event at once, the kernel's buffer takes them and there is no error. With the event held back until the child has exited, the write fails with `EPIPE`. This is more evidence that the answer must not say how much the child read.
- **A real child can show `/dev/null` and a pipe apart.** `[ -c /dev/stdin ]` is true for `/dev/null` and false for a pipe. The check uses only that a pipe is not a character device, so it does not pin that Node's pipe is a socket.
- **The P-sync hash covers more than the body.** `ChildProcess.listen` kept its body, but the type of its third parameter changed from `String` to `Input`, and `check_test` asked for a new hash. The reason in `ownership-v2.md` §2.13.7 stays true as it is.
- **A checklist written before an answer can be wrong.** My report said to put the change for this answer into one commit. The task wants the contract before the code, so there are two.
