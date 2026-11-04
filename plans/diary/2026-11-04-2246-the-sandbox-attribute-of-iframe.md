## 2026-11-04 22:46 CET — The sandbox attribute of iframe

**What I did**

#1890, a gap of #142: the `html` vocabulary gets `pub attribute "sandbox" on "iframe" : String`. The playground's output frame is `sandbox="allow-scripts"`, and the owner's `q6` (the frame loads from a URL) means `srcdoc` is not needed. `tests/corpus/browser/tea/IframeSandbox` pins the attribute written as text and from a hole. `boundary.md` §9.13 has the as-built note, and `skills/beni/references/api-html.md` is regenerated. I also corrected the time of #1902's Chrome run in its body: 22:40 to 22:42, not 22:44 to 22:47.

**What I learned**

- The vocabulary has no form for a set of tokens: `rel`, `type` and `autocomplete` are `String`. So is `sandbox` now. No guarantee needs a type here, because a token that the browser does not know lifts no restriction.
- An attribute from a hole is written after the template's own attributes. A frame takes its sandbox flags when it navigates, so the order of a `src` hole and a `sandbox` hole matters. I did not verify it and opened #1911. The playground writes `sandbox` as text, so it is not affected.
- `uptime` with `sed 's/.*load/load/'` drops the clock. Keep the time when a log must say when a run took place.
