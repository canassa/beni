## 2026-11-27 17:09 CET — Manager: v3 converges twice, and the master merge lands

### What I did

- **The soundness loop ran to convergence.** On the v3 branch (`ownership-v2-design-review`, draft PR #2585), six round sets ran between 2026-11-26 and 2026-11-27. Each found one class of hole until the last two.
  - **Holes found and fixed:**
    - #2695: the runtime's `send` runs `update` on a masked fiber;
    - #2696: a call of a computed top-level function;
    - #2697: a return-type dispatch is a switch point;
    - #2698: a writer forked in a call is judged on every version;
    - #2701–#2703 and #2708: repeated runs and writers read to a fixed point;
    - #2709/#2710: one cell at two places is decided on cells and their locations.
  - **Two clean round sets.** Each is four blind rounds plus a code reader:
    - `e22c75218e` (cells and fibers): blind rounds DG–DJ and code reader CR14;
    - `127cce0419`: blind rounds DK–DN and code reader CR15.
- **The master merge of the branch landed** (the owner: "fix the merge conflicts").
  - On the merge, v1 refused 7 `browser-inline` pages, because the branch's `Dict` is a foreign type. The owner ruled out a v1 change and any `.copy()`, so the path was to have v3 judge `browser-inline`.
  - v3 refused 38 safe pages there. Nine precision lanes won all 38 in the checker, each with kernel text, fixtures and an adversarial reviewer.
  - **Owner decision, 2026-11-27:** a message that only the program's own commands build counts as `update`'s own.
  - An integration lane merged everything, fixed two faults that appeared only when the rules combined, switched `browser-inline` to v3 (manifest `"ownership": "v3"`), and pushed. #2585 is conflict-free.
- **Follow-ups that landed:**
  - #2724: v3 publishes v1's clean-module mark, and the inline release size came back.
  - #2725: the refusal text no longer names the prototype.
  - #2712: seven latent gaps closed, plus a fifth oracle leg for the build users get.
  - Racing timer fixtures made deterministic.
  - #2729: inline no longer keys a `Show` by identity.
- **Master fixes:** #2699 (PR #2705) and #2706 (PR #2707), both release-optimiser bugs the oracle's release leg found. #2713 is filed.
- **Jayson's agent** took the v3 speed issues (#2549, #2567, #2539, #2535, #2534, #2513). I merged his #2728 after checking it, and watched #2720.
- **An audit** re-tested all 42 open v3 issues. 4 were closed, and the audit results are posted on the rest.

### What I learned

- **A clean set came only once fixes targeted whole classes.** A code reader kept finding a new route each round until each fix stated its rule independently of the route: every form that runs code is a switch point, every fixed point runs to its fixed point, cells are compared by the cell. Blind rounds of tens of thousands of programs almost never found these; the code readers did.
- **Rules that are sound alone can be unsound together.** The integration lane found two faults that no single precision lane could see. Merging precision lanes needs its own adversarial review of the union.
- **A local branch can miss a fix its siblings have.** Three local branches were built on a base without the #2710 fix, so 6 known faults came back there. Merge origin into every local lane before it lands, and audit what each base contains.
- **The oracle must test the build users ship.** The fifth leg (records in place, lists copied) found #2729 at once, a bug the four legs and a golden recorded in the wrong mode had hidden.
- **Flaky fixtures turn CI red.** Fixtures that race real timers show up as red CI and false DIFFs in blind rounds. A preload that stalls timers at random found 13 of them in one pass.
