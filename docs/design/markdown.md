# Markdown — CommonMark to `Html`, with no raw HTML

*2026-11-04, #240. **Specified, not built.** The contract for beni's Markdown library: which
CommonMark it parses, where it lives, the tree it gives, how that tree becomes `Html msg`, and
why no Markdown text can put script or markup of its own into a page. §9 holds the owner's three
decisions (taken 2026-11-04); §10 holds the slices and what "done" means for each.
Section numbers are never renumbered (CLAUDE.md rule 2); a later change is a dated amendment in
place.*

## 1. What this is

An article of the Conduit example has a Markdown body, and the page shows it as plain text
(`examples/conduit/src/Article.beni`, `body`, a `GAP` comment). elm-spa-example renders it with
elm-explorations/markdown, and the RealWorld spec's front ends render it as HTML. beni has no
Markdown library. A project can reach a JavaScript one only through a platform of its own
(`boundary.md` §3.1, amended 2026-10-03), and such a library gives HTML text, which a view can put
into a page only through the `raw` attribute (`innerHTML`).

A Markdown library needs no `foreign`. It is a parser and a view, both pure beni. So this is not a
gap in the wall (CLAUDE.md rule 7): a developer could write it. It is a library that beni ships
because a page that shows user text needs one, and because the safe version is easy to get wrong
(§6).

**The guarantee.** For every `String`:

1. `parse` returns, in time linear in the length of the text, and never throws (§7).
2. The `Html` that the renderer makes from the tree holds no element, attribute or event that the
   text names. Every element comes from the renderer's own table (§5). Every character of the text
   reaches the page as text, an attribute value or nothing.
3. No URL in the text can run script: every link and image URL goes through the `url` attribute
   rule that every view has (`language.md` §11.5 and §11.14, `backend.md` §15.3, `safeUrl`).

Elm's library is kernel JavaScript over `marked`. Its default, `sanitize = True`, escapes all HTML
(elm-explorations/markdown `src/Markdown.elm:78`, commit `5fdbf443`). beni's library keeps that
default as a property of the design, not as an option.

## 2. Where it lives

*Decided 2026-11-04 by the owner (Cesar, dashboard `conduit-fixes-q2`): "Core parser, `html`
renderer", as below (§9 D1).*

- **Core `Markdown`** parses a `String` to a tree of blocks and inlines (§4). It is pure, it
  imports nothing but core, and every platform has it. A build checks only the core modules it
  reaches (`fast-compiler.md` §8, amended), and reachability drops what a program does not call
  (`backend.md` §9), so a program that does not import `Markdown` pays nothing.
- **The `html` platform's `Html.Markdown`** renders the tree as `Html msg` (§5). `Html` is the
  `html` platform's type, so core cannot make it. `node`, `browser` and `browser-tea` re-export
  `Html.Markdown` beside `Html` (their `beni.json` `"reexports"`), so a page and a `node` server
  render the same tree to the same markup.

A program that wants its own markup — other classes, headings with anchors, code with a highlighter
— matches the tree itself. That is why the tree is public, as dillonkearns/elm-markdown's renderer
is, and not hidden behind one function.

## 3. Which CommonMark

**CommonMark 0.31.2** (2024-01-28, spec.commonmark.org/0.31.2), the spec's own section numbers:

| Spec section | Construct | Here |
|---|---|---|
| 2.1–2.3 | characters, lines, tabs, insecure characters (U+0000 → U+FFFD) | yes |
| 2.4 | backslash escapes | yes |
| 2.5 | entity and numeric character references | yes: numeric, and all 2,125 names of HTML5 (§9 D3) |
| 4.1 | thematic breaks | yes |
| 4.2, 4.3 | ATX and setext headings | yes |
| 4.4, 4.5 | indented and fenced code blocks, the info string | yes |
| 4.6 | HTML blocks | **parsed, never markup**: §6.1 |
| 4.7 | link reference definitions | yes |
| 4.8, 4.9 | paragraphs, blank lines | yes |
| 5.1–5.3 | block quotes, list items, lists (tight and loose) | yes, to the depth of §7.2 |
| 6.1 | code spans | yes |
| 6.2 | emphasis and strong emphasis | yes |
| 6.3, 6.4 | links and images, with titles and references | yes |
| 6.5 | autolinks (`<https://…>`, `<a@b.c>`) | yes |
| 6.6 | raw HTML | **parsed, never markup**: §6.1 |
| 6.7, 6.8 | hard and soft line breaks | yes |
| 6.9 | textual content | yes |

