## 2026-11-04 09:07 CET — release keeps pinned and spilled impure values

**What I did**

- Fixed #1227 on `release-keep-unread-field-call`. `Lower.orderedExprs` pins a value in a `const $t$<n>` when the printer sorts the keys or a later value hoists statements. It now lists the pin in `effect_keep` when the value may have an effect, as `enterInline` does for its arguments. Fixture: `run/ReleaseKeepsUnreadField`, a project with a test platform, with `Log.info`, `Debug.log`, an impure `foreign`, a record alias constructor, `Js.call` and `Js.get` getters.
- Found and fixed #1842, the same defect in the spill of `Lower.expr` (a value `JsIr.nesting.spill` tall). Fixture: `run/ReleaseKeepsSpilledCall`, a `Debug.log` under 50 and 51 `▷ inc`.
- Proved both fixtures red with the fix set aside (the release pass), and green with it. Added an amendment and two table rows to `backend.md` §9 item 1. Blessed `emit/release/tea/DomCapabilities`.
- Measured release sizes against master with `bench/size.mjs` and a byte compare of all 489 `browser/` fixtures.

**What I learned**

- The defect had a second symptom that the issue did not name. With both getters read, `Opt` folded the two unlisted pins back into the sorted keys, so release ran getter `a` before getter `z`. A listed `Js.get` is never folded (§9, amended 2026-10-02), so one fix closes both.
- At 50 nested calls, the spilled value is the whole record. The `let` then becomes a name for the unlisted spill (`y = x` aliasing), so even the binding's own `effect_keep` entry is gone.
- Every size change outside the new fixtures is a `Js.get` in `core/` or a platform: `core/Url.parts` (`hostname`), `Dom.box` and `Dom.viewport`, and the resize record. Master dropped or reordered these reads. The fix keeps them: +13 to +34 raw bytes on 5 `browser/tea` pages, +26 on the `browser-tea url` page. `run/` and `bench/corpus` did not change by one byte.
- `bench/size.mjs` does not cover `browser/`. A compare script must copy a project whole (shell, `src/`, a platform outside `platform/`) and build `prerender/` with `--no-prerender`, or 38 fixtures fail with both compilers and hide nothing but also prove nothing.
- `emit/release/tea/DomCapabilities`'s comment said "the four window reads are written in place". On master only one was. A golden's intent comment can be false for a long time when the golden is blessed from the output.
