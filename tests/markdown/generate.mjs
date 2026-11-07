// Writes tests/corpus/run/MarkdownSpec.beni from CommonMark 0.31.2's spec.txt
// (docs/design/markdown.md §8): each example's Markdown, and the spec's HTML
// for it in the form `Ssr.render` writes. The program prints `<n> ok` when
// `Html.Markdown`'s rendering is that HTML. An example in differences.txt
// differs on purpose; the program prints its rendering instead, and the
// golden holds it. Run it again, and bless the fixture, when the spec or
// differences.txt changes:
//
//   node tests/markdown/generate.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const lines = readFileSync(join(here, 'spec.txt'), 'utf8').split('\n');
const fence = '`'.repeat(32);
const examples = [];
for (let i = 0, n = 0; i < lines.length; i++) {
  if (lines[i] !== fence + ' example') continue;
  const md = [], html = [];
  for (i++; lines[i] !== '.'; i++) md.push(lines[i]);
  for (i++; lines[i] !== fence; i++) html.push(lines[i]);
  n++;
  // The spec writes a tab as `→` (its own `spec_tests.py` does the same).
  const tabs = (s) => s.replace(/→/g, '\t');
  examples.push({ n, markdown: tabs(md.join('\n') + (md.length ? '\n' : '')), html: tabs(html.join('\n') + (html.length ? '\n' : '')) });
}

const differences = new Map(
  readFileSync(join(here, 'differences.txt'), 'utf8').split('\n')
    .filter((l) => /^\d/.test(l))
    .map((l) => { const [n, ...why] = l.split(' '); return [Number(n), why.join(' ')]; }));

// The spec's HTML in the form `Ssr.render` writes. These are the only
// rewrites, and `onlyLineEnds` below checks it for every example:
//
// 1. A void element has no `/`: `<hr />` is `<hr>`.
// 2. `&gt;` is `>`, in text and in an attribute value.
// 3. `&quot;` in text is `"`; in an attribute value it stays.
// 4. Outside `<pre>`, the line ending after a block tag (`p`, `h1`-`h6`,
//    `ul`, `ol`, `li`, `blockquote`, `pre`, `hr`) or after `<br />` goes, and
//    so does the line ending before a block tag.
const block = /^<\/?(?:p|h[1-6]|ul|ol|li|blockquote|pre|hr)\b[^>]*>$/;
function normalise(html) {
  const parts = html.split(/(<[^>]*>)/).filter((p) => p !== '');
  let inPre = 0;
  const out = [];
  for (let k = 0; k < parts.length; k++) {
    let p = parts[k];
    if (p.startsWith('<')) {
      if (/^<pre\b/.test(p)) inPre++;
      if (/^<\/pre>/.test(p)) inPre--;
      p = p.replace(/\s*\/>$/, '>').replace(/&gt;/g, '>');
      out.push(p);
      continue;
    }
    if (!inPre) {
      const prev = parts[k - 1] ?? '', next = parts[k + 1] ?? '';
      if (block.test(prev) || /^<br \/>$/.test(prev)) p = p.replace(/^\n/, '');
      if (block.test(next)) p = p.replace(/\n$/, '');
    }
    out.push(p.replace(/&gt;/g, '>').replace(/&quot;/g, '"'));
  }
  return out.join('');
}

// Apart from rewrites 1-3, `normalise` only deletes line endings.
function onlyLineEnds(html, out) {
  const base = html.replace(/\s*\/>/g, '>').replace(/&gt;/g, '>').replace(/&quot;/g, '"');
  const got = out.replace(/&quot;/g, '"');
  let i = 0;
  for (const c of base) {
    if (i < got.length && got[i] === c) i++;
    else if (c !== '\n') return false;
  }
  return i === got.length;
}
// The check covers the examples whose golden `normalise` writes, the ones
// not in differences.txt.
for (const e of examples) {
  if (!differences.has(e.n) && !onlyLineEnds(e.html, normalise(e.html))) throw new Error(`normalise changes example ${e.n} past its rewrites`);
}

