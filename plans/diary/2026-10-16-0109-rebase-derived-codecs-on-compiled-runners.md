## 2026-10-16 01:09 CEST — rebase derived codecs on the compiled runners (#206)

**What I did.**
- Rebased #206 onto #204, which compiles every runner, and #208, slice B's shared validators. #204 rewrote `SchemaLower` around one generator over six operations and descriptions made of nodes. Rather than merge hunks, I took master's `SchemaLower` and `SchemaGraph` and ported the derived-codec additions onto them:
  - node makers `describedTuple`, `describedConstructors`, `describedMaybe` and `describedMaybeField`;
  - the new workers, written per operation;
  - `SchemaShare`'s counts now include derived definitions.
- `Json.decodeValue`/`encodeValue` now run compiled `read`/`write` workers. The new `run/JsonDerivedValues` holds the `.compiled-schemas` guarantee for them.

**What I learned.**
- `Codec a = Schema Value a` with `erased = cast` was unsound once typed workers existed. `Schema.decode` trusts a typed Encoded input's shape, and a `Codec`'s Encoded value is a `Value` from anywhere. The interpreter was not right either: it read a constructor through `ctorFromTyped`.
- The fix is `NHost`, which makes the context's Encoded end a host value:
  - in the engine, through `hostEnds`;
  - in a derived description, through `describedHost`;
  - for a compiled erased schema, through `MadeErased`/`hostWorker`.
- A definition writes no `decode`/`encode` worker set. Its root wraps the `read`/`write` workers instead (`SchemaGraph.hostAliased`).
- After the rebase, a five-field record that triggers `badString` sharing is byte-identical declared and derived in `--release` (986 brotli each). The eight-field record is still 1 085 against 1 086 brotli.
