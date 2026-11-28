## 2026-11-24 14:08 CET — v3: a started closure's functions, in any order and any call

**What I did**

- Fix lane fix213 on `ownership-v2-design-review`, for #2674 (code reader CR8 on 44a25c6b38): a started
  closure that handed a function forking a hosting fiber and one that masks to one helper call
  (`twoCalls h k`) was wholly accepted and trapped. It was the seventh round in a row with a hole in
  kernel §13 item 12 (d), so the fix is stated as one rule that does not depend on the way in.
  - The rule: a hosting function that a started closure runs is started so only where nothing else
    that the closure runs or loses, at any depth, can park the fiber masked or lend it. The order of
    the two is not read. `siblingRunsOn` had read `Fn.after_call` to decide the order, and that fact
    is about the closure's own calls only. A callee's order never reaches the closure's contract. Now
    every other function the closure runs or loses is judged by `valRunsOn`, which follows contracts
    across modules. `after_call` is still published, but no start reads it.
  - The reviewer found an older hole of the same kind. A masker kept in top-level data that holds no
    cell (`( masker, 0 )`, `Just masker`) read as `v_none`, so no rule saw it. A top-level value whose
    place can hold a function now reads as `outside`, code the walk does not know. My first try read
    every `v_none` function as unknown code. That gave core's Binary helpers `runs-on`, because a
    constructor used as a function is `v_none` too. I took that try back.
  - The same reading closed a list hole: `(apply [] k Lib.ctor).a` with `ctor = Pt`, then
    `List.push k`, printed `1,2 1,2` in place on the base.
  - Blind round CJ: the kernel now says why `Js.catchIf` and `Js.finally` need no entry in the defect
    list (item 11's *any other holder*, and `disjoint`).
- Fixtures: `run/CellStartedPair` and its live twin, a two-module project with 14 shapes (11 accepted
  on the base). `run/TopValueFunctionHanded` and its live twin. `cells.mjs` has 11 new `runon` shapes:
  base TRAP, fix REFUSED, dead twins SAME.
- Evidence:
  - Root dumps: 0 verdict changes on real roots. The one changed demand is the list hole above.
  - Sweep dump-diff: 28 114 programs that fork and make a cell. 10 changed, all accepted → refused,
    all new live shapes that TRAP on the base. 0 dead twins changed.
  - Ledger: 309 of 319 before and after. v3 time on the real roots: 2204.8 → 2194.0 ms.

**What I learned**

- When the same item has a hole for seven rounds, look for the filter that makes the rule depend on
  the path. Here it was one `after_only` argument.
- `v_none` has two meanings for a function: "no cell" and "no value". A fix that reads it as unknown
  code costs precision wherever constructors are used as functions. The place says which meaning
  applies.
- A fix for one hazard of item 12 (d) found an unrelated list hole, and only the root dumps showed it.
  Read each verdict change in the dumps. Do not assume a change is lost precision.
