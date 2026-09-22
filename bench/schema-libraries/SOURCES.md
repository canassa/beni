# Subject provenance and mechanisms

Versions were resolved on 2026-09-22 from the latest package release tag in
each upstream repository, then checked against the package version at that tag.
The exception is Effect: its existing `4.0.0-rc.116` submodule pointer was left
unchanged. `provenance.json` records every tag, commit, date, measured entry path
and SHA-256. `package-lock.json` fixes the benchmark-root dependencies and the
identical published package metadata; the source repositories' own lockfiles
fix their build and direct-symlink transitive dependencies where upstream
provides one. `scripts/wire-source-builds.mjs` then replaces all eight subject
packages with source-built submodule artifacts. All new source checkouts are
shallow submodules.

## Mechanisms

**Ajv 8.20.0.** Ajv lowers JSON Schema to JavaScript source, optimizes that
source, and calls `new Function` to construct the validator at runtime
([source](https://github.com/ajv-validator/ajv/blob/0fba0b8e649909613cfce0999b149cd08f4a4987/lib/compile/index.ts#L160-L180)).
That ordinary row therefore requires dynamic code generation. Its standalone
mode serializes the same generated validation functions as an ES module
([source](https://github.com/ajv-validator/ajv/blob/0fba0b8e649909613cfce0999b149cd08f4a4987/lib/standalone/index.ts#L29-L66));
construction needs code generation, but the emitted module's validation calls
continue functioning when string code generation is blocked.

**typia 15.0.0.** `validateEquals<T>` is intentionally only a transform marker:
the untransformed runtime function throws
([source](https://github.com/samchon/typia/blob/78124b0523b4e989aedb64fe4cd4e1fd59c44a2d/packages/typia/src/module.ts#L501-L529)).
The TypeScript 7 / `ttsc` transform replaces the marker ahead of time with
specialized validation code, so steady-state validation does not use dynamic
code generation and continues functioning when string code generation is
blocked. The tagged source explicitly labels
TypeScript 6 plus `ts-patch` as the typia 12 legacy path and says not to mix it
with the current toolchain
([source](https://github.com/samchon/typia/blob/78124b0523b4e989aedb64fe4cd4e1fd59c44a2d/website/src/content/docs/setup/legacy.mdx#L5-L19)).

**TypeBox 1.3.34.** This is the current `typebox` package, not the legacy
`@sinclair/typebox` package; the compiled API is `Compile` from
`typebox/compile`. `Compile` constructs a `Validator`
([source](https://github.com/sinclairzx81/typebox/blob/5177875a4854e5cf2c49d0b8f938704ca79205ae/src/compile/compile.ts#L36-L52)),
which builds source and evaluates it when the environment permits, but falls
back to the schema engine when evaluation is unavailable
([source](https://github.com/sinclairzx81/typebox/blob/5177875a4854e5cf2c49d0b8f938704ca79205ae/src/schema/build.ts#L43-L71)).
The value row is interpreted; the compiled row is normally generated and has a
built-in fallback rather than failing construction when string evaluation is
blocked. Its environment check attempts evaluation once before choosing that
fallback.

**ArkType 2.2.3.** ArkType normally precompiles schema traversals at
construction and binds the generated functions onto each node
([source](https://github.com/arktypeio/arktype/blob/03b1f015d9b7c5af5dac2caed1aeedefaf705ab3/ark/schema/scope.ts#L179-L203)).
Compilation calls a dynamic `Function` constructor
([source](https://github.com/arktypeio/arktype/blob/03b1f015d9b7c5af5dac2caed1aeedefaf705ab3/ark/schema/shared/compile.ts#L113-L126)),
but the default configuration probes CSP and sets `jitless`, which skips
precompilation
([probe](https://github.com/arktypeio/arktype/blob/03b1f015d9b7c5af5dac2caed1aeedefaf705ab3/ark/util/functions.ts#L95-L109),
[fallback](https://github.com/arktypeio/arktype/blob/03b1f015d9b7c5af5dac2caed1aeedefaf705ab3/ark/schema/scope.ts#L712-L716)).
It is therefore runtime-generated normally and continues through its
interpreter fallback when evaluation is blocked, although the capability probe itself attempts
`new Function` once.

**fast-json-stringify 7.0.1.** The library writes a serializer body and creates
the executable serializer with `new Function`
([source](https://github.com/fastify/fast-json-stringify/blob/6aa2ed4cc403cf68d7c31ee4dd14724372fea664/index.js#L200-L240)).
It is therefore runtime code generation and fails when string code generation
is blocked. It does
not natively satisfy this investigation's symmetric validation/error contract,
so the strict encode row is named `fast-json-stringify+handwritten-guard`; the
guard is a declared deviation and must not be attributed to the library.

**Zod 4.6.5.** Zod's default object parser is hybrid, not purely interpreted:
it emits a shape-specialized fast path and enables it when JIT is configured and
evaluation is available, otherwise it calls the generic parser
([source](https://github.com/colinhacks/zod/blob/59bbc03e10c636b9eb3c393dfeb552819774ec21/packages/zod/src/v4/core/schemas.ts#L2352-L2392)).
The benchmark therefore exposes the normal `zod` row and an explicit
`zod-jitless` interpreter baseline. That row uses the per-parse `jitless`
option, which selects the interpreter but does not avoid the cached capability
probe performed while the schema is initialized. Only global jitless skips the
probe
([source](https://github.com/colinhacks/zod/blob/59bbc03e10c636b9eb3c393dfeb552819774ec21/packages/zod/src/v4/core/util.ts#L517-L530)).
The caught probe and fallback make validation work under CSP, but may still
produce a browser `securitypolicyviolation` event.

**Valibot 1.5.0.** Valibot interprets a composed schema: the measured strict
object schema loops
over entries, invokes each child schema's `~run`, accumulates structured paths,
checks undeclared keys, and returns the dataset
([source](https://github.com/open-circle/valibot/blob/5016198907beb383f5a6d8bbcb4c7f1586d7c6a3/library/src/schemas/strictObject/strictObject.ts#L89-L235)).
There is no generated validator in this path, so construction is composition
and does not attempt string code generation.

**Effect 4.0.0-rc.116.** The measured default uses cached interpreted entries:
the registry starts with compiler adapters disabled, lazily compiles the AST to
interpreter closures, and caches them by AST
([source](https://github.com/Effect-TS/effect/blob/3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5/packages/effect/src/internal/schema/compilerRegistry.ts#L33-L86)).
Effect also has an opt-in compiler registry with fast decode operations and
interpreter fallback
([source](https://github.com/Effect-TS/effect/blob/3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5/packages/effect/src/internal/schema/compilerRegistry.ts#L88-L145)),
but that distinct compiled configuration is not a row in this matrix. The
default row does not attempt string code generation.

## Source-build outcomes

All commands ran under Node 24.19.0 on darwin-arm64. The reproducible sequence
is in `scripts/build-sources.sh`.

- Ajv: `npm install --ignore-scripts --legacy-peer-deps && npm run build` — pass.
  The release tag has no dependency lockfile, so that source-development
  install is not transitively reproducible; the benchmark runtime lock is.
- typia: `corepack pnpm@10.6.4 install --frozen-lockfile` then
  `corepack pnpm@10.6.4 --filter typia build` — pass. The transform-heavy
  Rolldown phase took 581.96 seconds and reported that the transform cache could
  not reuse the project compile.
- TypeBox: Deno 2.6.3 `deno task build` — pass, including package creation and
  are-the-types-wrong checks.
- ArkType: `npx pnpm@10.19.0 install --frozen-lockfile`, then the complete
  topological workspace build excluding docs — pass. Building only `arktype`
  first failed because `@ark/util`, `@ark/schema`, and `arkregex` had not yet
  produced their outputs.
- fast-json-stringify: no build script exists at the tag. After dependency
  installation, a direct import of checked-in `index.js` compiled and ran a
  serializer successfully.
- Zod: pinned Nub 0.8.3 `install --frozen-lockfile` then `nub run build` — pass.
  Nub is installed under ignored `.source-build/`, not in the user's home.
- Valibot: pinned pnpm 11.5.0 frozen install and workspace build — pass.
- Effect: pinned pnpm 11.20.0 frozen install and `--filter effect build` — pass.

The queried latest tools were TypeScript 7.0.2, ts-patch 4.0.1 and esbuild
0.28.2. `ts-patch` is retained as a recorded query, not used: it failed with
TypeScript 7, its version guard rejected TypeScript 5.9.3, and TypeScript 6.0.3
reached a typia-15-only descriptor mismatch. The successful current typia proof
uses TypeScript 7.0.2 and `ttsc` 0.28.1.

After building, `npm run wire:sources` symlinks Ajv, TypeBox, ArkType,
fast-json-stringify, Zod and Valibot directly to their built source trees. For
typia and Effect it copies the built `lib/` or `dist/` tree to ignored
`.source-build/packages/` and combines it with the version-identical published
package manifest, because the repository manifest describes the pre-publish
TypeScript source layout. An import audit resolved every package to those eight
source paths and imported each public entry successfully; the exact entry-file
hashes are in `provenance.json`.
