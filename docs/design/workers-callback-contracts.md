# Proposed platform callback record contracts

2026-10-30. **Requires owner decision [#1319](https://github.com/canassa/beni/issues/1319).
Not accepted language and not implemented.** This is option (b) of the worker
review. The worker API listings depend on this amendment. User examples carry
no ownership words. Their callback summaries are inferred from their bodies.

## Why this is a language change

Today language.md permits sync and ownership words only at the outer arrow of
a core or platform declaration. Moving callbacks to separate parameters fixes
sync but cannot express borrowed on a callback's nested state parameter.
The existing many and owned words do not express that obligation. The existing
entry protocol recognizes Tea and hosted records, not arbitrary worker records.
Claiming either mechanism already accepts these workers would be incorrect.

The proposal extends the existing entry analysis from ownership-checker.md §7
and §30.3. It does not assert that marking a callback value borrowed makes its
arguments borrowed. Entry combines the platform's declared callback contract
with the inferred ownership summary of each supplied function.

## Grammar and placement

In a core or platform type alias whose expansion is a record, an immediate
function field may be written as `field : sync (parameters → result)`.
Without sync it is `field : parameters → result`. Each parameter and the result
may carry the ownership words already allowed at those positions of an outer
arrow. Their compatibility rules remain those in language.md. Parentheses
around a function do not create an additional contract level. For example:

```text
pub type alias Definition config state call reply streamRequest error event chunk =
    init : Context event, config → Result error state
    start : sync (Context event, borrowed state → ⊤)
    handle : Context event, borrowed state, call → Result error reply
    stream : Context event, borrowed state, streamRequest, Sink error chunk → Result error ⊤
```

Only immediate function fields have this new contract position. Nested records,
function arguments within these fields, arbitrary tuple members and ordinary
user aliases acquire no new word position. Those remain misplaced_sync or
misplaced_ownership_word. Duplicate and incompatible words retain their current
diagnostics. A user may refer to the platform alias without writing any words.

An entry parameter may name a platform record alias under this amendment.
Expansion must yield a closed record of the selected entry protocol's fields.
This explicitly changes the current written-out-record restriction. Unknown
fields or missing roles report invalid_entry_kind. Existing Tea and hosted
entry declarations retain their current interpretation and diagnostics.

## Checking, unification and interfaces

Lowering retains a contract table on the platform alias declaration, keyed by
field name and parameter position. Ordinary type unification still sees the
same structural record with the words erased. The contract is not a nominal
record type and cannot be silently inferred from structural equality.

An annotated platform declaration that receives this alias imports its contract
table as obligations on that argument. After alias expansion and ordinary type
inference, the ownership and effect checks instantiate those obligations at
every call to that declaration. This includes records built by helpers,
record updates, aliases, generic forwarding and imported callers. Obligations
on unresolved function parameters propagate in the caller's interface summary;
they are discharged when concrete callbacks become known. A reachable entry
cannot leave them unresolved. Merely assigning a record to an ordinary alias
neither certifies nor removes the eventual constructor obligation.

Interfaces preserve the alias's contract table, its declaring package authority,
and the expanded parameter contract on exported consumers. Re-exporting through
a user alias preserves its origin but does not grant annotation authority.
Changing a contract invalidates reverse users even when its erased type is
unchanged. No contract data or wrappers survive emission. Handwritten platform
assertions remain on the trusted surface with body hashes and positive and
negative flip fixtures. Supplied user functions are checked from inferred
summaries; their behavior is never asserted by the alias.

Sync fields use the existing sync_boundary check. Borrowed fields require the
inferred argument summary to leave the root's reachable ownership cells usable
by the runtime after cancellation. A callback cannot consume, move, replace,
write an immutable owned cell, or export a resource that the root still owns.
Reading state and using its explicitly shared Ref or Semaphore capabilities is
permitted under those types' existing cell contracts. The analysis follows
aliases, closures and helper calls. Deferring a move into a command does not
hide it.

The proposed diagnostic is `worker_state_not_borrowed: Jobs.handle may move
root state through Worker.prepare; handlers borrow state retained by the worker.`
It points to the consuming expression and the constructor field that required
the borrow, with the shortest inferred alias path. This is a compile-time
ownership error, never InvalidOptions or a new runtime result variant.
Unresolved obligations report `worker_callback_contract_unresolved` with the
callback parameter and forwarding path. These two diagnostics are proposed,
not claims about today's compiler output.

## Entry rows and runtime obligations

Each entryKinds constructor row adds `callbackProtocol`, with value handlers
or machine, and the index of its entry parameter. A handlers record has exactly
init, start, handle and stream. A machine record has exactly init, update,
subscriptions, request and stream. The loader validates the types against the
config, state and protocol roles; it does not recognize module names.

For handlers, init establishes root state once. Start reads it synchronously.
Handle and stream borrow it for their entire request scope. The runtime retains
it until all child scopes and finalizers settle. Both serial and concurrent
constructors use this row. The concurrent bound changes admission only.
Root-owned children may retain read access until root cleanup. They cannot move
root resources away from their registered finalizers.

For machine, init establishes the model and initial commands. Update receives
the current model owned, runs synchronously, and installs only its returned
model before commands run. Subscriptions borrows that model synchronously.
Request and stream build messages synchronously; reply and sink are scoped
capabilities, not ownership of the model. Entry uses the existing finite model
invariant and retained-capture checks of §7, with command captures as retained
readers. No old model can remain available after an update that consumes it.
These are explicit extensions to the entry rows, not arbitrary new names
accepted by the existing entry word.

Implementation must pin cancellation after a read, a direct move, a move through
a helper, a deferred move, a generic forwarding call, an imported alias, a record
update and a suspending sync field. Include shared and pooled entries. Compare
interface cache invalidation and release bytes before accepting this slice.
