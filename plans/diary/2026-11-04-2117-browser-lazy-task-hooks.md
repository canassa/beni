# Browser lifecycle hooks use the lazy bridge

Closes #1858's platform half. Browser registers its stop callback directly with
Js.TaskHooks; Rt registers the turn hook and queries shutdown/log-context state
there; Hosted registers synchronous releases there. Reachable fiber work still
uses Task. The core half was already merged; the browser patch was adapted to
the typed Rt import and cleanup layout.

Measured on current workers-hostfree 1f4eef34e8 with the same release sources and
brotli quality 11: empty 1298 → 1299 B (raw 3078 → 3038), no-command TEA element
1876 → 1861 B (raw 4704 → 4654). The older fiber-lane 1485 B element measurement
was on its pre-DOM tree, whose empty page was 750 B; it is not this base. Task's
scheduler is absent from the no-command page. Scope allocation/resume helpers
remain for Tea.start and the browser after-render path. This PR does not claim
to finish the separate generic DOM/root-slot size debt in #1861.

A black-box output check is red before/green after: platform lifecycle hooks
refer directly to the bridge; a no-command page has no fiber maker, while a
command page retains it. TaskHookBridge, ShutdownBeforeFirstFiber and fiber
fixtures pass. The full Chrome browser corpus passes. Full base and branch
gates retain inherited failures; only two release module alias goldens changed,
were reviewed and refreshed, and their targeted check passes. Browser.host's
entry-word body was re-read and re-pinned: callback retention and its word are
unchanged. Evidence: ~/worktree-evidence/wd-dom-wire/hooks-1858/ on dagon.
