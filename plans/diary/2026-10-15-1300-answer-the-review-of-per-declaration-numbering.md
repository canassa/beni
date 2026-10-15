## 2026-10-15 13:00 CEST — answer the review of per-declaration numbering

**What I did**

Answered the review of PR #129. Applied the reviewer's fix that keeps the
release printer's "declared twice" bit (`Opt.Plan.repeated`) per
declaration statement instead of per name for the module, so
`emit/release/tea/HttpSendTracked.js` is master's bytes again. Corrected
three sentences of the new `backend.md` §4 text. Added two red pages under
`tests/pending/browser/dom/` (CK-232) for the reviewer's finding that a
markup lowering's compiler-made name can be a user's local, and asked the
owner how to keep the two apart (`emit-cache-q4`). Rebased #129 onto
master `7ff72c031`, recorded every run hash again, and rebased #122 onto
the same master.

**What I learned**

With the fix, every release build of 652 corpus programs is byte-identical
to master's, and development builds differ only in the numbers of
compiler-made names. My normalised comparison could not find the
collision: no corpus program holds one, and a proof over the corpus only
shows what the corpus holds. Master's last `browser-direct` change left
four `page_fuzz_test` scenario hashes unrecorded, so the gates on a branch
of master run those four under Node.
