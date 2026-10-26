# Applied drawing verification — 2026-10-26 16:10 CET

Applied the measured drawing to the shared BallMachine/View.beni. Dynamic glow
and ball-shadow filters are replaced by gradient halos and translucent token
rings; unused filter definitions are removed. Cabinet shadows are preserved.
Physics, controls and the four semaphore fibers are unchanged.

At eight permits and batch size three, three fresh counterbalanced trials
(four seconds warm-up, eight seconds timed) give median RAF cadence of
49.36 fps for the historical fixed-seed baseline and
59.99 fps for the applied drawing. The applied drawing has zero
frame intervals over 25 ms across all three trials, with p95 16.67 ms.
The baseline is faster in this session than in the earlier research; these
later results are recorded separately. No specific environmental cause was
isolated. Both runs have about 18–21 balls on the same M2 Pro/Chrome/Metal setup.

Raw data: results/2026-10-26/applied-timing-8-3.json.gz. The JSON records
`dev` as the historical baseline and `gradient` as the applied sample.
Generated modules and source copies: zig-out/bench/ball-machine-applied/.

The complete Chrome playground test passes (0 failed), including sliders,
reset/restart and all source modules. Desktop/phone screenshots in both schemes
are in zig-out/ball-machine-applied/screenshots/. The existing corpus fixture
passes in development, release and fiber modes; all console control logs,
step markers and frame reports match the old transcript. Refreshed only the
changed SVG transcript and three verified run hashes. Formatting passes.
The rebuilt local playground at http://127.0.0.1:8001/ serves the updated sample.

Full `zorg build gates` still fails on the previously tracked ownership goldens
(#1085) and case-folding filesystem tests (#90): 1721 passed, 16 skipped,
three failed tests. The owner requested publication and merge after this result;
the PR requires green CI before merging. Logs:
zig-out/ball-machine-apply-{page,corpus,gates}.log.

The earlier README records the research before adoption. Its exact historical
source/output hashes remain intact. build.mjs now accepts --source=path for
historical sources; with the current source its gradient variant is identical
to dev, recorded as gradientChanged=false. Use a separate --out directory when
rebuilding so old measurement artifacts are preserved.
