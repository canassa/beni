# A todo app: a beni server and a beni page

This example is a web application written in beni on both sides. The server
runs on the `node` platform. The page runs on the `browser-tea` platform. One
module, `shared/Todos.beni`, holds the shape of a todo. Both programs import it,
so the JSON the server prints is the JSON the page parses.

## What it shows

- `Http.Server` on `node`: a JSON API under `/api/`, and the page's built files
  everywhere else, each with its `content-type`.
- `Http.request` on `browser-tea`, in a `Cmd.task`: a TodoMVC page whose every
  change is a request, with the server's answer in the page.
- A `schema` declaration shared by two platforms through each manifest's
  `"paths"`.

## Layout

| Path | Is |
|---|---|
| `shared/Todos.beni` | the `Todo` and `Draft` schemas, and the list the API answers |
| `server/` | the `node` program: `beni.json`, `src/`, and `config/Config.beni` |
| `page/` | the `browser-tea` program: `beni.json`, `src/`, and the page shell `index.html` |

## Build and run

Build the page, then the server. Each `beni.json` names the platform, the
source paths and the output directory, so `beni build` takes no arguments.

```sh
cd examples/todo/page
beni build

cd ../server
beni build
node out/_main.mjs
```

Open http://127.0.0.1:8080/ in a browser.

The server prints nothing while it runs. It prints one line when it stops. To
stop it, send `POST /api/shutdown`, or press Ctrl-C:

```sh
curl -X POST http://127.0.0.1:8080/api/shutdown
```

To change the port or the address, edit `server/config/Config.beni` and build
the server again. A `node` program cannot read command-line arguments or
environment variables yet (canassa/beni#357).

The server reads the page's files from `../page/out`, relative to the directory
it runs in. Run it from `examples/todo/server`, or change `pageDir` in
`Config.beni`.

## The API

| Request | Answer |
|---|---|
| `GET /api/todos` | 200, the list of todos as JSON |
| `POST /api/todos` with `{"title": "…", "done": false}` | 201, the new todo with its id |
| `PUT /api/todos/<id>` with `{"title": "…", "done": true}` | 200, the changed todo; 404 when the id is unknown |
| `DELETE /api/todos/<id>` | 204; 404 when the id is unknown |
| `POST /api/shutdown` | 200, then the server stops |

A body that is not a todo is 400, with the schema's issues in the body. A wrong
method on a known path is 405 with an `allow` header.

## What it does not do

- **No database.** The todos live in memory, in a `Ref`. A restart loses them.
- **No binary files.** The server reads files as text (`Io.readFile`) and serves
  `.html`, `.mjs`, `.js`, `.map`, `.json`, `.css`, `.svg` and `.txt`. An image
  or a font is 404 until the server has bodies as bytes (canassa/beni#335).
- **No line while it runs.** A `node` program writes standard output only
  through the `Program` it ends with (canassa/beni#358).
- **No signal handling.** Ctrl-C kills the process with its connections open.
  `POST /api/shutdown` is the clean stop until `node` has signals
  (canassa/beni#338).
- **No command-line arguments.** The port is in `Config.beni` (canassa/beni#357).

## Tests

- `tests/corpus/run/TodoServer/` builds the server with a `Config` that listens
  on port 0 and drives the API with `_expected.requests`.
- `tests/corpus/browser/direct/TodoPage/` builds the page and drives it in a
  DOM with `_expected.steps`; the script answers each request with the JSON the
  server prints.
- `tests/blackbox/todo_example_test.zig` builds both programs from their
  manifests and checks that the server serves the page's files.

## Licences

The page shell's stylesheet is `todomvc-app-css` 2.4.3, by Sindre Sorhus,
under CC-BY-4.0: `page/licenses/todomvc-app-css.txt`.
