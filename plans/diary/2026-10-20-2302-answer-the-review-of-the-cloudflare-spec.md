## 2026-10-20 23:02 CEST — answer the review of the cloudflare spec

**What I did**

- Rebased `cloudflare-spec` onto master after #531 merged, so §9.12 follows §9.11 in one file.
- Answered the review of PR #533 (`cf-workers-review`, H1–H6, M1–M12, L1–L7) with dated amendments in §9.12: the host types all live in `Worker`, so the modules form no cycle; the platform answers a peer's close frame itself; the defect guard is one catch that logs and aborts, with a fixed prefix the Worker's `forward` throws again; a `Response` is validated in beni; the ownership row is proposed and asked; a defect in a Worker fiber would stop core for the isolate; the output gate, `Full`, the host's byte count, `TooManySockets`, the body read's ordering, the entry file's `$`-bindings and `export { … as Name }`, the test driver over Miniflare with a test-only time binding, no fibers from a handler, the host's close mapping, the namespace test, the `migrations` form for the pinned Wrangler.
- Wrote corrected versions of the four owner questions beside the dispatch files, not posted, and posted two new ones: the ownership row and the test-time binding.
- I had edited the committed diary entry of 21:51 in `3f257cf55`; the log is append-only, so this entry says so and that entry stays as it is.

**What I learned**

- `ctx.abort` terminates the running JavaScript and never returns: an error thrown before it is lost. A guard that must name the defect has to catch it first.
- The hibernation read loop sends no reply to a peer's close frame; the auto-reply flag acts only on sockets accepted with the standard API.
- V8 serialises a string with any code unit above U+00FF as two bytes per unit: a UTF-8 byte count passes values the host refuses.
- A Durable Object's `fetch` that awaits a request body lets other events run: a body is non-storage I/O.
- One Miniflare start costs 1 933M instructions, 45% of a case's budget.
