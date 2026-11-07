## 2026-10-29 20:48 CET — a correction to the Dom.js entry: Result gets the tags

**What I did.** The entry of 2026-10-29 19:02 (*Dom.js moves to beni*) says in its lesson that
"`NotFound` gets its integer tag". That is wrong, as the review of #1208 found: it is `Result`
that gets the integer tags once no `foreign` annotation names it, and `NotFound id`, a type of one
constructor with one field, is written as its field, the id string. Master's release wrote
`{$:"Err",a:{$:"NotFound",a:b}}`; the head writes `{$:1,a:a}`, `1` being `Err`'s tag. The same
entry says the records keep their names; they keep them only where `Dom.box` is live, since a
field the build also writes as a plain property is never renamed and nothing else pins them.

**What I learned.** Read a release shape off the golden against master's, constructor by
constructor: the tag that goes is the outer type's, and a one-constructor, one-field type has no
tag at all to lose.
