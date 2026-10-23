## 2026-10-23 21:55 CEST — correct the counts of slice 2a

**What I did**

- The review of #884 (four Low findings), in one commit. The two lemmas nothing used, `counted_write_preserves_binding_types` and `literal_preserves_binding_types`, are deleted; the PR body and PROOF-PLAN's *As built* for 2a say so. PROOF-PLAN's plan paragraph no longer says that every statement stays: the public theorem, `flat_preserved` and the case theorems keep their statements, fourteen lemma headers and the two constructors of `AllocatedFlatValue` change. "The theorem admits more heaps" is gone: `flat_preserved` and the case theorems take a weaker hypothesis, and `accepted_flat_anf_traces_agree` starts from the empty heap, so it admits no new heap. The docstring of `FlatInvariant` and COVERAGE say that the relation makes no claim about the contents of an array that no binding holds, except through the observer witness. The stale "flat heap" comments in `Frame.lean` and `Fields.lean` name `IntegerFrame`, and the 2026-10-16 *As built* in PROOF-PLAN points at 2a.
- A correction of the entry of 2026-10-23 13:57: "Eleven lemmas lost their heap premise" is wrong. Eight lost it (`arrayAt_flat`, `reaches_flat`, `corresponds_ref_frame`, `corresponds_flat_frame`, `named_cellsAt_of_covers`, `describes_mapOrigins_shared`, `describes_join`, `valueTyped_of_allocated`); six took `IntegerFrame` in place of the flat-next-heap pair (`valueTyped_after_flat_heap`, `bindingsTyped_after_flat_heap`, `describes_flat_frame`, `described_flat_frame`, `named_flat_frame`, `flatInvariant_heap_frame`), and `allocated_frame` replaced `allocated_mono`: fourteen changed headers after this commit, sixteen before it.

**What I learned**

- A count in a diary or a plan is checked against a header diff of the declarations, not written from memory: the review compared all 639 headers of the fragment with a script and found three wrong numbers in mine.
- "The theorem" needs a name: a weaker invariant weakens the hypothesis of the preservation theorems, and says nothing new about a public theorem that starts from the empty state.
