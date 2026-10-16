## 2026-10-16 03:14 CEST — Ownership O1: the corpus, and the precision rules

**What I did.** Slice O1 of `ownership-checker.md` §30.7 (issue #210), on top of #200's
`--ownership-everywhere`. The corpus first, by the owner's decision of 2026-10-16: the three identity
tests (`ListIdentity`, `ListIndexedIdentity`, `WriteRowsIdentity`) deleted; the four persistence tests
rewritten with `List.copy` where a version is kept, each with a rejected twin in `check/bad/direct/`;
the top-level lists the other fixtures wrote made by functions, or copied where the test is about the
constant itself; `QueuedListSnapshot`'s command keeps a `List.copy`. Then the checker limits, each as a
red pending fixture (CK-234 to CK-243) and then a general rule in `src/own/` (§30.9): function slots
and passes inside lambdas (which also fixes #212, a pass inside a lambda that dropped the callee's
`need`); nested env calls; send values are not lists; custom types hold what their constructors hold;
supplies probed cell by cell, with captures of the frame named and borrowed and an empty borrowed
supply handing nothing; what a callee relies on of the declaration's own function or of an enclosing
lambda's parameter is decided where it can be; carried lambdas call what the caller passed;
point-free names; the entry checks `onUrlRequest`/`onUrlChange`; `need` labels approximate where only
an approximate step fails. Words on `Task.timeout`, `Task.raceOk` (a `List` of functions now takes a
function's words) and `crossing Int32`. `bench/ownership-everywhere.mjs`: 31 of 835 programs rejected
became 3 of 840, and `browser-tea`'s two `Tea.application` lines none. The Lean bridge at its CI bound
is unchanged against master: 6 leads, all unconfirmed, the same ones.

**What I learned.** Three of the "limits" were holes, not limits. A pass inside a lambda dropped
`need` (#212); the entry never looked at the URL taggers (CK-243); and a slot call inside a lambda was
§6.1's conservative call, whose result counts as made by the call — so a loader answering a top-level
list was *accepted*. The last is general (#216): any call of a function value with no class claims a
fresh result. Two programs are not limits at all, or not ones words can fix: `RefModify`'s `Ref` value
is shared state by design (#219), and `Schema.parse`'s answer depends on which direction a mapping
function runs in, which one word cannot say (#218). And two pending pages, once their ownership lines
went, showed `browser-direct` defects of their own (#217). A red `test-pending` fixture of the
ownership kind with a `.platform` needed the harness to accept per-platform goldens.
