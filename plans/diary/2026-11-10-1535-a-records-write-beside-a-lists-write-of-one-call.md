## 2026-11-10 15:35 CET — a record's write beside a list's write of one call

**What I did**

- A step of #1018 (records in the ownership checker v2), on branch `own2-record-req`, stacked on #2431.
- A callee's requirement is one selection for all of its writes. #2426 split it for a list's write. The record
  half was a known limit: `twice b xs = both b xs xs` refused the update of `b` with the push onto `xs`.
- `CallReq.of` now makes two selections where the contract's own reading fails in the record pass: for a
  record's write each plain occurrence at a list's own storage is asked apart, and for a list's write each plain
  occurrence at a record's own object, as before. `Update.kindAt` and `Update.kindBelow` say a slot's kind.
- Fixture `ownership/RecordBesideLists`; one line of `RecordFoldPush.v2.ownership` moves; mutant
  `record_req_whole`.
- The owner's answer to `ownership-v2-fable-q2` came while I worked (Cesar, 2026-11-10 13:58 UTC: "A: two
  passes"). I wrote the decision into `ownership-v2.md` §2.11.5 in this branch's specification commit.
- The whole-corpus diff: the record lines that v2 refuses and v1 accepts go from 163 to 153.

**What I learned**

- I had put three items on the work list as record gaps: this one, the keep edge (a callee's result may keep
  what the caller writes later) and the fold over a list's elements. A probe of the list twin of each showed
  that v2 refuses the last two for lists too. They are limits of v2 as a whole and no work of the record pass.
  The bar for a record line is v2's own list behaviour, not v1's verdict.
- The pairs that the record reading drops each have a list's storage on one side. That is the whole
  soundness argument: a list's storage is no record's object, and a record that a list holds is an occurrence
  of its own. A slot whose kind no place says stays plain for both readings.
- The same split is missing where the requirement reaches the demand through a label's supply
  (`List.update [ { kids = k, other = k } ] 0 grow`): `Outward` joins the supply's conditions for every demand
  of the call. That is the next step.
- A header comment that grows by two lines moves every line number of a fixture's goldens and of its lines in
  the known list. I rewrote the two lines in place.
- The machine's disk was full during the step before this one (the Zig cache of this worktree held 112 GiB of
  its own, most of it from mutant builds). Check `df -h /home` before a mutant run and before the gates.
