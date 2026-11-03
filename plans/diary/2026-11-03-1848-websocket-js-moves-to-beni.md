## 2026-11-03 18:48 CET — WebSocket.js moves to beni

**What I did.** Step 13 of `plans/runtime-in-beni.md`: the eight exports and twenty helpers of
`platforms/node/WebSocket.js` written in beni over `Js` in `WebSocket.beni`, the file deleted
(#877, the last of the two servers). Spec first (`boundary.md` §9.11 *The sibling, moved*, item 26
amended again, row 13 and step 13), then the code, then two spec corrections the code forced.
`Socket` stays a `foreign type` with its state in a `Js.object`; the frame header is written by
`Js.setAt`, the unmask loop is a tail-recursive function over `Js.at`, `Js.setAt` and `Js.bitXor`
and prints as the sibling's `for`; the socket's `error` listener ends in `Js.throw`. Every
`run/WebSocket*` and `run/HttpServer*` fixture prints what it printed in both builds; a new
`emit/release/app/WebSocketEcho` golden pins the shape. Release brotli: all ten WebSocket programs
smaller (−41 to −97), the chat server −110, the bench server −34, nothing larger. Speed by §9.11
(m)'s arena load (`bench/websocket/load.mjs`, 100 players, `perf stat` on the server).

**What I learned.**

- **One text, one spelling.** A record field keeps its source name in a release build when the
  same text is used anywhere as a plain property (`boundary.md` §4, amended 2026-10-22). `isGone`
  reads the host's `error.code`, so `Close.code` stays `code` in every serving program; the spec's
  first claim that `Close` gets short names was wrong and is corrected.
- **A `Js.to` at a type that names a beni type pins that type.** `Js.to reader` typed
  `Resume (Result Close String)` kept `Result`'s string tags (`"Ok"` eleven times in the golden).
  `Task.resume`'s own `Js.from value` at a type variable does not pin.
- **Work after `Task.callback` costs a continuation per call.** `read` as "callback, then build
  the `Result`" put a then-combinator and a closure on every read, on top of the session loop's
  own: +3.9 % instructions per message on the arena load, reproducible on a quiet machine (five
  runs, no overlap). The fix is a host closure per waiting reader, `Js.from` of a lambda typed
  `Js.Value → ⊤` that holds the typed `Resume` and builds the `Result`; `read` is one
  `Task.callback` again. After it the medians differ by 1.3 % with overlapping ranges.
- **The load probe needs a quiet machine.** At a load of 4 master's own runs spread 10 %; at 0.9
  they spread 1 %. Instructions per message is the steadier figure; CPU time per message overlaps
  in every run.
- **A project with a `beni.json` resolves `--out` against its own directory**, so a relative
  `--out` from the worktree root writes a tree into the project; build from the project
  directory with an absolute path, as `bench/size.mjs` does.
