## 2026-10-21 20:36 CEST — Publish general declaration totality

### What I did

The owner replaced #618's proposed String.length whitelist with a general
checker fact, and separately approved replacing the markup classifier's
4096-instruction cutoff with an uncapped iterative walk. I recorded that
instruction on #618 and amended checker-v2.md §26 and
transparent-effects-proposal.md §14.

This first implementation slice publishes the fact without consuming it in
markup lowering. After method elaboration, a declaration is total only when
its effect rung is pure and every execution callee is known and total, with no
reachable recursion. An iterative SCC decomposition propagates non-totality.
Foreign pure and Js.pure execution regions use their existing trusted contracts;
argument formation still runs normally. Unknown callback, local-function and
evidence calls do not acquire a proof. Callable aliases follow their invocation
target; creating a returned function does not execute it.

The same bit travels through public interfaces and private dispatch answers.
Interface format 13→14, entry format 12→13 and dispatch format 12→13 reject old
records; loaders reject non-bit values. Changing an ordinary pure identity body
into a recursive body now changes its interface hash, including an importing
caller's hash. The original compiler failed that new assertion. Other focused
cases cover callable aliases, private mutual recursion, Js.pure-backed ordinary
imports, foreign pure imports, unknown callbacks and local recursion.

### What I learned

A module-wide error check must not erase valid declarations' totality facts.
The first qualification attempt exposed three existing digest assertions. Two
were unintended loss of unrelated facts: inference now runs per declaration,
uses the existing failure bits and rejects missing effect proof nodes.

The remaining case legitimately changes: changing Leaf.Pair from Int×Int to
Float×Int makes Side.relayed's body invalid. Its published Int annotation stays,
but its formerly true total bit becomes false. The manager audited and approved
adding Side to that row's changed hashes. Error assertions, digest assertions
and the two unaffected hash oracles stay intact.

The consumer, Unicode/order/large-expression fixtures and actual S1 scenario
measurements follow in the next slice. No S1 bar, ownership guarantee or handler
lifetime has changed. Lean and compiler speed work remain paused for this team.

Before publication, the manager approved replacing the initial SCC machinery
with the same proof computed by dependency settling: start false, seed only
eligible declarations with no outstanding callee, and settle reverse edges
once per proven target. A cycle and its callers never drain. This is an
uncapped O(V+E) least fixed point, with no precision loss. Whole-core public
interface hashes from the frozen SCC compiler and the new compiler are
byte-identical (29 modules). Foreign pure covers Js.pure generically; there is
no separate Js.pure name check in inference.

The initial full gates also found the new file missing from the architectural
source audit and the existing whole-core ownership-clean assertion at 4302M
against 4300M. The audit now includes the file. Removing duplicate call walks
and settling dependencies instead of decomposing components makes that same
normal-budget fixture pass without changing its input or grant. Matching
profiling-mode counts were 4323M for the SCC version and 4322M for dependency
settling; those profiling counts include different runner work and are not
normal gate counts. No budget was raised, and no green check was rerun merely
to double-check it.

The duplicate-call control exposed an apparent recursion that is not a call:
Basics.add is written `add a b = a + b`, but the existing compiler operator
contract writes native addition. The checker now shares that single contract
with the backend: exact core identity, saturated arity, no hidden evidence,
and one pure-total classification excluding partial indexed reads and writes.
The backend import is a thin re-export. There is no new function whitelist.
The string comparison primitive similarly follows its actual String.compare
callee, including an own declaration edge before that interface is published.
Both the arithmetic and own-string controls fail against the frozen old pass.

Before final qualification, I transferred only this slice's patch onto the
actual helper parent 24bdda22d, which includes the handler wiring work. The
old worktree's sources, patch, counters and frozen compilers remain available;
only its inactive private build caches were removed to make disk space. The
current compiler uses a fresh worktree and a separate local Zig cache.

The latest combined source passes twelve focused graph controls, both format
controls, the architecture rules and the unchanged digest suite. Its normal
whole-core ownership-clean check still costs 4301M against 4300M, so I stopped
implementation and reported the remaining wall. No budget was raised, no full
qualification or LLVM run was started, and this tree is not merge-qualified.
The prior green core count describes the earlier dependency-settling snapshot,
not this final intrinsic-aware snapshot.

## Latest-master qualification, 2026-10-21 20:08 UTC

The 24bdda checkpoint remained red at 4301M after the authorized direct-self
reduction and reuse of P6's positive value_arity fact. Both changes preserve
all 29 core interface hashes. A matched diagnostic comparison against its
exact pre-totality compiler measured +6,353,783 instructions; its deliberately
failing diagnostic budget is not a normal gate count. The single instruction
sample supplied only eight flat Totality samples and unusable call chains,
so it did not establish an inclusive phase attribution. The proposed terminal
walk instrumentation was never built or run.

The manager then integrated all of latest master 3fafb445c into the held S1
parent. That qualified control is c0d79a3b0, tree
67d15ce82c3e562802f01d14c3bf9581700adfec; its full reference hashes, gates and
pending checks pass. Its frozen Safe SHA is
97445d6706afed18f16ca6d990f306082577dcc34bafb20b3f5f8d6d741a4ff4.

I applied only the complete eighteen-file A patch to a new worktree on that
control, with a separate local cache. The applied patch is byte-identical to
the preserved 64eede54 patch. Twelve graph controls, two format controls,
architecture rules and all 23 digest cases pass. Core inputs are unchanged,
and all 29 published core hashes equal the previous A checkpoint. The normal
4300M ownership-clean core test now passes on this new parent. This is a fresh
result on the complete latest-master integration; the old red measurements
remain red. No grant, narrowed fixture or further optimization was used.

Full reference qualification follows. The required exact-head LLVM run is
still owed, as are review and both S1 size measurements. Slice B's general
call consumer and uncapped classifier have not been implemented in this tree.
