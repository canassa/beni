## 2026-11-02 18:07 CET — own2: soundness holes from the accept rows

**What I did.** Started #1685's naming step: v2's virtual-call demands are named
by their outer callee and the argument that supplies them, a closure's `once`
demand as `once <capture>`, a captured write by its local. Then reviewed every
"v2 accepts where v1 refused" row against v1 instead of trusting the earlier
oracle, and wrote a sanitiser probe for each suspicious one. Seven probes
trapped or printed a wrong answer; each defect is fixed on
`own2-slot-domain-tests`:

- a closure that writes its own parameter and escapes to a pessimistic callee
  (`List.foldl xs [] λx acc → List.push acc x` under v2's core): new
  `src/own2/Closures.zig`, §2.11.4 amended;
- captures bound at the body's point, so a capture written and read again in
  its closure was no later-use;
- `named = λ⊤ → shared` called through the declaration's own code;
- a call whose arguments and result cross recorded no use of its callee, so a
  closure called after a write of its capture was not live;
- `once` was never enforced on an escape, two labels of one slot, or a capture
  by another closure;
- a record field call fell into the comparison contract; a schema member used
  as a value read a "fresh" row although a `via` conversion may answer a
  top-level list (§2.11.5 amended);
- a callback's answer was apart from what its label was supplied.

Also: a record update's base is held only at the fields the update keeps
(§2.8), which was refusing the TEA update at about 240 corpus positions.

**What I learned.** The 161-probe oracle tested the cases the earlier lanes
thought of; the accept rows are the better map of where to look. Of the 96
rows, about a third were real holes. The remaining lone rows are path
precision with probes already (FoldCertificate, CallOtherPaths, Apart…), or
relied-on requirements (SplitCallSupply), or S7 (entry).
