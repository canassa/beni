## Worker callback contracts and owner brief

**What I did**

Revised PR #1304 on Dagon only. Audited language.md's sync and ownership-word
positions against all seven worker modules and all user examples. Removed user
ownership annotations. The existing entry word cannot describe worker callback
records, and moving callbacks into separate parameters does not express a borrow
of their nested state argument. Specified option (b), a narrowly scoped platform
record-contract amendment with grammar, structural unification, interface
obligations, inferred user summaries, diagnostics and explicit worker entry rows.
Opened owner decision #1319. Current language rules remain unchanged until that
decision; none of the proposed APIs was implemented or claimed to compile.

Moved concurrency from Worker.Options and Pool.Options to the concurrent
constructor's validated Concurrency argument. Serial and machine constructors
have no admission bound to misconfigure. Added noStream and noStreamRequest
library values. Audited all options and separated raw NativeOptions from managed
Ready and request policy. Shared heartbeat and lease durations are elected by
the first initializer and compared before consuming configuration. Native
constructor option mismatches remain generic asynchronous WorkerLoadFailed.

Rewrote #1315 and the research introduction with a two-sentence realm explanation,
the same platform operations under each candidate, proposed diagnostics, costs
and first measurements. Counted 130 erased-callable use sites, including Task 41,
Inline 11 and Rt 12. These are uses, not storage declaration or conversion counts;
the callback storage migration size remains unknown. Recorded a source-reviewed
32-site inline upcast projection. Recounted the complete pinned WebIDL input with
balanced braces: 346 files, 2,782 declaration blocks and 11,620 member rows.
Generated output count and bytes remain measurements required from the future
Zig generator. No new compiler speed or release-size result is claimed.
Updated implementation issues #1295 through #1300 and #1302.

One new adversarial reviewer checked every signature and example. It found two
issues: localStorage acquisition escaped the sample's guard, and native shared
option mismatches could not be distinguished by a managed handshake. Fixed both,
then received confirmation of no remaining blocking findings. The reviewer also
recomputed the census totals and checked the upcast projection.

Full nix develop --command zig build gates passed with exit 0 on Dagon. Subsequent
changes were documentation clarifications. Relative paths and heading anchors,
fences, section-number preservation, user qualifier scans, census totals and
whitespace checks pass. Final-head CI will be awaited after this diary commit.
The final PR comment will record its result and removal of this session's owned
worktree, local branch and scratch. The remote design PR remains open.

**What I learned**

A callback annotation must have an actual grammar and checker contract. An
ownership word on a function value does not specify ownership of its arguments.
An honest proposed language change is preferable to presenting invalid syntax
as an existing guarantee. Likewise, an error reason is only public when the host
exposes enough information to distinguish it. Static types cannot recover a
native constructor's deliberately generic error event.
