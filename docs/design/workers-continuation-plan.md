# Symbolic continuation plans and checked control lowering

Specified 2026-10-30 for workers-typed-runtime.md §3 and #1295. This is an
implementation extension of the selected typed-slot/closed-closure design.
It adds no source grammar, native exemption or ownership-v1 exception. Public
worker launching remains gated. The first deliverable publishes and round-trips
metadata only; it does not change Task, Suspend or emitted programs.

## 1. Preserve evidence before the checker store expires

`check/Module.zig` P5½ solves effects and builds EffectPlan; P6 elaborates
callee/evidence choices. The module's TypeStore, instruction/local type tables
and solver variables normally expire after checking. `js/Suspend.zig` currently
splits already-untyped JavaScript. It cannot reconstruct the lost type pairing.

Build `check/ContinuationPlan.zig` after P6 from the existing solved tables,
while they are alive. Publish only for modules with no errors, and only after
all publication/error checks succeed. The plan is a module artifact, independent
of which entry later reaches a declaration. Cached and fresh modules provide the
same artifact. Entry projections select sites; they do not instantiate all
recursive calls or merge runtime storage obligations across realms.

The plan is not the TypeKeys artifact. TypeKeys deliberately collapses open,
polymorphic and foreign types to wild; this plan must retain those types and
their identities. Nor is it a serialized TypeStore: no union-find parents,
ranks, solving worklists, pointers or unrelated locals/instructions are kept.

## 2. First artifact schema

The first version records symbolic type/effect evidence for existing EffectPlan
sites. It is deliberately not yet a continuation-body or free-variable plan.
Consumers must not infer that producer/consumer checking or Task migration is
complete from its presence.

Use fixed-size indexed rows and one extra-data array, under the repository's IR
rules. Stable order is declaring BIR declaration, then instruction order.

- A scope identifies one owning declaration. Its body type supplies the actual
  quantified/rigid variables used inside that body; its published scheme remains
  the source contract. The builder validates their instantiation relationship.
- A site identifies its BIR declaration and instruction, carries EffectPlan's
  `own` and `body` no/yes/poly choices, and refers to the solved instruction type.
  Function-definition roots come from Effects.fns (their authoritative checked
  function variable), because a let_def is not an expression with inst_type.
  Expression roots come from inst_type. Function-definition sites remain distinct
  from call sites. No effect row is
  silently treated as a call merely because it has `own != no`.
- Symbolic type nodes retain parameters, nominal applications, n-ary functions,
  tuples, records including row extensions, and unit. Aliases may be normalized
  to their expansion; recursive nominal bodies are not recursively expanded.
  Named/foreign types retain their actual declaring identity.
- A parameter belongs to a scope, with canonical binder position and ordinary
  quantified constraints. Distinct scopes' parameter zero is not one variable.
  Body variables corresponding to an annotation's quantified parameters are
  mapped to those parameters; they must not become unrelated fresh variables.
  Additional local binders retain distinct identity. No parameter becomes wild.
- Effect classes and their dependency/sync/sensitivity evidence use the existing
  Effects/Interface.EffectBlock vocabulary. Type paths name the symbolic roots
  they describe. Preserve dependencies; a poly site does not become always-yes
  or always-no. The plan does not replace authoritative interface summaries.

Use the existing Schemes.Writer and Interface Scheme/Term/Quantified/effect-block
vocabulary, not a second type language. Write each scope as a multi-root bundle
in one scheme-writing epoch so equal body variables remain equal across roots.
The bundle begins with the owner's published scheme type, then its actual
checked body type, followed by solved site roots in stable order. Use the
authoritative owner-and-annotation-specific lexical binder table captured from
P2/P3 `Types.Builder.scope` by `Effects.schemeReading`/`checkReading`. The same
annotation/where binder keys, order and kinds must agree. Record the actual
scheme and rigid-reading Vars in a typed indexed table; never infer binders from
all allocations in an annotation read. Schema reads allocate temporary flexes
that are not formal parameters, and the supported effect solver can structurally
zip readings whose allocation counts differ. Both cases keep the same real
lexical binders. An empty map is justified only by an explicitly captured empty
binder scope in both readings. Never merge/unify variables to force a match.
The checker already checked the body against its rigid reading. Unannotated owners share their existing roots. Reuse existing type
reference, constraint and effect encoding/validation. Preserve the owner
scheme's identity-quantifier and JavaScript-crossing flags using the same
authoritative Dispatch/TypeKeys inputs as ordinary publication. Extra local
quantifiers do not inherit another binder's flags. A private serialized scheme
record may carry these tables; it is not a new public interface surface.

Only scopes/types reachable from these roots and their effect evidence enter
the artifact. A module without sites has an explicit versioned empty plan; its private type
record is omitted (canonical 24-byte plan header) and no per-instruction
function-root table is built. Private type records admit only the reused
scheme/term/extra/type-reference/symbol tables; unrelated public interface tables
are invalid. This
empty representation is distinct from absent evidence. Unsupported or
missing solved evidence in a clean module is a compiler fault, not an empty plan
that falsely certifies completeness. Poisoned modules publish no usable plan.

