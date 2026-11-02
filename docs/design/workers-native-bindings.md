# Native binding generation and indexed metadata

**Specified 2026-10-30; implementation proceeds in stages under #1612.**
This expands the owner's decided C mechanism in [workers.md](workers.md) §4.
It adds no beni grammar. Generated native objects have ordinary nominal foreign
types. HostFree, Host.Raw, inferred realm summaries and the precise-error rule
remain the selected contract; this document does not replace them with trusted
raw wrappers or hidden native-shape flow.

## Pinned input and the first usable generator stage

`zig build native-bindings -- <idl-archive.tgz> <output-directory>` runs the Zig
generator. It accepts exactly the @webref/idl 3.86.0 archive pinned by
[the receipt](research/workers/sources.json). It verifies its SHA-256 before
reading IDL. Generation is offline; this command never downloads a dependency.
The caller acquires the archive from the pinned URL. A wrong hash is an explicit
source mismatch and writes no output. Archive size, expanded size, file count
and nesting have bounded input limits. Paths are archive-relative names, never
filesystem extraction paths. The reader rejects duplicate paths and non-IDL
payloads cannot introduce declarations.

The first stage emits a complete native **type and metadata catalogue**, not
callable browser operations. It indexes every IDL input and declaration, resolves
partials, includes and interface inheritance, generates the ordinary foreign
types of native interfaces and namespaces, and emits explicit identity-upcast
rows. It retains every member's exact IDL signature and attributes. Every member
is marked `adapter_required`; none is silently considered non-throwing or made
public merely because its signature parsed. The output is a real build-command
product consumed by focused generator tests and checked by the beni compiler.
Compiler loading of callable binding rows is the next stage, after the adapter
and lowering records below exist. No public worker launch support precedes the
realm proof and Wire gates.

## Input representation and parsing

The WebIDL reader tokenizes identifiers, punctuation, quoted strings and comments.
Strings and comments cannot terminate an extended-attribute list, a declaration
or a member. Source references are byte offsets into the owning file. Nodes are
flat fixed-size rows with ranges into shared sidecars; recursive braces and
parentheses use an explicit bounded stack. Parsing does not backtrack.

Recognized top-level declarations are interfaces, callback interfaces, interface
mixins, namespaces, dictionaries, enums, typedefs, callbacks and includes.
Partial interface, mixin, namespace and dictionary declarations remain distinct
source blocks before merging. Unknown declaration forms, malformed nesting,
unterminated strings or comments and incomplete declarations are errors with
file and byte span, not skipped lines. For this stage, a member row is a complete
semicolon-terminated IDL member at its declaration-body depth. The full tokenized
signature is retained, including argument types, optional and default arguments,
overloads, extended attributes, iterable and collection declarations and special
operation modifiers. A later operation mapper must classify every row; keeping
its source text is not approval to lower an unclassified operation.

The index preserves enum values and standalone callback and typedef declarations,
not only the interface blocks counted by the original research receipt. It also
preserves declaration-level extended attributes as source text. Exposed and
Global are parsed into explicit names; an absent Exposed is not assumed portable.
The literal wildcard is recorded as such and resolved against the compiler's
native universe when a binding is loaded. SecureContext, RuntimeEnabled and
other availability predicates remain in the original attribute text and cannot
be mistaken for a guarantee that a browser implements a feature.

## Deterministic merge and native identity

Sort files by normalized archive path, declarations by source order, and merged
native identities by exact IDL name. An interface or namespace has exactly one
primary declaration. Partials must have a compatible primary kind. Includes
must join an interface to a declared mixin. Duplicate primary declarations,
missing parents, missing include targets and cyclic inheritance are refusals.
Repeated includes of the same interface and mixin are refused as duplicate
identity. Merging retains each source block and member range. It never overwrites one
partial with another or expands a mixin twice because of input ordering.

Each native interface and namespace gets one nominal type. The generated module
is `Browser.Host.<IDLName>` and exports `pub foreign type <IDLName>`. These are
opaque native object identities, without a constructor, wrapper record or runtime
allocation. IDL names that cannot be represented as an ordinary beni module and
type name must receive an explicit versioned name-map row before generation;
they are not guessed or silently renamed. Format v1 maps only the lowercase
IDL namespace console to Browser.Host.Console and its Console type. The artifact
publishes that map and rejects collisions with unchanged IDL identities. Dictionaries, enums, callbacks and
typedefs retain catalogue rows but are not opaque native objects. Their callable
operation mapping must later produce ordinary beni records, unions, function
and alias types from the retained IDL facts. Mixins contribute operations to
implementing interfaces and do not manufacture standalone object types.

