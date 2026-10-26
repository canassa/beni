## 2026-10-26 16:13 CET — Publish the ball machine rendering improvement

**What I did**

The owner requested a PR and merge after the local macOS gate failures were
reported. Prepared the completed browser benchmark, raw timing/profile evidence,
reproduction scripts and gradient drawing improvement together for publication
(#1092, #1095). Included the SVG transcript and three verified run hashes, and
kept the unrelated untracked files outside the commit. CI will run the unmodified
full gates and native/WebAssembly parity suite before merge; every automated
review finding will be fixed or answered.

**What I learned**

The source branch is based on the latest origin/master. Chrome playground,
fixture behavior and formatting checks are green, while local full gates still
hit the already tracked macOS case-folding (#90) and ownership goldens (#1085).
The original benchmark and later applied check have different baseline cadence,
so both comparisons and their caveats are preserved. The historical comparison
needs source from the recorded revision now that the shared sample is optimized;
the README documents how to extract that source without changing the checkout.
