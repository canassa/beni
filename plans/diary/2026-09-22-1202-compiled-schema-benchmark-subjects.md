## 2026-09-22 12:02 CEST — Compiled schema benchmark subjects

**What I did**

- Implemented strict decode/encode adapters for Ajv, generated Ajv standalone,
  Typia, TypeBox value and compiled modes, ArkType, and the explicitly labelled
  `fast-json-stringify+handwritten-guard` encode-only row. All validate before
  the shared rename mapping; only Typia and FJS use native generated serializers.
- Added committed Ajv standalone output, transformed Typia sources/output, and
  direction-specific flat browser entries that do not root the workload matrix.
  The Typia source uses `validateEquals`, safe-integer tags, and a native custom
  finite-number tag; the emitted proof contains the generated checks.
- Normalized native union diagnostics to the discriminant-selected branch,
  increased TypeBox's native diagnostic cap so that branch is available, and set
  Ajv to first-error work before regenerating its standalone validators.
- Ran the official correctness-only preflight under pinned Node 24: all 13 rows
  loaded and passed. Independently checked every compiled flat entry and built
  each as minified browser ESM; none imported a matrix adapter or Typia's matrix
  proof. I did not run the timed matrix or change production code.

**What I learned**

- Typia 15 deliberately replaced its legacy TypeScript transformer with a native
  `ttsc` plugin. `ts-patch` 4 fails with TypeScript 7 before transformation, and
  invoking Typia 15's plugin through `ts-patch` on TypeScript 6 also fails because
  the expected plugin context is absent. The latest supported candidate therefore
  uses Typia 15 + TypeScript 7 + `ttsc`; whether to substitute the older
  ts-patch-compatible Typia line remains an explicit owner decision.
- A plain Typia `number` and ArkType `number` do not establish the benchmark's
  finite-number contract. Both needed native refinements, and generated output
  had to be inspected to prove `Number.isFinite` was really emitted.
- TypeBox caps native errors at eight by default. A four-branch union can exhaust
  that cap before reporting the branch named by the discriminant, so exact native
  fault paths require raising the cap before filtering the library's own details.
