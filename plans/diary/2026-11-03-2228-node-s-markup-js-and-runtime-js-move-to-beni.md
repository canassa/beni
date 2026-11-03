## 2026-11-03 22:28 CET — node's markup.js and runtime.js move to beni

**What I did.** #877 step 15 (#1810): `platforms/node/Rt.beni` is the `node` platform's runtime
module, as `browser`'s `Rt` is — `run`, the `ssr` lowering's seven exports and the two markup
primitives over `Js.Value` — the manifest says `"markup": { "lowering": "ssr", "module": "Rt" }`
and no `"runtime"`, and `markup.js` and `runtime.js` are deleted. Spec first (plan row 15 and
step 15, `backend.md` §15.6, `boundary.md` §9.2, the project `CLAUDE.md`). 258 `emit/` goldens
moved, every `emit/release/app/*` among them: the entry's `run` is beni, and the release optimiser
specialises it on `Io.run`'s constant `Program`. The playground's frame defines
`globalThis.process`, since the runtime reads the global where the file imported `node:process`.
A manifest rule had to move: `"markup".module` is read from the package that declares the chain's
first `lowering`, so a platform over `node` with a markup file of its own no longer sees `node`'s
`Rt` (`build/bad/MarkupRuntimeArity`, which now declares that file as its program runtime too).

**What I learned.**

- `Js.object`'s keys must be identifiers: a lookup table keyed by `&`, `<`, `"` and `\r` is a
  `case` in beni, not an object.
- `++` on a `String` is still `Basics.append`, string or list, and a program that had no list
  append pays 70 raw bytes for it; `"${a}${b}"` is `+`. An interpolation may not hold a string
  literal: bind it first.
- `e` (Euler) and `list`/`text` of the same module shadow a parameter: `SHADOWING`.
- The release optimiser specialises a function called once on a known record: `run(tb)` with
  `tb = Io.run …`, whose value is `Node.done`'s literal, became `()=>{…exitCode=0}` and the
  record lost its fields. Correct, and a golden to read twice.
- A hand-written runtime's `import process from "node:process"` was the one import of every
  release node program; the beni runtime has none, so a test that counted one import counts zero.
- The playground frame's `node:process` stand-in was an import only; a beni runtime reads
  `globalThis.process`, so the frame defines the global and the stand-in modules export it.
- A platform's `api-<platform>.md` lists its runtime module (`browser`'s `Rt` was there all
  along), so `zig build skill-api` moves with it.
