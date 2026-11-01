# Generic entry runtime implementation

2026-10-30. This specifies the first implementation of workers.md §2 and §11,
tracked by #1293. It adds manifest data, not language syntax. The larger runtime
and typed-callback restructuring required by the decided design is authorized;
implementation must retain its guarantees and budgets.

## Metadata and inheritance

A platform manifest may declare entryKinds, an array of records. Each record
has programType (a module-qualified nominal type), realm (a native realm name),
runtime (a module name in that platform package), constructors, launches and
parameters. All six fields are required, as workers.md specifies. A plain
top-level program whose nominal type takes no parameters writes explicit empty
arrays for its unused constructors, launches and parameter roles. A kind is identified by its
program type, not an arbitrary string alias or a compiler-known module name.

Constructor rows name a qualified declaration in name, its zero-based callback
record parameter in parameter, and callbackProtocol (handlers or machine).
Launch rows name a qualified declaration in name and the zero-based parameter
receiving this kind's Program in parameter. Parameter rows have index, an
optional field path and role (wire or local). An empty path selects the complete
type argument; a nonempty path selects record fields after ordinary expansion.
Distinct leaves must not overlap or repeat. The worker protocol's six fields
use six wire rows under parameter index two; state uses a local row at one.

The chain combines rows from its platform packages while preserving the defining
package and source manifest. Repeating a program type is invalid_entry_kind;
there is no order-dependent override. Identity is the resolved declaring module
and type, including its platform package, not a raw qualified string. The current
module graph still refuses equal platform module names across chain layers as
duplicate_module; this slice preserves that boundary and adds no new package
namespace feature. Unknown JSON keys retain the manifest's
ordinary forward-compatible behavior. Missing required fields or malformed JSON
field types remain the manifest's exit-2 error. Invalid semantic names, arities and roles produce
invalid_entry_kind against the defining manifest at 1:1, before output is written.

For the first complete runtime foundation, an existing top-level program string
selects the row with the same nominal type. Its runtime module supplies run
independently of markup. A platform without such a row keeps its existing
runtime-file or markup-module behavior. This compatibility path does not permit
a generic row to evade its checks by adding a legacy runtime file.

## Runtime contract

Check and build validate the same metadata against checked module interfaces.
All metadata-named modules are roots even when an app does not import them.
The selected runtime's run must be a public beni value with a body, exactly one
parameter and no hidden evidence parameters. The parameter is the selected
nominal Program with its declared arity; the result is unit. This unit-returning runtime cannot also supply the result required by
legacy exports program mode; that contradictory combination is invalid_entry_kind.
Aliases are expanded
using their checked interface bodies. Generic type arguments remain generic;
the runtime cannot silently specialize a universal Program contract to Int.

Run must not suspend. Read its inferred effect summary, rather than trusting a
name or a source annotation. Alias expansion is transparent to this check:
a body-root effect site reached through only zero-index alias-expansion steps is
still the runtime's own arrow. Parameter, result, field and other structural
steps name nested sites and must not be mistaken for the runtime arrow. Apply
the same inferred suspension/dependency rule to direct, nested, parameterized
and imported aliases, including warm cached schemes. A suspending root reports entry_runtime_suspends
at run, naming the selected runtime and pointing to the deferred-root pattern:
install listeners, start an owned root fiber, then return. Init may suspend
inside that fiber. A wrong signature, missing run or missing module reports
invalid_entry_kind. No generated output is committed after these failures.

The entry emitter calls run(main) synchronously. Generic runtime roots are
separate from markup roots: a program runtime does not have to implement start,
flush, markup primitives or any other export from the markup lowering's union.
When both exist, each imports and roots its own real beni module. Legacy
markup runtime tests retain their existing bytes and diagnostics.

## Validation boundary and follow-on work

Every declared program type and referenced constructor and launch symbol must
resolve. Indices must fit the declared saturated arity. Constructor results and
launch parameters must name the kind's Program with the correct arity. Callback
protocol tags and parameter roles must be well formed; contradictory or duplicate
rows are refused. Pending structural field obligations belong to the generic
scheme and are discharged on instantiation, not treated as satisfied by a parser.

This foundation does not emit source-discovered worker entries or add a public
worker launch API. #1294 owns the finite descriptor worklist, concrete type-role
instantiation, independent entry graphs, paths, bootstrap and output proofs.
#1295 and #1296 must provide realm and wire proofs before public worker launches
ship. #1297 supplies the callback protocol's ownership v2 obligations. Parsed
metadata alone is never advertised as worker safety or implementation of those
later slices.

## Evidence required

Black-box tests build a real non-markup platform with a beni runtime, execute
its emitted entry and observe its output. Pin both development and release entry
shapes. Refuse missing runtime or run, wrong arity, wrong Program, wrong result,
extra evidence and a run that suspends directly or through a helper. Include an
aliased Program and a metadata runtime unimported by app code. Check and build
must agree, and failures must leave no emitted output. Parser unit tests cover
malformed rows; fuzzing must retain the manifest reader's no-panic contract.

Use the development compiler while iterating. The manager runs full gates after
integrating the implementation and reviews the emitted behavior and diagnostics.

## Foundation scope

The first code slice checks runtime signatures and effects completely for the
selected top entry. Constructor records currently receive field-name and arity
shape checks, not ownership or effect certification of their callbacks. Concrete
record paths in constructor and launch schemes are checked now; generic field
paths remain in the original metadata as obligations for later instantiation.
None of these shallow shape checks certifies Wire or native realm availability.
The later source-entry, realm, wire and ownership v2 passes must consume the
retained rows before a public worker launcher can ship.

## Compact source discovery follow-on

[workers-entry-compact.md](https://github.com/canassa/beni/issues/1612) specifies the reviewed finite
symbolic source template/observation kernel, declaration sealing, paired capture
obligations and explicit residual boundary before its replacement implementation.
It remains a partial diagnostic foundation: no public worker launch, multi-entry
emission or completed C/EntryHost/Wire/ownership proof follows from that artifact.
