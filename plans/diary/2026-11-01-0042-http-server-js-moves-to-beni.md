## 2026-11-01 00:42 CET — Http/Server.js moves to beni

**What I did.** Step 12 of `plans/runtime-in-beni.md`: the eleven exports and thirteen helpers of
`platforms/node/Http/Server.js` are beni over `Js` in `Server.beni`, and the file is deleted;
`WebSocket.js` stays and takes the upgrade record `Server.beni` makes. Spec first (`boundary.md`
§9.10 *The sibling, moved*, §9.11 item 26 amended). The two `catch`es of `invalid` are
`Js.catchIf` naming Node's `TypeError` codes; the three code-filtering error handlers end in
`Js.throw`. `emit/release/app/HttpServe` pins the shape; the 28 `HttpServer`, 39 `WebSocket`
and 4 `TodoServer` runs print what they printed.

**What I learned.** Four things the golden and a speed probe found, none of which the corpus
could: a beni record stored through `Js.from` keeps its field names in a release build (§4's
pin), so the `Request` is built in `requestOf` from the host's request and the body the record
holds; `List.push` and `String.toLower` per header pair cost 2.8× the sibling's inline loop in
development, so the pairs go onto a host array (a `List` by representation) with `toLowerCase`
by `Js.call`; two helper functions per header cost 1.5× in development (the release optimiser
inlines them, the development build does not), so the two `catchIf`s sit in the loop; and
`process.getBuiltinModule` once per response cost the same 1.5× in both builds, so `http`,
`Buffer` and `ENETRESET` are top-level constants, as the sibling's imports were. After the four
the three loops time at master's figures in both builds. A `--library --release` build renames
its exports (`export{g,h}`), which a probe must pick by behaviour. The reviewer's probe scripts
went with the review clones in the cleanup; `zig-out/scratch/pr13/probe/` is the new one.
