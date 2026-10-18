## 2026-10-17 21:53 CEST — Spec: the `node` platform serves HTTP

**What I did**

- Read issue #331, `boundary.md` §4 and §9, `transparent-effects-proposal.md` §16–§17,
  `platforms/node/Io.beni` and `Io.js`, `core/Task.beni` and `tests/corpus/README.md`.
- Probed Node 24.19 for every failure of `node:http`'s server that the first slice meets:
  `listen` (`EADDRINUSE`, `EACCES`, `EADDRNOTAVAIL`, `ENOTFOUND`, the synchronous
  `ERR_SOCKET_BAD_PORT`), the body read (`ECONNRESET` when the client cuts the body), the
  response (`ERR_HTTP_INVALID_STATUS_CODE`, `ERR_INVALID_HTTP_TOKEN`, `ERR_INVALID_CHAR`), a
  malformed request (`clientError`, Node answers 400 by itself).
- Wrote `boundary.md` §9.10: the `Http.Server` API, the lifetime of a server (the fiber that
  called `listen` owns it), what a cancelled fiber does to its sockets, every failure and the
  typed error it becomes, and how `tests/corpus/serve/` drives a server with the port never in
  the transcript.
- Posted decisions 1 and 2 of #331 to the dashboard (`node-http-q1`, `node-http-q2`).

**What I learned**

- After `server.close()`, Node 24 keeps a keep-alive connection that is busy at that moment
  open, and it serves more requests on it. A graceful close must send `connection: close` on
  every response written after `close`.
- A `content-length` under the body's length hangs the client; one over it breaks the client's
  parser (`HPE_INVALID_CONSTANT`). Node 24 throws for neither. The platform must own that header.
- A write after the client left is dropped by Node with no throw. A body cut by the client
  rejects the body read with `ECONNRESET` (`aborted`), and unhandled, that crashes the process.
- In zsh, `echo ====` fails: a word that starts with `=` is a command lookup. Quote it.
