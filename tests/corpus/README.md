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
| `writes/` | `check`, then `dump --stage=writes`, both `--platform=browser-tea` | `<name>.writes` | the write-set pass (`write-sets.md` §8.1): per message key its write set and class, per view hole its class and reads; a project may name its sources elsewhere (`_expected.sources`), carry the hidden `--writes-work` cap (`.writes-work`), and be the gate of §8.2 (`.gate`: its `keys` lines must show two thirds bounded) |
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

### A program that must crash

A `run/` fixture with a `<name>.crash` golden (`_expected.crash` in a
project) asserts a defect (`boundary.md` §4.1, `CLAUDE.md` rule 9): the
program must exit **1**, its standard output must still be `.expected`
(what it printed before the defect), and its standard error must contain
the `.crash` file's text, its final newline left out — one line of Node's
report, such as `Error: disk on fire`, since the rest of the report is
stack frames whose paths are the test's own. Without a `.crash` file a
`run/` program must exit 0, as before. The `.crash` text is part of what a
build's run hash covers. `.crash` is never blessed: write it by hand.

### `browser/`: a program in a page

A `browser/` fixture is built like a `run/` one, twice, for the `page`
test platform (`tests/platforms/page/`: a view written with `foreign`
calls, a model, messages rendered on one microtask flush) — or, as a
project, for its own `platform/`. Each build is then loaded into a page of
its own by `tests/browser/driver.mjs` — both pages in one Node process, one
after the other — which runs `<name>.steps` (`_expected.steps` in a
project) against it, one step per line, `#` for a comment:

    click <selector> [ctrl|shift|alt|meta]… [button:<n>]
                                a bubbling `click` with those modifiers held
                                and that `button` (default 0); one whose
                                default a handler prevented logs `(click's
                                default prevented)`; a click on a link that
                                nothing prevented is stopped by the driver,
                                after every listener of the page, and logs
                                `(the host follows the link to "<href>")`,
                                so neither DOM leaves the page
    click <selector> <n>        `n` clicks in one task, then `(the step's task ended)`
    flush <selector>…           a click, then the program runtime's `flush()`
                                in the same task, then `(flushed)`; with
                                several selectors, each in turn, in one task
    input <selector> "<text>"   set `.value`, then `input`
    set <selector> "<text>"     set `.value` and dispatch nothing: a write no
                                event reveals, which only code outside beni
                                can make (`backend.md` §15.3, *Controlled
                                inputs*)
    type <selector> "<text>"    per character, in a task of its own: append
                                it to the live `.value`, then `input`
    key <selector> <key> [<modifier>…] [code:<code>]
                                `keydown` and `keyup` with that `key`, each
                                modifier (`ctrl`, `shift`, `alt`, `meta`,
                                `repeat`) set, `code` given (default `""`);
                                one whose default a handler prevented logs
                                `(keydown's default prevented)` (or `keyup's`)
    dblclick <selector>         a bubbling `dblclick` (`detail` 2), with no
                                `click`s before it
    press <selector>            a user's click: trusted (below); a listener
                                the driver added on the window, after every
                                listener of the page, logs `(a later
                                listener ran)`
    focus <selector>            `.focus()`
    blur <selector>             `.blur()`
    advance <ms> [tasks]        move the page's virtual clock on by `ms`,
                                firing each timer that comes due, earliest
                                first, the page settling after each; with
                                `tasks`, `(the timer's task ended)` is
                                logged as each timer's callback returns,
                                before any microtask it queued; a callback
                                that throws is reported to the window's
                                `error` listeners, as a host reports it
    event <window|document|selector> <name> [<n>]
                                `n` (default 1) plain `Event`s of that
                                name on the window, the document or the
                                element, in one task
    url "<url>"                 `history.replaceState` to the URL, relative to
                                the page's (`"?q=1#/active"`); nothing fires
    hash "<#fragment>"          the same, then one `popstate` and one
                                `hashchange` on the window in the step's
                                task, as following a link to the fragment
                                does (happy-dom's own `location.hash` fires
                                two `hashchange`s and no `popstate`)
    back / forward              `history.back()` / `history.forward()`, then
                                wait for the `popstate` the traversal fires
    location                    log `(location: <path><?query><#fragment>)`,
                                the origin left out
    title                       log `(title: "<document.title>")`
    file                        as the script's first step: the page is
                                opened from a file, its address `file:`
    throws load                 after the steps that set the page up: the
                                program must throw while it loads
    store <local|session> "<key>" "<value>"
                                `setItem` on that storage
    storage <local|session>     log `(localStorage: {…})`, its items by key
    timers                      log `(timers: <n>)`, the virtual clock's
                                timers that have neither fired nor been
                                cleared
    listeners <window|document> [<name>]
                                log `(listeners: <n>)`, the listeners the
                                page added to that target (for that event)
                                and has not removed — what a program still
                                holds of the host, seen without its code
    respond <n> <status> "<body>" [<name>: "<value>"]…
                                answer the `n`-th request the page made
                                (1-based, in the order `fetch` was called)
                                with a `Response` of that status, body and
                                headers, its `url` the request's
    respond <n> <status> chunks "<a>" "<b>"… [<name>: "<value>"]… [open]
                                the same, its body a stream yielding each
                                chunk in a task of its own; with `open` the
                                body never ends, as a stalled server's;
                                answering a request the page aborted logs
                                `(fetch <n> was aborted: nothing hears the
                                answer)`
    fail <n>                    reject the `n`-th request with `new
                                TypeError("Failed to fetch")`, the Fetch
                                standard's network error
    throws <step>               any step above, which must make the page
                                throw: each uncaught exception is the line
                                `(threw: <its first line>)`

