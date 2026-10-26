## 2026-10-26 16:10 CET — Apply the ball machine gradient halos

**What I did**

Applied the measured gradient halos to the shared playground/browser sample
(#1095). Removed dynamic blur filters and their unused definitions, keeping
cabinet shadows, physics, controls and semaphore fibers. Rebuilt the locally
served playground. Updated the existing SVG transcript and all three run hashes;
console control logs and frame reports are unchanged. Added APPLIED.md and fresh
raw timing data alongside the earlier benchmark, and allowed the local builder
to use historical sources or the now-optimized source without duplicating halos.

**What I learned**

The full Chrome playground script passes, including controls, source tabs,
repeated reset and desktop/phone views in both schemes. Corpus development,
release and fiber runs and formatting pass. Three fresh eight-permit timing
trials show median 49.36 fps for the baseline and 59.99
for the applied drawing, with no intervals over 25 ms in the candidate. The
baseline varies from the earlier session, so the new report keeps the fresh
comparison separate. Full Zorg gates still hit #90/#1085 (1721 passed,
16 skipped, three failed tests); the branch remains local without bypassing
that gate. No speculative physics or allocation changes were applied.
