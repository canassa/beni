## 2026-10-26 20:02 CET — the browser keys move to beni

**What I did.** `Hosted.js`'s last two exports, `keyOf` and `compareKeys`, are beni over `Js`
(#877), the first piece over `Js.lt` (#882, #1110): `key` builds `{ t, c, v }` with `Js.object`, the
type's `compare` carried as a lambda over the `where` clause; `compare` orders two identities with
`Js.lt` under `Js.pure`, and calls the stored `compare` with `Js.apply` for two keys of one type.
The `Hosted.keyOf` pin rows are withdrawn (`key`'s row is inferred), five documents carry dated
amendments. Sizes against #1110's compiler: the 218 `tea/` pages −1 248 B brotli (52 smaller, 165 equal, `LogCommandContext` +32 at −20 raw), the 78 other pages and the 642 node lines byte for byte, `size.mjs`'s 19 pages and apps −363 (TodoMVC 9 007 → 8 993, bike-wars −89).

The first gates run was red on three goldens the move changes: `emit/release/tea/HttpSendTracked`
(the key built in place, `Http.Key`'s `Track` box gone) and the `browser-tea` ownership reports of
`Conduit` and `WordsBrowser` (fresh values renumbered by one, no verdict changed). Blessed, and
`backend.md` §9's sentence on the key type amended.

**What I learned.**
- A sibling that goes takes its types out of the boundary set: `keyOf`'s `where k.compare` kept
  every key type boxed with string tags, and `Js.from` at a quantifier does not (`backend.md` §9,
  *What JavaScript sees keeps its shape*). So a page's release golden can change where no byte of
  the page's own code does, and an ownership report that counts fresh values through a key
  renumbers. Bless the pages' goldens with the move, before the gates.
- A platform module cannot be checked alone (`beni check --root=platforms/browser …` finds no
  `Browser`): the platform is embedded, so the compiler's build is the first check of an edit.
- A method named as a value is `λa b → a.compare b`, and the release optimiser does not eta-reduce
  it: the key carries `(b,c)=>a(b,c)` where the sibling carried `a`. Issue #1111; the bytes still fall
  because the sibling file and its import glue go.
- A fixture whose last flipped row moves to beni leaves the flips test with nothing to flip; the test
  asserts `count != 0`, so it must be retired with the reason, not weakened. The `-` rows still pin the
  fixture through the list's own checks.