`listeners` counts a registration as the DOM does — its event, its
listener and its capture flag — so adding one twice is one; a `once`
listener stops counting when it fires and one with a `signal` when the
signal aborts. The driver's own `error` listeners are not counted.

**Steps before the program loads.** The `url` and `store` steps a script
begins with run before the program's modules are imported, each a heading
with nothing under it, then `-- load`: how a fixture starts a page at an
address or with something stored. Every page starts with empty storage.

**The page's clock is virtual.** The driver replaces `setTimeout`,
`clearTimeout` and `Date.now` before the program loads: `Date.now()` is 0
until an `advance` step moves it, and a timer fires only when an `advance`
step reaches its time, so a debounce of 250 ms costs no wall-clock time and
a fixture about timing is deterministic in both DOMs. After each timer the
page settles — the fibers it resumed run, and may set the next timer —
before the next fires. A service a program waits on (`Http`, a search API)
is faked with a record of functions that sleep on this clock
(`boundary.md` §9.8.9).

**The page's `fetch` is scripted.** The driver replaces `fetch` before the
program loads, as it replaces the clock. Each call is logged when it is
made — `(fetch <n>: <METHOD> <path> <headers> [<body>]
[credentials:<mode>])`, the headers as JSON by lower-cased name (a multipart
boundary written `…`), a text body as a JSON string and a `FormData` one as
its entries — and stays pending until a `respond` or `fail` step answers it.
The request and the answer are the DOM's own `Request` and `Response`. An
abort of a pending request (or of a body still streaming) rejects it with
the signal's reason, as the host's `fetch` does, and logs `(fetch <n>
aborted: <the reason's name>)`, so a cancelled `Restart` and a timeout are
both visible. A `data:` URL goes to the host's own `fetch` and is neither
numbered nor logged. A request still pending when the script ends fails the
case, so no fixture forgets one.

**A successful `load` leaves the page**, which neither DOM can show and the
driver cannot follow, so no fixture asserts one; a refused `load` is a value
and is shown.

**The page is an `http` page with fixed entropy.** Its address is
`http://127.0.0.1:<port>/_page.html` in both DOMs — Chrome loads it, and
the program, from a server the driver starts — so `Url.fromString` reads
it and its path is the same on every machine; only the port differs, and
no fixture shows it. `crypto.getRandomValues` is a fixed sequence, so a
program that seeds `Random` from it is deterministic.

