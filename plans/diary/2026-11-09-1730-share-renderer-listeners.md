## 2026-11-09 17:30 CET — Bind shared listeners to inline entry

**What I did**

Committed the renderer-free foundation as e289d6e99 after the manager's
zorg.3 gate and Chrome baseline comparisons matched exactly. Released
the slot before starting the next slice. Both browser manifests now
depend on browser-base; removed their duplicate Listen modules together.
Inline subscription starts run in a registration thunk that selects the
renderer entry, while listener removal remains owned by the mount.

Added NestedBaseEntry before implementing the integration. The old inline
listener refused callback. With shared Listen but entry binding omitted,
the fixture failed behaviorally: each update ran before its reader
returned. With binding, both readers return first and updates retain send
order 2,1. Development and release pass. Targeted inline and TEA Node
corpora pass, as do ownership body-pin, P-sync and generated-skill checks.
Updated generated interfaces and the ownership justification; no golden
or budget changed. Gates, Chrome and empty-page size comparison await a
new manager slot, so this slice is not yet committed.

**What I learned**

The registration thunk must enclose the subscription start's lowered
statements as well as its final call. This captures the renderer entry
at installation without delaying event decoding. The entry runs nested
readers immediately and drains their sends when the outer reader returns.
Existing throwing-reader and stop fixtures continue to pass.

The initial constructor-pattern update exposed known #2258. The manager
identified open PR #2366 on inline-update-param-pattern and directed this
lane to keep the case form; no further work on that defect. Evidence is
saved in zig-out/scratch/inline-update-pattern.md. Shared Cmd/Sub and all
capability moves remain ahead; the capability APIs remain incomplete.

## Timer-only registration cost removed after review

The full validation found 16 intended release emit changes plus one runner
response failure absent from master. The manager requested all-16 sizes
and diffs; saved them in zig-out/scratch/listener-emit-review.md. Empty
pages were byte-identical, Chrome had only known DomCapabilities, and a
subsequent lane blackbox suite passed. No golden was changed or commit made.

Before the owner decides on listener growth, the manager required the two
timer-only fixtures to pay no unused context. The lowering now names its
entry-capture helper and receives the build-wide source-reachability fact.
When unreachable, the registration wrapper is omitted and its state is
eliminated. MainOwnedKeys and RootClosures now match their original emit
goldens and clean-master bytes exactly: 1897/880 and 1817/842 raw/Brotli.
The nested-entry positive control also passes. Fresh commands, hashes and
outputs are in timer-entry-review. No full gates or Chrome rerun after
this refinement. Everything stays uncommitted, with no other work started,
while the manager waits for the owner's decision.

## Owner accepted listener bytes; final validation authorized

The owner accepted the reviewed listener growth and the manager granted
final full gates and Chrome against clean master on zorg.3. Remeasured all
16 emit fixtures after the timer-only fix: the 14 guarded outputs match
the reviewed build exactly, while both timers match master and their
unchanged goldens. Regenerated only the accepted 14 emit goldens from
these fresh real runs; manifest and commands in listener-approved-review.
Final gate and Chrome comparison remains pending at this entry.

## Final validation completed under the accepted-golden policy

The final zorg.3/default-mode gates exactly match clean master 620c322a45:
only the known six ownership golden mismatches, two CPU budgets and two
APFS case-folding tests. No emit mismatch or runner timeout on either
final run. Chrome has no new lane failure: lane 745/746 with DomCapabilities
only; master 742/745 with DomCapabilities plus baseline-only ScriptedFetch
and managed/Network. Kept all failures and corrected the initial slot
message's mistaken Chrome count immediately. The comparison accepts only
new failures as blockers, as the manager directed.

Reconfirmed all four empty-page hashes against master after final gates;
sizes remain 498/271 raw/Brotli and 1882/881 prerendered. Timer-only outputs
remain byte-identical at 1897/880 and 1817/842. The other 14 retain the
reviewed bytes, +39–52 Brotli each. Regenerated exactly their accepted emit
goldens from fresh runs; no other existing golden or budget changed.
The complete table, command manifest and comparisons are in
zig-out/scratch/listener-accepted-report.md. Released the slot with no job
running. The listener slice is ready for its authorized local commit;
shared Cmd/Sub and capabilities remain outstanding, and nothing goes to
GitHub.
