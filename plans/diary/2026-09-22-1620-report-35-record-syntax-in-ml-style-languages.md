## 2026-09-22 16:20 CEST — report 35: record syntax in ML-style languages

**What I did**

- The owner, looking at `type alias User =` / `{ name : String` / `, age : Int` /
  `}`, said it is ugly and that an indentation-sensitive language should use
  that to its advantage. Sent one research agent for primary sources on how
  ML-family and layout-sensitive languages declare records; it wrote
  `docs/design/research/35-record-syntax-in-ml-languages.md` (Lean 4, Idris 2,
  Agda, F#, Nim, Koka, Scala 3, Elm and its forks, Roc, Haskell, PureScript,
  Gleam and others; 288 links; three `[sketch]` layout syntaxes for beni's
  record type and `schema` declaration; no verdict). Spot-checked its local
  line references and key sources before relaying it. Committed the report;
  nothing else changed.

**What I learned**

- **Layout records and inline record types have never coexisted.** Every
  language with `structure … where`-style fields (Lean, Idris, Agda, Nim) has
  no anonymous record type in a signature; every structural-records language
  (Elm, Roc, PureScript, SML) kept braces. Beni's records are structural and
  appear inline, so a layout form is a second spelling, not a replacement —
  Koka's situation, tied by desugaring, is the only precedent for having both.
- Elm's leading comma is not a principle: Tibell called comma-first a
  workaround for Haskell's missing trailing comma, Evan declined to argue it,
  and elm-format ended the debate by adoption. Feldman proposed newline
  records in 2015 and later, in Roc, made commas load-bearing again — for
  VALUES and for types spanning lines, not for a declaration whose every
  field starts `name :`.
- The beni-shaped candidate is the `let`-binding column: a bare field block
  after `=` needs no new parser state and no new lookahead, and it fixes the
  one place the current form is awkward (a doc comment separated from its
  field by the comma). The cost is two spellings; the mitigation is Koka's
  desugaring. F#'s decade of alignment-by-field-name-length is the warning
  against the alternative of letting a brace set a column.
- S1 is the cheapest moment to change the schema body's spelling — parser,
  formatter, fourteen fixtures — and the moment passes at S2.
