## 2026-10-20 22:42 CEST — Amend the WebSocket specification after its reviews

**What I did**

- Wrote a dated amendment to `boundary.md` §9.11 that settles each finding of the two reviews of
  #531: the review agent's H1–H4, M1–M10 and L1–L13, and the bot's 19 points. No section is
  renumbered.
- Split the shared surface into the handle operations (shared) and the reading style (per
  platform), took `buffered` and `drain` out of the shared part, and gave each side its own set
  of close codes.
- Fixed two server rules that would build a hang or a crash: `drain` waits for the last write's
  callback, and a client's network failure ends its connection, not the process.
- Added the `Origin` check to the example, a row for `WebSocket.Socket` in
  `static-dispatch-spike.md` §3.5, a note on W52, and an issue for each item of (o).

**What I learned**

- The standard and the browsers differ for a WebSocket: WebKit fires `error` with no `close`,
  Chrome throws a `SecurityError` that the standard removed in 2016, and Firefox throws for a CSP
  refusal under a name nobody verified.
- Node emits `drain` only after a `write()` that returned `false`; a small write followed by a
  wait for `drain` waits forever.
- A hibernating Durable Object cannot keep a fiber waiting in `read`, so a server's reading style
  is a question for the owner, not a detail.
