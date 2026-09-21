# 31 — Derived codecs: should beni generate encoders and decoders?

**Question** `fast-compiler.md` carries a standing recommendation from report 18 — *"decide
structural codec derivation separately, needing no dispatch at all"* — which has never been decided.
This report assembles the evidence for that decision. It does not take it.

**Sources** beni's own design documents; the Hacker News corpus collected for
[report 30](30-elm-complaints-on-hackernews.md) (7 285 comments); Roc's Zulip, read with the
`roc-zulip` skill; Effect v4's `Schema` module as vendored in `references/effect`.
**Not available:** `references/roc` and `references/zig` are uninitialised submodules, so every Roc
claim here is from chat, not from source — see §9.

---

## 1. What beni has today

Three decisions already on the record, quoted rather than paraphrased.

**Codecs are generated at the port boundary, from the type** — [`boundary.md`](../boundary.md) §3.1:

> "**The payload widens to any type the compiler can generate a codec for.** … the safety comes from
> *generating* the codec, not from the list. Admitted: everything Elm admits, plus **ADTs and records
> of admitted types** … Still refused … functions, type variables, extended records, and anything
> containing a foreign type."

with a depth bound, because "machine-generated deserializers are themselves a crash site".

**`Decoder` stays an ordinary value** — [`typed-effects-review.md`](../typed-effects-review.md) Q9:

> "Do not make `Decoder` an effect. A decoder is a value you build, combine and run more than once;
> an effect is a call you make once."

**And the general question is explicitly deferred** — [`fast-compiler.md`](../fast-compiler.md),
report 18's second standing recommendation: *"decide structural codec derivation separately, needing
no dispatch at all."*

So the gap has a precise shape. **A value crossing a port gets a compiler-generated codec; a value
arriving any other way does not.** Everything in `boundary.md` §6's capability roadmap past the
first entry — `fetch` and streaming, `localStorage` and structured storage — delivers data that a
hand-written `Decoder` must interpret, exactly as in Elm.

---

## 2. The cost, measured

From the report 30 corpus (7 285 comments, 2 776 commenters, 2011–2026):

| | comments | authors | pre-0.19 / post |
|---|---:|---:|---:|
| JSON decode/encode discussed at all | 63 | 48 | 45 / 18 |
| …with pain words attached | 39 | 33 | 30 / 9 |
| **codegen named as the answer** | 33 | 26 | 15 / **18** |
| derived codecs asked for specifically | 23 | 20 | 18 / 5 |

Two readings, and the second is the one that matters.

**The complaint peaked in 2017 and faded.** On its own that would suggest the problem solved itself.

**But codegen-as-the-answer is the only sub-theme that grew after 0.19.** The demand did not go away;
it was met *outside* the language, separately, by every team that hit it — `json2elm`, `swagger-elm`,
`elm-graphql`, `elm-export`, `elm-protobuf`, `elm-bridge`, `haskell-to-elm`, `elm-street`. One team
generates its Elm `Model` types from its Haskell backend, and reports that as the reason it cannot
flatten the model (`yakshaving_jgt, #25098879`). The clearest statement of the principle:

> "The complaint is that humans have to write and maintain code that the compiler could be writing."
> — `jeremyjh, #21321990, 2019-10-22`

and the diagnosis of *why* Elm could not:

> "You define types and the serialization instances are derived. … Elm cannot do this, because it
> does not even have type classes." — `jeremyjh, #21321944, 2019-10-22`

*(inference)* That is a language-shaped hole filled by a build step, in every shop, independently —
the same pattern report 30 §3.9 found for i18n and for `main`. It is weak evidence that hand-written
decoders are intolerable and strong evidence that they are a tax everyone pays privately.

---

## 3. Prior art

### 3.1 Elm — the baseline, and its honest defence

Hand-written `Decoder` values, combined with `mapN`. The defence is not inertia, and it is the one
real argument against derivation:

> "The automatic decoders/encoders in Haskell only work if the shape of your JSON perfectly matches
> your record definition." — `fbonetti, #14892909, 2017-07-31`

Corroborated from the other side: a commenter notes real-world decoders are hand-written in Haskell
too (`always_good, #14894511`). And a cost of the hand-written *pair* that nobody proposes a fix for:

> positional decoders "get annoying for objects with lots of fields (since the order has to exactly
> match the constructor), or for objects that need to round-trip" — `jcparkyn, #36053371, 2023-05-24`

### 3.2 Roc — the finding that contradicts report 18

Roc **moved encode/decode off its ability system and onto static dispatch with auto-derivation**:

> "encode and decode will be implemented via static dispatch and auto derived. So not really
> absolute. Just not abilities anymore" — Brendan Hansknecht, #ideas › Encode/Decode, 2025-12-29,
> [565607409](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Encode.2FDecode/near/565607409)

Derivation is **opt-in per type, written in the type declaration**, not structural-by-default:

