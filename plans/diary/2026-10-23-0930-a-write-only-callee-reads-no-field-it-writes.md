## 2026-10-23 09:30 CEST — a write-only callee reads no field it writes (#405)

**What I did.** First precision fix of R4 (#315). At a call, a summary entry that only
writes a record (`W{F}`, no `R`, no `E`) became a use with the written fields as its
exception set, as an update's base use is, instead of a use of the record whole. The
TodoMVCs' `changed model (List.map model.todos …)` and `commit`'s `changed closed …` are
accepted: 27 rejected record lines go across the corpus, the examples and the benches,
and none appears. No list line moved. `ownership/RecordWriteOnlyCall` pins the accepted
shape and two callees that read the written field and stay rejected; it is red on master.

**What I learned.** The callee's own reads of the other fields are already their own
entries (`π1.editing R`), so the write's entry never needed to stand for them; only the
summaries' `RW{F}` for such a parameter became `W{F}`. `W{}` (fields a block could not
name) stays a whole use.
