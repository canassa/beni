## 2026-11-05 14:01 CET — Prove a single DOM root

**What I did.** Specified and built a private typed root connection and a
compiler proof over every view/helper return and the producer's normalized
Instance. Proven pages avoid a root Slot; unknown, escaped, mutable, mapped,
deferred and range roots retain their general output. Kept multi-program
pages wholly general as the owner's accepted #1989 debt. Brought in the Node
boundary changes, reviewed the overlapping dispatch and pins, and measured
empty/text/TEA-element pages at 909/908/1393 B brotli versus 1566/1562/2018.
Chrome, Workers, cold/warm jobs1/8 and the targeted word/fence checks pass.
The candidate gate and final inventory evidence accompany the PR.

**What I learned.** A typed connection alone can retain both renderers unless
ordinary specialization receives the same sound facts as the proof. The
shared List.mapHelp allocation loses multi-program precision; numeric-index
precision did not close that graph and is parked. Selecting the renderer job
inside mount preserves the public constructors' pure effects. A once factory
also needs aliased to preserve aliases of its captures. The effect witness
caught eager argument construction being dropped: every binding introduced
for the selector must keep the original source effect, even when the chosen
branch never reads that argument's value.
