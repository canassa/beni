## 2026-10-15 10:16 CEST — fix the adversarial review of the release maps

**What I did**

Fixed the review of PR #117. A branch that specialisation decides now
takes the position of the operand it keeps (`Spec.foldTo`), so a crash
in the kept call names its own line and not the test's. Every release
map ends its last line with `;` when its last segment has fewer than
five fields. The hoisted map drops a module that records no mark. The
test checker now reads each spot with Node's `node:module` `SourceMap`
too. The hoisted test pins a `for` head, a new test pins the decided
branch, and the library test pins its last segment. §11.2 has item 6,
instruction counts (+2.1% to +3.5%), and the help line says that a map
embeds the source. I posted the owner question on a map without source
text (`release-maps-q1`).

**What I learned**

Node's map reader ends a segment only at a `,` or a `;`. At the end of
the string it reads the missing fields as zero deltas, so a final
four-field segment takes the previous name. That holds for development
maps too: all 40 of conduit's end that way. A sweep of every segment
with Node's reader found it in 1 551 library segments that my own
decoder read correctly. A position test needs a second reader.
