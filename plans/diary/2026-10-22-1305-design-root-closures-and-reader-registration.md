## 2026-10-22 13:05 CEST — Design root closures and reader registration

**What I did**

Drafted the design-only amendment for #668 directly after the owner's 2026-10-22
amendment in browser-inline.md §8.4. Read the issue, the complete piece contract,
the latency/size report's Parts 2–3, the record ownership contract and #315's plan,
the current lowering hooks, write sets and #631's cache constraints. Generated and
read tea-inline's two-widget unique-components output on dagon, without measuring.

Specified own-module root factories, deterministic preallocated group buckets,
mount-time readers in either order, synchronous ordered group union, Main-owned
keys, validated generic replacement routes, retention evidence and emit cache
dependencies in both directions. Listed changed and new emit/page fixtures with a
two-widget output oracle and concrete variants. Separated owner decisions and
recommendations. The PR is for owner review and must remain unmerged. No compiler,
runtime, fixture or proof file changes; all builds and checks are on dagon using
the self-hosted compiler in the flake shell.

**What I learned**

The landed ownership hoist table authorises accepted demands in clean enforced
modules; it does not by itself prove permanent slice identity or authorise a
loader's additional copy stores. The root plan must establish that correspondence
and carry explicit replacement evidence. Generated access to the current model
must also remain distinct from source closures, whose old-value captures still
obey the record ownership rules.

Preallocating writer buckets before any root mounts removes tea-inline's earlier-
writer ordering assumption. Multiple registered fields require a once-per-entry,
document-ordered union per tail; separate synchronous group calls could duplicate
or reorder readers. The reference's unchecked loader and microtask scheduler are
not compatible with beni's validation and synchronous dispatch contracts.

The full unfiltered self-hosted `zig build gates` passed on dagon in the flake
shell. No LLVM build or measurement was run.
