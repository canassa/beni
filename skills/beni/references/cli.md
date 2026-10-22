# The command line

`beni help` prints the usage. This file lists every command and flag.

## Commands

| Command | Does |
|---|---|
| `beni new [--platform=browser-tea\|node] <dir>` | make a project that builds and runs |
| `beni build [options] [--watch] [--platform=<name>] [<path>...]` | compile to JavaScript for a platform |
| `beni serve [build options] [--port=<n>] [--host=<address>] [--no-reload] [<path>...]` | `build --watch` and an HTTP server with live reload |
| `beni check [options] [--platform=<name>] <path>...` | parse, lower and check every module; report diagnostics; write nothing |
| `beni fmt [options] [--check] [--stdout] <path>...` | format in place, or `--check` to report, or `--stdout` to print |
| `beni dump [options] --stage=<stage> [--positions] [--platform=<name>] <file>` | print one file's representation |
| `beni skill` | print the path of the installed skill folder |
| `beni skill install [--link] [--force] <dir>` | put the skill folder into `<dir>/beni`, for an agent harness |
| `beni version` | print the version |
| `beni help` | print the usage |

A `<path>` is a `.beni` file or a directory, walked recursively. Inside a project, `build` and
`serve` take the platform and the paths from `beni.json`.

## Options for every command but `skill`

| Flag | Meaning |
|---|---|
| `--diagnostics=text\|json` | diagnostics on stderr as prose (the default) or as one JSON array |
| `--self-profile=<path>` | write a Chrome trace-event JSON file at exit |
| `--jobs=<n>` | worker threads; the output is identical for every `n` |
| `--root=<dir>` | the source root that module names are derived from |
| `--core` | treat the files as the core package (`foreign` is legal); never for a project |
| `--core-root=<dir>` | read core from this directory instead of the embedded copy |
| `--explain` | also emit `unit_discarded`, a `_ =` in front of a `⊤` |
| `--pattern-budget=<n>` | the work one `case` can spend on exhaustiveness before it is refused |

## `check`, `build` and `serve`

| Flag | Meaning |
|---|---|
| `--cache-dir=<path>` | keep checked modules between runs here (default `.beni-cache`) |
| `--no-cache` | read and write no cache |
| `--platform=<name>` | `check`: also load the platform, as `build` does; optional. `build`, `serve`: required unless `beni.json` names it |

## `build` and `serve`

| Flag | Meaning |
|---|---|
| `--out=<dir>` | the output directory (default: `beni.json`'s, else `out`) |
| `--library` | no `main`; every exported name is kept |
| `--source-maps` | a `.map` beside every module (the default; with `--release` only when given) |
| `--no-source-maps` | write no `.map` files |
| `--release` | dead bindings out, short names, compact printing, joined constants; refuses `Debug` |
| `--watch` | rebuild on every change, until Ctrl-C |
| `--poll-interval=<ms>` | how often `--watch` looks for changes (default 200) |

## `serve`

| Flag | Meaning |
|---|---|
| `--port=<n>` | the TCP port; `0` picks a free one (default 8000) |
| `--host=<address>` | the address to listen on (default `127.0.0.1`) |
| `--no-reload` | do not inject the live-reload script |

## `new`, `fmt`, `dump` and `skill`

| Flag | Meaning |
|---|---|
| `new --platform=browser-tea\|node` | which template (default `browser-tea`) |
| `fmt --check` | exit 1 when a file is not in the formatter's layout; write nothing |
| `fmt --stdout` | print the formatted text instead of writing it |
| `dump --stage=tokens\|ast\|bir\|interface\|raw\|types\|graph\|dispatch\|writes\|ownership` | which representation (required); `interface` prints a module's public signatures |
| `dump --positions` | include source positions |
| `dump --platform=<name>` | as `check`'s, for the stages that resolve imports |
| `skill install --link` | write a symlink to the installed folder instead of a copy |
| `skill install --force` | replace a beni skill that is already at `<dir>/beni`; anything else is refused |

The ownership dump shows where a field is read before a record write, and where a closure
reads a field it captures. Each location uses source line and column numbers.
A cast path shows the complete type after `as`. The first boundary is exact.
A repeated complete type folds deeper paths and uses the `⁺` marker.

## Migration flags that a diagnostic names

`beni help` does not list these. A diagnostic about an old spelling names the one that rewrites a
file in place: `beni fmt --migrate-cons <file>` for `::`, `--migrate-unicode` for the ASCII
symbols, `--migrate-top` for `()` and `Never`, `--migrate-lambda` for `\x ->`, `--migrate-let` for
`let … in`, `--migrate-names` for `modBy`, `remainderBy` and `logBase`, `--migrate-init` for an
`init` that is a value. Each rewrites one thing; all but `--migrate-let` keep the file's layout, and
`--migrate-let` reformats the whole file. Run one at a time.

## Exit codes and diagnostics

- `0`: no errors. `1`: at least one error diagnostic (`fmt --check`: a file is not formatted). `2`: a
  usage or I/O failure.
- A warning never changes the exit code.
- `--diagnostics=json` prints one array of objects: `code`, `severity` (`error` or `warning`),
  `span` (`file`, `start` and `end` with `line` and `col`, counted in code points), `title`,
  `message`. The text form prints the same, Elm-style, with the source line.
- Diagnostics are sorted by file, position and code, whatever `--jobs` is.

```sh
beni check --diagnostics=json src
beni fmt --check src
beni build --release
beni dump --stage=interface --platform=node src/Main.beni
```

Sources: `docs/design/frontend.md` §1, §10, §12; `docs/design/ownership-checker.md` §16.7, §31.10; `src/Cli.zig`'s usage text.
