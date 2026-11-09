## 2026-11-09 12:53 CET — CI on azathoth: green, and faster

**What I did.** Managed the follow-up to moving CI to azathoth (#2264):
- The host cache kept the runners' 0600 file modes, so every restore after the first master save
  failed. That was fixed on the host (infra aec0695). #2314 makes a failed restore or save a warning,
  and the job then runs without the cache.
- Master was red for two reasons:
  - a type-checker step had become quadratic in erased classes since 70664db0e3 (#2334, 45 s → 0.2 s);
  - two Chrome pages failed: a race on image promises and a missing Chrome golden (#2336).
- The owner made the Lean proofs on-demand: `gh workflow run ci.yml -f lean=true` (#2321).
- #2340 measured the 13-minute Chrome job. On the owner's decision, the page fuzzer now runs only
  under happy-dom (#2370, 1029 → 745 cases). The driver installs its helpers once per page and reads
  a phase in one call (#2371). Chrome on azathoth now takes 167 s.

**What I learned.**
- A gates test that asserts a ratio of records can hide a time blow-up. The 120 s hang guard caught
  it only when CI was loaded.
- On 3 runners with a shared CPU quota, waiting in the queue costs more than any job's own time.
  Measure from a job's start, not from the whole run.
