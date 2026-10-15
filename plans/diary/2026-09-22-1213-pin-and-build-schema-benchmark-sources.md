## 2026-09-22 12:13 CEST — Pin and build schema benchmark sources

**What I did**

- Added shallow source submodules at the resolved release tags for Ajv 8.20.0,
  Typia 15.0.0, TypeBox 1.3.34, ArkType 2.2.3,
  fast-json-stringify 7.0.1, Zod 4.6.5 and Valibot 1.5.0; retained Effect's
  existing 4.0.0-rc.116 pointer unchanged. Recorded tags, commits, dates and
  permanent source links without committing or staging vendored contents.
- Built every subject from its pinned source. Ajv, Typia's native `ttsc` path,
  TypeBox, the topologically ordered ArkType workspace, Zod, Valibot and Effect
  passed; fast-json-stringify has no build step and passed a direct-source smoke
  test. Captured the exact commands and the failed partial attempts that exposed
  package-manager and workspace ordering requirements.
- Added the exact runtime/tooling lock, source-build and wiring scripts,
  provenance JSON and mechanism/CSP notes. The wiring replaces all eight npm
  subjects with source-built submodule artifacts; an audit resolved every public
  entry to those paths, compiled generation passed, and each measured entry has
  a recorded SHA-256.

**What I learned**

- TypeBox 1 is the `typebox` package and exposes `Compile`, not the old
  `@sinclair/typebox` `TypeCompiler`. Its evaluator and ArkType both have CSP
  interpreter fallbacks, while their normal paths generate functions.
- Typia 15 deliberately moved from the legacy Typia 12 / TypeScript 6 /
  `ts-patch` path to TypeScript 7 and `ttsc`. The current source build is slow
  because the native transform can force a full-project recompile, but its
  emitted result needs no runtime code generation.
- Zod 4.6.5 is hybrid: object validation JITs a specialized fast path when
  allowed and otherwise interprets it. Per-parse jitless selects the interpreter
  but does not suppress the earlier capability probe; only global jitless does.
