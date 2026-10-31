# Worker callback protocol contracts

**Decided by the owner, 2026-10-30: no language change.**
[Decision #1319](https://github.com/canassa/beni/issues/1319#issuecomment-6525031739).
Specified, not implemented. Record alias fields contain ordinary function types.
Neither platform records nor user examples gain new annotation syntax.

## Protocol metadata, not field annotations

Each constructor in the platform's entryKinds table names its zero-based entry
parameter index and callbackProtocol, either handlers or machine. The loader
resolves that parameter's ordinary record type after alias expansion and checks
its fields against the protocol's config, state, message and wire roles. Missing,
extra or ill-typed fields report invalid_entry_kind. Constructor and module names
do not choose the protocol. Renaming them does not change the obligations.

The parameter needs no entry word. In particular, this design does not widen
the existing entry word's grammar or its accepted Tea record shapes. Definition
and Machine are ordinary structural aliases. The table, not an annotation on
an alias, establishes their obligations at the constructor call.

| Protocol | Field | Callback obligation |
|---|---|---|
| handlers | init | Runs once in the worker root; may suspend; its result establishes root-owned state |
| handlers | start | Non-suspending; borrows root state while installing root-scoped children |
| handlers | handle | May suspend in a request scope; borrows root state |
| handlers | stream | May suspend in a request scope; borrows root state |
| machine | init | May suspend; establishes the model and root commands |
| machine | update | Non-suspending; receives model owned; installs only its returned model before commands run |
| machine | subscriptions | Non-suspending; borrows the model |
| machine | request | Non-suspending; constructs a message from the call and scoped reply capability |
| machine | stream | Non-suspending; constructs a message from the stream request and scoped sink capability |

Serial and concurrent handler constructors use the same handlers row. Their
admission policy does not change ownership. Dedicated and Shared use the same
rows, and pools retain their supplied Program's row.

## Ownership checker v2 and effects

**Implementation belongs to ownership checker v2, specified in
[ownership-v2.md](ownership-v2.md). v1 is frozen.** #1297 depends on v2's inferred
callback summaries, entry model invariant and native backing-identity demands.
The entry reasoning follows the Tea protocol in ownership-checker.md §7; that
reference explains the contract, not permission to extend the frozen v1 pass.
The existing effect checker enforces non-suspension, as it already does for
main's implicit sync boundary. No new language word is required.

After ordinary type inference, the constructor row supplies obligations against
the user's inferred callback summaries. This covers records built by helpers,
record updates, generic forwarding and imports. The compiler does not trust a
user annotation or infer authority from structural equality. Unresolved callback
obligations propagate through function interface summaries and must be discharged
when a reachable entry is instantiated. A record alias neither certifies a
callback nor hides its inferred effects or ownership behavior.

Interfaces retain the resolved constructor symbol, parameter index, protocol
row version, role substitution and remaining inferred callback obligations.
Ordinary record unification is unchanged. Re-exported aliases need no special
contract table. Changing a platform row invalidates reverse users even when
its ordinary function type is unchanged. No metadata or wrapper is emitted
solely to perform these static checks.

A borrowed state argument must remain usable by the worker after cancellation.
The callback cannot move a root-owned resource, mutate an immutable owned cell,
or export ownership that the root retains. Reading state and using its shared
Ref or Semaphore capabilities follows those types' existing v2 cell contracts.
The analysis follows aliases, helper calls and deferred command captures.
Machine update uses the finite model invariant and retained-reader checks:
no consumed old model remains reachable by a later runtime read or command.

The runtime retains root state until its children and finalizers settle, except
for the explicitly destructive fatal-shutdown policy in workers.md §7. Start's
root-owned readers may retain read access until root cleanup. They cannot move
resources away from the root's registered finalizers. A machine installs the
new model synchronously before launching commands. Reply and sink are scoped
capabilities; they do not grant ownership of the model.

## Diagnostics and fixtures

Use sync_boundary for a callback that may suspend at one of the implicit
non-suspending fields. Point to the field, constructor and suspending call chain.

The ownership diagnostic is `worker_state_not_borrowed: Jobs.handle may move
root state through Worker.prepare; handlers borrow state retained by the worker.`
It points to the consuming expression, constructor field and shortest inferred
alias path. It is never InvalidOptions or a runtime result variant.
Unresolved obligations report worker_callback_contract_unresolved with the
callback parameter and forwarding path. These are specified diagnostics for
the future implementation, not claimed output from today's compiler.

Pin cancellation after a read, a direct move, a move through a helper, a deferred
move, generic forwarding, an imported alias, a record update and suspension at
each implicit non-suspending field. Cover Shared and pooled entries. Include
constructor renaming and a changed callbackProtocol row with unchanged ordinary
type to pin interface invalidation. Compare release bytes to prove the static
contract emits no extra machinery. The trusted runtime row needs positive and
negative fixtures for its state lifetime and model replacement obligations.
