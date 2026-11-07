## 2026-11-08 00:40 CET — a result's folds as its own slot

**What I did**

- Took over #2217 after its review failed. The walk up from a result slot stopped at its own place (`sameCycle(p, p)` is false off a self-loop), and a lower fold was dropped as covered by a higher one that no route passed. `LevelTargets.of` now reads the folds off the slot's path as `Place.extend` makes them, and `LevelWide` says the arrival as the parameter's own slot at each, with no walk.
- Renamed `Place.sameCycle` to `sameComponent`, reflexive. Every caller was guarded or asked about a real step, except `StepsTo`'s `on` and this PR's loop.
- A copy at a fold off the slot's path (`Arrival.level_copy`) is skipped by a read that writes out every slot, and `Normal` drops nothing below one. That keeps `c2dead`'s caller at master's cost.
- `StepsTo` walks `PathsTo`'s contexts: one arrival on doubling middles was `2^(d+1)` nodes.
- Wrote `gen8`: recursive readers and records on the read route, at the default allowance.

**What I learned**

- A marker that an arrival is a copy must survive the normal form. The first cut used `path = none`, and `Normal` then dropped the slot's own entry under a fold on its path. `gen8` found it in 200 programs.
- A frame between (`go f = hg f`, `hg (hg f)`) says the callee's copies again as its own arrivals, so a caller writes each out. 52 of gen7's 30 000 go to the limit at its raised allowance, 48 of them with such a frame.
