## 2026-10-26 19:37 CET — the Js comparison intrinsics

**What I did.** #882, the four comparison intrinsics `Js.lt`, `gt`, `le` and `ge`: `foreign pure`
declarations in `core/Js.beni` over one type variable, written in place as `<`, `>`, `<=` and `>=`
by `js/Lower.zig`'s intrinsic arm, the sibling's functions in `core/Js.js` for a value use.
Fixtures: `run/JsOperators` (`compared`, `comparedViaValues`), `emit/release/core/JsCompare` (the
shape), `ownership/core/JsWords` and the two pin files. The spec was in place since 2026-10-23
(`boundary.md` §4.2, `backend.md` §4). They are what `Hosted.js`'s key order needs to move to beni
(#877) without shipping `String.compare` to every page.

**What I learned.**
- A new `Js` intrinsic costs one enum member, one `Lower` arm, one declaration and one export: the
  checker and the resolver find it by name (`std.meta.stringToEnum`), and `inPlaceLiterals` has an
  `else`. The pins (`trusted-surface.txt`, `word-bodies.txt`) are the part that is easy to forget.
