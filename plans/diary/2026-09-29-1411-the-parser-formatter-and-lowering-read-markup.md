## 2026-09-29 14:11 CEST — the parser, formatter and lowering read markup

**What I did**

- Three lexer fixes from the lexer's review, each with a fixture that failed first: a column-1
  `--` comment inside a tag or a hole no longer ends the markup; a stray byte in a tag stops at
  the tag's own syntax (a new `markup_stray` token, artifact v6); a stray's message says where it
  stood (opening tag, closing tag or text).
- Built frontend.md §9.4–§9.7: markup and vocabulary declarations parse with recovery
  (`unclosed_element`, `mismatched_closing_tag`, `element_as_argument`), dump as S-expressions,
  format under §11.15, and lower to one `markup` instruction per tree with items, constants,
  class/style entries, components, For/Show rows and their captures and inputs. Text is trimmed as
  Solid trims it and decoded against WHATWG's table, generated at build time from htmlize 1.1.0's
  pinned `entities.json`, with htmlize's vectors as tests. Artifact v7 carries `uses_markup`.
- The checker stops a markup module with `no_markup_vocabulary` and a vocabulary declaration with
  `not_implemented`, markup typing as the error type so nothing cascades. The 22 markup codes are
  in the catalogue. As-built notes in §9.3–§9.7 record every reading the spec left open.

**What I learned**

- Markup-free lexing lost 4–5 % with the lexer's source untouched and its instruction count equal;
  branch misses rose by a third. Appending the 22 diagnostic codes alone reproduced it, and aligning
  `tokenize` did not help this time. Count instructions, cycles and branch misses with
  `perf_event_open` before chasing a timing difference in source.
- The parser's vocabulary lookahead after `pub` cost 2 % of parse instructions until it tested the
  next token's tag before comparing the word's text.
- The fmt harness can check "never changes what a page says" before any lowering exists, by
  comparing the BIR dump, which holds each text run after trimming and decoding.
