## 2026-11-02 19:56 CET — Preserve runtime storage types

**What I did**

Added the approved private typed list builders, checked existential storage,
borrowed Debug inspection and data-only schema failure reporting. Kept callback
roles and implicit type identities through generic and higher-order code.
Migrated coordination containers, Task scheduling, Hosted jobs/taps/relays and
inline dispatch/subscription/undo storage. Added generated host scheduling,
event and filesystem operations. Rebased onto the merged worker runtime and
generic Wire work. Kept worker event streams and Node Program/file waits typed.

Checked focused runtime, inspection, identity, effect, realm, TEA and inline
fixtures. The inline send regression now runs in development and release.
These are checkpoint commits: HostFree remains off, larger Schema and renderer
families remain, and final hashes and full gates are still owed before a PR.

**What I learned**

An existential must retain the separate callback roles of the stored value;
one flattened effect class conflates a function with the callbacks it receives
or returns. Imported generic helpers need the same structured relationship.
Typed queue entries also need a typed protocol invocation at the synchronous
runtime boundary so release elimination retains their side effects.
