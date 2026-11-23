## 2026-11-24 00:42 CET — A keyed Show on browser-inline

**What I did.** Compiled `Show` (#2636) on `browser-inline`: a `Show` among an element's
children is a branch region of two arms, the fallback (absent, one element, `<></>` or
`Html.text e`) and the body as a one-item row, shown by the new runtime `keyShown`, which
remounts the body when the key is not `===` the one shown. Markup interface 1.36:
`programShowEffect`, `programShowFallbackIsText`, `programShowFallbackText`. Spec in
`browser-inline.md` §8.2, *A `Show`*. Pages `ShowKeyed`, `ShowFallbackThrows`, and
`SwapAndShow` copied from `browser/tea`; five `build/bad/inline/Show*` refusals;
`emit/release/inline/ShowKeyed` (3 065 B raw, 1 214 B brotli). Sweep: 175 → 176 of the
`browser/tea` + `browser/dom` pages build on inline.

**What I learned.** A `Show`'s fallback is an attribute (`language.md` §11.18), so
`browser-tea` evaluates it at every render even while the body shows; the reviewer caught that
the first build evaluated it only on `Nothing`, like an arm. A throw in a binding stops the page
before the crash screen in development only; release needs a `.release-expected`. The other
three Show pages stop on other limits: `ShowAndBranches` (a `Show` followed by a `Show`),
`ShowValueArms` (a body that is a branch), `VerifyQuiet` (a class list held as a value).
