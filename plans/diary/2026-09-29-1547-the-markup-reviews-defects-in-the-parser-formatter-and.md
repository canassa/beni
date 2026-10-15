## 2026-09-29 15:47 CEST — the markup review's defects in the parser, formatter and lowering

**What I did**

- A quoted attribute name with no `=` at the end of the file crashed lowering, which found the
  value's brace two tokens past the name. The escape's node now records its value and brace
  (`Ast.MarkupAttrEscape`), and lowering, the dump and the formatter read them from there.
- The formatter prints markup that must stay on its line (after a sibling with no space, after a
  `{`) whole, flat; a broken one after a sibling hangs off the children's column; no break where
  it cannot shorten a line (a lone name in a hole, an attribute-less tag's `>`). 200 glued `For`s
  went from 2.7 MB of output to the input re-indented; 36 non-idempotent fuzz finds pass.
- An element's attributes and children are parser siblings, so thousands of `{x.r}` holes are not
  "nested" past 4 096; CRLF text lines lose their `\r`; the lexer's mode stack spills past its
  frame and reports nothing, so markup nested through holes is one parser `nesting_too_deep`;
  braces on an element, two roots, a hole closed by a tag and a stray closing tag are one message
  each, in their own words; duplicate attributes are found in linear time.
- Corrected bench/README's claim of a 4–5 % lexing loss: interleaved, pinned `perf stat` with a
  short run subtracted shows identical instructions and cycles within the spread.

**What I learned**

- Allowing braces without `...` to parse (so lowering says the one thing) let the formatter print
  a `...` that was not there and change the program; the review's generators found it in minutes.
  Keep them (`gen.mjs`, `mut.mjs` in the scratchpad) running after any recovery change.
- A width that is finite means the node has a one-line form; printing a glued node flat is what
  makes "the author wrote it on one line" a fixed point.
