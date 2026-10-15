## 2026-10-16 01:07 CEST — a write to a top-level list in main

**What I did.** Looked into #199, where a private top-level list written from `main` is
accepted as `call` but rejected `top-level` when the write is in a function. I built the
minimal programs and ran `dump --stage=ownership` on them. The acceptance needs `xs` to be
read exactly once in the module. With a second read (`List.sum xs`) the same write in `main`
is rejected `top-level`. So the acceptance comes from the 2026-10-15 *initialization
transfer* amendment, not from a special case for `main`. I also tried an alias that is read
later, a read in a local function, a public destination written by a function, and a read
of a `let` binding that is used again. Each one is rejected. `InitializationTransfer`
already pins both halves of the issue (`branchRead` is accepted, `functionRead` is
rejected), and §26.7 records that the Lean oracle models the transfer. Nothing changes in
the compiler. I added a dated clarification under the amendment so that the rule can be
found from the `top-level` cause.

**What I learned.** When the transfer applies, the report gives the cause `call`, because
the read is the instantiated result of a summary. That makes the rule hard to find from the
report, and it is why the issue looked for it in §23. The question to ask of a write like
this is whether any reader is left after it. A count of "where is the write" does not
answer that.
