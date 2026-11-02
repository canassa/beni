## 2026-11-02 15:33 CET — Preserve hosted send effects

**What I did**

Reproduced #1694 on origin/master: a startup command sent Ready before
Task.never inside Task.scope, but only development rendered ready. Wrapped
the send supplied to hosted jobs, after-render work, subscription fibers and
listeners in a typed adapter around Js.apply before erasing the body to
Js.Value. Added the reduced page and a page covering sends before unit,
yield, and a listener's returned cleanup. Both regressions passed with the
adapter and failed with the fix stashed. Refreshed execution hashes, the
three release shape snapshots, and the generated browser API reference.
The ownership summary records the additional wrapper closure; its
acceptance decisions are unchanged.

**What I learned**

The release optimizer correctly followed an incorrect purity answer:
Hosted.job had erased the body without connecting its Send parameter to an
impure operation. Lower.discard therefore listed the callback invocation
among pure_discards. A typed host adapter preserves the effect information
through the ordinary checker without any compiler change. A plain Task
callback program retained its call under release; the erasure was in the
browser platform's hosted callback constructors.