So the subset is CommonMark less one thing: raw HTML never becomes markup. Nothing else is left
out, because each construct that is left out turns text that an author wrote as Markdown into
literal `*`, `#` or `[` on the page.

**Not here:** the extensions of GitHub Flavored Markdown (tables, strikethrough, task lists, bare
URL autolinks, footnotes), smart punctuation, heading anchors and syntax highlighting. Each is a
later, dated amendment of this section. A program that wants one now renders the tree (§2).

## 4. The tree

```text
-- core/Markdown.beni
pub type Block
    = Paragraph (List Inline)
    | Heading Int (List Inline)                    -- level, 1 to 6
    | ThematicBreak
    | CodeBlock CodeBlock
    | BlockQuote (List Block)
    | BulletList Bool (List (List Block))          -- tight, the items
    | OrderedList Int Bool (List (List Block))     -- start, tight, the items
    | HtmlBlock String                             -- §6.1: text, never markup

pub type alias CodeBlock =
    language : Maybe String                        -- the info string's first word, decoded
    code : String

pub type Inline
    = Text String                                  -- references and escapes decoded
    | CodeSpan String
    | Emphasis (List Inline)
    | Strong (List Inline)
    | Link Link
    | Image Image
    | HardBreak
    | SoftBreak
    | HtmlInline String                            -- §6.1: text, never markup

pub type alias Link =
    destination : String                           -- decoded and percent-encoded, as CommonMark's
    title : Maybe String
    content : List Inline

pub type alias Image =
    destination : String
    title : Maybe String
    description : List Inline                      -- the renderer's `alt` is its plain text

pub parse : String → List Block
```

- **`parse` is total.** CommonMark has no syntax errors: every string is a document. There is no
  `Result` and no error type.
- **Link reference definitions are resolved by `parse`** and do not appear in the tree. A
  reference with no definition is text, as CommonMark says.
- **A destination is normalised as CommonMark's reference renderer normalises it**: references
  and escapes decoded, then characters outside the URL set percent-encoded (spec §6.3's examples
  show the output). The renderer writes it as it is.
- **`Text` runs are joined**: two `Text` are never adjacent, so a renderer writes one text node
  per run.
- `eq` and `compare` are derived (`static-dispatch-spike.md` §9), so a test compares trees.

*As built 2026-11-05 (slice M1):* the constructors are positional, `CodeBlock (Maybe String)
String`, `Link String (Maybe String) (List Inline)` (destination, title, content) and `Image String
(Maybe String) (List Inline)` (destination, title, description). A record alias is also a
constructor of its module, so `Link Link` is `duplicate_constructor`. A title that is `""` is
`Nothing`, as the reference renderer writes no `title` for it.

## 5. The renderer

```text
-- platforms/html/Html/Markdown.beni
pub view : List Markdown.Block → Html msg          -- a fragment of the blocks
pub fromString : String → Html msg                 -- view (Markdown.parse text)
```

Each node is one markup site of the renderer, written in markup, so the `html` vocabulary checks
it and each lowering compiles it (`language.md` §11):

| Node | Markup |
|---|---|
| `Paragraph xs` | `<p>` xs `</p>`; in a tight list item, xs alone |
| `Heading n xs` | `<h1>` … `<h6>` |
| `ThematicBreak` | `<hr>` |
| `CodeBlock c` | `<pre><code class="language-…">` text `</code></pre>`; no `class` when `language` is `Nothing` |
| `BlockQuote bs` | `<blockquote>` |
| `BulletList`, `OrderedList` | `<ul>`, `<ol>` (`start` when it is not 1), `<li>` per item |
| `HtmlBlock s`, `HtmlInline s` | the text `s` (§6.1) |
| `Text s` | the text `s` |
| `CodeSpan s` | `<code>` text `</code>` |
| `Emphasis`, `Strong` | `<em>`, `<strong>` |
| `Link l` | `<a href={l.destination}>`, `title` when there is one |
| `Image i` | `<img src={i.destination} alt={plain text of i.description}>`, `title` when there is one |
| `HardBreak` | `<br>` |
| `SoftBreak` | the text `"\n"` |

