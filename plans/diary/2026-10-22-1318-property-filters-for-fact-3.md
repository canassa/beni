## 2026-10-22 13:18 CEST — property filters for fact 3

**What I did**

- Built slice 5 of `plans/type-directed-points-to.md` (#722): a site's own var of a property
  is filtered by its field's key. `Emit` passes `Spec.Input.field_keys`, the key of each field
  of every record representation, and `Pts.ownField` sets the var's filter from it.
- Fixed two places that lost a site's key. `Mod.copyNode` now carries an allocation's key to
  the node it moves into. `Copy` now keeps every key, so `JsIr.closed_decls` and the rule
  behind it are gone.
- Amended `backend.md` §9 *Declared-type filtering of fact 3*. Added four `run/TypedFilterField*`
  fixtures and `emit/release/app/FieldKeyFilter`.

**What I learned**

- An arrow is keyed by what it returns, not by its type. My first version filtered function
  fields and miscompiled `SpecRecordLambda`. `TypedFilterFieldFunctions` now catches that.
- The filter alone did not stop the N = 64 merge. Two key losses hid it: an object moved into a
  call node lost its key, and `Copy` dropped the keys of any declaration the checker had not
  keyed. `step : Msg, Model → Model` is one of those, because `Msg` holds a host `Value`.
- With both fixed, the second solve on N = 64 makes 1 623 folds where it made 10 569.
  The release corpus total does not change, and only `inline/MergedChildren` gets smaller (−21 B).
