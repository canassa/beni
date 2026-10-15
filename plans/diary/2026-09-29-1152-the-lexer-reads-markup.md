## 2026-09-29 11:52 CEST — the lexer reads markup

**What I did**

- Built frontend.md §9.1–§9.3: a mode stack in the tokenizer (`tag`, `children`, `close`,
  `hole`), eight markup token kinds each re-derivable from tag and start, the operand-start rule
  for `<`, the column-1 reset, the 4 096 bound, the stray bytes in text and in tags, the spread
  rule. Front-end artifact v5. The parser reports each markup expression once as
  `not_implemented` and skips it until the markup parser exists.
- A parse fixture may now carry a `.tokens` golden; twelve markup fixtures and one
  comparisons-stay fixture use it. `bench --phases=` and `bench/markup/` measure the lexer
  alone: ~277 MB/s, ~8.1 M LOC/s on markup; markup-free lexing unchanged.
- Recorded in §9.3's as-built note the readings the spec left open (close mode, stray-byte
  length and codes, text runs raw, the newline before a column-1 break, the bound reported once).

**What I learned**

- A first cut cost markup-free code 2–3 %: a 32 KiB array field copied into every file's
  tokenizer, and markup states inflating `next`'s state machine. A local array behind a slice
  and a separate `nextMarkup` removed it. Pin to one core and interleave eleven runs; single
  runs on the small corpus vary by ±5 %.
- Strings never nest, so they need no stack entry — which keeps the string fast path exactly
  what it was.
- A `builtin.is_test` assertion that every token's re-derived end equals what the lexer
  consumed turns the property, fuzz and stress tests into a check of the two-column cache.
