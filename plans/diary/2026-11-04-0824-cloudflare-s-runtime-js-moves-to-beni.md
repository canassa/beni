## 2026-11-04 08:24 CET — cloudflare's runtime.js moves to beni

**What I did**

- Built #1813 on `cloudflare-runtime-in-beni`, stacked on #1838 (step 17 of `plans/runtime-in-beni.md`), under the owner's answer A to `runtime-in-beni-q3`: `Js.method` takes parameters after its receiver, and `Js.module` is a static namespace import of a `node:` or `cloudflare:` built-in. Spec first in `boundary.md` §4.2, `backend.md` §4 and §9, `checker-v2.md` §30.
- `platforms/cloudflare/Rt.beni` is the platform's runtime module through the top-level `"module"` of #1838, and `runtime.js` is deleted: the last hand-written file of the platforms. The `workers/` corpus is green under Miniflare in both builds; every program is 89 to 93 raw bytes smaller.
- Fixtures for both spellings in `run/`, `emit/core/` with release twins, and `check/bad/core/`.

**What I learned**

- A `foreign` cannot write `sync` on a type variable, so a lambda of any count at `Js.method` is a checker special case: the callee is generated against a throwaway variable (the use stays recorded) and the call takes the lambda's own arrow; the `sync` demand's site must be the reference to `Js.method`, or the report says "`a function` hands it on".
- Two defects hid behind the first fixtures of #1838: a program of an embedded platform need not import the runtime module, but `Session.isPlatformRoot` only rooted the markup one (a directory platform roots every module, and `run/ProgramModule` imports `Rt`); and the hoist plan declined the one file for any emitted module with a host import it could not place, which the multi-file `run/JsModule` release pass did not show. A size measure found both: +214 to +539 brotli per Workers program was the multi-file layout, not the runtime.
- A hoisted import text written by hand needs the space after the binding: `import*as a from"…"`; the printer's compact mode inserts it, the hoist's own text did not.
- `Js.js` exports a value form for every `foreign` of `Js.beni` (check 2), so `Js.module` has one that throws: a static import cannot be a value.
