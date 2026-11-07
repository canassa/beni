## 2026-10-23 23:23 CEST — the node platform's thin wrappers move to beni

**What I did.** Started #877, the platforms' hand-written JavaScript in beni. Read the two plans
(`core-in-beni.md`, `runtime-in-beni.md`) and `boundary.md` §4, §4.2, §5.2, §9.2 and §9.3, and
planned eleven pull requests in order: the thin wrappers first, then the middle files, then the two
servers. Opened #882 (`Js.lt`, `gt`, `le`, `ge`, which the owner decided on 2026-10-02 for
`Hosted.js`'s keys), #883 (a `via` extractor may be a beni declaration: today `check/Vocab.zig`
and `Reach.privateExtractor` both require a `foreign`, which keeps `Html.js` hand-written) and
#886 (`docs/design/backend.md` is double-encoded on master since `540e16e03`). Wrote the two
specs as dated amendments on their branches. Moved `Ssr.render` and `Node.print`, `printLines`
and `exitWith` to beni over `Js`; `Ssr.js` and `Node.js` are gone. Measured against master's
compiler with `bench/size.mjs`: release brotli −10 888 over 587 programs, 558 smaller, 20 larger
by 1–30 B at fewer raw bytes; asked the owner whether the 20 meet R47-3 (`runtime-in-beni-q1`).

**What I learned.**
- A `Js.object` key is a plain property, so every beni record field of the same text keeps its
  source name in every release build: the keys `code` and `out` pinned `Schema`'s `Issue.code`
  in every schema program. The `Program` keys are `$c` and `$o`, which no beni identifier can be.
- A private helper called from one live function is not written in place when its other callers
  are dead: the object literal is written in each function, as the sibling did.
- `++` on two strings is `Basics$append` in a development build and `+` in place under
  `--release` when one operand is a string literal (`Lower`'s string rule).
- Only a keyed root module adds its `Js.from`/`Js.to` types to the release optimiser's wild set;
  core and a platform add their crossing quantifiers alone (`TypeKeys.zig`). `String` and
  `List String` were wild in a plain `node` program only because a live `foreign` named them.
- The development goldens import `Node$printLines` from the module's own file whether the value
  is `foreign` or beni, so none of the 44 moved; the 57 hoisted release goldens did.
- `word-bodies.txt`'s hash is reproducible with twenty lines of Python, so a pin can be written
  before the test runs.
- `node`'s `runtime.js` and `markup.js` can go together through the runtime-module mechanism
  `browser` already uses; the two servers use no JavaScript form beni over `Js` cannot write, and
  their host modules reach beni as `process.getBuiltinModule("node:http")`. `escape`'s `g` regular
  expression is the one `Js.regExp` gap, and `cloudflare/runtime.js`'s prototype methods with
  parameters the one `Js.method` gap.
- The machine's heavy lock became a two-slot semaphore (`heavy-run`) and the machine rebooted
  during the session; a reviewer session with no task did a worker's steps in the shared worktree
  (none landed). `run/HttpServerBadClients` (#515, #701) flakes under load in the gates; recording
  the run hashes first lets the gates skip Node for it.
