## 2026-10-26 03:30 CET — Ownership v2 S2: the review round

**What I did.** Answered the adversarial reviews of #1036 and #1037 and the
direction review's S2 items in two commits. κ left the `NodeId` column for
an immutable persistent map its holder owns (`Cond.Kappas` = `Ids.KappaId`):
a class carries `kappas`, `join` builds a new snapshot and never writes a
member's, `propagate` reads the members' maps, a union's κ is derived on
every read, `kappaLeq` simulates over node pairs. Atoms are per path: a
projected leaf at a summary position derives `apart` and `excl` (for
arrivals that stand for many positions), a plain path is `yes`, and the
position itself compares the members' `reach`, so `[ (a, b), (b, a) ]` is
`shared` at `[*]` while each component is `apart`. `lower` is incremental
(W fresh pushes O(W log W), measured), supplies are keyed by label with
the handed value's snapshot, sorted runs merge in one pass, and the normal
form spells each sorted item in its own context. Liveness lanes are keyed
by the use's source atom and the phase, path nodes by their own atom,
`Ancestry` by the region's settlement lane; queries charge every region
and path step before reading it. `Rows` keeps v1's `List`-of-functions
rule and composes derived `eq`/`compare` from the components' classes.
Fault-injection tests sweep every allowance from 0 for each operation.
The design edits moved out of these PRs: #1038 rewrites the document.

**What I learned.**

- Interned nodes cannot own ANY mutable fact — not use labels, not κ. The
  first symptom (labels) was fixed locally; the second (κ) needed the
  representation change the reviewers asked for. When one structural fact
  about a table forces a change, look for every other place that assumed
  the opposite before the next review does.
- "Per path" is the sound reading of κ, but the position node must still
  see every object its members hold below it, or sibling-component aliases
  (`[ (a, b), (b, a) ]`) hide behind two true per-component atoms. The
  holder check is the other half; κ alone never certifies that write.
- A sorted run's spelling for a canonical form must not borrow ordinals
  from the enclosing DFS, or storage order reaches the bytes.
- A lane atom is a SOURCE identity: a sorted index, an input position or a
  frame-local counter is not one, and the phase is part of the key.
- `perl -0pi` with `|` delimiters corrupted a file header three times in
  two sessions; it is banned from my toolbox for multi-line edits.