const lit = (s) => '"' + [...s].map((c) => {
  const n = c.codePointAt(0);
  if (n >= 0xd800 && n <= 0xdfff) throw new Error('a lone surrogate has no beni string literal');
  if (c === '\\') return '\\\\';
  if (c === '"') return '\\"';
  if (c === '$') return '\\$';
  if (c === '\n') return '\\n';
  if (c === '\t') return '\\t';
  if (c === '\r') return '\\r';
  if (n < 32 || n === 127) return '\\u{' + n.toString(16) + '}';
  return c;
}).join('') + '"';

const rows = examples.map((e) => `( ${e.n}, ${lit(e.markdown)}, ${differences.has(e.n) ? 'Nothing' : `Just ${lit(normalise(e.html))}`} )`);
const known = [...differences.keys()].filter((n) => !examples.some((e) => e.n === n));
if (known.length) throw new Error(`differences.txt names examples the spec does not have: ${known}`);

const fixture = join(here, '../corpus/run/MarkdownSpec.beni');
writeFileSync(fixture, `-- run: the conformance of \`Html.Markdown\` to CommonMark 0.31.2
-- (docs/design/markdown.md §8). Written by tests/markdown/generate.mjs from
-- the spec's ${examples.length} examples (tests/markdown/spec.txt, CC BY-SA 4.0); do not edit
-- it by hand. A line is \`<n> ok\` when \`Ssr.render (Html.Markdown.fromString
-- md)\` is the spec's HTML in \`Ssr.render\`'s form. The ${differences.size} examples of
-- tests/markdown/differences.txt differ on purpose: each holds raw HTML,
-- which the renderer shows as text (§6.1). Their line is \`<n> raw\` and the
-- rendering, which the golden pins, or \`<n> DIFFERS\` when the tree holds no
-- raw HTML.
import Html.Markdown
import Markdown exposing (Block, BlockQuote, BulletList, Emphasis, Heading, HtmlBlock, HtmlInline, Image, Inline, Link, OrderedList, Paragraph, Strong)
import Node exposing (Program)
import Ssr


examples : List (Int × String × Maybe String)
examples =
    [ ${rows.join('\n    , ')}
    ]


check : Int × String × Maybe String → String
check ( n, markdown, wanted ) =
    got = Ssr.render (Html.Markdown.fromString markdown)
    case wanted of
        Just html →
            if got == html then "\${String.fromInt n} ok" else "\${String.fromInt n} DIFFERS \${Debug.toString got} WANTED \${Debug.toString html}"

        Nothing →
            if List.any (Markdown.parse markdown) rawBlock then
                "\${String.fromInt n} raw \${Debug.toString got}"
            else
                "\${String.fromInt n} DIFFERS: no raw HTML \${Debug.toString got}"


-- The tree holds an \`HtmlBlock\` or an \`HtmlInline\`.
rawBlock : Block → Bool
rawBlock b =
    case b of
        HtmlBlock _ →
            True

        Paragraph content →
            List.any content rawInline

        Heading _ content →
            List.any content rawInline

        BlockQuote children →
            List.any children rawBlock

        BulletList _ items →
            List.any items λitem → List.any item rawBlock

        OrderedList _ _ items →
            List.any items λitem → List.any item rawBlock

        _ →
            False


rawInline : Inline → Bool
rawInline x =
    case x of
        HtmlInline _ →
            True

        Emphasis content →
            List.any content rawInline

        Strong content →
            List.any content rawInline

        Link _ _ content →
            List.any content rawInline

        Image _ _ content →
            List.any content rawInline

        _ →
            False


main : Program
main = Node.printLines (List.map examples check)
`);
console.log(`${examples.length} examples, ${differences.size} differences; now run beni fmt on ${fixture}`);
