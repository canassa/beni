## 2026-11-15 17:51 CET — Html.targetValue answers Maybe String

**What I did**

- Reproduced #1993 on master `e72a8bfd80`: a click on a `<div>` with `Html.targetValue` stopped the page with `TypeError: Cannot read properties of undefined (reading '$plain')`.
- Made `Html.targetValue : Event → Maybe String`, `Nothing` when `value` is not a string (the owner's decision, 2026-11-05, `boundary.md` §4.3 (a) on #1999).
- Gave `onInput` and `onChange` a private extractor, `controlValue`, and allowed them only on `input`, `select` and `textarea`. Their payload stays `String`. On another element they are `unknown_attribute`.
- Compared the optional Cloudflare error flags (`overloaded`, `durableObjectReset`, `retryable`) on the host value with `Js.same`, in `Worker.beni` and `Worker/Object.beni`, as the review of #1999 asked.
- Added `browser/dom/TargetValueNoValue` and `check/bad/markup/InputEventOffControl`. Both fail on master.

**What I learned**

- The dispatch dump prints `via` only for a `pub` extractor (`src/check/Dispatch.zig`, `extractor`). A private one prints no name.
- A type test in the extractor costs every input page about 90 bytes before brotli. Where the HTML specification promises the type, the specification is the reason (§4.3 (a)), and the read needs no test. With it, the release output did not change.
- The `on` list of an event is the tool that makes a payload type true, as `onCheck` already showed.
