## 2026-11-03 12:00 CET — Shared chains and nested optionals

**What I did**

Resumed the saved Chain work after the host reboot. Task now shares the
cell-backed Chain. Entries keep generic payloads plain; removal tokens are
created only when retained and forget their entry after removal. Queue and
Task stack writes avoid those tokens. Typed array construction shares one
Builder identity and the existing ownership rows; snapshots no longer import
List's runtime. A Queue library import reproduces the previous initialization
cycle and now runs successfully.

Nested Opt values use cached private none escapes. Checked concrete element
representations keep identity emission; generic operations preserve nesting.
Removed the payload-kind refusal and recorded the static decision in dispatch
caches and the emission funnel. Runtime fixtures cover direct, inferred and
rigid nested round trips, Queue, erased wrappers, and warm dispatch round trips.

The serialized timing comparison showed no regression: Queue offer/take
45.47 to 43.64 ns per pair, Deferred handoff 4.51 to 3.09 microseconds, ready
Deferred 47.65 to 35.78 ns. Samples, especially ready Deferred, vary; these
are not broad speedup claims. Parked fibers retain 1,520 bytes instead of
2,768, and completed handles 1,059 instead of 1,539. The six fiber cost and
size ratchets pass with tighter caps; the 480,000-waiter Semaphore passes
development and release with Node's default heap. Queue's 24 program runs pass.

A declaration ledger found that Queue's batch accumulator pulled in persistent
List writers. Filling one typed builder reduced the queue bundle from 5,430
to 4,615 bytes brotli, below its original 5,006-byte cap. Recorded scoped run
hashes and the changed fiber emission goldens. Full gates remain for the
completed HostFree branch; inherited ownership pin and integration findings
remain on its review list.

**What I learned**

A sound generic optional representation can still be the wrong storage layout
for a hot container. Keep presence on concrete pointers and retain payloads in
their own type. Stable removal handles require indirection, but queues and
stacks that keep no handle need not allocate one. Moving a builder's nominal
identity also requires moving its ownership identity and asserted array rows;
the alias fixture caught that dependency. Shared runtime code must avoid an
implicit List-to-Task initialization edge, even when its source module graph
is acyclic.
