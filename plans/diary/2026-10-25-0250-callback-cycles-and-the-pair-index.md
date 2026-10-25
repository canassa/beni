## 2026-10-25 02:50 CEST — Callback cycles and the Dict pair index

**What I did**

Fixed #968 in this PR. `Dict.merge` hands each of its three callbacks what
the others returned. Three walks cut such a chain only at the callback
itself: the result instantiation, `returnsOwned`/`provOwned` and
`callbackLoanDemands`. Every lap therefore went one level deeper, up to the
`callbacks` limit of 4. The callbacks of one call now form one cycle. Their
results are one least fixpoint (`InstCtx.outer`). Whether each returns owned
is one invariant (`ro_guards`). A loan demand that is already being followed
is not followed again (`loan_chain`). The limit is unchanged.

The adversarial review found that the ownership guard ignored which part of
the result was being established. A callback handed a component of its own
result was then assumed owned, and that component could be a top-level list.
Master had the same hole with one callback. The guard now carries
`ro_within`, and `ownership/CallbackComponentGuard` pins both shapes.

On draft #961 the `Map` index now maps a key to its entry pair (the owner's
decision in #973), and `Dict.keyAt` is added. The #958 message no longer
offers a copy that does not fix the refusal. #474's three pending fixtures
are refused as they specify, so they moved to the corpus.

**What I learned**

A cycle cut has to match the whole question it answers: callee, callback,
written place, extent, and the part of the result. Dropping any one of these
turns an assumption into an unsound answer.

A diagnostic's fix must be a program the checker accepts. Two reviews found
the shared-values advice failing on its own fixtures (#987, #977).

An `Int` can hold a fraction, so every index read in core needs a
whole-number check (#988).
