# Stored schema functions and inferred effects

This prototype is synchronous. It can show that ordinary Beni values can store,
swap, and compose reader and writer functions, but it cannot show that either
function suspends correctly. In particular, a successful call through a stored
function is not evidence for H4: there is no suspension object, continuation,
cancellation, or inferred effect bit in today's compiler.

## What the pinned Effect implementation establishes

Effect keeps the two directions separate. A `Transformation` stores a decode
getter and an encode getter and `flip` swaps both the functions and their
directional requirements
(`references/effect/packages/effect/src/SchemaTransformation.ts:178-210`).
Composition runs decoders forward and encoders backward, unioning each
direction's requirements independently (`SchemaTransformation.ts:245-260`).
Effectful getters are distinct stored variants whose functions return `Effect`
(`SchemaGetter.ts:61-87,126-137`), and `transformEffect` constructs both sides
without erasing that distinction (`SchemaTransformation.ts:380-387`).

The distinction propagates through the schema itself. A schema exposes separate
`DecodingServices` and `EncodingServices` parameters
(`Schema.ts:172-180`); a composed transformation unions the source, target, and
conversion requirements in the matching direction (`Schema.ts:5322-5326`). The
public decoder and encoder return effects carrying those respective requirements
(`SchemaParser.ts:262-303,615-655`). At execution, the interpreter sequences a
stored `TransformEffect` with `flatMap`, rather than treating the returned effect
as the transformed value
(`internal/schema/interpreter.ts:17-22,34-62`).

That is the relevant standard. Effect's service type parameters are not a demand
that Beni copy its environment type. They demonstrate that effect information is
part of each stored direction and survives construction, flip, and composition.

## Compatibility with P2, and the unresolved point

P2 has the right local mechanism. Every function type carries inferred
`suspends` and `impure` flags; calling a function propagates its flags to the
caller; a lambda keeps its own flags until it is actually called; and top-level
definitions generalise flag variables
(`docs/design/transparent-effects-proposal.md:459-469`). Pure functions may be
used in effectful function positions by lattice subsumption, including record
fields (`:491-497`). A call whose bit is true or unresolved receives the L1
suspendable lowering (`:716-722`). This is enough in principle for a structural
record whose reader and writer fields retain their own function types: `flip`
just swaps fields, and composition creates directionally correct lambdas.

It is **not yet a proof for the proposed `Schema e a` abstraction**. If `Schema`
is opaque or nominal and its published type carries only `e` and `a`, the effect
variables of the stored reader and writer may disappear at the abstraction or
module boundary. Calling `decode schema` then has no visible reason to inherit
the particular value's reader bit. Conversely, conservatively marking every
schema operation suspending would preserve correctness but lose P2's synchronous
fast path and is a material API/runtime choice. The existing P2 plan already
requires flag obligations rather than equality and interface preservation for
higher-order functions (`plans/effects-plan.md:131-139`); it does not yet specify
effect information hidden inside a nominal value.

Therefore the synchronous library shape is useful but H4 remains open. Before
the representation is fixed, the effects design must show one of:

- the schema's two stored function types remain visible to inference across the
  abstraction and interface boundary, with independent reader/writer bits;
- the nominal type carries equivalent directional effect parameters; or
- all schema execution is deliberately effectful, with the fast-path and output
  cost measured and accepted.

The same question applies to endpoint validators and recursive/deferred thunks,
not only custom transformations. Directional `impure` bits must survive too,
because release optimisation may not discard or duplicate those calls.

## Future executable acceptance

These require the effects slices and fiber runtime; none is claimed by the
prototype.

1. Build a schema in module A whose decoder suspends and whose encoder is pure;
   export it behind the intended schema abstraction. Module B decodes through a
   composed object/list schema, parks, resumes, and returns the exact value. Its
   interface dump must retain the decoder bit without colouring the encoder.
2. Flip that schema. Encoding must now park and resume, decoding must remain on
   the synchronous path, and a double flip must restore both interface bits and
   behaviour.
3. Pass pure and suspending transformations through the same top-level generic
   schema combinator in one program. Both instantiations must work. A local
   extraction should produce P2's explicit monomorphisation diagnostic rather
   than silently selecting the wrong lowering.
4. Suspend inside a recursive transformed schema after several fields and list
   elements. Resume with the full key/index path and correct depth. Cancel while
   parked and prove that no conversion continues after cancellation and that
   registered finalisers run.
5. Exercise `FirstError` and `AllErrors` with effectful sibling validators in a
   recorded left-to-right order. `FirstError` must not start later work;
   `AllErrors` must implement its specified sequential or parallel policy and
   retain every complete issue.
6. Make both decode and encode transformations fail after suspension, including
   through `flip`. The failures must remain ordinary directional `Issue` values,
   never suspension objects mistaken for successful data.
7. Put schema execution at each synchronous host boundary (`main`, a future DOM
   callback, and any foreign callback). A suspending reader/writer must either be
   accepted by a specified async boundary or rejected with the full `sync`
   diagnostic chain. A synchronous `Probe.finish` run proves neither case.
