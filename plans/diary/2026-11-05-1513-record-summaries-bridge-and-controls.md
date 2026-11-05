## 2026-11-05 15:13 CET — W{F} in the oracle, the record bridge and the record controls

**What I did**

- Worker `own-record-bridge`, #1872 (slice 3 of #316). The Lean oracle's summaries now
  name the fields that a record write updates (`Summary.fieldWrites`, `W{F}`,
  `ownership-checker.md` §31.7). A call demands such a row with the update's Dead test
  per field (`rowDemand`). `calleeKept` is accepted; a callee that reads its written
  field still makes the earlier write refused.
- The owner decided `own-record-bridge-q1` (Jayson, 12:35 UTC): `CallSound` gets a
  fourth clause, `fields`. `summary_sound` claims more and stays `sorry`; the falsifier
  checks the clause on a generator v7 campaign.
- The bridge spells record objects as beni records and compares the `update` lines at
  their sites. The record probes are a fixed family. Generator v7 and the targeted
  product draw record objects. Three controls (`record-dead`, `update-base`,
  `call-fields`) have fixed witnesses and the targeted product catches each.
- Opened #2008 (a Zig over-refusal of a once lambda that reads and updates its
  captured record) and #2010 (v7 in the long bridge campaign).

**What I learned**

- `Summary.writes` must keep every written cell. A refinement row that only narrows it
  keeps every old reader conservative, and `CallSound.writes` true. Putting record
  writes in a separate row would have made clause 1 false for them.
- The flat proofs unfold `demand` in a few places only. A `recordDemand` that differs
  only in what it records needs one lemma (`recordDemand_success`), and the update's
  proof reads the whole demand from the same state.
- A structure literal in a `#guard` cannot continue its fields on a less indented
  line; a `def` is the easy way out.
- The bridge's `demands` array carried the record lines as a property, which
  `JSON.stringify` drops. The evidence now writes them as `updates`.
- Most record differences between the two checkers are on purpose: 23 of 24 record
  leads are Zig's hoist, which the oracle refuses by the owner's decision of
  2026-11-04.
