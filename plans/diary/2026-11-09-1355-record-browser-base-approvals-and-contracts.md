## 2026-11-09 13:55 CET — Record browser base approvals and contracts

**What I did**

Recorded the owner's five approvals, relayed by the manager, in the browser
capability base design. Updated sequencing: move capabilities with current
inline subscription limits, then add model-dependent sets and full keyed
policies before the site depends on them. Kept all work local.

Specified scoped listener registration with a captured renderer entry,
including nesting, synchronous decoding, restoration and defect behavior.
Specified existing command log-context capture and reply-update context
restoration. Proposed a separate phase-aware init proof for review, because
shared command construction currently reads context impurely. Added exact
fixture contracts to the document and unexecuted source drafts under
`zig-out/scratch/contract-fixtures/`. The existing ThrowingRead corpus case
is the guarded-reader regression to retain.

No compiler or platform implementation was changed. No build or test was
run: dependent implementation awaits the manager's review of the contracts,
and the earlier zorg build prerequisite remains stopped. No GitHub action.

**What I learned**

`Js.read` is explicitly impure, so `Task.keepLogContext` cannot be called
pure merely to accept shared commands in a prerender init. The existing
`directPure` walks the whole init body. Preserving command construction
context therefore needs an explicit phase-aware proof or another approved
design, rather than moving capture to command execution after the dynamic
log scope has ended. A deferred command body's host read and an eager
capture of a host value need opposite acceptance results.
