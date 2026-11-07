## 2026-10-31 03:44 CET — Token dump columns are linear in the line length

**What I did**
- Issue #1365: `dump --stage=tokens` took 579 ms on a 640-term single line. The cause was `diagnostic.column` in `src/dump/tokens.zig`, called per token, which counts code points from the line start. One line of n tokens costs O(n^2) bytes.
- Added `diagnostic.ColumnCursor`, which continues from the previous token on the same line (the parser's `codePointColumns` already did this), and used it in the token dump. Columns are unchanged.
- Debug build, 640 terms: tokens 622 ms before, 57 ms after (160: 115 to 81 ms, 320: 52 ms).
- Tests in `src/diagnostic.zig`: columns equal `column()` on a line of multi-byte code points, and bytes scanned grow linearly (3996 at 1000 tokens, 15996 at 4000).

**What I learned**
- The `types` cost on long lines is not the lexer: its profile is in `solve` and `ownership`. It needs its own issue.
