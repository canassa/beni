## 2026-11-03 04:29 CET — Typed Cloudflare storage

**What I did**

Migrated the Cloudflare platform's handlers, state, request trampolines,
mailboxes, native handles and completions out of Js.Value. The reviewed
native supplement pins Cloudflare workers-types5.20261102.1 and its archive
digest. Generated Promise resolvers retain exact non-thenable payload types;
native adapters preserve unknown thrown identities. List readers support
arrays, trie headers and suffix views, and retained definition lists are
snapshots. Generated declarations now retain their canonical formatting.

Objects use closed typed jobs, native completion handles and a private
parameterised Context carrier, preserving independent callback effects and
handler suspension. RPC and host-event promises preserve host-abort Reset
semantics. Reply holders use wd-size's compiler-derived traversal and the
agreed private brand. Integrated its library-pack correction1fd81d7b.

All16 workers fixtures pass under Miniflare in development and release,
with32 recorded hashes. The final isolated HostFree family check passes,
from134 initial refusals. Added native failure/List-representation probes,
a nested/generic Reply and callable/native state fixture, the named-access
fence fixture, and six HostFree refusal cases parked while rollout is off.
The fresh safe compiler and generated skill API pass. The broad run-hash
attempt exposes inherited HostFree failures; their goldens were not changed.
Logs and receipts are under the lane's worktree-evidence directory.

**What I learned**

An opaque non-parametric recursive context merges latent callback effect
classes. Keeping the instance as a private carrier parameter preserves those
classes. Native resolvers also keep completion callbacks out of handler
storage. An RPC failure must remain pending until host abort if its public
result is Reset; rejecting it early changes the caller's behavior.
