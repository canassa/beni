## 2026-11-05 04:08 CET — Core gets a CommonMark parser

**What I did**

I built slice M1 of `docs/design/markdown.md` (#240): `core/Markdown.beni`, a CommonMark 0.31.2 parser with all 2,125 HTML5 named references, the 64-level caps and the tree of §4. A harness outside the tree rendered its tree with commonmark.js's HTML rules and matched all 652 spec examples, in a development and a `--release` build. Two fixtures pin the tree (`run/MarkdownTree`) and the limits with cmark's 25 pathological inputs (`run/MarkdownLimits`). `skills/beni/references/markdown.md` is new. I opened #1947 for a crash of the ownership checker v2.

**What I learned**

- Core is checked for the platforms that edit lists in place, whatever the program's platform. `beni check` of a program does not show it: the build's core pack and the corpus's core parity dump do. My first version threaded the parser's state through records and lists, and the checker refused 190 writes. Core's engines keep growing state in host objects (`Schema`, `Queue`), and so does the parser now. Every value it makes is plain, and it became faster (2.4 s for the 25 inputs, from about 4 s).
- `Maybe.withDefault (List.get xs i) d` in a core module crashes the ownership checker v2 (`src/own2/Shape.zig:766`, #1947). A declaration-level bisector found it: replace function bodies with `Debug.todo "stub"` and halve the kept set. It took 25 checks of about a second each.
- `Js.regExp` refuses the `g` flag, because a global pattern keeps a position between uses. `replaceAll` makes a fresh global copy of the pattern for each call.
- Two of cmark's inputs were quadratic in my first version, as in the reference parser commonmark.js: `[a](b` repeated (the destination scan) and `<!--` repeated (the comment scan). cmark's two answers, a limit of 32 open parentheses and a flag per kind of raw HTML with no end left, made them 172 ms and 552 ms from 6.7 s and 74 s.
- A record alias is a constructor of its module, so the spec's `Link Link` is `duplicate_constructor`. The tree uses positional constructors.
- The fb55 `entities` copy and WHATWG's `entities.json` agree on all 2,125 names that end in `;`.
