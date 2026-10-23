## 2026-10-23 02:02 CEST — Publish ownership on the module DAG

**What I did**

Moved ownership summary computation onto the worker that checks each module,
before interface publication. Published public summaries and opaque type slots
in interface format 16, with canonical path, allocation and returned-class
numbering. Retained private cache rows and a clean-report certificate separately.
Removed source-key folding from interface hashes. Added in-place cache firewall,
opaque-slot and jobs 1/8 round-trip coverage. Kept the serial dump as an independent
verdict comparison. All building and testing used dagon and the shared gate
lock; no benchmarks or size measurements were taken.

**What I learned**

Equivalent ownership facts can acquire different path, allocation and returned
closure numbers when computed per module. The public wire format must canonicalize
these names while retaining the shared fresh/escaped number namespace and the
object-number range used when applying summaries. An ownership report cached on
a platform that does not enforce may contain rejected demands, so an enforcing
build needs a clean-report certificate before skipping that module.

Kept allocation renaming at the serialization boundary: changing read-off
numbering can change recursive fixpoint precision. The worker-versus-serial
comparison checks demand verdicts directly, and the ownership goldens stay fixed.
Rebased onto the lazy block reader from #814, retained on-demand decoding for
public rows and callable aliases, and advanced the block version to 34.

Computing summaries during ordinary checks also reaches deep private call chains
that report-only checks never visited. Kept recursive operand evaluation out of
the larger summary-discharge frames, memoized solved-type DAG queries and spine
conditions, and interned identical condition sequences. The condition lookup is
cleared when speculative analysis rolls its condition table back. The two cache
firewall regressions exercise actual in-place library builds as well as hashes.

Integrated declaration totality's interface format 15 and cache entry 14; the
combined interface is format 16. Parameter-only result-guard conditions are
accumulated once, with duplicate conditions removed. Callback conditions retain
their original update order because speculative walks may reuse condition ids.
Public allocation numbering skips descriptors that contain no allocation name;
those descriptors never contributed to the wire format.

Totality's two unknown-callback controls previously compared whole interface
hashes. Their recursive edits also change the callback's ownership call count.
The tests now inspect the serialized totality bit directly, retain the non-total
assertions on both bodies, include a positive control, and require the ownership
hash change instead of treating it as a totality change.
