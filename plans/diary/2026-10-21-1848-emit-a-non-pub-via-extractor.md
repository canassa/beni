## 2026-10-21 18:48 UTC — emit a non-pub via extractor

**What I did.** A `pub event` may name a `foreign` that is not `pub` as its
`via`. The checker already accepts that. The markup row recorded only an
interface value, so a non-`pub` extractor was absent, and the `dom` lowering
wrote `Rt$identity`. The handler was typed as taking the extractor's result
and received the event. `browser/dom/PrivateVia` shows it. Before the fix the
paragraph is `"[object Object]"`. After it, `Probe$probe` is what `$$probeX`
holds and the paragraph is `"probe-saw"`.

**What I learned.** The vocabulary row already stores the extractor by name,
and the as-built note that the name need not be `pub` is the contract. The
interface index is only the `pub` path. `identity` is the extractor of an
event with no `via`.
