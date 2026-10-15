## 2026-10-12 18:50 CEST — ownership slice 3e: ownership words, and the decoder in `Expect`

**What I did.** Specified (`ownership-checker.md` §24, `boundary.md` §4, `language.md` §3/§5.4/§9/§10) and
built thesis Change 5(a): contextual ownership words in front of a top-level signature's parameters and result,
and `crossing` in front of `foreign type`, in core and platform packages only (`misplaced_ownership_word`
everywhere else — 5(b) refused — and for nested, misplaced or impossible words). Lowering records them per
declaration (`Bir.Decl.own_start/own_end`, artifact format 22) and erases them from the type. The checker takes
a worded declaration's summary from its words; a `foreign` without words now gets the thesis's row (escapes
everything), withdrawing §6.1 item 2's narrowing as §15 decision 6 said. Annotated `Js` (from, to, the
comparisons, array/object, each, throw, ref/read/write, pure/finally/catchIf/suspending, fingerprint), `String`
(join, fromList, split, words, lines, toList, indexes), `Debug.log`/`toString`, `Schema.parse`/`print` (+With),
`Hosted.keyOf`, `Html.Event`, `Node`'s three and `Ssr.render`; `trusted-surface.txt` lists each with the fixture
that pins it and `check_test.zig` enforces the list. Followed the `Http.Expect` decoder: function slots (a
function stored at a path of a parameter) and carried lambdas (a lambda a call returns keeps its class).
Research 81 measures it.

**What I learned.** Most of the rejections Change 5 was expected to clear were really about two words:
`Html.Event` crossing (TodoMVC's `payload` lines were the event, not the view) and `String.join` reading.
Following the decoder works, but Conduit's HTTP lines do not move: the decoders forward the request's
`Problem`, and the failing `Response` comes back through `Task.callback` as `⊤`. A two-constructor failure in
`Http.wait` clears all 21 — measured, not built, left to the owner (rule 10). `Js.throw`'s result is honestly
`fresh` (it never returns), which removed a `⊤` from every `Debug.todo` arm. `Schema.print` is `aliased`, not
`borrowed`: an `Issue` keeps its input. Reading the sibling and the body before every word caught both.