A selector is one CSS selector without spaces and must match an element.
The two lines in parentheses are logged when the step's own task ends,
before any microtask it queued, so what the page logged before them ran in
that task and what it logged after ran later: that is how a fixture shows
five messages rendering once, or `flush` rendering at once. The page
settles between two characters of a `type`, as between two keystrokes, so
a controlled input shows whether it was reconciled before the next one.
The program runtime is the module the entry file imports `run` from.
The golden is the transcript: `-- load`, then `-- <step>` for each step,
each followed by what the page logged (`console.log: …`) and then
`document.body`, one node per line, text and attribute values as JSON
strings, a form control's live `.value` (and `.checked`) after its
attributes, `:focus` on the focused element — or `(the DOM did not
change)`. An uncaught exception in the page outside a `throws` step (which
must throw, and records each exception instead), and a step that cannot run,
fail the case with the step, the message and where it was thrown; they
are never a golden. `<name>.release-expected` works as in `run/`.

**Listener subscriptions both ways.** A development build of a page whose
subscriptions include a listener (`Sub.on`; `boundary.md` §9.8.5) carries a
test hook, and such a build is run a third time, copied to `out-fiber/`
and loaded with `--fiber-page`, which sets the hook before the program
loads: every listener then runs in a fiber, as every subscription did
before listeners needed none. Its golden is the development build's, which
it never blesses, so each such page shows that the two paths cannot be told
apart; its run hash is a third line, `dev_fiber`. A build without the hook
— no listener subscription, or `--release` — runs as before. Under
happy-dom an exception a microtask throws escapes to Node; the driver
reports it to the page's `error` listeners, as a browser does, so a page
that shows the error it was stopped by (`boundary.md` §9.8.10 (c), the
development crash screen) shows it in both DOMs.

**Which DOM.** The gates run the page in Node under happy-dom,
`tests/browser/happy-dom.mjs`: one vendored, checksummed file that
`tests/browser/vendor.sh` regenerates from pinned versions, so the gates
need neither a browser nor the network. Compiling it costs about 100
million instructions, so the driver keeps V8's code cache in the
checkout's `zig-out/browser-driver-cache/` — never in `/tmp`, where every
worktree's copy of happy-dom was an entry of its own and the cache once
filled the disk. Node keys an entry by the file's path, and each page
program is compiled from a directory no later run repeats, so the driver
prunes the cache as it starts: once it holds more than 1 024 entries,
those older than an hour go. Deleting the directory is always safe; a
missing entry is compiled again. `zig build test-browser` runs the
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
- steps dispatch untrusted events in both DOMs, and `key` types nothing —
  except `press` and the focus events a `focus()` or `blur()` call fires,
  which are trusted as Chrome makes them: Chrome's `press` is its own
  click, sent through `Input.dispatchMouseEvent`, and happy-dom, which has
  no `isTrusted`, is given one that is true for exactly those. The
  emulation is dispatched from the driver's stack, so where Chrome runs
  microtasks between two listeners of a user's click, happy-dom does not:
  a fixture shows what the runtime does at a listener's end, not what the
  host does after it;
- `Headers`: happy-dom iterates names as they were written, where the Fetch
  standard and Chrome lower-case them, so a fixture that shows headers
  lower-cases them itself (the fetch log does);
- a request's method: the Fetch standard (and Chrome) upper-cases only
  `DELETE`, `GET`, `HEAD`, `OPTIONS`, `POST` and `PUT`, happy-dom every
  method, so the fetch log normalises the method the page asked for as the
  standard does;
- a link followed: happy-dom follows an `<a href>` when the click bubbles
  through it, before the window's listeners run, so a window listener that
  prevents the default (the link guard of `Browser.Navigation`) is too late
  for a click on an element inside the link; Chrome follows it after the
  dispatch, as the standard says. happy-dom then changes the address without
  loading anything, so a fixture shows the address before such a click;
- `history.back()`: happy-dom fires the `popstate` at once, in the step's
  task, Chrome in a later one; the `back` and `forward` steps wait for it.

