## 2026-10-22 16:42 CEST — make the pointer extractor private

**What I did**

- Removed `pub` from `Html.pointer`, the extractor of the six pointer
  events (#696). It was `pub` only because the lowering found an extractor
  among the `pub` values of the vocabulary module. #639 fixed that (#532).
- Amended `boundary.md` §9.8.20 (d), its fixture note and its *As built*
  note, with the date. Ran `zig build skill-api`: `api-html.md` does not
  list `pointer` now. The skill's bullet about `Html.pointer` now says that
  the extractor is private to `Html`.
- Blessed `check/bad/markup/PointerExtractor` and `PointerExtractorType`
  again. A call to `Html.pointer` now gets `private_name`, not a type
  mismatch, and the intent comments say so.

**What I learned**

- The pointer pages now take the path of a private `via` under all three
  lowerings that have them: `dom`, `browser-tea` over it, and
  `browser-inline` (`browser/inline/PointerPoint`). Before this change, no
  fixture built a private `via` under `browser-inline`.
- A change to the comment at the top of a `check/bad` fixture moves the
  lines of its diagnostics. Bless the fixture after the last edit of its
  source, not before.
