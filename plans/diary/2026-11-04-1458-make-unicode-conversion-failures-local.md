## 2026-11-04 14:58 CET — Make Unicode conversion failures local to a file

**What I did**

Handled lexical and parse failures in intermediate and converted formatter text as per-file rewrite diagnostics. Added a black-box regression with a commented unit followed by a tuple selector, proving that the failed file stays unchanged and a subsequent file still converts. Removed the unreachable star diagnostic, documented retired append-only codes, narrowed the negative-comparison hint to number literals, and reverted the sample ASCII-byte conversion while keeping ASCII notation.

**What I learned**

Normalizing layout before conversion does not eliminate every failure: deleting the closing parenthesis after a line comment can leave a tuple selector at the start of a line. The old command escaped with SyntaxErrors. The formatter must treat every failed rewrite as a local diagnostic and keep processing other files.
