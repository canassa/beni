## 2026-10-22 04:24 CEST — combined solver slice 5: fact 3 into the extraction

**What I did.** Issue #649, in three PRs.
- #650: facts 4 and 5's fields and returns became columns of fact 3's own `Prop` and `Site`, and decided conditionals are read off `memo`, so `prop_lat`, `ret_lat` and `decided_conds` are gone.
- #671: fact 3's constraints, guards with their kill lists, and the walk's side steps are extracted in the recording walk's own order and replayed. The replay equalled the recording walk on the whole corpus, every site numbered alike.
- This PR deletes the recording walk, `byUnits` and `max_pts_sweeps`. The order check becomes a shuffled replay, which passes on the whole corpus unbounded.

**What I learned.**
- The recording walk made one choice at run time: it noted a member read's guards only when the read's object was not `top` at its first evaluation. That choice decides copy against join in `copySource`. The replay has to keep the guards open and decide at the first evaluation; the extraction cannot decide it.
- With its node limit lifted, the old shuffled-order check failed on four programs. It was comparing storage rather than effective facts (#657, fixed by #661).
- The 16 400-arm case's peak RSS is bimodal (about 76 or 90 MB at 32 jobs) with any compiler. Compare its distributions, not single runs.
- dagon's disk filled up twice during the session.