These are the elements of the HTML in the spec's examples, so §8's conformance test compares
the two after normalisation.

The renderer never uses the `raw` attribute (`innerHTML`, `Html.beni:789`), and never a quoted
attribute name (`language.md` §11.5). Its only attribute values that come from the text are
`href`, `src`, `alt`, `title`, `start` and `class` (as `language-` plus the info word).

*As built 2026-11-05 (slice M2):* `platforms/html/Html/Markdown.beni`, with `view` and
`fromString` as above. The `html` vocabulary had no `start` on `<ol>`; it has now (`pub attribute
"start" on "ol" : Int`). `node`, `browser`, `browser-tea` and `browser-inline` re-export
`Html.Markdown` beside `Html`.

## 6. Safety

### 6.1 Raw HTML is parsed, and becomes text

*Decided 2026-11-04 by the owner (Cesar, dashboard `conduit-fixes-q3`): "Show it as text", as
below (§9 D2).*

CommonMark recognises HTML blocks (spec §4.6) and raw inline HTML (spec §6.6), and its renderer
writes them to the page as they are. beni parses them by the same rules, so that the rest of the
document parses as CommonMark says — an HTML block ends a paragraph, and a `*` inside an HTML tag
opens no emphasis. It keeps them in the tree as `HtmlBlock` and `HtmlInline`, with their source text.

**The renderer writes that text as text.** `<script>alert(1)</script>` in a body shows on the page
as those 25 characters. The renderer writes an `HtmlBlock` as a `<p>` of its text, and the line
ends stay in the text. This is elm-explorations/markdown's default (`sanitize = True`), and it
keeps everything that the author wrote visible. A program that wants to allow some tags renders
the tree itself (§2), and must then build those elements through the `Html` vocabulary, never
from the text.

### 6.2 URLs

A link `href` and an image `src` are `url` attributes of the `html` vocabulary, so every lowering
sends them through `safeUrl`, which writes a `javascript:` or `data:text/html` URL, with any
spacing a browser ignores, as `""` (`backend.md` §15.3; `platforms/browser/Rt.beni:2000`,
`platforms/node/Rt.beni:83`). The library does not add a second filter: one rule, in one place, for
every view. A `javascript:` link in a Markdown text is therefore an `<a href="">` with its text.

### 6.3 Text

Every `Text`, `CodeSpan` and `CodeBlock` string reaches the page through a markup text hole, which
a lowering writes as a text node (dom) or escapes (`ssr`). Character references are decoded by
`parse`, so `&lt;script&gt;` in a text shows `<script>` as text, and never becomes a tag. U+0000 is
U+FFFD (spec §2.3).

### 6.4 The RealWorld payloads

The RealWorld e2e suite puts six payloads in an article body and checks that no `script` element
and no `on…` attribute is in `.article-content` (`specs/e2e/xss-security.spec.ts:66`, realworld-apps
commit `077acadf`): a `script` tag, `img onerror`, `svg onload`, `iframe srcdoc`, an `a` with a
`javascript:` `href`, and `div onmouseover`. Each is a case of §8's fixtures, on a page.

## 7. Cost and limits

### 7.1 Time

