## 2026-10-19 10:08 CEST — admit a write through a field in the flat fragment

**What I did**

- The push receiver of `FlatANF0` is any atom (it was `FlatAtom`: an integer or a variable), so `push r.0 x` is in the fragment. `FlatAtom` and `Atoms.flat_atom_list` are deleted; `push_preserved` takes the receiver from `Fields.flat_atom_list_path`. No other proof changed: the demand is the real one on the projected list's cells, and `live_path_apart` already kept every array of a live projected value apart from the written root through the Dead test. Part of #165, after #375.
- Folded the review notes 1 and 2 of #375 into README, COVERAGE and PROOF-PLAN: `FlatANF0` puts no condition on an atom, typing fixes the atoms; no program `check` accepts at the default inference fuel reaches `shared_deep_failure`, and `flat_preserved` is generic in the fuel, so the lemma stays.
- Probes `fieldWrite` (a push through two field levels with the record live at another field: accepted, one in-place write, both runs end at `{[1, 7], [2, 3]}`) and `fieldWriteLive` (the written field live afterwards: refused by the Dead test, the two runs differ), with kernel proofs that put both in `FlatANF0`.
- `lake build`: 10,027 constants, the 4 pinned `sorryAx` dependents, 62 files, 3 sorries, every `#guard` passes.

**What I learned**

- The #375 lemmas were already path-generic. The variable restriction on the push receiver cost nothing to lift: the proof of `push_preserved` used four facts of `flat_atom_list` that `flat_atom_list_path` did not give (the key, the three lookups), and none of them.
- A case arm `| push _ =>` fails when the constructor loses its argument ("Too many variable names provided"); the arms in `flatExpr_default_uses` and `flat_uses_typed` needed the same edit as the probes.
