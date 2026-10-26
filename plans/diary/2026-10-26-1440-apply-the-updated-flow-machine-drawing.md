## 2026-10-26 14:40 CET — Apply the updated flow machine drawing

**What I did**

The owner steered the pending PR/merge to include the updated beni-logo/flow.html
machine. Inspected its actual src/flow.js drawing and ported the continuous
cabinet, inset side panels and pipe window, vents, clamps, brighter metal rims,
permit sockets, vertical bucket indicators, exit light and finished-ball trails
to the beni/SVG sample (#1089). Trails retain at most seven positions per ball.
The modular semaphore program and sticky controls stay in place.

Captured the reference over HTTP and compared it with desktop/phone playground
renders in both schemes. The full Chrome playground script passes with zero
failures, including the updated drawing and all controls. Updated the browser
fixture's markup transcript and all three run hashes against the rebased core
with Zorg LLVM. Its machine-event and frame-count transcript is unchanged.

**What I learned**

The latest reference changed its canvas drawing rather than the HTML controls:
the old separate bucket/check bodies are now one cabinet around the same physics
geometry. A file URL prevented Chrome from running the reference's module, so the
visual comparison serves the reference over HTTP. The new appearance needs no
JavaScript runtime fork; it remains ordinary beni markup and drawing state.
