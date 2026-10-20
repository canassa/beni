# A project

## `beni new`

`beni new <dir>` writes a project that builds and runs: `beni.json`, `src/Main.beni` and a
`.gitignore` for `out/` and `.beni-cache/`. `--platform=browser-tea` (the default) writes a
`Tea.sandbox` counter; `--platform=node` writes a program that prints a line. The directory must be
new or empty. It prints the next two commands.

## `beni.json`

The project file, in the directory `beni` runs from (or `--root`):

```json
{
  "name": "counter",
  "build": { "platform": "browser-tea", "paths": ["src"], "out": "out", "base": "/" },
  "html": "index.html"
}
```

| Key | Is | Default |
|---|---|---|
| `"build"."platform"` | the platform, what `--platform` says | none: `build` refuses |
| `"build"."paths"` | the source paths, what the positional arguments say | none: `build` refuses |
| `"build"."out"` | the output directory, what `--out` says | `out` |
| `"build"."base"` | the URL path the output is served under; ends in `/` | `/` |
| `"html"` | the page shell, a file relative to `beni.json` | the platform's |

A command-line flag replaces the manifest's value, field by field. `check` always takes its paths.

## Modules and files

- Every `.beni` file under a source path is a module. `src/Ui/Card.beni` is `Ui.Card`.
- A module name segment starts with a capital letter. A hidden entry (`.` prefix) is skipped.
- Keep one `main : Program` per build. `check` reports no missing `main`; `build` does
  (`missing_main`, `duplicate_main`).

## `beni build` and the output

`beni build` compiles to `out/`:

| Path | Is |
|---|---|
| `out/_main.mjs` | the entry module; `node out/_main.mjs` runs a `node` program |
| `out/index.html` | the page shell, for a page platform; it loads `/_main.mjs` |
| `out/<Module>.mjs`, `out/Ui/Card.mjs` | your modules, one file each |
| `out/_core/`, `out/_platform/` | core and the platform; only what the program reaches |
| `*.mjs.map` | a source map beside every module, with the beni source inside; `--no-source-maps` drops them |

- Reserved names start with `_`; a module cannot take one.
- `--release` drops dead bindings, shortens names, joins constants and prints compactly. It refuses
  a program that reaches `Debug` (`debug_in_release`). The output behaves exactly as the development
  build does.
- `--library` builds without a `main`; every exported name is kept.
- A failed build writes nothing: the last good output stays.
- `.beni-cache/` holds checked modules between runs. `rm -rf .beni-cache` is always safe.

## `beni serve`

`beni serve` builds, watches the sources, and serves `out/` at `http://127.0.0.1:8000/` with live
reload: the page reloads after each successful build; a failed build keeps the last page and prints
the errors. `--port=<n>`, `--host=<address>`, `--no-reload`. A path that names no file is answered
with `index.html`, so a client-side route survives a reload. `beni build --watch` is the same loop
without the server.

Sources: `docs/design/frontend.md` §1, §10; `docs/design/backend.md` §2.
