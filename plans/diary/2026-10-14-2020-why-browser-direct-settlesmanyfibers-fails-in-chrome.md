## 2026-10-14 20:20 CEST — why browser/direct/SettlesManyFibers fails in Chrome

**What I did**

Fixed the reviewer's text points on PR #103 (`navigateerror` fires on a
cancelled navigation in Chrome; the README lists every happy-dom miss).
Then measured `SettlesManyFibers` in Chrome 153 on this host with probe
copies of the page driver. No change to the repository's code.

**What I learned**

The driver's `settle` waits one `setTimeout(0)` turn in Chrome, but core's
scheduler runs 64 fibers a turn and posts the rest to a `MessageChannel`,
so 2 000 fibers need about 7 timer turns (4.5–7.2 ms quiet). The transcript
then reads the page mid-work. On a quiet machine the direct build reached
2 000 in 2 of 20 trials and the harness case failed 3 of 3; under full CPU
load it passed 20 of 20 and 3 of 3. So it is the driver's assumption, not
the hardware, the OS or Chrome; load only moves the race. A fix would count
undelivered `MessagePort` messages in the prelude, as `settle` already
waits for `setImmediate` under happy-dom. That is the owner's call.
