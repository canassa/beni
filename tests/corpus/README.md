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
| `ownership/` | `check`, then `dump --stage=ownership` | `<name>.ownership` | the ownership checker's report (`ownership-checker.md` §9): one line per demand with its verdict and cause; a project takes `_expected.ownership`. Beside a `.platform` file, one platform per line, the fixture is a case per platform (`<name> [<platform>]`), checked and dumped under it, with one golden per platform (`<name>.<platform>.ownership`, the last part of a path); a token `<platform>+everywhere` is that platform with the hidden `--ownership-everywhere`. Where the chain edits lists in place (its first `"lists"`, read from the manifests) or the token says `+everywhere`, the `check` must fail, with the ownership codes alone, exactly when the report has a rejected or pending line or a `limit` line, and elsewhere it must pass (§28.10, §16.7). With a `.cached` file (its reason), each such `check` is run twice more with a cache directory of its own — writing every cache entry and summary block, then installing them — and both must agree with the `--no-cache` one (§28.4) |
| `typekeys/` | `check`, then `dump --stage=typekeys` | `<name>.typekeys` | the checker's type-key artifact (`checker-v2.md` §36): every node, the keys the module adds to the wild set, each local's key and each allocating instruction's; a project takes `_expected.typekeys`; the fixture must check clean, and a `core/` fixture is checked with `--core` |
| `repkeys/` | `build --release --rep-keys` (hidden) | `<name>.repkeys` | the representation keys a release build lowers with (`js/RepKeys.zig`, `backend.md` §9): the build's table of canonical closed types, each with what it is at run time and whether it is in the wild set, then per module every name and node lowering keyed; a project takes `_expected.repkeys` and may carry a `platform/` of its own; `repkeys/inline/` builds for `browser-inline`; the build must say nothing |
| `check/bad/` | `check --diagnostics=json` | `<name>.diag` | must fail resolution; the **whole** diagnostic list is the golden |
| `build/bad/<Dir>/` | `build --diagnostics=json --platform=…` | `<Dir>/_expected.diag` | must fail the BUILD: exit 1, the whole diagnostic list, and no `out/` |
| `build/bad-release/<Dir>/` | the same, **plus `--release`** | `<Dir>/_expected.diag` | must build clean WITHOUT the flag and fail with it (`backend.md` §9's refusal of `Debug`) |
| `run/` | `build --platform=node`, then `node out/_main.mjs` | `<name>.expected` | **the second boundary**: the emitted program's stdout |
| `run/`, with `<name>.requests` | `build --platform=node`, then `node tests/serve/driver.mjs out/_main.mjs <name>.requests` | `<name>.expected` | a server program driven by the script: the transcript of its answers, then its streams and exit (*A server program*) |
| `browser/` | `build --platform=tests/platforms/page`, then the program in a page, driven by `<name>.steps` | `<name>.expected` | the second boundary in a DOM: the page after the load and after each step |
| `workers/` | `build --platform=cloudflare`, then `node tests/workers/driver.mjs out _expected.steps` under Miniflare | `_expected.expected` | a Worker (`boundary.md` §9.12 (k)): the transcript of each request's answer and the Worker's console; projects only, two cases each (the development build, and `--release --allow-debug` with its own `_expected.release-run-hash`); not a gate — `zig build test-workers` in `nix develop .#workers` (*A Worker*) |
| `regress/` | as above, by subdirectory | as above | named after the bug they pin, e.g. `Shadowing2.beni` |

**Warnings on a fixture that compiles.** A `check/good/`, `writes/`,
`emit/`, `run/` or `browser/` fixture must compile silently, unless it
carries a `.diag` golden (`_expected.diag` in a project): then the warnings
its compile prints are compared with it byte for byte, and a `.diag` on a
fixture that compiles silently is refused. It exists for a program that
means what a warning is about — a fixture that prepends in a loop on
purpose meets `prepend_in_loop` (`checker-v2.md` §35) — so the warning is
pinned rather than hidden.

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
`--platform=node`; there is no per-fixture flag file. Under
`build/bad/workers/` the build takes `--platform=cloudflare`: that
platform's own refusals, such as an object's `tick` that may wait
(`boundary.md` §9.12 (e.5)), which the `workers/` kind cannot hold. That kind exists
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
A line of `tests/blackbox/run-hashes.txt`, a program a black-box scenario
runs, covers the same things: the emitted output tree, the expectation
written in the test and the Node version. A script that lives in the
project directory rather than in that tree contributes its own bytes, and
the rest of the project, `.beni-cache` included, contributes nothing.

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

### A server program

A `run/` fixture with a `<name>.requests` script (`_expected.requests` in a
project) is a server (`boundary.md` §9.10 (h)). Each of its two builds is
run by `node tests/serve/driver.mjs out/_main.mjs <name>.requests` in the
project directory, instead of by `node out/_main.mjs`, and the driver's
transcript is the golden. The driver starts the build as a child with
`tests/serve/preload.mjs` imported first, which writes the address of each
server the program binds to a pipe (file descriptor 3). So a fixture
listens on port 0, the driver learns the port from the pipe, and **the port
never appears in the transcript**. The script is one JSON object per line,
`#` for a comment:

    {"method": "GET", "path": "/items?limit=3", "headers": {"accept": "text/plain"}, "body": "…"}
                                a request to the program, printed as `> GET
                                /items?limit=3`, its headers as `> name:
                                value` (a value that is a list is one header
                                line per entry), then a blank `>` line and the body,
                                one `> ` line each, when there is one; the
                                answer is `< 200`, each response header as
                                `< name: value` in the order received with
                                `date` left out, then a blank `<` line and
                                the body lines; a request the client cannot
                                complete prints `< (error ECONNRESET)`, with
                                Node's code; one unanswered for 5 s prints
                                `< (no response in 5000 ms)`
    {…, "detach": true}         the same request, not waited for: its answer,
                                or `(error …)` when its connection ends, is
                                printed after the last step under
                                `--- detached ---`, in completion order
    {…, "abort": true}          the same request, sent and then given up on
                                at once: the server sees a client that left
                                before it answered
    {"raw": "GARBAGE\r\n\r\n"}  those bytes on a new connection; prints
                                the first line of the answer and `(closed by
                                the server)`
    {"cut": {"path": "/x", "declared": 10, "body": "abc"}}
                                a request whose body stops short: the headers
                                with that `content-length`, the body given,
                                then the connection closes
    {"signal": "SIGTERM"}       the signal, to the program

A script also drives WebSocket clients (`boundary.md` §9.11 (l)), each with a
name, through the driver's own small RFC 6455 client, which prints the
handshake and can send the frames no conforming client sends. What the server
sends a socket is kept, in order, until a `receive` step takes it, and a close
frame the server sends first is answered at once with the same code, as a
browser answers one:

    {"socket": "a", "path": "/arena", "protocols": ["v1"]}
                                open socket `a`: `> (socket a) GET /arena
                                ["v1"]`, then the answer as a response is
                                printed, each line `< (socket a) …`, a 101's
                                `sec-websocket-accept` checked and shown as
                                `(the right key)`. Optional: `"method"`,
                                `"http": "1.0"`, `"host": false` (no `host`
                                header), `"upgrade"` (the header's value),
                                `"version"`, `"key"`, `"headers"`, and
                                `"wait": false`, which does not wait for the
                                answer: an `answer` step prints it later
    {"answer": "a"}             wait for, and print, the answer of a socket
                                opened with `"wait": false`
    {"send": "a", "text": "hi"} a text message: `> (socket a) "hi"`
    {"send": "a", "repeat": 300, "bytes": 1024}
                                300 messages of 1024 bytes, `<i> ` then `x`s,
                                in one write
    {"send": "a", "frame": {"opcode": 1, "text": "x", "fin": false, "mask": false, "rsv": 4, "hex": "…", "length": 9}}
                                one frame as written, for a fault: the
                                payload is `text` or `hex`, `length` the
                                length the header declares
    {"ping": "a", "text": "p"}  a ping; its pong is a message, `pong "p"`
    {"close": "a", "code": 1000, "reason": "bye"}
                                a close frame (no code when `code` is left out)
    {"receive": "a"}            the next thing socket `a` got: `< (socket a)
                                "text"`, `close 1000 "reason"`, `close (no
                                code)`, `pong "…"`, `binary <n> bytes` or `(the
                                connection ended)`; `(nothing arrived)` after
                                5 s
    {"receive": "a", "count": 128}
                                the next 128 text messages, summed up as
                                `128 messages, <bytes> bytes`
    {"receive": "a", "until": "drained"}
                                every message up to the first that is the
                                text, which is printed after `… `
    {"pause": "a"}, {"resume": "a"}
                                stop and start reading the socket
    {"drop": "a"}, {"reset": "a"}
                                end the TCP connection, with a FIN or with a
                                reset, and no close frame
    {"page": "<entry.mjs>", "steps": "<file.steps>"}
                                run a page program under the page driver
                                (happy-dom), opened from this server with
                                `--server`, and print its transcript, each
                                line `| …`; with `"wait": false` it runs
                                beside the next steps, and with
                                `"wait-handshakes": true` the page driver
                                has `--wait-handshakes`
    {"page-wait": "<step>"}     wait, 5 s at most, until the page has run
                                that line of its script; the wait uses the
                                lines up to it, so a second wait for the
                                same line waits for the next one, and a
                                page that ended stops the wait at once
    {"page-end": true}          wait for the page to end, 20 s at most,
                                then stop it; print its transcript

A `{"fault": "socket:EIO"}` step, first in a script, makes the first socket
the program upgrades fail, as Node fails one (`error`, then `close`), with
that code after the client's first bytes: how a fixture reaches a network
failure, named or not. `socket:errno=ENETRESET` gives the error only that
number, with the `code` Node gives a number libuv does not name, as on
macOS and the BSDs.

After the last step the driver waits up to 5 s for the program to exit, then
prints `--- stdout ---`, `--- stderr ---` and `--- exit <code> ---` (or
`--- exit signal <name> ---`, or, after a SIGKILL, `--- exit killed: still
running after the last step ---`). Standard error goes through one filter,
so a crash is deterministic: the project directory's absolute path becomes
`<project>`, lines that start with `    at ` are dropped, and the
`Node.js v…` line is dropped. An IPv4 address before a `:port` becomes
`<address>`, and so does any quoted value of an indented `address:` line of
an error's properties; an IPv4 address anywhere else stays as it is. The
bound port after an IPv4 address, or on an indented `port:` line, becomes
`<port>`; any other port stays as it is, so a line that names the wrong
port differs. A `logfmt` line with `timestamp` first, the one `Io.run`'s
sink writes, has its time as `timestamp=<time>`. The driver connects to
`127.0.0.1` only, so a served fixture listens on `127.0.0.1`: an IPv6
address stays in the transcript, except as the value of an `address:` line.
The driver exits 0 whatever the program did; what it did is the
transcript. A served fixture has no `.crash`: the crash is in the
transcript.

The record line (`.run-hash`) of a served build is `<pass> <node version>
serve <sha-256>`: the digest covers what a `run/` one covers, and the
driver's bytes, the preload's and the script, so a change to any of them
runs the program again (`tests/blackbox/serve.zig`).

### A program whose schemas are all compiled

A `run/` or `browser/` fixture with a `<name>.compiled-schemas` file
(`_expected.compiled-schemas` in a project) asserts `schema.md` §6's guarantee,
*A statically known schema runs compiled*. Every schema it builds is fixed at
compile time, so its development build must ship no library interpreter,
whichever of the runners and `describe` it calls:
`_core/Schema.mjs` must declare neither `Schema$run`, which every interpreting
runner calls, nor `Schema$box`, the one maker of an `Interpreted` schema. The file's
text says why the fixture qualifies. Like `.crash`, it is written by hand and
never blessed. It costs no build of its own, because it reads the output of the
development build the case already makes. Conduit's pages and the schema
fixtures that build only compiled schemas carry one.

### A Worker

A `workers/` fixture is a project built for the `cloudflare` platform
(`boundary.md` §9.12): its modules, a `beni.json` whose `"exports"` lists the
Durable Object classes, a `wrangler.jsonc` as the author writes it (§9.12 (i);
the driver maps `compatibility_date`, `compatibility_flags`, `vars` and
`durable_objects` with `migrations` to Miniflare's options), and an
`_expected.steps` script. Each of its two cases — the development build, and
the release build — is run by `node tests/workers/driver.mjs
--miniflare=<index.js> out _expected.steps` in the project directory, under
Miniflare (the `workerd` nixpkgs' `wrangler` carries; `nix develop .#workers`
sets `BENI_MINIFLARE`), with `cf: false`, on 127.0.0.1, disposed at the end.
Nothing is deployed and no account is used. The transcript is the golden,
`_expected.expected`; the port never appears in it. The two run-hash
records of a project are written by `zig build test-run-hashes
-Dcorpus=workers` in the same shell; `zig build test-workers` only checks
them and does not read `BENI_RUN_HASHES`. The script is one JSON object per
line, `#` for a comment:

    {"method": "GET", "path": "/items?limit=3", "headers": {"accept": "text/plain"}, "body": "…"}
                                a request, printed as `> GET /items?limit=3`,
                                its headers as `> name: value`, a blank `>`
                                line and the body when there is one; the
                                answer `< 200`, each header `< name: value`
                                sorted by name as the host keeps them, a
                                blank `<` line and the body lines; one
                                unanswered for 5 s prints `< (no response in
                                5000 ms)`
    {…, "detach": "long"}       the same request, not waited for, named
    {"answer": "long"}          wait for, and print, a detached request's
                                answer, each line `(long) < …`; one still
                                pending after the last step is printed then,
                                under `> (answer long, at the end)`
    {…, "abort": 20}            sent, then given up on after 20 ms; under
                                Miniflare the Worker's client is Miniflare's
                                own entry worker, so `request.signal` never
                                fires here (§9.12 (k), #600)
    {"socket": "a", "path": "/arena/x", "protocols": ["v1"]}
                                open a WebSocket client named `a` with the
                                `ws` library Miniflare carries, on the
                                Worker's port: `> (socket a) GET
                                /arena/x ["v1"]`, then the 101 and its
                                headers as `(socket a) < …`, or the refusing
                                response the same way; what the server sends
                                is kept, in order, until a `receive` step
    {"send": "a", "text": "hi"} a text message: `> (socket a) "hi"`
    {"send": "a", "binary": 3}  a binary frame of 3 bytes
    {"close": "a", "code": 4000, "reason": "bye"}
                                a close frame (no code when `code` is left out)
    {"close": "a", "frame": "03e7"}
                                a hand-made close frame, its payload in hex
                                (the code's two bytes, then the reason's), for
                                what the client library refuses to send: a
                                code outside 1000-4999, a reason that is not
                                UTF-8; `> (socket a) close frame 03e7`. A
                                payload over 125 bytes, or one that is not an
                                even count of hex digits, is a script error:
                                the driver stops with exit 2 and names the step
    {"drop": "a"}               end the connection with no close frame
    {"idle": 16000}             no event for 16 s, past the 5 s step limit,
                                for what the host does on its own clock:
                                hibernate an idle object; `> (idle 16000
                                ms)`. A count that is negative or not an
                                integer, a script whose idle steps sum over
                                60 000 ms, or an idle step with another key
                                is a script error, before anything runs
    {…, "until": "closed p2"}   any step but `idle`: wait for a console line of the
                                Worker that holds the text before the step
                                ends, since a line an object writes from a
                                socket event has no order with the mark;
                                `(no line "…" in 5000 ms)` otherwise, one
                                line on standard error names it, and the
                                run fails
    {"receive": "a"}            the next thing socket `a` got: `< (socket a)
                                "text"`, `close 1000 "reason"`, `binary <n>
                                bytes` or `error …`; `(nothing arrived)`
                                after 5 s
    {"receive": "a", "count": 3}
                                the next 3 text messages, summed up as `3
                                messages, <bytes> bytes`

After each step the lines the Worker wrote to its console follow, `| out:
…` and `| err: …`: the driver asks the Worker's test hook `/__beni/mark/<n>`
after each step and waits for its line, so a step's lines never land under
the next; the host's stack lines (`    at …`) are left out, since they hold a
store path. A request forwarded to a Durable Object whose path ends in
`/__beni/tick` fires the object's timer (a `ticked` event; 204, or 409 when
no timer is armed), and one ending in `/__beni/alarm` runs its `alarm`
(204); under `--test-hooks` the object arms no host timer. Each of the two
cases starts Miniflare once.

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
    mouse <selector> <name>     a bubbling `MouseEvent` of that name
                                (`mouseover`, `mouseout`, `mousemove`, …),
                                button 0
    drag <selector> <name>      a bubbling drag event of that name
                                (`dragstart`, `drag`, `dragenter`,
                                `dragover`, `dragleave`, `drop`,
                                `dragend`): a `MouseEvent` in both DOMs,
                                with no `dataTransfer`, cancelable but for
                                `dragleave` and `dragend`; one whose
                                default a handler prevented logs
                                `(drop's default prevented)` (or its name's)
    pointer <selector> <name> [<x> <y>] [id:<n>] [type:<t>] [secondary] [box:<selector>]
                                one `PointerEvent` of that name
                                (`pointerdown`, `pointermove`, `pointerup`,
                                `pointercancel`, `pointerenter`,
                                `pointerleave`, `pointerover`,
                                `pointerout`) at the point `x`, `y`
                                (default 0 0), CSS pixels from the top-left
                                corner of the `box:` element's border box
                                (default the element itself; a selector
                                with no spaces); `pointerId` `n` (default
                                1), `pointerType` `t` (`mouse`, the
                                default, `pen`, `touch`, or `none` for
                                `""`), primary unless `secondary`. It bubbles and
                                is cancelable as the standard fires it:
                                `pointerenter` and `pointerleave` do
                                neither, `pointercancel` does not cancel.
                                One whose default a handler prevented logs
                                `(pointerdown's default prevented)` (or its
                                name's). happy-dom has no layout, so every
                                box is at 0 there and only Chrome shows a
                                handler converting the point to its own
                                box: name the point in the box of the
                                element that has the handler, and both DOMs
                                print the same transcript
    press <selector>            a user's click: trusted (below), in two
                                tasks — `pointerdown` and `mousedown`,
                                whose default focuses the nearest focusable
                                element the press is in (or takes focus from
                                the one that has it), then, the page
                                settled, `pointerup`, `mouseup` and
                                `click`; a listener the driver added on the
                                window, after every listener of the page,
                                logs `(a later listener ran)`. In Chrome the
                                press is at the element's centre, and a step
                                whose element is covered there — by a crash
                                screen, say — fails: no user could press it
    focus <selector>            `.focus()`
    blur <selector>             `.blur()`
    advance <ms> [tasks]        move the page's virtual clock on by `ms`,
                                firing each timer that comes due, earliest
                                first, the page settling after each as a
                                step's page settles (*The page's clock is
                                virtual*), before the next fires; with
                                `tasks`, `(the timer's task ended)` is
                                logged as each timer's callback returns,
                                before any microtask it queued; a callback
                                that throws is reported to the window's
                                `error` listeners, as a host reports it
    frame <n> [<ms>] [tasks]    draw `n` virtual frames, each `ms` (default
                                16) after the one before: the clock moves on
                                as `advance` moves it, then the callbacks
                                `requestAnimationFrame` was asked for before
                                the frame began run in one task, in the
                                order asked, each handed the frame's time;
                                one asked for while they run is the next
                                frame's. Each frame logs `(frame at <t> ms:
                                <k> callbacks)` before they run, `k` those
                                asked for before it began (one an earlier
                                callback cancels is counted, and does not
                                run); with `tasks`, `(the frame's
                                task ended)` is logged as its callbacks
                                return, before any microtask they queued;
                                the page settles after each frame, as after
                                a timer, before the clock moves on
    frames                      log `(frames: <n>)`, the frame callbacks
                                asked for and neither run nor cancelled
    event <window|document|selector> <name> [<n>]
                                `n` (default 1) plain `Event`s of that
                                name on the window, the document or the
                                element, in one task
    detail <window|document|selector> <name> <json>
                                one `CustomEvent` of that name whose `detail`
                                is the JSON value, as a host page pushes data
                                to a program (`Push.onPush`'s `rr-push`)
    stop                        the entry file's `stop` (`boundary.md`
                                §9.4.5, amended 2026-10-17), the page's
                                unmount; logs `(stopped)`
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
    element "<id>"              as a step before the program loads: a `<div>` of
                                that id in the body, for a program `mountAt`
                                places there
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
                                chunk in a task of its own, the page
                                settling before each chunk and before the
                                end; with `open` the body never ends, as a
                                stalled server's;
                                answering a request the page aborted logs
                                `(fetch <n> was aborted: nothing hears the
                                answer)`
    fail <n>                    reject the `n`-th request with `new
                                TypeError("Failed to fetch")`, the Fetch
                                standard's network error
    socket <n> open ["<protocol>"]
                                the `n`-th WebSocket the page made opens,
                                with that subprotocol (default none); the
                                protocol must be one the page offered, and a
                                page that offered some must get one, since a
                                host fails any other handshake
    socket <n> message "<text>" the server sends a text message
    socket <n> binary <bytes>   the server sends a binary message of that
                                many bytes
    socket <n> close <code> "<reason>"
                                the server's close frame: `close`, clean
    socket <n> fail             the connection fails: `error`, then `close`
                                with 1006, not clean
    socket <n> error-only       the connection fails as WebKit fails one:
                                `error`, and no `close`
    socket <n> buffered <bytes> what the page sent and the host did not:
                                the socket's `bufferedAmount`
    socket blocked              the next `new WebSocket` throws a
                                `SecurityError`, as a browser's does for an
                                insecure socket from an `https:` page
    sockets                     log `(sockets: <n>)`, the sockets the page
                                made and has not closed
    socket <n> wait <k>|open|closed
                                with `--server` only: give the page what
                                the host's socket did, one event at a time
                                in order, until the socket has received
                                `k` messages in all, has opened, or has
                                closed; wait for the next event in real
                                time, 5 s at most
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
`clearTimeout`, `setInterval`, `clearInterval` and `Date.now` before the
program loads: `Date.now()` is 0 until an `advance` step moves it, and a
timer fires only when an `advance` step reaches its time — an interval at
each of its times, as one timer that `timers` counts once — so a debounce of 250 ms costs no wall-clock time and
a fixture about timing is deterministic in both DOMs. So are the page's
frames: the driver replaces `requestAnimationFrame` and
`cancelAnimationFrame` too, in Chrome as in happy-dom, and a callback runs
only when a `frame` step draws a frame — so a fixture counts the frames a
page asks for, and an idle page's `frames` reads 0
(`browser/tea/AnimationFrames`, `boundary.md` §9.8.18 (g)). `advance` and
`frame` settle the page, as below, after each timer they fire and after
each frame `frame` draws, before the clock moves on or the next timer
fires: the work a timer or a frame set going runs with the clock at its
time, and may set the next timer (`browser/tea/AdvanceSettlesEachTimer`).
A streamed `respond` settles the page before each chunk and before the end
of the body, so the work one chunk set going, and the work that work
queues, runs before the next chunk arrives
(`browser/tea/RespondSettlesEachChunk`).

**A step's page is the page once all the work core's scheduler queued for
the step has run, in both DOMs.** The driver does not wait for work a page
starts outside that scheduler: a `window.postMessage`, a
`BroadcastChannel`, a worker's reply or a `requestIdleCallback`. A page has
settled once its microtasks have run and a turn of the event loop has
passed with no continuation of core's scheduler left to run. The scheduler
runs 64 tasks a turn and goes on in a `setImmediate` under happy-dom, and
in a message to a `MessagePort` in Chrome, which has no `setImmediate`; so
the driver takes more turns while a `setImmediate` is pending, or while a
message the page posted to a `MessagePort` is not yet delivered, which the
driver counts from the post to the delivery. A step that starts more
fibers than 64 therefore shows them all run
(`browser/tea/SettlesManyFibers`).

After 1 000 turns the driver stops waiting and fails the step: `Error: the
page still had a setImmediate to run after 1 000 turns` (`a message to
deliver` in Chrome), `core's scheduler never ran dry` — a `throws` step
too, which does not take the cap for the throw it expects. The step fires
no later timer, frame or chunk, and a later settle of that page waits one
turn, so a page that keeps the scheduler busy forever costs one capped
settle — about 4 s in Chrome, which holds a nested timer to 4 ms — and not
one per timer. (Such a page also grows core's queue without end, and V8
refuses the queue's array, `RangeError: Invalid array length`, after a few
seconds of work.) A message that is never delivered keeps the count above
zero, so the next settle reaches the cap. Five things leave a message
undelivered: a port the page never starts, a port closed (`close()`) with
a message still queued, a post on a closed port, a post after the other
port closed, and a post to a port that was transferred, whose new object
the driver does not listen on. The count holds only while the ports stay
in the page, so a post that transfers a counted port — to a worker, a
frame, another port or `structuredClone` — fails the step at once. A
message event a script dispatches is not a delivery, and a message that
arrives with nothing counted fails the step. A service a program waits on
(`Http`, a search API) is faked with a record of functions that sleep on
this clock (`boundary.md` §9.8.9).

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

**The page's `WebSocket` is scripted** (`boundary.md` §9.11 (l)), as its
`fetch` is, in both DOMs. Each `new WebSocket` is logged as it is made —
`(socket <n>: <path> [<protocols>])`, the path alone when the socket's host
is the page's — and stays connecting until a `socket <n> open` or `socket
<n> fail` step answers it. What the page sends and closes is logged:
`(socket <n> sent: "<text>")`, `(socket <n> close: <code> "<reason>")`, and
`(socket <n> close)` for a close with no code. The constructor, `send` and
`close` throw what the standard says they throw for what they are handed,
so a platform that hands the host something it refuses meets the host's
own exception. A message that arrives while the page closes the socket is
dropped, as the host drops it, and logged. A socket still open when the
script ends is not a failure: a page that keeps one is the normal case. Chrome ends a connection whose
network dropped with `close` 1006 and no `error`; a script writes that as `socket <n> close 1006
""`, which is clean, since the page module does not read `wasClean`.

**A page against a real server.** With `--server=127.0.0.1:<port>`
(happy-dom only), the page driver opens the page from that address and gives
it happy-dom's own `WebSocket` (which wraps the `ws` library) in place of the
scripted one, so a socket the page opens to `/chat` reaches the server there.
Node's `WebSocket` (undici) cannot serve, because it calls `unref` on what
`setTimeout` returns, and the page's virtual clock returns a number. Each socket is still
numbered and logged, and the scripted `socket` steps are refused. What the
host's socket does is held, in order, and reaches the page only in a `socket
<n> wait` step, each event in a task of its own, so a snapshot never depends
on when the server answered. The socket's `bufferedAmount` is the host's at
the time the page reads it, so no golden shows it (#632).
`--wait-handshakes` tests that: after each step, the driver waits until the
host has answered every socket's handshake, and lets the page settle again
before the snapshot. The line of each step the driver has run goes to file
descriptor 3. The serve driver's `page` steps start it so, with the program
under test's port (`tests/blackbox/chat_example_test.zig`, `boundary.md`
§9.11 (l)).

**The page never leaves its document.** A navigation the page starts to
another document — `location.assign`, `replace` or `reload`, a write to
`location.href`, and so a successful `load` — is stopped as it starts and
logs `(the host leaves the page for "<url>")`, the address written as the
fetch log writes one; the address stays, and no event of the page's
fires — Chrome's Navigation API reports the cancel, `navigateerror` with an
`AbortError` on `navigation`, which no platform reads
(`browser/tea/NavigateCommandsLeave`). A navigation inside the document (a
fragment, `pushState`) runs as the host runs it. Chrome would load the new
document, which the driver cannot follow, and happy-dom, whose window
loads nothing, would change only the address. The page's history begins
at the page in both DOMs, so a `back` past its first entry does nothing.
A refused `load` is a value and is shown.

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
need neither a browser nor the network. *Added 2026-10-18:* happy-dom's HTML parser closes
elements the standard leaves open, so the driver, given `--parser=tests/browser/parse5.mjs` (the
harness always gives it under happy-dom), builds the tree of every `insertAdjacentHTML` string
with parse5, the standard's algorithm: a page then shows the tree a browser builds
(`browser/inline/EndTags`). `tests/browser/vendor-parse5.sh` bundles it, offline, from a local
npm install, checksummed and pinned like happy-dom. Compiling it costs about 100
million instructions, so the driver keeps V8's code cache in the
checkout's `zig-out/browser-driver-cache/` — never in `/tmp`, where every
worktree's copy of happy-dom was an entry of its own and the cache once
filled the disk. Node keys an entry by the file's path, and each page
program is compiled from a directory no later run repeats, so the driver
prunes the cache as it starts (`tests/browser/compile-cache.mjs`): once it
holds more than 1 024 entries, it removes the old ones — those older than
an hour — among the first 128 it reads. A run never reads more than 1 025
names, so what a page spends on pruning does not grow with the cache: a
fuzz sweep leaves about 116 000 entries, which the gates' runs then clear
128 at a time. Deleting the directory is always safe; a missing entry is
compiled again. `zig build test-browser` runs the
same fixtures in one headless Chrome (a fresh target per page) against the
same goldens; Chrome comes from `-Dchrome=` or `PATH` (`nix develop
.#browser`). `tests/blackbox/browser.zig` has the measurements behind the
choice. Where the two DOMs are known to differ, a fixture that reaches the
difference carries a `<name>.chrome-expected`, which `test-browser`
compares instead of `.expected`. The differences known today:

- the HTML parser: after a misnested `</p>` (`<p><div></div></p>`),
  Chrome makes an empty `<p></p>` and happy-dom does not; and inside an
  SVG `<foreignObject>`, an HTML integration point, Chrome makes HTML
  elements and happy-dom SVG ones (`browser/dom/SvgDrawing`);
- event loop order: the page runs on Node's event loop, so the order of
  timers, `MessageChannel` messages and I/O against each other is Node's;
  a fixture about scheduling order belongs to `test-browser`. Frames are
  not among the differences: both DOMs draw only the driver's virtual
  frames (`frame`);
- layout: happy-dom lays nothing out, so sizes and positions are zero;
- CSS values: a property the page sets through `style.setProperty`
  goes back into the `style` attribute as each DOM serialises it. A
  colour is `rgb(…)` in Chrome and as the page wrote it in happy-dom
  (`browser/tea/BikeWars`: `#222` is `rgb(34, 34, 34)` in Chrome). A
  number has at most six decimals in happy-dom, as CSSOM says, and six
  significant digits in Chrome (`browser/tea/Sternhalma`:
  `275.75128869403574px` is `275.751289px` in happy-dom and `275.751px`
  in Chrome). Chrome writes a large number with an exponent:
  `1234567.5px` is `1.23457e+06px`, and happy-dom keeps it;
- leaving the page: happy-dom sees only a navigation through `location`,
  so a form's submission, `window.open(url, "_self")`, a link activated
  outside the `click` step (a `press`, a script's `a.click()`) and
  `history.go(0)` do nothing there, where Chrome logs `(the host leaves
  the page for …)`; for a navigation to a fragment the page makes, Chrome
  fires `popstate` and happy-dom does not, so a follower of the address
  hears it in Chrome only (`browser/tea/NavigateFragment` has none); and
  for an empty fragment (`#`), Chrome adds the `#` to the address and
  fires `popstate` and `hashchange`, and happy-dom does nothing at all —
  the `location` step prints the same, since `location.hash` is `""` in
  both;
- steps dispatch untrusted events in both DOMs, and `key` types nothing —
  except `press` and the focus events a `focus()` or `blur()` call fires,
  which are trusted as Chrome makes them: Chrome's `press` is its own
  click, sent through `Input.dispatchMouseEvent`, and happy-dom, which has
  no `isTrusted`, is given one that is true for exactly those. The
  emulation is dispatched from the driver's stack, so where Chrome runs
  microtasks between two listeners of a user's click, happy-dom does not:
  a fixture shows what the runtime does at a listener's end, not what the
  host does after it. A microtask a click's listener queues therefore runs
  before `(a later listener ran)` in Chrome (HTML's microtask checkpoint
  after a callback the host ran) and after it under happy-dom
  (`browser/tea/FocusInFlush`);
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
fixtures built the same way, the shapes of what the lowering emits, and
`emit/release/tea/` holds release applications built for `browser-tea`,
their golden `_main.mjs` whole. The
steps, the transcript, the run hashes and `test-browser` are the kind's
own. The differential oracle against dom-expressions' fixtures is a
separate, DOM-free comparison of template strings and walks:
`tests/oracle/`, run by `tests/blackbox/oracle_test.zig`.

**The `direct` lowering was retired on 2026-10-19** (issue #423) with the `browser-direct`
platform; git history is the reference. Its pages are `browser/tea/` pages, built for
`browser-tea` alone; its ownership fixtures read on `browser-inline` or
`browser-tea+everywhere`; its refusals that are not the lowering's are under
`build/bad/inline/`, `build/bad/everywhere/` and `check/bad/inline/`.

**The `inline` lowering's fixtures** (`docs/design/browser-inline.md`) are
under `inline/` of four kinds, built with `--platform=browser-inline`, or for
a project's own `platform/` layered on it: `emit/inline/` and
`emit/release/inline/` application builds, their goldens in tea-inline's
shape (the release file whole, so a byte of `core/Task`, `core/Dict` or a
message object that creeps in shows); `build/bad/inline/` projects for what
the lowering refuses, each class of `browser-inline.md` §5; and
`browser/inline/` pages, built for that platform alone, development and
release.

Every enforcing `build/bad/` project is also checked for its release refusal
— under `inline/`, on a project's own `platform/`
whose chain edits lists in place, and under `everywhere/`: built again with
`--release --allow-debug`, it must be refused with the same diagnostics and
nothing written (`--allow-debug` because `Debug`'s own refusal is
`build/bad-release/`'s claim). `check/bad/inline/` fixtures are checked with
`--platform=browser-inline`, so the ownership checker enforces there.

**`build/bad/everywhere/`** projects are built for `browser-tea` with the
hidden `--ownership-everywhere` (`ownership-checker.md` §30.7): the ownership
checker's refusals on a platform that edits nothing in place, apart from any
lowering's. One whose golden holds only the ownership checker's codes is also
built without the flag, which must succeed silently (§28.10).

**The page fuzzer** (`docs/design/browser-direct.md` §8.3 and its
2026-10-09 amendment, `tests/browser/fuzz.mjs`) runs on every
`browser/tea/` page, its development build against its release build: one
seed of thirty random steps, the two pages compared after each — the body,
the properties it does not print, the title, the address, the storages,
every logged line but those the pair may differ on, the errors — in the
driver's process after the fixture's pages. A difference fails the case
with the seed, the step, the sequence shrunk, and what differs; a
sequence of view events is printed as a `.steps` script, the red-first
fixture of the defect. A fuzz that agreed is the `fuzz` line of the
fixture's run hash. `zig build fuzz` runs fifty seeds of sixty steps.
A `browser/tea/` page that carries a `.fuzz-run-hash` (create it empty,
then `zig build test-run-hashes`) has a value-fuzz case of its own,
`<page> [value fuzz]`, budgeted apart from the page's: it builds the two
`--fuzz` builds, development and release, dumps the message types and
fuzzes them, messages as values included, and records its line in
`<name>.fuzz-run-hash` (`_expected.fuzz-run-hash` in a project), beside
the page case's own fuzz of view events (`browser/tea/TypedInput`).

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

## Hang guard

Every corpus case has its own 120-second wall-clock timeout, including each
value-fuzz or platform case independently. A timeout fails and names the case.
A corpus kind is a suite and has no shared deadline. Performance claims belong
in `test-perf` and `bench`.

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

Ownership-report projects may also use `_expected.sources` for an unchanged
external application. The enforcing `check` and ownership dump use that same
source directory and the project's `.platform` entries; the intent `.beni`
file only lets the walker discover the project. Conduit pins its complete
report this way, independently of its still-pending document helper lowering.
