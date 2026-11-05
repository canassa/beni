## 2026-11-05 14:45 CET — The html platform renders Markdown

**What I did**

I built slice M2 of `docs/design/markdown.md` (#240): `platforms/html/Html/Markdown.beni`, with `view` and `fromString`, which turn core's Markdown tree into `Html msg`. The `node`, `browser`, `browser-tea` and `browser-inline` platforms re-export it, and the `html` vocabulary gained `start` on `<ol>`. `tests/markdown/` keeps CommonMark 0.31.2's text and licence, a generator and the list of planned differences. `run/MarkdownSpec` checks all 652 examples through the real renderer: 580 are the spec's HTML, and the other 72 hold raw HTML, shown as text. `run/MarkdownSafety` and the page `browser/tea/MarkdownSafety` pin the RealWorld XSS payloads and the script URLs. `bench/size.mjs` has a `browser-tea markdown` line, the baseline for #1936.

**What I learned**

- The spec's HTML is not `Ssr.render`'s form. `Ssr.render` writes void tags with no `/`, no line ending between blocks and no escape for `>`. The generator normalises the spec's HTML to that form, so an `ok` line's golden comes from the spec, never from beni's output.
- Each of the 72 differences holds raw HTML. I checked each one with a program that parses the example and looks for an `HtmlBlock` or an `HtmlInline`, before I wrote its line in `differences.txt`.
- The URL rule of every view already writes a `javascript:` URL as `""`. The renderer needs no check of its own: a link's destination goes into `href` like any other value.
- A page that renders Markdown ships 22,268 brotli bytes: about 10.0 kB of entity table, 9.6 kB of parser and 2.1 kB of renderer. A program with no Markdown builds to exactly master's bytes, which I checked on Conduit.
- A string literal inside an interpolation hole is not allowed. Bind it first.
- The gates hold a generated `.beni` fixture to `beni fmt`'s layout too. The generator writes one line per example, and the formatter breaks a long tuple over several lines, so `beni fmt` runs after `generate.mjs`.
- `zig build install` adds the skill folder's files and never deletes one. After I ran the gates on a branch with `references/dates.md`, the skill gate of a branch without it failed: 24 installed files against 23 (#1987). Delete `zig-out/share/beni/skills` after a branch switch in one worktree.
- `tests/blackbox/ownership-v2-known.txt` keys each known v1/v2 difference by its line and column. A change that moves lines above such a position moves the key, and the gate fails on the same difference at the new position.