A later version adds ordered free variables, typed continuation bodies and
join/loop regions. Do not guess those from an incomplete first-version row.
An annotated polymorphically recursive call at `List a` is a finite symbolic
application involving the same binder, not an instruction to monomorphize the
next nesting level. One source site remains one site at arbitrary recursion depth.

## 3. Bytes, cache validity and diagnostics

Carry the plan with the module's existing dispatch sidecar, with an explicit
plan schema version and a dispatch format-version bump. Existing older entries
are misses, not implicitly complete empty plans. Embedded checked-core packs and
ordinary cache reads use the same path; build/cache identities include the new
format. No raw TypeStore.Var, session TypeId, Symbol or Graph.Index reaches bytes.
Nominal references use package/declaring-module/type identity; names use text.
BIR indices remain module-local indices pinned by that module's source key.

Loading validates column bounds/alignment, checked arithmetic, row tags and
reserved fields, roots/children/ranges, parameter scope/position/constraints,
canonical ordering and acyclicity of structural type references, and all effect
class/path/dependency references. A linear colored walk checks structural and
alias-body cycles; variable requirements are checked separately in owner and
alias-parameter scopes. Validate effect paths against the actual type structure,
including explicit alias expansion and substitutions, using explicit indexed alias frames bounded by the actual
encoded path, without applying the public publication depth limit. No source type is truncated. Unresolved nominal references are validated
through the existing read-then-resolve graph/type-table phase. Resolution failure
or malformed/unknown-version bytes is a cache miss. No corrupt input reaches an
assert or panic. After BIR and dispatch are available, validate owner ranges,
site instruction kinds and complete agreement with the saved EffectPlan rows.
The nullary-dot checked rewrite is validated through the existing dispatch callee
evidence before cache installation: frontend field_access plus a recorded
nonnull callee becomes the checked method_call, exactly as Nullary.cached does.

The hidden `dump --stage=continuations` inspects uncached metadata. For cache
validation, hidden `check --continuations` prints the same source-module artifacts
that the actual check installed, following existing `check --type-keys`. It does
not recompute metadata from discarded stores. Default check output, diagnostics
and exit codes are unchanged; dump continues to refuse cache flags.

Extend the existing dispatch roundtrip hook so an enforced roundtrip covers the
plan as well. A cold publication, roundtrip and warm cache read must preserve
symbolic parameter equality, nominal identity and yes/poly distinctions. Bump
only the formats that actually contain these rows; do not alter the public
interface layout merely to store module-private continuation evidence.

## 4. Checked control representation: later deliverable

Before JavaScript lowering, generate ordinary rank-one typed declarations for
control and result slots, conceptually:

```text
Control a = Direct a | Parked (Slot a)
Slot a = Ref (Maybe a)
```

Check generated constructors, patterns, calls and closures with ordinary typing
and effect rules. Preserve source callback/suspension/realm obligations and the
original declaration schemes; making control explicit must not hide a source
callback obligation. Check producer/consumer pairing before erasing types.
The plan alone is not this check. No higher-rank/existential source type is added.

A generated continuation captures its input Slot a, output Slot b and other
values at their actual types inside a closed unit job. The emitted entry has a
finite closed union of site jobs. A generic job helper remains symbolic; storing
its closed unit callback does not store an unconstrained a in a universal field.

On an immediate call, return Direct value without allocating a result slot or
continuation. Only after observing Parked input does its caller allocate an
output slot and frame, append that frame inner-first, and propagate Parked output.
A missing result is an internal defect. Consumption/token state prevents repeated
frames or stale wake callbacks from publishing or running work again. Pending
work is detached/consumed before callbacks, preserving existing scheduler and
cancellation order. The prototype's silent Nothing and repeated-drain behavior
are explicitly not admissible production semantics.

## 5. Sentinel representation proof: later deliverable

Keep the existing unique sentinel as runtime control, never as an application a.
After checking the explicit control graph, a representation pass may encode
Direct a as the raw return value, and Parked slot as that sentinel plus a
compiler-private return-payload channel. This channel is a representation of the
checked sum's payload, not a source Value field, runtime cast or unchecked native
callback store. There is no implementation of this channel in the first slice.

The representation pass must verify:

1. Each parked payload is produced by the matching checked Control a constructor.
2. Each payload projection belongs to the immediately preceding call's matching
   Parked branch, with the same substituted a. Capture it into its typed local
   before any callback, call or operation that can overwrite the channel.
3. A direct branch never reads the payload channel or allocates a slot/frame.
4. Calls invalidate prior uncaptured channel evidence. Nested execution,
   independent schedulers and exceptions cannot reuse stale evidence.
5. The channel belongs to the same emitted runtime/realm instance as its sentinel;
   entry/shared-code placement cannot mix incompatible instances or payloads.
6. All joins, tail-loop re-entry and list-building continuations preserve these
   rules. Source Task.andThen/isWaiting keep their ordinary public behavior;
   compiler protocol operations do not expose the channel to source callers.

These are checked constructor/eliminator representation obligations. A generic
cast from a global raw value is not an implementation of them. If the pairing
cannot be established for a shape, do not emit it via a fallback. Specify and
complete the missing typed transformation before switching production Task.

