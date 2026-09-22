# Typia generated proof

`input.ts` is the complete benchmark matrix and `flat.ts` is the independent
flat-only bundle input. `generated/input.js` and `generated/flat.js` are committed
transform output, not hand-written validators. Regenerate them with:

```sh
npm run generate:compiled
```

The candidate uses Typia 15.0.0, TypeScript 7.0.2 and `ttsc` 0.28.1. Typia 15
removed its legacy transformer in favor of this native `ttsc` plugin. The
initially requested `ts-patch` path is therefore not available in the latest
Typia line: `ts-patch` 4.0.1 fails to load TypeScript 7, and with TypeScript 6
it invokes Typia 15's plugin without the required `ttsc` context. Selecting an
older Typia line was not done silently. The owner approved **latest Typia with
its supported `ttsc` transformer** on 2026-09-22, superseding the original
`ts-patch` requirement; this is the approved configuration.

The transformer configuration is deliberately strict:

- `validateEquals<T>`, never `is<T>`, supplies structured native errors and
  rejects surplus properties.
- `finite: true` makes every generated number check reject `NaN` and infinities.
- `undefined: false` together with TypeScript's
  `exactOptionalPropertyTypes: true` distinguishes an absent optional property
  from a present property whose value is `undefined`.
- JSON serialization uses transformed `typia.json.stringify<T>` functions.

There is one measured configuration departure for the path contract. Typia's
closed-object validator normally emits a key-count shortcut before its per-key
surplus check. When every optional property is present along with one extra key,
that shortcut reports only the parent object. Each object proof type therefore
has a never-valued template index signature whose key starts with
`__beni_schema_never__`. No JSON value satisfies the emitted branch; measured
unknown JSON keys, including strings with that prefix, are rejected. **A later
generated-code audit found a JS-only defect:** Typia emits
`null !== value && undefined === value` for `never`, so a matching-prefix key
valued `undefined` is accepted and subsequently dropped. This is recorded, not
patched; the row is not fully strict for arbitrary JavaScript encode inputs.
The signature keeps Typia on the native per-key diagnostic path, which produces the
required exact fault path. This costs an `Object.keys` traversal on valid
objects and is part of the measured Typia row, not removed from timing.
