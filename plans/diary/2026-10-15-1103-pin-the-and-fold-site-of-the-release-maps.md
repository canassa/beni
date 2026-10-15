## 2026-10-15 11:03 CEST — pin the && fold site of the release maps

**What I did**

Answered the re-check of PR #117. The F1 test now also builds the
reviewer's t7 program, `n > 100 && Aid.bad n`, as a second program, with
one needle on the kept call: it maps to 8:16. With only the `&&`/`||`
fold site reverted to `copyNode`, the needle maps to the `&&` at 8:13
and the test fails. I added the empty library module (`_core/Int.mjs`, 0
bytes, with a 1 584-byte map) to the follow-up issue draft.

**What I learned**

The two fold cases cannot share one program. A second `Debug.todo` call
stops `todo` being copied to either call, and only a copy shows the
position that a fold leaves: with two calls, both the `cond` and the
`&&` needles map right with or without the fix.
