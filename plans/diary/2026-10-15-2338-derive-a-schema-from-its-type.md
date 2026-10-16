## 2026-10-15 23:38 CEST — derive a schema from its type (#193)

**What I did.** Built `schema.md` §12, slice C. `Json.decode text` returns the type the program uses it at, and the compiler derives its codec. It finds the type by annotation, by inference from later use under Roc's closing rule (a young open row no member's type reaches is closed at the declaration's boundary), or by forwarding through `where a.codec`.

I first specified what §12 left to the build as §12.10 and A.12:
- a definition per concrete type, in the using module, with slots for type variables;
- containers in the compiler's table;
- nested module codecs that take no evidence;
- `Maybe` of a slot;
- the node kinds `tuple`, `constructors`, `maybe`, `codec`, `char`, `int32` and `never`;
- Json call specialisation;
- `Http.expectJson` inferred, with the schema form renamed `expectSchema`;
- `Schema.structural` as the opaque-type hint.

The checker side is `src/check/Codec.zig`, which waits, closes, derives and refuses (`no_derived_codec`, `derived_codec_needs_type`). A use's evidence is a new `codec` dispatch term. The definitions are virtual declarations of the module's schema plan, so SchemaLower emits them as declarations, and Reach and DCE treat them as schema members. The new kinds are also library builders and engine nodes in `core/Schema`, so the `--schema-library` differential runs them. `core/Json` is new.

Fixtures:
- `run/JsonDerived{Table,Records,Constructors,Modules,Article}`, with `.compiled-schemas`;
- `check/bad/NoDerivedCodec` (ten reasons) and `DerivedCodecNeedsType`;
- `dispatch/JsonDerived`;
- `emit/app/JsonDerivedDce`;
- `browser/tea/HttpJsonDerived`;
- an `ordering_test` pair;
- an `iface_test` build at jobs 1/8 through the three round trips.

`Dict`/`Set` are refused and deferred to #205.

**What I learned.**
- A derived record compiles to the same workers as a declared one. Brotli is 1 085 declared against 1 086 derived. Parse is 754 against 759 ns, print 546 against 538 ns, and a 1 000-row list 508 against 498 µs.
- The iface test found a hole that no corpus fixture had: a nested type whose module's one `codec` is another type's (the module rule makes it every type's method) was compiled as if it were its own. A nested module codec is now unified with `⊤ → Codec T`.
- The Conduit budget failures midway were stale run hashes, not cost. Per-build instructions moved by about 13M.
- `/tmp` filled repeatedly. Keep `TMPDIR` and logs under `~/.cache`.
