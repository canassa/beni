# Schema worker composition checkpoint

The owner removed runtime interpretation and deferred projections to #1790. Record,
tagged and recursive construction now retain typed child workers. Description nodes
contain only inspection metadata; the old Datum/Any access adapters, interpreter,
forced flag and differential passes are deleted. Skills and removed-name diagnostics
record the smaller public API.

The boxed Job draft was discarded. Ownership identified its sixth callback parameter
as the boxed datum, while path and job captures were read-only. The replacement
retains typed products and variants and uses immutable compiled paths. Core ownership
accepts every list and record operation without a copy fix. The getter fixture proves
composed readers read each field and discriminator once in both output modes.

The 44 Schema runtime fixtures, emit goldens, API generation and skill checks pass.
The whole gate is still red at this HostFree checkpoint, including #1793 and #1798,
ownership-pin/catalogue drift, formatting and older native/source-map expectations.
The same endpoint-identity and native-export failures reproduce with the saved baseline.
No unrelated expected runtime outputs or trust pins were blessed.

A validation mistake was caught before acceptance: the installed incremental Debug
compiler lagged core edits. Earlier watcher timing checkpoints are historical only.
A one-shot compiler and the fresh ReleaseSafe compiler now emit identical benchmark
JavaScript. Final paired measurements and hash recording use that verified compiler
under the shared lock. No speed-parity claim or completed PR follows from stale timings.
