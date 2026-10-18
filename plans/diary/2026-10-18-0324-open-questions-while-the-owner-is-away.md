## 2026-10-18 03:24 CEST — open questions while the owner is away

**What I did**

The owner is away (2026-10-18) and left standing rules: S1 (#297) only, plus #341, #286's design pass
and Jayson's #331/#333. A decision that adds to or changes plan §9, or reverses a decided design, is the
owner's. I record such decisions here as numbered questions, each with the option I would pick, take
the conservative path meanwhile, and continue with work that does not depend on them.

- #341 (#286's (b), sound projection) is merged as `2cabeed03`. With it come the cycle-group solver
  (Tarjan), the second-pass fixture and the re-entry guard.
- #286's design pass is committed on `ownership-fold-design` (`c885c97e2`, docs only) and opened as a PR.

**Questions for the owner**

1. **#286 F2, the typed cast marker, as specified, makes core's `Schema` refuse itself.** Core goes from
   116 demands with none rejected to 1 035 demands with 481 rejected and 29 pending, all in `Schema`.
   - **Cause.** Three functions go over `value-cells`: `ctorArgs` 390, `fieldsFrom` 590 and `printWith`
     450, against a limit of 256. Each cast of a parameter names a new cell, and `Context.fail` is read
     through `Maybe`, `Nullable` and `Presence` in every order. The marker's `⋆` fallbacks are not the
     cause.
   - **Options:**
     - (i) fold every marker after the first onto it, whatever its type, so that `Schema`'s round
       trips stay exact at the first level only;
     - (ii) raise `value-cells`;
     - (iii) make the `value-cells` check scale (it is pairwise, so quadratic), so that no limit is
       raised.
   - **My pick: (iii), measured before it is chosen.** (ii) raises a limit, against the owner's "no
     limits". (i) is a precision loss, which the owner rejected unless no precise design exists. If (iii)
     is impossible or too slow, that is the finding to bring back, and (i) is the fallback design for
     the owner to approve.
   - **Meanwhile:** F1 (closures at their environment) and F3 (the type-variable fold) each measured a
     rejection delta of 0. Building them is part of (c), which the owner ordered built together after the
     design, so I am not building them ahead of this answer.
2. **#286 (d), per-level exclusivity, is about 600 lines and a dozen fixtures.** It also closes the
   `paramHole` soundness hole found in #341's review, which is on master today. It is predicted, not
   measured, that `browser-direct`'s `Tea.want` is accepted once `Dict.insert`/`update` publish the
   level fact.
   - **My pick:** go ahead once question 1 is answered, because it closes a known unsound acceptance on
     master.
   - **Meanwhile:** not started.

**What I learned**

- A fold point can be precise and still unaffordable. F2's cost is the number of distinct cells, not
  approximation. "No limits" and "no precision loss" together mean the algorithm must scale, and when it
  cannot, that is the owner's decision, not a parameter to tune.
