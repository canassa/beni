## 2026-10-12 18:50 CEST — an SVG vocabulary for the browser platforms

**What I did.** Specified `boundary.md` §9.9 (pointers in §9.1, §9.3, `language.md` §11.14,
`backend.md` §15.3/§15.6, `browser-direct.md`) and built it: elm/svg's elements, attributes and
events as 230 more declarations of `html`'s one vocabulary module (no `Svg` module: a tag resolves in
one vocabulary with no import, and beni already folded elm/html's three modules into one). The parser
table learned foreign content (`Scope.svg`, `misplaced`, `contentIn`), so `dom` and `ssr` refuse an
element whose place would give it the other namespace; `dom` wraps a multi-node template holding an
SVG element in an `<svg>` (flags 2|4, which `Rt.template` already handled); `direct` compiles a `For`
row whose root is SVG. The driver gained a `mouse` step. Fixtures: `browser/dom/SvgDrawing`
(happy-dom and Chrome differ on `<foreignObject>`'s HTML: `.chrome-expected`),
`browser/direct/SvgRows`, `emit/dom/DomSvg`, `run/MarkupSvg`, `build/bad/{Dom,}SvgMisplaced`; all
seven red with the lowering changes reverted.

**What I learned.** The namespace is the parser's, never the name's: a template needs no
`createElementNS`, only the right wrapper at its top and a refusal where the place disagrees with the
declaration. happy-dom ignores HTML integration points. The vocabulary's duplicate check was a text
comparison per pair of declarations — quadratic; exact names now compare by interned symbol. Even so a
markup program's check costs ~6 ms more in the ReleaseSafe build (37 → 43 ms on `browser/dom/Events`),
most of it in `Types.build`, which grows with the vocabulary module's size for reasons not yet found;
worth profiling if vocabularies keep growing. `perf_event_open` is denied in the agent sandbox: use
`--self-profile` for timings.