> "you should be able to do `encoder_for : _` and `parser_for : _` in the opaque type declaration and
> that should give you auto-generated implementations for them" — Richard Feldman,
> 2026-07-26,
> [612853585](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/.E2.9C.94.20opaque.20type.20Encoding.2FDecoding.20derivation/near/612853585)

Coverage as of mid-2026: records, lists, tuples and tag unions derive; the user reports the bare
`: _` "auto-derives the JSON codec, and a record with the opaque field round-trips"
(`612856179`). Derivation lags equality — "we don't have as many things auto-derived yet, like
equality might be the only one. Maybe encode too, but I don't think decode" (Richard Feldman,
2026-05-29,
[598649710](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/Zig.20compiler.20feature.20parity/near/598649710)).

**This is the report's most consequential finding.** Report 18 recommended deciding codec derivation
"needing no dispatch at all". The peer project that beni's static dispatch is modelled on did the
opposite: it deleted its dedicated ability machinery and routed codecs *through* dispatch. That does
not make report 18 wrong — beni is not Roc and the JS target differs — but the recommendation's
central premise now has a counterexample and should not be carried forward unexamined.

### 3.3 Effect v4 — declare the relationship once, get both directions

`references/effect/packages/effect/src/Schema.ts` is 15 423 lines, with `SchemaAST` (5 201),
`SchemaTransformation` (2 117), `SchemaGetter` (2 208) and `JsonSchema` (1 627) beside it. The
architecture, from its exported surface: a schema carries a `Type` and an `Encoded` side, and one
declaration yields `decode*` **and** `encode*` in six result flavours, plus `is`/`asserts`
predicates, plus JSON Schema generation.

The part that matters for beni is `SchemaTransformation` — **2 100 lines devoted to the case where
the wire shape does not match the domain type.** Effect's answer to §3.1's objection is not "write
the decoder by hand" but "declare the transformation, still declaratively, and keep both directions
and the schema in sync."

*(inference)* That reframes the decision. **Derived-versus-hand-written is a false dichotomy.** The
third option is a bidirectional description from which the compiler projects an encoder, a decoder
and — if wanted — a schema, with mismatch expressed as a declared transformation rather than as
imperative decoder code. That is also the only design of the three that makes the round-trip law
checkable.

### 3.4 Others, from general knowledge — *unverified, not read for this report*

Haskell's `aeson` with `deriving Generic`; Rust's `serde` with `#[derive]` plus per-field
attributes for renaming and defaults; Swift's `Codable` with an opt-out `CodingKeys` enum. All three
follow the same shape: **structural derivation by default, with a declarative escape for mismatch.**
Flagged as recollection; none was checked against source, and none should be cited from this report.

---

## 4. Three hard cases that decide the design

### 4.1 Shape mismatch — the objection that survives

Derivation only covers the 1:1 case, and real APIs are not 1:1: renamed fields, optional-versus-null,
tagged unions with a discriminator field, dates as strings, numbers as strings. This is the reason
Elm's hand-written decoders are defensible, and any beni design must answer it.

