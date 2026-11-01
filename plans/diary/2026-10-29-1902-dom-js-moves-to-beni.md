## 2026-10-29 19:02 CET — Dom.js moves to beni

**What I did.** PR 7 of #877: the six DOM capabilities (`focus`, `blur`, `box`, `scrollTo`,
`scrollIntoView`, `viewport`) are beni over `Js` in `Dom.beni` and `platforms/browser/Dom.js` is
gone. Spec first: `plans/runtime-in-beni.md` row 8 and *Step 8*, `plans/core-in-beni.md` step 4,
`boundary.md` §9.8.6's as-built note and §5.1's example that named the sibling. One private
`found` finds the node (`getElementById`, `Js.isNull` → `NotFound`), each capability calls the
node's method through `Js.call`, `viewport` reads the four window properties with `Js.global`;
nothing is caught, since no call documents a failure. Fixtures: `browser/tea/DomCapabilities`
runs all six and the five `NotFound`s under happy-dom in both builds; `emit/release/tea/DomCapabilities`
pins the release shape. Sixteen browser hashes of the pages that use `Dom` moved.

**What I learned.** The first build failed on `SHADOWING`: the full-screen functions bind a
local `node`, and a new top-level `node` shadows it — read the module's locals before naming a
helper. `Debug.log` returns its subject, so a `case` arm that logs must end in `⊤` itself. And the
release shape is not what I had written: `NotFound` gets its integer tag, but `Box` and
`Viewport` keep `x`, `y`, `width` and `height`, because `box` reads the host rectangle's four
properties with `Js.get` and item 4's closed list never renames a field the build also writes as
a plain property. A claim about a release shape is read off the golden, not reasoned from the
boundary set alone. And the bar is measured, not assumed: the first bodies, written over
`Result.map` with a `done` helper, made two pages that only focus 35 and 17 raw bytes larger; the
sibling's shape — `found id use` with the continuation, a block lambda per capability — is what
the emitted code has to match, and with it every page fell below the sibling's.
