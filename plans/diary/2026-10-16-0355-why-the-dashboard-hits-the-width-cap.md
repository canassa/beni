## 2026-10-16 03:55 CEST — why the dashboard hits the width cap

**What I did.** Investigated #220. I reproduced the N=256 refusal with the research repo's
own generator (`./rr generate shared-components beni-direct`). I then measured summary
widths with local instrumentation in `normalize`/`coarsen`, which is not committed, and
built a second beni with the cap set to a million to price full precision. The findings
are posted on #220.

**What I learned.** `limit width` never fires. §16.7's *coarsening* does, already at N=16,
and it also runs silently on Conduit's `update` and on core's `Schema.runRoot`/`run`/
`descend`. The rejection comes from the cut merging each model list with its elements,
which hold the decoded host value and `⊤`. That is why the message blames JavaScript and
suggests a `List.copy` the app already has.

The width that matters is 3 paths per list-holding model field. It has to grow, because it
is the model type's size, so a cap of 64 counts the wrong thing. The parts that multiply
are paths into a host `Value`, spelled five ways through the decoder's `#Just`/`#NonNull`,
and read-off's pairwise spine conditions. The pairwise conditions make the uncapped pass
quadratic: read-off is 94% of a 21 s pass at N=1024.

Full precision is cheaper than coarsening at N=256: 1.4 s and 300 MB, against 2.8 s and
2.3 GB today.