The three known answers: **attributes** (serde), **a declared transformation** (Effect), or
**fall back to a hand-written decoder for that type** (Roc's `encoder_for` with a manual body). Only
the second keeps both directions in sync by construction.

### 4.2 Validated newtypes — a live bug in Roc, and a dependency in beni

The case where a type is an opaque wrapper carrying an invariant — `Username := Str` with a minimum
length. Roc derived it for an opaque over a *record* but not over a *primitive*:

> "derives fine for an opaque over a **record**, but not for one over a **primitive** — the
> validated-newtype case" — Dzmitry Misiuk, 2026-07-27,
> [613054979](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/.E2.9C.94.20opaque.20type.20Encoding.2FDecoding.20derivation/near/613054979)

Richard Feldman: "that's a bug" (`613055153`). The contributor's design question — **"peel or
reject?"** — is precisely the question beni would face, and he argued for peel: consistent with
records, and format-generic rather than JSON-specific.

**This lands directly on beni.** `boundary.md` §6 makes `Intl` and time the first capability
specifically because it "establishes the **validated-newtype pattern** that every later capability
reuses." So beni's capability roadmap is built on exactly the construct where Roc's derivation
broke — and the failure mode was a runtime panic, not a diagnostic.

A second question hides inside it, which neither Roc thread settles: **a derived decoder for a
validated newtype must re-run the smart constructor**, or it manufactures values that violate the
invariant the newtype exists to enforce. Peeling to the backing type and wrapping is only correct if
the wrap is the *checked* constructor.

### 4.3 Types that cannot round-trip — and where the failure should land

Not every type has a codec, and the boundary is not obvious. Roc's case was floats: JSON has no
representation for `NaN` or infinity, so a derived codec over `F64` cannot be total. The resolution:

> "the fallible-float boundary is now closed at the checker — `Money := F64.{ encoder_for : _ }` gets
> the same clean `TYPE MISMATCH` as a bare `F64` instead of panicking" — Dzmitry Misiuk, 2026-08-01,
> [614066861](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/.E2.9C.94.20opaque.20type.20Encoding.2FDecoding.20derivation/near/614066861)

*(inference)* The transferable lesson is not about floats. It is that **derivation creates a new
class of type error — "this type has no derivable codec" — and that error must be a diagnostic, not
a panic.** beni already holds this discipline elsewhere: §3.1's depth bound exists so a generated
decoder "fails as a value rather than as a stack overflow", and the checker's guards "report, never
poison silently". A derivation feature inherits that obligation.

beni's `Int` is a double ([report 30](30-elm-complaints-on-hackernews.md) §7.4), so the same
question arrives immediately: is a derived codec for `Int` total, and what happens past 2⁵³?

---

## 5. What derivation actually buys

Not keystrokes. The corpus's own framing is about labour — "code that the compiler could be
writing" — and that framing, under CLAUDE.md rule 7, is the *weak* case: convenience is not a
guarantee, and Elm's own counter-argument (shape mismatch) mostly defeats it.

The stronger case is one nobody in the corpus quite makes. **A hand-written encoder/decoder pair has
no guarantee that it round-trips.** Nothing checks that `decode (encode x) == x`; the two are
separate functions maintained by hand, and the only defence is a property test the programmer
remembers to write. `jcparkyn` gets closest — round-tripping means "twice as much code to write, and
no way to verify that they're equal."

Derived pairs are correct by construction, and a *declared* pair (Effect's model) makes the law
checkable even where the shape does not match. That is a guarantee in the sense rule 7 requires — no
silent wrong answer at the boundary — rather than an ergonomic improvement. **If derived codecs are
adopted, this should be the stated justification**, because it is the one that survives the
1:1 objection.

Note the supporting fact from §1: beni already accepts this argument at the port boundary. The
question is only whether the same reasoning extends past it.

---

## 6. The design space

Four options, in increasing order of commitment. *(inference throughout)*

**A. Do nothing.** Ports keep generated codecs; everything else writes `Decoder` by hand.
Cheapest; leaves the corpus's #2 language complaint unanswered and invites the same private-codegen
ecosystem Elm grew.

**B. Lift §3.1's generator to a language feature.** The codec generator exists and is specified —
the admitted set, the refusals, the depth bound. Make it callable for any admitted type, not only at
a port. Smallest delta, reuses a tested component, and inherits its limits exactly: no functions, no
type variables, no extended records, no foreign types. Does not address shape mismatch at all.

**C. B, plus a declared mismatch story.** Field renaming, optionality and discriminators expressed
declaratively, so the derived pair stays bidirectional and the round-trip law still holds. This is
Effect's design and it is where the guarantee in §5 actually lives. Much larger; needs its own
surface syntax, which is a `language.md` change.

**D. Opt-in per type, Roc-style.** Derivation requested in the type declaration rather than applied
structurally. Orthogonal to B/C — it is about *when* derivation fires, not what it covers. Roc chose
it; it makes the feature visible and keeps the compiler from generating codecs nobody asked for.

The interaction with static dispatch is the open technical question. Report 18 says derivation needs
no dispatch; Roc routes it through dispatch. *(inference)* beni's well-known-method machinery already
derives `eq` and `compare` when a type declares none — a derived `encode`/`decode` pair is the same
shape of thing, which argues the two features should at least be specified together rather than, as
report 18 assumed, separately.

---

## 7. Open questions for the owner

1. **Is the justification the guarantee (§5) or the ergonomics (§2)?** This decides whether the
   feature is rule-7-legitimate or merely convenient, and it changes the design: a guarantee argues
   for C, convenience is satisfied by B.
2. **Structural by default, or opt-in per type (D)?**
3. **Peel or reject for validated newtypes (§4.2)** — and if peel, does the derived decoder re-run
   the smart constructor?
4. **Which types have no derivable codec**, and is that a diagnostic at the declaration or at the
   use site? `Int` past 2⁵³ needs an answer either way.
5. **Does derivation ride on static dispatch or stand apart?** Report 18 assumed apart; Roc says
   together.
6. **Does `core` ship a `Json` module at all**, or is JSON a platform concern? Nothing in the design
   documents settles this, and it bounds everything above.

---

## 8. Threats to validity

- **No Roc source was read.** `references/roc` is an uninitialised submodule; every Roc claim is
  from Zulip chat, which the skill's own guidance calls "people thinking out loud". The `encoder_for
  : _` syntax and the record/primitive asymmetry are reported by users and confirmed by a core
  maintainer in-thread, but not verified against the compiler.
- **§3.4 is recollection**, not research, and is marked as such.
- **The corpus counts JSON mentions, not complaints.** 48 authors discussed decoders; 33 attached a
  pain word. The regexes cannot tell a grievance from an explanation.
- **Effect was read for architecture, not semantics.** I read its exported surface and module sizes,
  not its parser. The claim "one declaration yields both directions" follows from the exports; the
  claim that transformations keep the round-trip law is my reading of what `SchemaTransformation`
  is for, not a verified property.
- **No measurement of beni.** Nothing here quantifies what a derived codec would cost in output
  bytes or compile time. §3.1's generator exists, so that measurement is available and has not been
  taken.
