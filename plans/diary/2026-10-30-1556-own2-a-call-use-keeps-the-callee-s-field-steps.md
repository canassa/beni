## 2026-10-30 15:56 CET — own2: a call use keeps the callee's field steps

**What I did**

- Fixed #1325. `Walk.readOff` marked `R` for every use at the use's own path. For a `call` use it ignored `use_node`, the callee's use shape. So `rxb2 g = rb g.x`, with `rb r = List.length r.b`, was summarised `π1.x R` where §2.7 and §2.10's read-off ask for `π1.x.b R` too. A caller then accepted a push of a list `g.x.b` holds, with `g` read later. v1 refuses it. The read-off now walks the callee's use shape below the argument's path and marks `R` at each marked path (`Mark.compose`).
- Fixtures: `ownership/CallFieldStep` and `ownership/CallFieldStepImported` (two modules). Both cover two calls, three calls, a tuple part and a constructor field. The single-module one also has an annotated other-field twin (accepted), a write through a helper, and two parameters of one type. On master each fails the v1/v2 parity check with four wrong acceptances.
- Across the ownership, `run/` and core corpus, v2 verdicts change only in the new fixtures. 14 other files' summaries gain `R` paths, each one a callee's marked path below the argument. Most are `[*] R` beside a callee's `[*] A`, which is what v1 prints (`Copy.copiedFirst`, `NullaryCopy.copied`, `ReturnsFresh.copiedThenRead`, `Differential.t33`).
- Filed #1327 and #1328.

**What I learned**

- A callee's deep read (a leaf of marks, §2.13.6) cannot be grafted into the caller's use shape as a leaf. A leaf's marks all hold below it, so a shallow `W` at the same path joins it and becomes `S`. On the corpus that turned about 30 summaries from `W` to `S` and refused `core/CastCallHolds` 25:9, which v1 accepts. §2.10's use vocabulary has no deep `R` beside a shallow `W`, so this is the owner's decision (#1328). Until then a callee's leaf composes as `R` at its path, as master did, and a deep read through a closed-type helper stays accepted (`str r = Debug.toString r.x`).
- `Place.extend(p⟲, ⟲)` appends a second level when the place has no direct self-edge (`sameCycle(p, p)` is false for `Rose`, `Tree`). Composing a callee's `⟲` onto an argument path that already ends in `⟲` must stay at it.
- Two parameters of one place share their canonical path ids, so a memo keyed by path alone merges them. The compose memo is keyed by the parameter too, and the `both` twin fails without it.
- On master v2 refuses a call of a row-polymorphic callee when the edited list sits at a field outside its row (#1327). That approximation also hides #1328 for unannotated helpers.
- `zig build gates` took 1 min 55 s after the edit, not about 10 s.