For each interface inheritance edge, emit an upcast row from the child nominal
type to its parent. The row lowers to identity. Chained conversions are ordinary
composition; there is no general subtyping or implicit downcast. Operation
inheritance and mixin application resolve through this same indexed graph.

## Indexed artifact contract

The catalogue has a format version and the exact source package, version, URL
and SHA-256. Its sorted files retain path and source text; declaration and member
rows refer to file indices and source offsets. Native type rows link module
name, ordinary exported type name, primary declaration, exposure and parent.
Upcast rows name the source and destination type indices. Every operation row
also has a status; the first-stage status is adapter_required.

A later callable binding row must contain all of:

- native identity: declaring interface, member name, overload and source span;
- resolved ordinary beni signature and its nominal type identities;
- inferred availability seed from Exposed and native intrinsic metadata;
- effect rung and the exact typed expected-error adapter;
- direct-lowering recipe and any argument conversion or validation obligations.

IDL does not describe every exception. A missing adapter or recipe blocks that
operation from the generated public API. An adapter must name its primary-source
algorithm and exact expected predicate; every other failure remains a defect.
No generic catch, structural brand guess or arbitrary Js.Value conversion fills
the gap. Unknown host intake uses Host.Raw, and an unavailable sound validator
returns the selected RawValidationUnsupported outcome.

The compiler integration seam resolves generated ordinary foreign types to the
existing nominal TypeId by module and declaration provenance. It verifies the
artifact's source revision, identities and signature against the resolved
interface. There is no new TypeStore variant for a native-shaped Js.Value.
Native identity, realm and HostFree facts belong to indexed metadata associated
with that nominal identity. Type inference and ordinary callback summaries keep
the identities visible. This seam will not be enabled until the complete row
validation and direct-lowering consumer are implemented together.

## Diagnostics and validation

Generator diagnostics distinguish source mismatch, invalid archive, invalid IDL,
duplicate native identity, unresolved reference, inheritance cycle and unsupported
beni name. Each IDL diagnostic includes file and byte offset and writes no output.
Malformed native metadata is never accepted as an ordinary user error at runtime.

Focused tests exercise the actual generator command with the pinned archive,
compare repeat output byte for byte, check the complete source counts, and feed
generated nominal types to the real beni compiler. Small parser tests cover
attributes, partials, inheritance, includes, dictionaries, enum strings, callbacks,
typedefs, overloaded operations and malformed nesting. The byte parser has a fuzz
harness. Check rejection before output for source mismatch and invalid references.
Future operation tests pin wrong native receivers, realm misuse through callback
and container paths, exact error predicates and unchanged emit/release/ bytes for
identity upcasts and direct operations. Generation time and catalogue bytes are
reported separately from ordinary checker throughput and package-index loading.

## Callable subset in the compiler

The first callable rows are `Window.document`, `Document.querySelector`
(from ParentNode), `Node.textContent` get/set, `Element.toNode`,
`TextEncoder.create`/`encode`, `Timers.setTimeout`, and
`WorkerGlobalScope.self`. `Uint8Array.byteLength` is an ECMAScript intrinsic
under intrinsic revision 1. The pinned catalogue resolves the reviewed rows
in `src/native/Operations.zig` to native declarations and member spans;
unreviewed members still require adapters. Generation emits source-linked
callable rows, ordinary typed modules and precise-error siblings. The first
modules ship in core, so loading uses core provenance, never an app's module
spelling. The checker validates callable signatures and effects against the
trusted table before it seeds a summary or the backend uses a direct recipe.

Native objects remain host objects. Identity upcasts, construction, encoding
and simple property operations lower directly. Result/Maybe adapters retain
their normal beni representation. The query-selector adapter catches only a
DOMException named SyntaxError, and rethrows everything else.

Realm bits travel on the existing typed effect classes, copies and dependency
edges. Shared pure classes must be published when distinct scheme sites refer
to them; otherwise an imported opaque holder loses its stored callback's
summary. Interfaces carry availability and deferred generic dependencies.
Interface format 19 adds realm class words, initializer availability and the
dormant HostFree quantifier bit; dispatch format 16 carries entry/initializer
availability. EntryHost checks each emitted projection before output.

HostFree is implemented behind an internal Session option, off by default
until typed Task storage and the dependent callback queues are ready. It walks
representations, including opaque constructors, and retains generic requirements
in interfaces and through the quantified-use/copy worklist. No CLI flag exposes
this rollout option. Browser Http/WebSocket UTF-8 length helpers use the new
native operations; remaining native migration is tracked in
[#1636](https://github.com/canassa/beni/issues/1636).
The HostFree representation facts are immutable before the checker DAG runs;
held parameters and native/callable flags reach a fixed point without expanding
recursive type applications. Dependency digest version 6 includes those facts
when the internal option is enabled, including private representation changes.
