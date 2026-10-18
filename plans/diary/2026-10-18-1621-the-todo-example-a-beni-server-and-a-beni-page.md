## 2026-10-18 16:21 CEST — The todo example: a beni server and a beni page

**What I did.** Built `examples/todo` for issue #356: a `node` server (`Http.Server`, a JSON
API over a `Ref`, the page's files served as text with their `content-type`) and a
`browser-tea` TodoMVC page over `Http.request`, with one shared module `shared/Todos.beni`
that both manifests reach through `"paths": [..., "../shared"]`. Tests: `run/TodoServer`
(the API through a `.requests` script, a `Config` of its own on port 0),
`browser/direct/TodoPage` (the page on both browser platforms, its requests answered by the
script), and `tests/blackbox/todo_example_test.zig` (both programs built from their
manifests, the server serving the built page). The corpus harness now takes several
directories in `_expected.sources`, one per line. Issues opened: #357 (arguments and
environment on `node`), #358 (no line on standard output while a `node` program runs),
#359 (one source directory per project; fixed here), #360 (no kind drives a page against a
live server; debt), #361 (the page case's budget grant, 8 900M for 8 091M measured).

**What I learned.**
- The three expected walls were one real wall and two conveniences. A module is shared by
  listing its directory in both manifests: module names come from the path relative to each
  directory argument. The port cannot come from the command line, so it is a module the user
  edits, and the test gives its own. The page's files are all text, so `Io.readFile` and a
  header serve them; only bytes (#335) are missing.
- A fourth wall nobody listed: a `node` program cannot print a line while it runs. Its
  standard output is the `Program` it ends with, `Js` is closed to it, and core's `Log` of
  `boundary.md` §9.8.15 (b) is not built. The server prints "stopped" and nothing before.
- On `browser-direct` the ownership checker refuses `Http.send` whenever the tagger's payload
  can hold a list, and `Http.Error` holds lists (`BadBody`, `UnprintableBody`), so every
  `Http.send` with the standard error type is refused there. `Cmd.task` over `Http.request`
  passes when the `Expect` is built inside the command's lambda; a top-level `Expect` value
  is not followed (`ownership-checker.md` §24.9). The idiom costs nothing on `browser-tea`.
- `World.copyTree(dir, "")` copies nothing: an empty skip prefix matches every file name.
- An application page under `browser/direct/` costs four builds and two Node runs; a
  TodoMVC page over `Http` and two schemas is 8 091M, so every such page needs a grant.
- The dispatch machine's heavy lock queues builds behind other agents for tens of minutes:
  write everything that needs no binary first, then build once.
