## 2026-10-15 20:21 CEST — A Chrome golden for Sternhalma's rounded lengths

**What I did**

- Found the cause of the red `zig build test-browser` (issue #157). It is
  not a colour. Sternhalma writes each cell's `left` with
  `String.fromFloat x ++ "px"`, for example `275.75128869403574px`. The
  two DOMs round that number in different ways when they write the
  `style` attribute again:
  - happy-dom 20.14.5 writes `275.751289px`: at most six decimals, as
    CSSOM's rule for a `<number>` says.
  - Chromium 153 writes `275.751px`: six significant digits. A large
    number gets an exponent (`1234567.5px` is `1.23457e+06px`).
- Proved it with one probe page per DOM (the same seven values) and with
  the two goldens: they are equal after a round to six significant
  digits, and 1 456 of 4 989 lines differ.
- Blessed `browser/direct/Sternhalma/_expected.chrome-expected` and added
  the difference to `tests/corpus/README.md`'s known DOM differences.
- Chrome suite: before, 572 cases and 1 failure (Sternhalma). After, all
  17 corpus parts pass, on the branch rebased onto master `f1ab9cc87`.

**What I learned**

- The CSS-values bullet said that happy-dom keeps a value "as the page
  wrote it". That is true for a colour only. happy-dom rounds numbers
  too (`468.0px` is `468px`).
- A seeded `.zig-cache` without `tmp/` stops every `zig build` at
  configure with `FileNotFound`. Make the directory before the first
  build.
