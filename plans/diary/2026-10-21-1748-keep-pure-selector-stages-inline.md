## 2026-10-21 17:48 UTC — Keep pure selector stages inline

### What I did

Implemented #621 against the reviewed helper correction, then joined the
parent view-helper branch without rewriting history. The release fixture
`PureSelectorStage` fails before the correction and passes after it: a
pure Bool selector remains directly in its arm-index call.

The checked-effect visitor now accepts the same omitted arm bodies and
skipped definitions as branch lowering. Only an index initializer asks
about this projected expression. Whole-expression queries, other branch
modes, helper argument retention and the optimizer keep their rules.

### What I learned

The original arm markup is conservatively effectful, but its replacement
numeric index does not evaluate that markup. Protecting the index temporary
using the original whole expression unnecessarily prevents release inlining.
The helper runtime controls, including hidden empty results with a logging
selector, unused effectful arguments and guarded throws, remain green in
both modes. Full hashes, gates and pending qualification are recorded in
the pull request. This changes no totality policy; #618 remains with the
owner. No size result is claimed before measuring the qualified compiler.
