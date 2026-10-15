## 2026-09-22 12:44 CEST — Specialize schema benchmark flat bundles

**What I did**

- Audited the flat-only browser bundle evidence and found that the Zod,
  Valibot and Effect entries executed a generic JSON-Schema-to-native converter,
  retaining unrelated union, array and recursive-schema capabilities.
- Replaced only those flat entry paths, including the Zod jitless control, with
  literal native flat-schema constructors while preserving each subject's
  strictness, numeric checks, optional-field semantics and native error options.
- Left the matrix adapters and generic builders unchanged. The focused Node 24
  preflight passed all 13 rows, source verification passed all eight corrected
  entries, and all 25 browser bundles passed their flat-only and execution
  audits without a generic builder input.

**What I learned**

- Tree shaking cannot remove branches in a schema converter that executes over
  runtime schema data, even when the entry supplies a constant flat schema.
  Its own retained bytes understate the effect because its references also root
  unrelated native-library APIs.
- The correction affects only flat-entry cold startup and browser bundle size;
  steady-state matrix measurements, full-adapter startup and CSP evidence use
  different entry surfaces and are unchanged.
