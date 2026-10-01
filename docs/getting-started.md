# Getting started

This page takes you from nothing to a counter running in your browser that reloads when you save.
It takes about five minutes, most of it compiling the compiler.

## 1. Install beni

beni is built from source for now. Its toolchain — Zig 0.16 and Node 24 — is pinned by the
repository's `flake.nix`, so the only thing you need installed is [Nix](https://nixos.org/download)
with flakes enabled.

```sh
git clone https://github.com/canassa/beni
cd beni
nix develop                                 # or: direnv allow
zig build -Doptimize=ReleaseFast            # writes zig-out/bin/beni
export PATH="$PWD/zig-out/bin:$PATH"
beni version
```

The compiler is one binary with the core library and the platforms inside it; copy
`zig-out/bin/beni` anywhere on your `PATH` and the clone is no longer needed.

## 2. Make a project

```sh
beni new counter
cd counter
```

`beni new` writes three files:

| File | What it is |
|---|---|
| `beni.json` | the project file: its `"build"` key says which platform the program is for (`browser-tea`, The Elm Architecture in a page), where the sources are (`src`) and where the output goes (`out`) |
| `src/Main.beni` | the program: a model (an `Int`), messages, `update`, and a `view` written as markup |
| `.gitignore` | the two directories a build makes: `out/` and `.beni-cache/` |

`beni new --platform=node hello` makes a command-line program instead; build it with `beni build`
and run it with `node out/_main.mjs`.

## 3. Serve it

```sh
beni serve
```

```
beni: serving out/ at http://127.0.0.1:8000/
beni: built in 74 ms
```

Open <http://127.0.0.1:8000/>. The page is `out/index.html`, which the platform supplies: a plain
HTML page whose one `<script type="module">` loads the program. `beni serve` builds the project,
serves `out/`, and keeps watching `src/`.

## 4. Edit, and watch it reload

Change the heading in `src/Main.beni` — `<h1>Hello, beni</h1>` — and save. The terminal says
`beni: built in … ms` and the page reloads by itself.

Now make a mistake: change `count + 1` to `count + "1"` and save. The terminal shows what is wrong,
where, and why:

```
-- TYPE MISMATCH ------------------------------------------- src/Main.beni:17:21

The 2nd argument to (+) is not what I expect:
...
beni: build failed; waiting for changes
```

The page keeps showing the last program that built — a failed build writes nothing — until you fix
the line, when it rebuilds and reloads again. Stop the server with Ctrl-C.

## 5. Build for production

```sh
beni build --release
```

`out/` then holds `index.html` and one minified `_main.mjs`: copy the directory to any static host.
The live-reload script is never in a file the build writes; `beni serve` adds it to the pages it
serves, on the way out.

## The commands

| Command | What it does |
|---|---|
| `beni new [--platform=browser-tea\|node] <dir>` | make a project that builds and runs |
| `beni build [--release]` | build once; nothing is printed when it succeeds |
| `beni build --watch` | build, then rebuild whenever a source changes, until Ctrl-C |
| `beni serve [--port=<n>] [--host=<address>] [--no-reload]` | `build --watch`, plus a development web server for `out/` with live reload; any path without a file extension that names no file gets `index.html`, so client-side routes survive a reload |
| `beni check src` | type-check without writing anything |
| `beni fmt src` | format every file in place |
| `beni help` | every command and flag |

Inside a project the platform, paths and output directory come from `beni.json`; outside one, give
them on the command line: `beni build --platform=browser-tea --out=out src`.

## Your own page

To add styles, a title or an element to mount into, write your own page and name it in
`beni.json`:

```json
{
  "name": "counter",
  "html": "index.html",
  "build": { "platform": "browser-tea", "paths": ["src"], "out": "out" }
}
```

In `index.html`, write `{{entry}}` where the program's script goes:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Counter</title>
    <style>body { font-family: system-ui; }</style>
    <script type="module" src="{{entry}}"></script>
  </head>
  <body></body>
</html>
```

A page that never says `{{entry}}` is refused, since it would never load the program.

`{{entry}}` becomes `./_main.mjs`, a path relative to the page, so `out/` works hosted at a
domain's root or under a sub-path. If your app has nested client-side routes (`/todos/3`) and is
hosted at the root, add `<base href="/">` to the `<head>` so the script still loads from them.

The build copies only what it writes: an image or a stylesheet beside your page is not copied into
`out/` yet, so keep styles inline in the page for now.
