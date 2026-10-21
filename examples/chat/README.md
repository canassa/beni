# A chat room: a beni server and a beni page over a WebSocket

This example is a chat room written in beni on both sides, with no
JavaScript of its own. The server runs on the `node` platform. The page runs
on the `browser-tea` platform. They talk over one WebSocket per page
(`docs/design/boundary.md` §9.11).

## What it shows

- `Http.Server.listenWith` on `node`: the page's built files, and a WebSocket
  at `/chat` for each page, with `Server.accept` and a session that reads with
  `WebSocket.read`.
- A check of `origin`: the server refuses a socket that a page of another site
  opens (RFC 6455 §10.2).
- `WebSocket.listen` on `browser-tea`: the page's socket is a subscription,
  `update` keeps it in the model, and `WebSocket.send` is a command. When the
  connection ends, the page waits and connects again.
- One module, `shared/Chat.beni`, for the protocol. It uses only the WebSocket
  operations that both platforms share (`write` and `Close`), so both programs
  import it.

## Layout

| Path | Is |
|---|---|
| `shared/Chat.beni` | the events, their lines, and `tell`, which writes an event to a socket |
| `server/` | the `node` program: `beni.json`, `src/`, and `config/Config.beni` |
| `page/` | the `browser-tea` program: `beni.json`, `src/`, and the page shell `index.html` |

## Build and run

Build the page, then the server. Each `beni.json` names the platform, the
source paths and the output directory, so `beni build` takes no arguments.

```sh
cd examples/chat/page
beni build

cd ../server
beni build
node out/_main.mjs
```

Open http://127.0.0.1:8080/ in two browser tabs, and type in one of them.

To stop the server, send `POST /api/shutdown`:

```sh
curl -X POST http://127.0.0.1:8080/api/shutdown
```

Every page's socket is closed with 1001, and the server prints one line.

## The test

`tests/blackbox/chat_example_test.zig` builds both programs as above, with a
`Config` that listens on port 0, and runs the server under
`tests/serve/driver.mjs`. The script opens a WebSocket of its own, runs the
page under the page driver against the server, and checks what each side hears.
