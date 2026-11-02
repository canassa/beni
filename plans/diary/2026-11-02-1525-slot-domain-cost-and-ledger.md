## 2026-11-02 15:25 CET — Ownership v2 on the slot domain: cost fixed, ledger narrowed (#1685)

**What I did.** Continued branch `own2-slot-domain` (rebased on `origin/master`). Cost first:

- **Why the build was 6× the prototype on `removeMin`.** Profiling each phase showed it all in the read-off's
  `sepOf`, 30 565 then 75 001 records in rounds 2 and 3. The distinct check expanded a call into one entry per
  arrival per caller entry, with no deduplication (the prototype kept one entry per leaf), and grew its
  condition by a merge per entry (`unionOf`, `Cond.conj`). One entry per leaf of an expansion took generic
  `removeMin` from 120 138 to 20 266 records; gathering the conditions once took the *Fields* family from
  1.94×/2.15×/2.37× per doubling to linear.
- **Deliveries** (§2.12 step 2), `Deliver.zig`: a round opens every member's evaluation at once; a call of a
  member reads its growing draft through a *key* whose leaves only grow, and every consumer subscribes to the
  key and gets each leaf once. Conditions and labels are read from the previous round's candidates. Then a
  validation round evaluates each code plainly. `rotate` with 2…60 lists: 451, 647, 1 050, 1 761, 3 294,
  6 324 records in three rounds, linear. Generic `removeMin` 23 633, core `Dict.removeMin` 23 715, `descend`
  30 659, *Fields* 1/2/4/8/16 11 679 / 21 533 / 41 802 / 82 362 / 163 426, all growth 0. Core in 2.0–2.5 s
  Debug.
- **Soundness found on the way**, each checked against v1 and the fixture's intent: a call's other arguments
  were never its write's operands (`TakenTree`'s `List.set b 0 (Node b)` was accepted); a holder's other slots
  were never held under separation (`CallOtherPathsKeys`); a slot below a folded level was described at the
  root (`relBelow` gave up on `⟲` names; `CycleLinkReadAfter`'s stale read was accepted); a cast lost its
  element slots (`CastCallHolds`); `⟲` into a literal skipped a part on the cycle at another place
  (`FoldedWriteCall.shallowCopy`); a spread's length was taken as one (`rest ++ [ a ]`'s head was never `a`,
  `PatternPositionsStored`); a prepend was always fresh storage, never a re-cons of its base (`Prepend`,
  `PositionsSaturate`); and a self-feeding fold described itself without end (Dict and List folds hit the
  limit).
- **Precision**: apart occurrences (`s~`, a holder need only be apart from the written object), an unvouched
  call read through its parts, call uses read through the callee's footprint, the cell write at `◆` behind
  its barrier.

Ledger against old v2 over the 2 158 roots, per position: 2 541 same, **2 accepted→refused** (`List.unzipHelp`,
a selection over-asking a generic element family; `CastCallHolds` 25:9, a cast read approximately), 90
refused→accepted: 57 that v1 accepts; of the 32 v1 refuses, each read against its fixture and the code, all
are safe (footprint reads, a callee's own refused write, the selection discharged at callers, intents that
name them as known false refusals). Per demand text, 79 accepted→refused of which 77 sit at a position old
v2 also refuses at another path. Still open: three Schema declarations reach the allowance (`madeNode`,
`shapeOf`, `shapesOf`, unchecked before), per-route demand naming, the corpus expectation files, the old
engine's hidden flags, the seven requirement fixtures, the gates and the release measurement.

**What I learned.** (1) Profile by phase before theorising: the 6× was one missing dedup, not the design.
(2) Types never separate two objects here: a cast reads one object as another type, so a type filter on the
relation was unsound and is gone. (3) The per-demand ledger hides refusals behind naming (`cell` vs `cell◆`);
compare per position. (4) A live evaluation must agree with a plain one: keep a plain mode in a debug build
to diff against, since the validation round catches only what it sees.
