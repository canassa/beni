## 2026-11-06 05:58 CET — answer the review of the fixed classes

**What I did** (#1662, PR #2128, still a draft until `toplevel-ref-twin-q1` has an answer)

- The automatic review posted nothing, so I asked for a pass with `@claude review`. It found no blocking bug and asked six questions.
- Its question on `sync` found a real gap. Fixed classes can refuse a program that checked before: a top-level `apply = { Ref.update loads …; λf x → f x }`, used with a suspending callback and inside `Ref.update`'s `sync` function, now gets `sync_boundary`. Each use of a fixed class also added its own `sync` source, so a second error landed at the use that only passed the suspending callback. Now a use of a fixed class adds no source; the demanded node reports. `check/bad/TopLevelFixedClassSync` pins both: the one refusal, and a use whose copy is fixed only by unification, which must stay refused.
- Measured the cost with `--self-profile` on two generated 7 008-line modules (Debug builds, 6 runs, median). With no fixed value, the effect phase went 15.6 → 16.1 ms and the whole check stayed within noise. With 500 top-level cells, the effect phase went 12.9 → 22.7 ms, the whole check +4.5 %.
- Added comments for the re-solve state, `unite`'s roots and `refresh`'s order.

**What I learned**

- A per-use `sync` source is right for a copy, and wrong for a shared class: there, it reports the error at every use. Test where a refusal lands, not only that it comes.
- In the path with no fixed class, an empty `scratch.alloc(u32, 0)` per class and one more column per node cost about 1 ms in a 15 ms phase in Debug. Return `&.{}`, and make the column only when it is needed.
