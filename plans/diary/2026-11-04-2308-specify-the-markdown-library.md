## 2026-11-04 23:08 CET — Specify the Markdown library

**What I did**

I wrote `docs/design/markdown.md`, the spec of #240: CommonMark 0.31.2 parsed to a public tree in core's `Markdown`, rendered as `Html msg` by the `html` platform's `Html.Markdown`. Raw HTML is parsed, and the renderer writes it as text. Links and images go through the `url` attribute rule (`safeUrl`), and nesting is capped at 64 levels. Three choices are the owner's, and I asked them on the dashboard: `conduit-fixes-q2` (where the library lives), `q3` (raw HTML as text or left out) and `q4` (the HTML 4 or the HTML5 entity table).

**What I learned**

- elm-explorations/markdown is kernel JavaScript over `marked`, and its default `sanitize = True` escapes all HTML (`src/Markdown.elm:78`). So "raw HTML shows as text" is Elm's default, not a new rule.
- The `html` platform already writes a `javascript:` or `data:text/html` URL as `""` in every `url` attribute (`platforms/browser/Rt.beni:2000`). A renderer in markup needs no URL filter of its own.
- The HTML5 entity table is the one large cost of full conformance: 2,125 names, about 9.5 kB brotli, against 27,921 bytes for all of Conduit's release build. HTML 4.01's 252 names are about 1.2 kB. With them, only the spec examples that use five HTML5-only names differ.
- A recursive tree needs a nesting cap in a language that promises no runtime errors: derived `eq`, the renderer and a lowering's walk all recurse. markdown-it caps at 100 by default and at 20 in its CommonMark preset.
- The RealWorld e2e suite tests six XSS payloads in an article body (`specs/e2e/xss-security.spec.ts:66`). They are free fixtures for a page.
