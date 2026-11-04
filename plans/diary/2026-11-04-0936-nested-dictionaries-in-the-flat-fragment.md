## 2026-11-04 09:36 CET — Nested dictionaries in the flat fragment

### What I did

- Opened #1840 (part of #522 and #165) for the gap that #1808 left: a list
  of dictionaries and a dictionary of dictionaries were outside the flat
  fragment of the Lean ownership proof, because `DictFree` kept a dictionary
  out of a list element and out of a dictionary's value.
- Showed the gap on master `eec7712e0d` in a scratch Lean file: `check`
  accepts both shapes, both runs agree, and `¬ FlatANF0` holds for both.
- Removed `DictFree` from `FlatType.list`, `FlatType.dict`,
  `FlatANF0.literal` and `FlatANF0.dictEmpty`.
- Moved the list cases (`literal`, `push`, `at`, `set`, `copy`, `prepend`)
  and the dictionary cases (`dictEmpty`, `dictInsert`, `dictRemove`,
  `dictGet`) to the element's representation. They now conclude at the
  result's representation, as `Preserved` asks.
- Added transport lemmas in `FlatFragment/Fields.lean`: `pathKinds`,
  `pathKinds_entryAbstract`, `deepExclusive_entryAbstract`,
  `storeExclusive_entry`, `storeSpines_entry`, `storeCertificate_entry`,
  `entryAbstract_stored`, `entryAbstract_stored_dict`,
  `entryAbstract_fold_join`.
- Added six probes in `Trace.lean` (three accepted, three refused by the Dead
  test with different runs) and two trace theorems through
  `accepted_flat_anf_traces_agree`.
- `scripts/audit.sh HEAD` passed (9 min 53 s), `lake build` passed
  (4 min 20 s, the same 4 `sorryAx` dependents).

### What I learned

- The checker's store tests read an abstract only through its paths' cell
  lists, their container kinds and deep exclusivity. `entryAbstract` keeps
  all three, because a dictionary entry adds a field step only below an
  element step. So one lemma about `pathKinds` carries every store test to
  the representation, and the runtime half of each case did not change.
- `rw` cannot match two `fun (_, old) => …` lambdas from different
  declarations: each has its own matcher. Apply a lemma to the hypothesis
  instead (`entryAbstract_stored … resultEq`); application checks by
  definitional equality, which sees through the matchers.
- `simp only [← xDef] at h₁ h₂ …` renames a representation abstract to the
  old name in every hypothesis at once. The locations must stay on one line;
  a wrapped list of locations does not parse.
- The case statements were the only thing that `DictFree` protected:
  `entryType t` holds no dictionary, so the old proofs already covered every
  representation type.
