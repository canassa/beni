## 2026-11-27 16:51 CET — browser-inline keeps no record to compare

**What I did**

- Fix lane fix237 on `ownership-v2-design-review` (base d144411a2e), #2729. In the build users
  get on `browser-inline` (records written in place where v3 accepts them), a `Show` keyed by
  identity kept its body after `update` wrote the shown record in place; the copying build and
  `browser-tea` made a new body. The committed golden of `browser/inline/ShowAndBranches` held
  the in-place page (line 139). It now holds the copying page.
- The cause was the runtime: `keyShown` kept the record as the region's key and compared it by
  `===`, which `boundary.md` §9.4.8 forbids and rule 8 forbids. The fix is in the lowering and
  the write-set pass, not the checker. The pass now records a selector on a `Show` keyed by
  identity: the anchored reads of the `Just`'s payload alone (`Writes.recordEdgeSelector`).
  `programHole` hands it out (interface 1.45). For a value that is not primitive-`eq` and not
  identity-safe, the lowering keeps no key: the `Show` uses `armShown`, and a renewal entry in
  the selector's read set, just before the `Show`'s entry, marks the body to be made again
  (`renew`). So the decision is the source's write set, the same in every build.
- A `For` keyed by reference over items that are not primitive-`eq` matched rows by keeping each
  item in a `Map`: the same breach, and no write set can say which row is which. It is now class
  1 with a fix (`keyed={.id}` or `keyed={False}`); the permanent answer is the owner's (#2504).
  No page of the corpus keys such a `For` by reference.
- Specified first in `browser-inline.md` §8.2 and §9, `boundary.md` §9.4.6 (1.45) and §9.4.8,
  `write-sets.md` (*a `Show` keyed by identity*) and `language.md` §11.18. Pages
  `browser/inline/ShowIdentityWrites` and its `browser/tea` twin; `build/bad/inline/ForByReferenceRecord/`.

**What I learned**

- The write set is exact enough for a `Show`: a record field write conflicts with the payload's
  read, a write of another model field does not, and a node write of the `Maybe` around the same
  payload does not. It over-approximates `Maybe.map model.user (λu → u)`, which makes a new body
  where `browser-tea` keeps it; that is the one listed difference.
- All 447 `browser/inline` and `browser/prerender` pages under the five legs: 423 SAME, 22 REFUSED
  (the same refusals as the base), 2 PLAINFAIL (`NavigateCommands`, as on the base), 0 faults.
  The base had one TRAP (`ShowAndBranches`).
