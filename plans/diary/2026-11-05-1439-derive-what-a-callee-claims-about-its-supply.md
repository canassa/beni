## 2026-11-05 14:39 CET — Derive what a callee claims about its supply

**What I did.** Replaced `SupplyRead` with the fact the manager pointed at: a label's supply now publishes `below`, the
distinct check over the value handed at each direct call (`SupplyCond.zig`, block version 21), carried through passes
and forwarding lambdas, and asked only by a write below the root. `EntryHeld` walks a closure's captures.

**What I learned.** Reading multiplicity at the caller could not work: the contract has no place for it, so each fix
closed one route. A single `sep` could not carry the fact either: a root write reaches one object and must not pay for
what is below it, which is why `chain xs identity λl → List.push l 3` was refused until the two meanings became two
fields. A fixture holding several routes is not proved by an old binary refusing it, because any one route refuses the
whole program; the mutation that removes the rule is the proof. I twice wrote a green twin that was wrong: a closure that
holds `a` and may run again really cannot edit it, and that refusal was right.
