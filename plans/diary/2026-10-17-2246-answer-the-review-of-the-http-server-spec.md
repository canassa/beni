## 2026-10-17 22:46 CEST — Answer the review of the HTTP server spec

**What I did**

- PR #333's review found five gaps in `boundary.md` §9.10 (d) and (e). I probed each on Node
  24.19 and amended the section: three more `listen` codes (`EAFNOSUPPORT`, `EAI_FAIL`,
  `EMFILE`/`ENFILE` → `TooManyOpenFiles`), the server's `error` after it listens (a
  defect), where a failed write surfaces (`clientError`, never `res`), the statuses that carry
  no body (204 and 304 take an empty body and no `content-length`; 1xx is invalid), and
  validation before any header is set. The fault-injecting `{"fault": …}` step is in (h).
- Built the first slice on `feat/node-http-server` (local until the owner answers q1–q3 and
  #333 merges): `Http.Server`, the driver and preload, eight fixtures, gates green.
- Opened #335–#340 for what §9.10 (j) leaves out.

**What I learned**

- Node drops the body for 101, 204 and 304 and keeps a `content-length` the server set; a final
  `100` resets the connection.
- A client that leaves while a 64 MiB response is written is the socket's `ECONNRESET`, routed to
  `clientError`; `res` emits no `error`.
- `cache_test` assumed exactly one `node` module is not imported by its program; a second
  module in the platform broke it. The count now follows the platform's files.
