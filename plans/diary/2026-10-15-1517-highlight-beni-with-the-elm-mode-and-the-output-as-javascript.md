## 2026-10-15 15:17 CEST — highlight beni with the Elm mode and the output as JavaScript

**What I did**

Jayson asked for an Elm grammar on beni files and a JavaScript grammar on
the emitted modules, naming Prism.js "if there is better use it". The editor
is CodeMirror, so I used CodeMirror's own: the Elm mode of
`@codemirror/legacy-modes` for beni, through `StreamLanguage`, and
`@codemirror/lang-javascript` in a read-only view for the JavaScript tab. One
library, one highlight style, no second highlighter. #136 was merged, so the
change is on #139.

`syntax.js` now hands Elm everything Elm reads as beni does (names, a name at
column 0 as a definition, types, numbers, characters, ASCII operators,
brackets) and keeps beni's rules in front for the rest: `${…}` strings, `\\`
lines, comments, the Unicode notation, `⊤ ⊥ λ`, beni's keyword set, and
markup. The four new modules are vendored with their checksums and licences.
Screenshots of a sample with every beni token, and of the JavaScript tab, are
in the coordinator's directory.

**What I learned**

- The Elm mode is 4.3 KB with no imports and returns `error` for any
  character it does not know, so `→` would have shown as an error without
  beni's rules in front of it.
- The Elm mode calls an operator a keyword and a bracket a builtin; a thin
  wrapper renames them, and its state rides inside beni's own.
- Elm's mode starts a `{-` block comment, which beni does not have, so a `{`
  must be taken before Elm sees it.