## 6. Deliverable and validation order

First: plan publication, serialization, validation and focused inspection tests.
No Task/Suspend/Lower/queue changes, no payload-channel implementation. Check
annotated polymorphic recursion at changing List nesting, distinct Int/String
sites, higher-order poly effects, nested binders and independent nominal types.
Use the actual compiler/dump boundary for symbolic evidence; retain full existing
runtime transcripts and emitted bytes. Corrupt/truncated/version-mismatched cache
artifacts must safely miss and rebuild. Compare cold/warm/roundtrip and jobs1/jobsN.

Next: generate and ordinarily check the explicit control graph, then prove its
sentinel representation on finite immediate/parked cases before complete Task
migration. Include joins, loop/building-loop re-entry, interruption, stale/double
resume, finalizer ordering/failure, independent schedulers and fatal deadlines.
Immediate paths must construct no destination slots/frames or boxed direct
results. Source allocation counters are not VM allocation measurements.

Every production switch retains the individual original release-byte budgets,
identical raw/Brotli measurement options, runtime parity and checking-throughput
budgets. Measure with the Zig development compiler and coordinate timing windows;
no benchmark, allocation or byte claim follows from this design alone. Worker
launch stays gated until the complete typed runtime and realm/Wire proofs pass.

## 7. Private depth and transient construction

The public scheme writer's 512-level publication bound is not a limit on private
solved types. A private function may return thousands of nested lists while the
public main has a shallow Program type. Metadata must not reject this program.
The scoped writer therefore uses an explicit postorder stack over reachable
variables, retaining the ordinary Scheme vocabulary, memo sharing, record-field
text ordering, constraints and alias-body tables. Alias bodies are emitted with
the same private iterative traversal. Ordinary add/addPlanRoot behavior and their
existing depth policy remain unchanged. No depth cap is raised and no err/wild
substitute is serialized. The compact artifact's explicit graph verifier detects
cycles and checks owner/alias parameter bounds. Effect paths use explicit indexed
alias frames derived from their actual encoded data, with no public-depth cap.

The synthetic bundle TypeStore.fresh/addVars operation appends only a temporary
tuple descriptor for the existing effect-path traversal. It does not unify or
change any existing type content, flags, constraints or scheme. Parameter pairing
is held in the writer's private memo, never forced into the source store. Verify
that original interface flags and emitted programs remain unchanged.

Canonical alias rows preserve nested alias names, while `TypeStore.resolved`
compresses an alias chain's `actual` links. Effect paths are produced from that
checked store. Private path validation therefore expands canonical alias chains
transparently before a non-expansion step and before checking the terminal
carrying type; an explicit expansion still requires an alias. Substitution uses
indexed frames and the already checked acyclic term graph. Field steps compare
interned names, since the symbol column can contain repeated occurrences.
The private export traversal lives in `check/ScopedTerms.zig`; its writer
callbacks preserve the ordinary scheme vocabulary and public writer behavior.

Scope and site IR use `MultiArrayList` columns of small fixed records; each
scope addresses its sites by a flat start/length pair. The private codec retains
its explicit 16-byte scope/site rows, so storage layout is independent of the
in-memory columns. Variable type payload remains in the shared Interface extra.

The scoped writer preseeds the owner's complete canonical quantifier order,
including parameters reachable only through transitive `where` constraint types,
before visiting body/site roots. Owner identity ordinals retain their ordinary
scheme meaning; unrelated site parameters are appended after all owner parameters.

Private path validation computes one symbolic head-projection summary per term
in its existing acyclic postorder. A parameter projects its own index. An alias
whose body projects parameter `q` inherits its actual argument `q`'s projection;
other terms have a structural, nonprojecting head. Transparent normalization of
such an alias jumps directly to that argument under the existing outer frame.
It does not instantiate the alias body or allocate a frame. Nonprojecting aliases
retain indexed substitution frames; explicit expansion steps still expand exactly
one named alias. Thus compact compositions of identity aliases do not cause
exponential expansion. Tests count summary work, normalization steps and retained
frames deterministically, rather than imposing a depth or expansion cap.

Private record fields must be strictly ordered by actual field-name text, with
no duplicate names even when distinct local symbol slots contain the same name.
On cache installation, resolve private references once and check every app/alias
term against the declaration's real kind and exact arity. These checks supplement
generic Interface bounds validation without changing the public Interface codec.
Substitution frames are truncated when their parameter is projected to an outer
frame; the backing array retains capacity, never dead frame entries.

The normalization work bound is polynomial in encoded evidence: build projections
once in O(term/alias edges); each encoded effect-path step and its terminal head
normalization traverse at most the encoded graph depth, without expanding argument
diamonds. Across paths the bound is O(graph size × (total encoded steps + paths)),
not blanket linearity in source size. Live substitution storage is bounded by the
current path's explicit expansions and graph traversal; projected frames are
popped rather than retained. Deterministic tests include compact diamonds at32/64
levels, mixed structural/projecting aliases and explicitly shadowed parameter0.
