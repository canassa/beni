## 2026-10-02 19:17 CEST — Core in beni, Effect parity, typed keys, ⊤/⊥, and the optimiser's audit

**What I did** (as manager; Opus agents in worktrees implemented every slice)
- Core is beni but `Js.js` and a 13-line `List.js`: `Task.js` and `List.js` ported (release equal or
  faster; `List` −6.8 KB in total), `Basics.eq` by name uses a type's own `eq`, `Dict`/`Set` compare by
  contents (Elm had this; beni had regressed), `Debug.toString` prints beni source by type.
- Effect parity: kernel additions, `Deferred`, `Duration`, `Schedule` with retry/repeat, a virtual
  clock, `par`/`forEach`/`race`/`timeout` (all faster than Effect v4 by instructions); the runtime made
  pay-for-what-you-use; listener subscriptions run without a fiber.
- Milestone 2's acceptance app `ApiAndRoutes` landed after core and platforms are checked at beni build
  time and several exact compiler speedups; JSON over HTTP landed; command keys carry a type identity.
- TodoMVC is one full-spec app: 10 053 → 8 575 B brotli whole-spec (Solid 1 5 717, Svelte 4 4 565).
- Syntax: `⊤`/`⊥` replace `()`/`Never`, `if` without `else` for `⊤` branches, `_ =` on `⊤` warned.
- Research 52 audited `Spec` against SCCP/IPSCCP, LLVM's Attributor, MLton, Closure; the owner adopted
  a combined optimistic solver. Slices 0–3 landed (an undefined-memory read, counters, a monotone
  points-to, truthiness); the solver's design is normative in `backend.md` §9.
- Fixed along the way: a soundness hole (schema `Type` in constructors), build output depending on
  where the project lives, an unsound specialiser fact, an order-dependent inline, a browser-only
  macrotask slot that dropped the defect teardown, a cache key missing embedded core files.

**What I learned**
- Agents' "confirm first" choices must come to the owner before a mechanical commit, not after.
- A green gate can hide order- and location-dependent bugs: the harness's paths sort one way; add
  tests that vary the project's location and module order.
- `/tmp` filled repeatedly from the page driver's unbounded cache and agents' scratch; now bounded.
