## 2026-11-09 12:21 CET — cheaper Chrome driver evaluations

**What I did**

Installed the Chrome driver's helper functions once per document before navigation.
Combined settling, log/error draining and the successful DOM snapshot in one
Chrome evaluation per phase, preserving separate tasks for actions and repetitions.
The happy-dom call sequence and source-expression fallback stay the same.

Five warm TodoMVC runs (development and release pages per case) measured wall
seconds per case of 0.5462 before, 0.3076 with helpers installed once, and 0.2798
with the combined observation. Node plus Chrome CPU-seconds were 0.5877, 0.4122
and 0.3815. Reports matched byte for byte, including missing-selector and
expected-throw failures and a Chrome fuzz/replay smoke run. No goldens changed.
Full Chrome before/after timings and the gate result are recorded with the PR
for #2340.

**What I learned**

Persistent drivers would require a harness redesign: spawnAndCapture captures to
EOF and reaps each child under the case timeout. Reuse needs a request protocol,
per-request stream limits and timeout/crash recovery, and resets for parsed
steps, options and working paths. The manager approved stopping after the two
local driver improvements; the remaining option stays tracked in #2340.
The first untouched-master Chrome run stalled at ComputeCoverage; one clean
rerun passed, so it was excluded from the performance comparison.
