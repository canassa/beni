## 2026-11-03 21:47 CET — dictionary entries through the type

**What I did**

- Reproduced the witness of #1796. The checker accepts a dictionary of lists,
  but no naming covers its result through the checker's abstract
  (`StatementChecks/DictEntryPaths.lean`, `no_cover`).
- Added the relation through the type, the owner's option 1: `entryPath` and
  `entryAbstract` in `Soundness.lean`. An abstract dictionary element step
  maps to the concrete element step and field 1. `Covers`,
  `CertifiedExclusive` and `Describes` keep their definitions. The clauses of
  `Invariant`, `CallSound`, `LinkedWritesCovered`, `summary_sound`,
  `map_summary_sound` and `invariant_preserved` read through the type. The
  checker and the interpreters did not change.
- Proved that one naming describes the witness through the type (`cover`,
  `certified`, `described`).
- Slice 3 of #522 in the same pull request (Jayson, `ownership-proofs-q8`):
  `DictFree`, `FlatType.dict`, the five dictionary forms in `FlatANF0`, the
  heap clauses of `FlatInvariant` at the representation, and the five cases
  in `FlatFragment/Dictionary.lean`. Probes `dictOps`, `dictValueWritten`,
  `dictBranch` and `dictInRecord`. The witness is in the fragment
  (`program_flat`).
- Checks: `scripts/audit.sh HEAD` passed in 702 s. `lake build` passed in
  251 s with 11,333 constants and the same 4 `sorryAx` dependents.

**What I learned**

- The abstract alone cannot tell a dictionary from a list of pairs. A type
  is necessary to read a dictionary on the heap.
- Keep the static clauses at the source type and the heap clauses at the
  representation. Then a type with no dictionary is its own representation,
  and the old case proofs stay as they are. Only the cases that can see a
  dictionary need the new lemmas.
- An insert is a push or an in-place set. `dictPut_split` gives both as
  `as ++ e :: bs` from `as ++ mid ++ bs`, so the push's certificate lemmas
  serve both with one proof.
- A remove keeps a sublist of the old footprint. Thus the old certificates
  give the new ones directly (`filtered_footprint_nodup`, `_once`).
- The audit rejects an equation lemma that two modules realise on their own.
  Put a new lemma inside the existing import chain.
- `dictFocus` needs the scope summaries of #165 step 3. It stays outside the
  fragment.
