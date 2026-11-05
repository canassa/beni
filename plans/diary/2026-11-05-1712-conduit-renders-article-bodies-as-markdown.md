## 2026-11-05 17:12 CET — Conduit renders article bodies as Markdown

**What I did**

I built slice M3 of `docs/design/markdown.md` (#240). `Article.body` in `examples/conduit/` now renders the body with `Html.Markdown.fromString`, and the `GAP` comment is gone. The reader page's article body has a heading, emphasis, strong text, a code span, a list with a link, and a paragraph. Its transcript shows each element. Without the change, that page fails. On master `6f03a9ef06`, Conduit's release build grows from 114,700 to 169,646 bytes raw and from 29,357 to 48,184 brotli.

I also answered the review of slice M2 (#2011). The list kinds share one helper, and `run/MarkdownSafety` pins script URLs with a tab, a line end, a space or a NUL in them, a list that starts at 123456789, and nesting 50,000 deep. The generated `run/MarkdownSpec` now checks by itself that each listed difference holds raw HTML.

**What I learned**

- A helper that returns a fragment with a `<For>` in it, put into an element as a hole, adds one end anchor (`<!---->`) after the items in the DOM. The `ssr` lowering writes no anchor, so `run/MarkdownSpec` does not see it. Only the Conduit reader's transcript shows it: one comment node in each `<ul>`.
- CommonMark replaces a NUL with U+FFFD before anything else (spec §2.3), so a link to `\0javascript:` becomes `%EF%BF%BDjavascript:`, a relative path. A tab, a line end or a space in a destination is percent-encoded the same way. No spelling of that kind reaches the browser as a script URL.
- A check on the normalisation of the spec's HTML must skip the planned differences: example 616 has a `/>` inside the text of raw HTML, which is not a void tag.
- After the push of #2011's review fixes, the branch on GitHub had the new head, but the pull request kept the old head for more than 20 minutes, and no CI run started. An `@claude review` in that time reviews nothing. Check `gh api repos/canassa/beni/pulls/<n> --jq .head.sha` before you ask for a review pass.
- A helper call in an `Html msg` hole is not made again while its arguments are `===` the last render's (`language.md` §11.6). So Conduit's article page does not parse the body again on each keystroke in the comment box. `browser/tea/MarkdownBodySkip` shows it with `Debug.log` in the helper: one parse per body.