**Run hashes** work as in `run/`, with the DOM on the line
(`dev v24.19.0 happy-dom-20.14.5 <sha-256>`) and the digest covering the
DOM's checksum, the driver and the steps as well; `zig build
test-run-hashes` records them. `test-browser` never skips and never
records.

**The `dom` lowering's fixtures** (`backend.md` §15.10) are under
`browser/dom/`, files and projects alike, and are built with
`--platform=browser`; those under `browser/tea/` are built with
`--platform=browser-tea`, The Elm Architecture written in beni over it.
`emit/dom/` and `emit/release/dom/` are `emit/`
fixtures built the same way, the shapes of what the lowering emits. The
steps, the transcript, the run hashes and `test-browser` are the kind's
own. The differential oracle against dom-expressions' fixtures is a
separate, DOM-free comparison of template strings and walks:
`tests/oracle/`, run by `tests/blackbox/oracle_test.zig`.

**The `direct` lowering's fixtures** (`docs/design/browser-direct.md` §12.3)
are under `direct/` of three kinds, built with `--platform=browser-direct`:
`emit/direct/` and `emit/release/direct/` are application builds (rooted
at `main`, not `--library`), the first goldening the module, the second
the release file whole; `build/bad/direct/` projects need no `platform/`
of their own; and every `browser/direct/` page is built **for both
platforms** from its one source — `browser-direct` and `browser-tea`, dev
and release, four pages — against one golden, since the two platforms are
each other's oracle. A difference the design specifies (one is §8.2's
`init`, evaluated inside the mount on `browser-direct` and where `main` is
evaluated on `browser-tea`) is a `<name>.tea-expected` (and `.tea-release-expected` when the release build differs), which the
`browser-tea` builds read instead and never bless, with its reason in the
fixture's comment. Their run hash lines are `dev`, `release`, `tea_dev`
and `tea_release`.

**The page fuzzer** (`docs/design/browser-direct.md` §8.3 and its
2026-10-09 amendment, `tests/browser/fuzz.mjs`) runs on every
`browser/direct/` page without a `.tea-expected` — its `browser-tea` build
against its `browser-direct` build — and on every `browser/tea/` page, its
development build against its release build: one seed of thirty random
steps, the two pages compared after each — the body, the properties it
does not print, the title, the address, the storages, every logged line
but those the pair may differ on, the errors — in the driver's process
after the fixture's pages. A difference fails the case with the seed, the
step, the sequence shrunk, and what differs; a
sequence of view events is printed as a `.steps` script, the red-first
fixture of the defect. A fuzz that agreed is the `fuzz` line of the
fixture's run hash. `zig build fuzz` runs fifty seeds of sixty steps.
A `browser/direct/` page's fuzz is a case of its own, `<page> [value
fuzz]`, budgeted apart from the page's: it builds the two `--fuzz` builds,
dumps the message types and fuzzes them, messages as values included, and
records its line in `<name>.fuzz-run-hash` (`_expected.fuzz-run-hash` in a
project).

**`emit/release/split/`** — release applications, whose golden is
`_main.mjs` whole — are built with `--platform=browser`, the `dom` lowering
over a markup runtime that is the beni module `Rt` and a hand-written file
importing it (`boundary.md` §9.2, *A runtime module*): what a page ships once
program and runtime are specialised together (`backend.md` §9). The pages
of `browser/dom/` and `browser/tea/` run the same runtime.

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

## Budgets

Every corpus case is held to the gates' instruction budget (CLAUDE.md, *Every test has a
budget*), its own and its children's instructions. A case over it is made smaller, split or
removed. The owner may grant a **large program** its own budget, case by case: a `.budget` file
(`_expected.budget` in a project) whose first word is the limit in millions of instructions and
whose rest says why and when it can go. A file without a reason fails the case. Granted so far:
`browser/tea/ConduitReader`, `ConduitEditor` and `ConduitTour` (12 000M, 2026-10-08): the
RealWorld app, whose release build alone is ~5 800M because of the release optimiser's
`specialise` phase (research 62 §1.3).

A project may also take its modules from outside the corpus: `_expected.sources` holds a
repo-relative directory whose `.beni` files are the program, so several scripts can drive one
application (`examples/conduit/src`).

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
  modulo positions and the spelling of a last-argument lambda (its
  parentheses, or a `<|` before it, which the formatter moves between and
  which lower to nothing — `frontend.md` §11.5), and the input and the
  output carry **the same comments
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
