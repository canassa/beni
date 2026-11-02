## 2026-11-02 20:26 CET — own2: recursive labels, a distinct-check cycle, imported arrival order

**What I did** (branch `own2-soundness-4`, on `own2-v2-core-blocks`; no PR)

- #1721: a label's `calls` now adds up its sources in one frame (`Eval.factsOff`). A direct call counts one. A
  passed-on callee label counts its own `calls`. Two sources are many. Before, they were joined with max, so a
  recursive function that calls its callback and hands it to itself (`mapHelp`, `List.initialize`'s helper, an
  app's `myMap`) had a `once` label, and a closure that writes a capture was accepted under it. The sanitiser
  trapped. Spec §2.11.3 amended. Fixture `run/SanitiserRecursiveLabel`. The probes `F-RecMapOnce`,
  `F-OnceViaMap` and `F-InitCapture` are now refused.
- #1723: `Distinct.instCondMixed` had no in-progress guard. A fold step whose argument holds the step's own
  answer asked the step's condition inside its own arguments without end. It now marks the call while it asks
  it, in a bit of `cond_state`, and reads a cycle as `no`, as `instCond` does. Eight limit lines of
  `FoldKeepsInner` and `FoldKeepsInnerRefused` go. `Codec.Decode.oneOfHelp` is a real cost (#1714), not this
  loop. Fixture `ownership/FoldFeedbackCondition`.
- JsonCodecs 187:13: `Contract.arrivalLess` sorted a slot's `cb` arrivals by intern id. An importer interns
  them in another order, so `Codec.Encode`'s block did not re-encode to its own words, it was read as unknown,
  and every call into it was pessimistic. They now sort by canonical words. Fixture
  `ownership/ImportedArrivalOrder`.
- #1722: B-KappaAtView-2 and E-RoseApart4 were never accepted by master's v2 at the refused positions. Master
  left those declarations unbuilt, and v1 refuses both. Q-CastNestToFlat is a real precision loss against
  master's v2 (v1 refuses too). Its cause is below; it is left open.
- Filed #1727: a closure that does cell operations on a captured `Ref` is `once`. After #1721 this refuses
  `Task.retry`/`forever` callbacks that count with a `Ref`.

**What I learned**

- The ledger against the base, not only against master, found the 8 new refusals (all `once`, all real
  repeat-callers). Master's v2 had no position there, so a comparison against master alone shows nothing.
- A block that fails its own round trip is silent: the importer only prints `unknown block M`. When an
  imported call reads ⊤ unexpectedly, look for that line first.
- In the slot domain a case scrutinee is a `.whole` use and is read deep. So `len : List a` reads `π1ε*`, while
  §2.13's pattern rule (*a list pattern reads the parameter parts of the value it matches*) and master's v2 read
  `π1` only. Fixing it needs a shallow use through Walk, Facts, Liveness and the read-off.
