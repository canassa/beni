## 2026-11-02 02:30 CET — Finish typed Task storage

**What I did**

Replaced Task's erased control records, continuations, result slots, scopes,
finalizers, observers, schedulers, clocks and log contexts with typed storage.
Closed unit jobs retain their original callback and matching result destination.
Core-private native adapters keep timer and channel resources in JavaScript;
Task's only `Js.Value` is its plain parked sentinel. Recorded the owner's
approved invocation/completion protocol and rebased onto workers with master
merged. Renderer queues and other erased core containers remain separate work.

Added regression coverage for exported callback factories, suspending cancellers
(#1649), private runtime access and release corruption from unused pattern aliases
(#1654). Updated existing ownership trust pins and added unsafe escape-word flips
for retained native callbacks. Kept cancellation before a queued child's first
line and covered it directly. Corrected the HTTP abort driver's race with server
receipt using the HTTP continue acknowledgement (#1661), without a delay.

The run and tea corpus passed during the migration; finishing integration checks
cover direct user calling conventions, cache/cutoff decisions and output trees.
Runtime capability pruning remains deferred under the owner's build-first
instruction; no benchmarks or design comparisons were run.

**What I learned**

Erasing a result destination is as limiting as erasing the callback: typed hidden
completions let each closed job own the pair. Mutable callback cells must retain
inferred effect relationships, including a pure factory's nominal result.

A shared JavaScript initializer node cannot be overwritten while removing one
dead binding: a pattern alias and its constructor field reads can share it.
A child-completion observer should decrement a counter rather than rescan all
children. Finally, a local HTTP write callback proves no server-side receipt;
startup cancellation must keep its existing semantics while the test driver
establishes the protocol event it needs.

The final core parity check also exposed a v2 disjointness false positive for
fresh chain snapshots after Ref reads (#1664). Added its 24-line fixture and
six exact exceptions through ownership-v2.md §7.2's existing mechanism. V1
accepts the collector; no runtime or public API workaround was introduced.

Final validation: `zig build test-run-hashes` and unfiltered `zig build gates`
passed after the workers rebase and reviewed metadata updates.
