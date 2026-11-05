# tests/markdown — CommonMark's own examples

The conformance test of core's `Markdown` and the `html` platform's `Html.Markdown`
(`docs/design/markdown.md` §8).

| File | What it is |
|---|---|
| `spec.txt` | CommonMark 0.31.2, the spec's text, unchanged: `commonmark/commonmark-spec` at tag `0.31.2` (commit `9103e341a973`), SHA-256 `257c41ad946f7a1414a499aca402a1aa8fdac3678532266611348c1cf54f4b80` |
| `LICENSE-commonmark-spec.txt` | its licence, unchanged: the spec is CC BY-SA 4.0, copyright John MacFarlane |
| `generate.mjs` | writes `tests/corpus/run/MarkdownSpec.beni` from `spec.txt` and `differences.txt` |
| `differences.txt` | the examples that differ on purpose, each with its reason |

`run/MarkdownSpec` holds each example's Markdown and the spec's HTML for it, in the form that
`Ssr.render` writes: void elements with no `/`, no line ending around a block tag or after
`<br>`, and `>` and a text's `"` not escaped. It prints `<n> ok` for each example that renders as
that HTML. An example in `differences.txt` prints `<n> raw` and its rendering instead, and the
golden pins it. Each difference holds raw HTML, which the renderer shows as text (§6.1): the fixture
parses each one and prints `<n> DIFFERS` when its tree holds no `HtmlBlock` and no `HtmlInline`.
`generate.mjs` also checks that its HTML rewrites (listed in its comment) only delete line endings
past the three that `Ssr.render`'s form needs. The fixture is a work derived from `spec.txt`, so it
is under the spec's licence too.

After a change to `spec.txt` or `differences.txt`:

```sh
node tests/markdown/generate.mjs
zig-out/bin/beni fmt tests/corpus/run/MarkdownSpec.beni
BENI_WRITE_EXPECTED=1 zig build test-blackbox -Dcorpus=run/MarkdownSpec
```

Read every changed line of the golden: a line that is not `ok` and not in `differences.txt` is a
defect, never a line to bless.
