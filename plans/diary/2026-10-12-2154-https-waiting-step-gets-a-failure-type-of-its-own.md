## 2026-10-12 21:54 CEST — Http's waiting step gets a failure type of its own

**What I did.** Took the owner's decision on `ownership-checker.md` §24.11 item 1: `Http`'s private `Step`
carries `Failed Failure` (`TimedOut | Unreachable`) instead of `Failed (Response String)`, turned back into
`Timeout_` / `NetworkError_` where the answer is read. Amended `boundary.md` §9.8.12 (c) and answered §24.11
item 1 with the measurement. New fixture `ownership/HttpAnswerEdited` (Conduit's shape, the answer pushed onto
in `update`): accepted, where the base binary rejected its send `need`. Run hashes re-recorded. Release sizes
of the Http, Api and Conduit pages: +24 raw bytes, −35 to +19 brotli. PR #76 was closed by GitHub when #73's
branch was deleted, so the rebased work is PR #77.

**What I learned.** Conduit goes from 26 rejections to 5, all `payload` (O6), on both TEA platforms; in the
corpus `ApiLogin`, `HttpMultipart`, `HttpCancel` and `HttpProgress` move, nothing else. The decoder is
followed only when the parser is a parameter of the function that sends, as in Conduit's `Api.send`: a
decoder built inside the work's own lambda (`HttpAnswer`, `ApiItems`) stays `need`, a §24.9 limit and not
the failure type. A PR stacked on another branch is closed, unreopenably, when that branch is merged and
deleted — retarget it to master before the base merges.
