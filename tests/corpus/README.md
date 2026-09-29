# tests/corpus — the fixture tree

`tests/blackbox/corpus_test.zig` walks this tree at test time and generates
one black-box test case per fixture file, named by its path. **Adding a test
is dropping in a file.** Every case drives the real installed binary
(`./zig-out/bin/beni`) through files and flags only, and asserts on its
outputs: stdout, the JSON diagnostics on stderr, and the exit code.

## Directories

| Directory | The compiler runs | Compared against | Meaning |
|---|---|---|---|
| `parse/good/` | `dump --stage=ast` | `<name>.ast` | parses clean; the AST golden pins the tree |
| `parse/bad/` | `check --diagnostics=json` | `<name>.diag` | must fail; the **whole** diagnostic list is the golden |
| `parse/*/`, optionally | `dump --stage=tokens` | `<name>.tokens` | when the file exists: the lexer's token stream and comments, for decisions the AST cannot show (which `<` opens markup, where a text run ends); create it empty and bless to opt in |
| `fmt/` | `fmt --stdout` | `<name>.expected` | formatter output; `.expected` must be a fixed point and parse to the same AST as the input |
| `bir/` | `dump --stage=bir` | `<name>.bir` | lowering golden: resolution, desugaring, interface skeleton |
| `check/good/` | `check`, then `dump --stage=interface` | `<name>.iface` | resolves clean against the project and core; the golden is the module's public face |
| `check/bad/` | `check --diagnostics=json` | `<name>.diag` | must fail resolution; the **whole** diagnostic list is the golden |
| `build/bad/<Dir>/` | `build --diagnostics=json --platform=…` | `<Dir>/_expected.diag` | must fail the BUILD: exit 1, the whole diagnostic list, and no `out/` |
| `build/bad-release/<Dir>/` | the same, **plus `--release`** | `<Dir>/_expected.diag` | must build clean WITHOUT the flag and fail with it (`backend.md` §9's refusal of `Debug`) |
| `run/` | `build --platform=node`, then `node out/_main.mjs` | `<name>.expected` | **the second boundary**: the emitted program's stdout |
| `browser/` | `build --platform=tests/platforms/page`, then the program in a page, driven by `<name>.steps` | `<name>.expected` | the second boundary in a DOM: the page after the load and after each step |
| `regress/` | as above, by subdirectory | as above | named after the bug they pin, e.g. `Shadowing2.beni` |

The two `check/` kinds also take a **directory** as one fixture: every
`.beni` under it is a module of one project, and the golden is
`<name>/_expected.iface` or `<name>/_expected.diag`. Cross-module
resolution needs more than one module to exist, so that is where imports,
cycles and interfaces are actually tested (`docs/design/checker.md` §3).

`build/bad/` is **only** the directory form, and there the whole directory
is the project: every file under it is copied, not only the `.beni`s,
because the fixture may carry its own **platform package** — the thing
`boundary.md` §4's sibling checks are checks of. A `platform/`
subdirectory means `--platform=platform`, and without one the build takes
`--platform=node`; there is no per-fixture flag file. That kind exists
because nine diagnostic codes could be produced nowhere else: six need a
platform, and three (`missing_main`, `main_not_program`, `duplicate_main`)
need a build, `check --platform` having deliberately no opinion about
`main`. See `build/bad/README.md`, and `plans/coverage-audit.md` Part A for
the three that are still blackbox-only.

A `run/` project may carry a `platform/` directory the same way, and is
then built with `--platform=platform` in a world of its own: a test platform
layered on `node` is how a program observes what only a platform may write,
such as `run/MarkupFieldIdentity`'s `refEq` (`backend.md` §15.8).

`build/bad-release/` is that kind again with `--release` added and
`--allow-debug` left off: a fixture there must build **clean** without the
flag and fail with it, which is the only way to state `debug_in_release` —
the one code in the catalogue a development build cannot produce
(`backend.md` §9's *`Debug` is refused, not pinned*). Its own
`README.md` has the four assertions.

`run/` builds every fixture twice, in development and with `--release
--allow-debug`, and runs each build under Node — unless the fixture's
`.run-hash` (`_expected.run-hash` in a project) says that exact build was
already verified. A record holds one line per build, `<dev|release> <node
version> <sha-256>`; the digest covers every file of the output tree (its
path and bytes; `_manifest.txt` left out, since it only lists the others'
hashes), the golden the build is compared with (`.expected`, or
`.release-expected` for the release build when there is one) and the Node
version. Any change to one of them makes the build run under Node again,
exactly as it would with no record, and the gates say in one line how many
did. `zig build test-run-hashes` (with `-Dcorpus`, `-Dllvm`) runs the
selected programs and rewrites their records with the builds whose output
matched; a build that fails is reported and left without a line. Regenerate
after a change to what the compiler emits (the emitter, the runtime,
`core/`), after adding or re-blessing a `run/` fixture, or after a Node
upgrade, and commit the records with the change; on a merge conflict in
them, take either side and regenerate. The code is
`tests/blackbox/run_hash.zig`, and `run_hash_test.zig` drives the walker to
show a recorded build skipped, a changed one run, and a mismatch refused.

### `browser/`: a program in a page

A `browser/` fixture is built like a `run/` one, twice, for the `page`
test platform (`tests/platforms/page/`: a view written with `foreign`
calls, a model, messages rendered on one microtask flush) — or, as a
project, for its own `platform/`. Each build is then loaded into a page by
`tests/browser/driver.mjs`, which runs `<name>.steps` (`_expected.steps`
in a project) against it, one step per line, `#` for a comment:

    click <selector>            a bubbling `click`
    input <selector> "<text>"   set `.value`, then `input`
    key <selector> <key>        `keydown` and `keyup` with that `key`
    focus <selector>            `.focus()`

A selector is one CSS selector without spaces and must match an element.
The golden is the transcript: `-- load`, then `-- <step>` for each step,
each followed by what the page logged (`console.log: …`) and then
`document.body`, one node per line, text and attribute values as JSON
strings, a form control's live `.value` (and `.checked`) after its
attributes, `:focus` on the focused element — or `(the DOM did not
change)`. An uncaught exception in the page, and a step that cannot run,
fail the case with the step, the message and where it was thrown; they
are never a golden. `<name>.release-expected` works as in `run/`.

**Which DOM.** The gates run the page in Node under happy-dom,
`tests/browser/happy-dom.mjs`: one vendored, checksummed file that
`tests/browser/vendor.sh` regenerates from pinned versions, so the gates
need neither a browser nor the network. `zig build test-browser` runs the
same fixtures in one headless Chrome (a fresh target per page) against the
same goldens; Chrome comes from `-Dchrome=` or `PATH` (`nix develop
.#browser`). `tests/blackbox/browser.zig` has the measurements behind the
choice. Where the two DOMs are known to differ, a fixture that reaches the
difference carries a `<name>.chrome-expected`, which `test-browser`
compares instead of `.expected`. The differences known today:

- the HTML parser: after a misnested `</p>` (`<p><div></div></p>`),
  Chrome makes an empty `<p></p>` and happy-dom does not;
- event loop order: the page runs on Node's event loop, so the order of
  timers, `MessageChannel` messages and I/O against each other is Node's,
  and there is no `requestAnimationFrame` frame clock; a fixture about
  scheduling order belongs to `test-browser`;
- layout: happy-dom lays nothing out, so sizes and positions are zero;
- steps dispatch untrusted events in both DOMs, and `key` types nothing.

**Run hashes** work as in `run/`, with the DOM on the line
(`dev v24.19.0 happy-dom-20.14.5 <sha-256>`) and the digest covering the
DOM's checksum, the driver and the steps as well; `zig build
test-run-hashes` records them. `test-browser` never skips and never
records.

**How the `dom` lowering's fixtures plug in** (`backend.md` §15.10). The
`page` platform is the harness's own, standing in until `platforms/browser`
exists. When it does, a `dom` fixture is a `browser/` fixture built for
`browser` instead: give the kind a `browser/dom/` subdirectory whose
fixtures take `--platform=browser` (one line in `fixturesOf`, as `markup/`
does for the check kinds), or give a project fixture a `platform/` that
layers on `browser` by name, as `run/MarkupFieldIdentity` layers on
`node`. The steps, the transcript, the run hashes and `test-browser` are
unchanged; the differential oracle against dom-expressions' fixtures is a
separate, DOM-free comparison of template strings and walks.

`bir/` files whose name starts with `core_` are run with `--core` so that
`foreign` declarations are legal (`language.md` §5.4).

`check/good/`, `check/bad/` and `dispatch/` fixtures under a `markup/`
subdirectory — files and projects alike — are run with `--platform=html`, so
their markup is typed against the HTML vocabulary (`checker-v2.md` §25).

Every fixture is **one idea, as small as the idea allows**, with a `--`
comment on its first lines saying what it proves. In `parse/bad/` the comment
also names the expected diagnostic code(s) and their `line:col`, so a blessed
golden can be checked against the intent before it is committed. A few
fixtures cannot hold a comment without changing what they test (an empty
file, a file that is only `"`); those have a sibling `.md` note instead.

File names are `UpperCamel.beni` because the module name is derived from the
path and each segment must be a valid upper identifier (`language.md` §1);
`parse/bad/invalid_module_path.beni` is the one deliberate exception.

Fixtures whose bytes cannot be typed (invalid UTF-8, a bare `\r`, a tab, a
control character, CRLF endings, a 1 MB line) are generated by a small Python
one-liner so the bytes are exact; the generating script is not kept, the
bytes are what is tested.

## Golden discipline

These rules are copied from `.claude/skills/write-tests/SKILL.md` and are the
reason this corpus does not rot the way Elm's did:

- **A `bad/` fixture without a `.diag` file is a failure, not a pass.** Elm's
  `bad/` fixtures asserted only "this failed to compile" — never *which*
  error. We assert the whole diagnostic list: code, severity, span, title,
  message.
- **Goldens come from real runs, never from hand-writing.** Bless with
  `BENI_WRITE_EXPECTED=1 zig build test-blackbox`. The failure message says
  so. The value is fully materialised before any golden is written, so an
  error cannot truncate a golden to empty.
- **Check every blessed golden against the fixture's intent comment** before
  committing it. Blessing records what the compiler *did*, not what it
  *should* do; the comment is the claim, the golden is the evidence.
- **Goldens carry no positions** unless `--positions` is passed, so a
  formatting change to a fixture does not churn its `.ast`.
- **A golden diff is a review item, not noise.** If a change to the compiler
  changes many goldens, that is information about the change.
- **Never golden what running would prove.** The AST, diagnostic and BIR
  dumps here are shape claims that cannot be observed by running a program;
  semantic claims go in `run/`, whose `.expected` is what the emitted program
  printed under Node and not text the compiler produced. A change that alters
  emitted SHAPE but not behaviour leaves every `run/` fixture green; a change
  that alters behaviour fails one, by name.
- `fmt/` has three extra invariants checked mechanically: formatting an
  `.expected` again is a fixed point, `parse(fmt(s))` equals `parse(s)`
  modulo positions, and the input and the output carry **the same comments
  in the same order**. The last one is its own check — through
  `dump --stage=tokens`, by kind and text — because the AST dump carries a
  doc comment as `(doc …)` and drops a plain `--` one entirely, so a lost or
  reordered comment used to show up only as a golden diff at bless time.
- Abuse inputs are first-class: a hostile file must produce a diagnostic,
  never a panic, a hang or an OOM, and must leave no partial output behind.
- Determinism, and the interface format: the walker in
  `tests/blackbox/corpus_test.zig` passes no `--jobs` at all. The `--jobs`,
  round-trip and cache claims are made by a few hand-picked black-box tests,
  each on a small project built to reach one branch, not by a sweep over this
  corpus: `cache_test.zig` (a warm build is byte-identical to a cold one, a
  cache written at `--jobs=1` is read at `--jobs=8`, and the counters of a
  cold and a warm run), `iface_test.zig` (all three round trips on a build,
  and an importer's diagnostics through the record), and `build_test.zig`
  and `blackbox_test.zig` (a refused build, and every stream, at `--jobs=1`
  and `--jobs=8`).
- The corpus walker passes **`--no-cache`** to every `check` and `build`.
  Since M4-3 the cache is on by default (`frontend.md` §1) and these cases
  run with cwd = the repo root, so without the flag ~576 fixtures would share
  one `.beni-cache/` that survives between suite runs — and a golden compared
  against a run that may have hit an entry written by a different case, or by
  yesterday's build, is a golden compared against history. The CACHED path
  is covered where it can be controlled instead, by `cache_test.zig` and by
  `tests/blackbox/cutoff_test.zig`'s edit classes. `fmt` and `dump` take no
  cache flag at all and create no directory.
  `.beni-cache/` is in `.gitignore`: a cache is machine-local by policy and is
  never committed, and deleting it is always safe.
