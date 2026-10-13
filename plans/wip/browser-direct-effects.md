# Direct browser effects — work in progress

The owner requested this WIP push on 2026-10-13 so the reproduction and attempted
implementation survive outside the Mac's staged tree and `/tmp`.

`browser-direct-effects.patch` preserves the attempted implementation, including
its draft dated specification. It was captured against commit
`c1e422284ffbb5ff5e98ca39ecaac8031564aebe` before the blocked implementation was
removed from the working tree. Apply it to that base in a separate checkout; it
is not a patch against this branch's newer blocker amendment.

The attempt is unfinished and has not passed compilation or gates. Checking the
embedded direct platform rejects three driver appends as `list_may_be_shared`:
`keyed`'s Concurrent arm, `keyedNow`'s Concurrent arm, and `want`'s tap append.
The staged implementation had not yet reached behavioural validation, and may
contain additional defects. No claim of completed effects support is made.

The reduced pending reproduction and passing browser-tea oracle are committed
as ordinary fixtures. Their focused checks passed with pinned Node 24.19.0.
The full `zorg build gates` run failed in four existing tests on this Mac: two
case-sensitive-path assumptions and two cache-pruning CPU-budget overruns.
The owner explicitly authorized committing and pushing this work in progress
with those failures recorded. Nothing is merged and no PR is opened by this push.
