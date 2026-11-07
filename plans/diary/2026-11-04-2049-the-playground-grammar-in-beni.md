## 2026-11-04 20:49 CET — The playground grammar in beni

**What I did**

Step 2 of `playground.md` §10.7 (#142): `playground/syntax.js` became `playground/src/Syntax.beni`, with the rules of CodeMirror's Elm mode translated into it. `zig build playground` now builds `playground/src/` as a development `--library` into the site's `beni/`, and `editor.js` runs the grammar through a short `StreamLanguage` adapter until the beni editor replaces CodeMirror. The page test builds `playground/src/` with the compiler under test. The pull request is stacked on #1897. Before this I wrote `srcdoc.js` in beni too, but the owner's `q6` (the frame loads from a URL) makes `srcdoc.js` go with `frame.js`, so I kept only its build plumbing and did not push it.

**What I learned**

- A grammar that reads a whole line and gives every piece of it is easy to compare. Against `syntax.js` with the Elm mode it gave the same named pieces on all 4 428 `.beni` files of the repository and on 30 000 random lines.
- Most of the Elm mode cannot be reached from beni: beni's rules take strings, comments, `{` and every keyword first. What is left is names, types, numbers, character literals, operators, brackets and `[glsl|`.
- The vendored Elm mode file must stay until `vendor/` goes, because its MIT notice covers the translation.
- The development library build costs bytes: the page loads 6 243 bytes at brotli quality 11 for the grammar, against 3 841 for the JavaScript. A release library would be 3 543, but it renames its exports (#1901).
- The test servers had no type for `.mjs`. A module script of type `application/octet-stream` does not load, so the page's first beni module needed a line in both servers.
- The Chrome load and compile times are still owed: the machine's load stayed at 6 to 16 this evening.
