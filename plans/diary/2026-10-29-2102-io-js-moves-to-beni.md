## 2026-10-29 21:02 CET — node's Io.js moves to beni

**What I did.** Step 10 of `plans/runtime-in-beni.md`, PR 9 of #877: `Io.beni`'s two `foreign`s
have bodies. `finish` reads the fiber's `Exit` and the host `Program`'s `out` and `code` by
`Js.get` (`Program` stays `Node`'s `foreign type`); `startRead` makes an `AbortController`, asks
`process.getBuiltinModule` for `node:fs/promises` at each call, and hands `then` two lambdas, the
rejection handler naming the canceller's `AbortError` and the twelve `code`s of `FileError` and
throwing everything else again. `Io.js` is gone. Spec first: the plan's row 10 and *Step 10*,
`core-in-beni.md` step 4, `boundary.md` §9.8.15's as-built note (the built-in door), the
proposal's `readFile` amendment. `emit/release/app/IoReadFile` pins the release shape; the three
`run/` fixtures (`SuspendReadFile`, `ReadFileErrors`, `ReadFileDefect`) already run the
success, the code table through real failures, and an `EIO` rejection that must crash.

**What I learned.** A beni platform module reaches a Node built-in without a new intrinsic:
`process.getBuiltinModule` is sync and returns the live module object, which is also why it is
asked at each call — `ReadFileDefect`'s fault platform replaces `fs.readFile` after the program
starts, and a module read once at load would not see it, where the sibling's ESM binding did
through `syncBuiltinESMExports`. And rule 9 in a promise's rejection handler is a `Js.throw` with
nothing around it: the throw is a rejection nothing handles, and Node's exit 1 is the crash.