`parse` is linear in the length of its input, for every input. *Amended 2026-11-05 (the review of
#1950):* it reads the text with the host's patterns at a position, through `slice`, so linear time
assumes that `slice` of a long string is O(1), as V8 (Node, Chrome) makes it with sliced strings.
`Js.regExp` refuses the `y` flag, which would read at a position with no `slice`. The known traps are the inputs of
cmark's pathological tests (cmark `test/pathological_tests.py`, commit `5290e3edfa`, 25 cases):
many emphasis openers with no closer, many `[` with no `]`, deeply nested brackets, long runs
of backticks of different lengths, many link reference definitions, and deeply nested block
quotes and lists. The
implementation follows cmark's answers to them: the delimiter stack with a lower bound per
delimiter kind (spec §7.3, *process emphasis*, `openers_bottom`), and a bracket stack whose
inactive openers are skipped.

*As built 2026-11-05 (slice M1):* five measures keep it linear.

- Emphasis is a pass over a bracket's or a paragraph's items, with a stack of open delimiters and
  the twelve lower bounds of spec §7.3.
- A bracket that forms no link joins its parent as one item, so 25 000 nested `[` cost no copy.
- Backtick runs are found once, by length, and a code span's closer is a search in them, not a
  rescan of the rest of the text.
- A bracket is inactive when a link formed after it opened: a count, not a walk of the stack.
- Two scans that the reference parser repeats end early, as cmark ends them. A bare destination
  fails past 32 open parentheses (cmark `src/inlines.c:1098`; spec §6.3 allows a limit). Raw HTML
  of a kind whose end (`-->`, `?>`, `>`, `]]>`) a scan did not find through the end of the text is
  not scanned again (cmark's `FLAG_SKIP_HTML_*`, `src/inlines.c:974`).

Measured on cmark's 25 inputs (Node 24, `--release`): `unclosed links B` took 6 679 ms and `unclosed
<!--` 74 202 ms before the last two measures, and 172 ms and 552 ms after them (one run each). Every
input now takes at most about a second at cmark's size (`pattern ![[]() repeated`, 960 kB: 1 049
ms), and twice the size takes about twice the time (1 847 ms). `run/MarkdownLimits` holds all 25,
with `[a](b` and `<!--` at a size that a quadratic scan cannot finish inside the 120-second hang
guard.

### 7.2 Depth

The tree is recursive, and so are its derived `eq`, the renderer, and a lowering's walk of the
markup. With no cap, a text of 100 000 `>` makes a tree 100 000 levels deep, and every recursive
walk of it overflows the stack: a runtime error (CLAUDE.md rule 9). So **nesting is capped at 64
levels**, of blocks and of inlines, counted apart:

- If a container marker (`>`, a list item's marker) opens level 65, it is text of the paragraph
  at level 64.
- If an emphasis, link or image opens inline level 65, it stays as its delimiter text.

The cap bounds a real blow-up and changes no document that a person writes. markdown-it has the
same rule: `maxNesting` is 100 by default and 20 in its CommonMark preset
(`src/presets/default.ts:40`, `commonmark.ts:40`, commit `a8c00d474e`). The fixtures pin the text
at the cap.

### 7.3 Size

The parser and the renderer are code that ships in each program that renders Markdown, plus the
reference table of §9 D3: 2,125 names, about 9.5 kB brotli in a simple form. Master
`006f4a9e75`'s Conduit is 27,921 bytes brotli, so the table alone is about a third of it.

- **Only a program that renders Markdown ships the table.** The table is one top-level value of
  `core/Markdown`, read only by the parser's reference decoding, so reachability drops it from
  every program that does not call `Markdown.parse` (`backend.md` §9). A build checks only the
  core modules it reaches (`fast-compiler.md` §8), so a program that does not import `Markdown`
  does not check it either. Slice M2 shows both: a program that does not import `Markdown` builds
  to the same bytes as on master, and no name of the table is in its output.
- **A baseline line.** Slice M2 adds a line for a program that renders Markdown to
  `bench/size.mjs`, so a later change to the table's encoding has a number to beat. That change is
  #1936, the owner's "measured cost to reduce later" (§9 D3); it must keep §8's reference examples
  passing.

*Measured 2026-11-05 (slice M2), `--release`, brotli 11.* `bench/size.mjs`'s `browser-tea
markdown` page renders a short text: 62,612 bytes raw and 22,268 brotli, against 979 and 489 for
the `browser-tea hello` page beside it. Of that, the table is about 10.0 kB (a page that only
parses: 20,130; the same page with an empty table: 10,148), the parser's code about 9.6 kB, and the
renderer about 2.1 kB (a page that renders: 22,220). Conduit's source with no `Markdown`, built by
the compiler of this slice, is byte for byte what master `1468390492`'s compiler builds: 111,448
bytes raw and 28,135 brotli, with no name of the table and no `Markdown` module in it.

## 8. Tests

- **Conformance.** `tests/markdown/` vendors spec.txt of CommonMark 0.31.2 (CC BY-SA 4.0, kept with
  its licence and its SHA-256) and a script that writes the fixture `run/MarkdownSpec` from it:
  each of the 652 examples' Markdown as input, and its HTML as the expected output, normalised to
  the `ssr` lowering's serialisation (attribute order, `<hr>` for `<hr />`, the whitespace between
  blocks). The program renders each example with `Ssr.render (Html.Markdown.fromString md)`. An
  example that differs on purpose — raw HTML (§6.1), and nothing else — has its beni output as
  its expected output and its number in `tests/markdown/differences.txt`, with the reason. Every
  other example must match, the 17 of spec §2.5 (references, examples 25 to 41) included.
- **Safety.** A `run/` fixture renders §6.4's payloads, the `javascript:` and `data:text/html`
  links in every spelling `safeUrl`'s pattern names, and `&lt;script&gt;`, and prints the HTML.
  A `browser/tea/` page renders them in a DOM, and its transcript shows the text and no element.
- **Limits.** A `run/` fixture parses cmark's pathological inputs at a size that a quadratic
  parser cannot finish inside the 120-second hang guard, and the nesting at 64 and 65 levels.
- **The tree.** A `run/` fixture prints `Debug.toString (Markdown.parse md)` for one document of
  each construct, so the tree's shape is pinned apart from the renderer.
- **Size.** §7.3's two measurements: the `bench/size.mjs` line, and a program with no
  `Markdown` that builds to master's bytes with no name of the table in it.
- **Conduit.** `browser/tea/ConduitReader` gets an article body with a heading, a list, emphasis,
  a link and a code span, and its transcript shows the elements.

## 9. Decisions

The owner took all three on 2026-11-04 (Cesar, dashboard).

- **D1 — Where it lives** (`conduit-fixes-q2`, 23:38 UTC). **Decided: "Core parser, `html`
  renderer"** (§2). The other answer was a module of the Conduit example, which only Conduit has.
- **D2 — Raw HTML** (`conduit-fixes-q3`, 23:38 UTC). **Decided: "Show it as text"** (§6.1), as
  Elm's default does. The other answer was to leave it out, as cmark's safe mode writes `<!-- raw
  HTML omitted -->`.
- **D3 — Named references** (`conduit-fixes-q4`, 23:39 UTC). **Decided: HTML5's 2,125 names.**
  The owner: *"It's CommonMark, so be conformant and pass the spec's reference examples. A missing
  name shows the author's text wrong. 9.5 kB is a measured cost to reduce later (compact table
  encoding), not a reason to change behaviour now. Make sure only programs that render Markdown
  ship it, and add a size line so the reduction has a baseline."* §7.3 holds the two size
  conditions, and #1936 the reduction. The other answer was HTML 4.01's 252 names, about 1.2 kB
  brotli, with a name outside them left as text.

## 10. Slices

- **M1 — the parser.** `core/Markdown.beni`: §4's tree and `parse`, the HTML5 reference table,
  §7's limits. Fixtures: the tree, the limits. `skills/beni/` and `zig build skill-api`.
  *As built 2026-11-05:* `run/MarkdownTree` and `run/MarkdownLimits`. A harness outside the tree
  rendered `parse`'s tree with commonmark.js's HTML rules (raw HTML as it is) and matched all 652
  examples of the spec, in a development and a `--release` build; slice M2 makes that the
  corpus's conformance fixture. The table is WHATWG's `entities.json` (2026-11-05, SHA-256
  `d741d877ac77…`), the 2,125 names that end in `;`. The two passes keep their growing state (the
  open blocks and their children, the open brackets and their items, the open emphasis delimiters)
  in host objects written in place, as `Schema` and `Queue` keep theirs. A first version threaded
  it through records and lists, and the ownership checker refused 190 of its writes when it
  checked core for an in-place platform: a frame's list of children inside the list of frames is
  a list the checker cannot prove unshared. Every value the passes make (`Node`, `Item`, `Inline`,
  `Block`) is a plain value, never written once made.
- **M2 — the renderer.** `Html.Markdown` (§5), the re-exports, the conformance fixture and
  `tests/markdown/`, the safety fixtures. §7.3's two size measurements and the `bench/size.mjs`
  line. *As built 2026-11-05:* `run/MarkdownSpec` (580 examples `ok`; the 72 of
  `tests/markdown/differences.txt` each hold raw HTML, which shows as text: 46 HTML blocks and 26
  inline), `run/MarkdownSafety` and `browser/tea/MarkdownSafety`.
- **M3 — Conduit.** `Article.body` renders the body with `Html.Markdown.view`; the `GAP` comment
  goes. `ConduitReader`'s new article and transcript (§8). Closes #240.
