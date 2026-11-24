## 2026-11-24 05:04 CET — A lambda reads its captured field after its record

**What I did.** Fixed #2658. With records written in place, a lambda that is a `let` item's value and
reads a field of a record that a later item binds had its eager read (§31.6) placed at its creation,
before the record existed: `const $t = p.n;` before `const p`, a `ReferenceError` on node
`--records-in-place` and on browser-inline. The checker (`closure`, the lambda branch) now sends a capture
of a local that is not bound yet to `resolveLate`, as #2620 does for local functions: the read is placed
just after the item that binds the record. The lambda is not moved. Its body names the temporary before
its `const`; `hoistedRead` reserves that name ("pending") and `placeHoists` binds it. Spec: §31.6, §31.10,
§31.14 amended. Tests: `run/RecordReadLambdaBoundAfter` (`.in-place`) and
`browser/inline/RecordReadLambdaBoundAfter`; both fail with the fix reverted.

**What I learned.**
- The lambda need not move. `let_forward_reference` refuses any naming of the lambda between its item and
  the record's (a record field, a list, a call), and refuses a lambda in a nested block or inside a record
  that names a later local. So the lambda runs only after the record's item, and the temporary is bound
  right there. A closure may name a later `const`; the dead zone is only at access.
- browser-inline lowers an `update` arm twice in one naming generation. The first version of the fix
  reused the first copy's temporary in the second copy, and the page threw `$t$12 is not defined`. A row
  that is bound but not pending, met in a lambda's body, is an earlier copy's, so each copy reserves its own.
- A sleep between a lambda and the record it reads fails under spreads too, on master (#2663). In
  `--release` it can print a wrong answer (`undefined`) instead of crashing.
