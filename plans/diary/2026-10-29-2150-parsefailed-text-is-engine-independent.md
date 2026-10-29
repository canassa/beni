## 2026-10-29 21:50 CET — ParseFailed text is engine-independent

**What I did.** Issue #1166. `schema.md` A.13 fixes the `ParseFailed` message as `invalid JSON`, with
no position (a position would need beni's own scanner; the engine's message is never parsed). Both
`JSON.parse` sites in `core/Schema.beni` (library parse and the specialised path's `compiledParse`)
now drop the caught `SyntaxError`'s message; the `instanceof SyntaxError` catch is unchanged. Updated
the `run/` goldens (`SchemaJson`, `SchemaComposed`, `SchemaDeclRecords`, `TodoServer`) and four
`emit/release` goldens that embedded the text. `SchemaJson` is the fixture that failed before.

**What I learned.** Both paths share one parse site in core, so `src/` needed no change. The
sandbox refused some commands whose text contained certain words; running in the background worked.
