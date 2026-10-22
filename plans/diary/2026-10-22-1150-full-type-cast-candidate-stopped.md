## 2026-10-22 11:50 CEST — Full type cast candidate stopped

**What I did**

Read #286 and ownership-checker.md §16.7, then started from origin/master
`9c9de7a66` in an isolated dagon worktree. Wrote a dated proposed amendment
before implementation. Proved the red-first FullCast fixture: master reports
identical unmarked provenance for reads as List Int and List String. Tried a
full structural type key, cast path step, returned-edge handling and summary
encoding. The candidate compiled, but core preflight newly refused safe Schema
code, beginning with run c at Schema.beni:2109:35. Stopped under the owner's
explicit precision rule and reported #712 on #286. No implementation PR or
merge, and no green candidate gate result.

Preserved the patch, fixture, baseline binary/report, failure logs and source
hashes on dagon at ~/worktree-evidence/beni-full-cast-f2/. Restored implementation
files before this documentation commit. Removing the worktree and /tmp files
after pushing this record; the evidence directory and shared cache remain.
All edits, builds, commits and pushes happened on dagon, inside the flake shell
for builds, using the self-hosted compiler. No measurements, cap changes, weakened
checks or budget raises.

**What I learned**

The initial candidate changes Schema's precision before its own fixture can
run: core_pack refuses approximate writes through c.fail cast as Maybe Js.Value
and Nullable Js.Value. This is evidence against that candidate, not proof that
full-type markers cannot work. Physical identity at trailing casts, folded
occurrence conditions and portable variable identity still need review; the
candidate is not a complete or sound implementation claim. F2 remains open.
