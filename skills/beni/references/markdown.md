# Markdown

`Markdown` is core, on every platform. `Markdown.parse text` reads a CommonMark 0.31.2 document
and gives its blocks. It never fails: every text is a document.

## The tree

| Block | Is |
|---|---|
| `Paragraph inlines` | a paragraph |
| `Heading level inlines` | `#` to `######`, or a setext heading (level 1 or 2) |
| `ThematicBreak` | `***`, `---` or `___` |
| `CodeBlock language code` | a fenced or indented code block; `language` is the info string's first word |
| `BlockQuote blocks` | `>` |
| `BulletList tight items` | `-`, `+` or `*` items; each item is a `List Block` |
| `OrderedList start tight items` | `1.` or `1)` items |
| `HtmlBlock text` | raw HTML, as text |

| Inline | Is |
|---|---|
| `Text s` | text, with escapes and character references decoded |
| `CodeSpan s` | `` `code` `` |
| `Emphasis inlines`, `Strong inlines` | `*a*`, `**a**` |
| `Link destination title inlines` | `[a](/url "title")`, a reference, or an autolink |
| `Image destination title inlines` | `![alt](/img.png)`; the description is inlines |
| `HardBreak`, `SoftBreak` | a line ending with two spaces or `\`, and a plain line ending |
| `HtmlInline text` | raw HTML, as text |

A link reference definition (`[a]: /url`) is not in the tree: a reference that uses it is a
`Link`. All 2,125 named character references of HTML5 decode (`&copy;`); a name that HTML5
does not have stays as you wrote it.

```beni
import Markdown exposing (Block, Heading, Text)


pub titles : String → List String
titles text = List.filterMap (Markdown.parse text) λb →
    case b of
        Heading 1 [ Text t ] →
            Just t

        _ →
            Nothing
```

## Raw HTML and URLs

- Raw HTML is in the tree as `HtmlBlock` and `HtmlInline`, as its text. Never make an element of
  it. Show it as text, or leave it out.
- A destination is in the tree as it was written, escapes and references decoded and unsafe
  characters percent-encoded. A `javascript:` URL is in the tree too: an `href` or `src` in markup
  writes it as `""`.

## Limits

- Blocks nest to 64 levels, block quotes and lists together. Inlines nest to 64 levels. A deeper
  marker stays as text.
- `parse` takes time linear in the text's length.

Sources: `docs/design/markdown.md` §3, §4, §6, §7; `core/Markdown.beni`.
