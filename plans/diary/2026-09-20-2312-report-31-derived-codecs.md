## 2026-09-20 23:12 CEST — report 31: derived codecs

**What I did**

- Wrote [`docs/design/research/31-derived-codecs.md`](../docs/design/research/31-derived-codecs.md),
  assembling the evidence for `fast-compiler.md`'s undecided standing recommendation from report 18
  ("decide structural codec derivation separately, needing no dispatch at all"). The report lays out
  the design space and the open questions; it deliberately does not take the decision.
- Sources: beni's own documents; the report 30 HN corpus for cost evidence; **Roc's Zulip via the
  `roc-zulip` skill**; Effect v4's `Schema` as vendored. Found `references/roc` and
  `references/zig` are **uninitialised submodules**, so no Roc source was readable — every Roc
  claim is chat-sourced and flagged as such.

**What I learned**

- **Roc moved encode/decode off abilities and onto static dispatch with auto-derivation** — "Just
  not abilities anymore" (Brendan Hansknecht, #ideas › Encode/Decode, 2025-12-29, 565607409).
  Report 18 recommended deciding codec derivation *without* dispatch; the peer project beni's static
  dispatch is modelled on did the opposite. The recommendation's premise now has a counterexample and
  should not be carried forward unexamined.
- **Roc's derivation is opt-in per type**, written in the declaration as `encoder_for : _` /
  `parser_for : _` (Richard Feldman, 2026-07-26, 612853585) — not structural-by-default. Records,
  lists, tuples and tag unions derive; derivation lags equality.
- **Derivation broke on exactly the construct beni's capability roadmap depends on.** Roc derived
  for an opaque over a record but not over a primitive — the validated-newtype case — and it
  *panicked* (613054979); Feldman called it a bug. `boundary.md` §6 makes `Intl` first precisely
  because it "establishes the validated-newtype pattern that every later capability reuses". A
  second question neither thread settles: a derived decoder for a validated newtype must re-run the
  smart constructor or it manufactures values violating the invariant.
- **Derivation creates a new class of type error and it must be a diagnostic, not a panic.** Roc's
  float case was resolved by closing it "at the checker … instead of panicking" (614066861). beni's
  `Int` is a double, so the same question arrives immediately at 2⁵³.
- **Derived-versus-hand-written is a false dichotomy.** Effect's `Schema` is one declaration
  yielding both directions plus JSON Schema, with **2 100 lines of `SchemaTransformation`** for the
  shape-mismatch case that is Elm's whole defence of hand-written decoders. The third option is a
  declared bidirectional description, and it is the only one of the three that makes the round-trip
  law checkable.
- **The rule-7 case is the guarantee, not the keystrokes.** A hand-written encoder/decoder pair has
  nothing checking that `decode (encode x) == x`. That is the justification that survives the
  1:1-shape objection; "code the compiler could be writing" does not.
- Corpus finding worth keeping: the JSON complaint peaked in 2017 and faded, but **codegen-as-the-
  answer is the only sub-theme that grew after 0.19** — the demand was met outside the language, by
  every team separately. Same pattern as i18n builds and generated `main` in report 30 §3.9.
