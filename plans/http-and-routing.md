# HTTP v2 and routing — the slice plan

*Written 2026-10-01.* The contract is [`boundary.md`](../docs/design/boundary.md) §9.8.12 (HTTP,
version 2) and §9.8.13 (routing: `Url.Parser`, `Url.Builder`, `Browser.Navigation`,
`Tea.application`), with [`frontend.md`](../docs/design/frontend.md) §10.4's amendment for deep
links. This file orders the work into slices that each land with `zig build gates` green and
their own fixtures, and lists the choices the specification took for the owner (H1–H10, §3).
It is Milestone 2's items 2 and 3 in [`status-2026-10.md`](status-2026-10.md) §6.

**Sources read.** elm/http 2.0.0 (`src/Http.elm`, `src/Elm/Kernel/Http.js`), elm/url 1.0.0
(`src/Url.elm`, `src/Url/Parser.elm`, `src/Url/Parser/Query.elm`, `src/Url/Builder.elm`), both
fetched from GitHub; `references/elm-browser` (`src/Browser.elm`, `src/Browser/Navigation.elm`,
`src/Elm/Kernel/Browser.js` — `_Browser_application`'s link guard, `_Browser_go`, `pushUrl`,
`load` — and `notes/navigation-in-elements.md`). The beni side: `platforms/browser/` (`Http`,
`Url`, `Browser/Navigation`, `Listen`, `Time`, `Cmd`, `Sub`), `platforms/browser-tea/Tea.beni`,
`core/Schema.beni`, `core/Task.beni`, `tests/browser/driver.mjs`, `tests/corpus/README.md`,
`src/devloop/Serve.zig`.

## 1. What the driver must learn first

Every slice below is tested by `tests/corpus/browser/` pages and `.steps` scripts. Today's
driver has `url`, `hash`, `key`, `click`, `advance` and a virtual clock; routing and HTTP need
five more steps. They are one slice of their own (R0) because changing `driver.mjs` changes every
browser run hash (the digest covers the driver), so the slice re-records the hashes once and the
later slices change only their own.

| Step | Does | Logs |
|---|---|---|
| `click <selector> [ctrl\|shift\|alt\|meta]… [button:<n>]` | the existing bubbling `click`, now with modifiers and a `button` (default 0) | `(click's default prevented)` when a handler or a listener prevented it, as `key` does |
| `back` / `forward` | `history.back()` / `history.forward()`, then waits for the `popstate` the traversal fires and settles. Where happy-dom's history fires none, the driver keeps its own entry list and does what `hash` does — `replaceState` to the entry, one `popstate` — and the README lists it under the known differences | — |
| `location` | nothing | `(location: <path><?query><#fragment>)`, origin left out, as the port differs per run |
| `respond <n> <status> "<body>" [<name>: <value>]…` | answers the `n`-th request the page made (1-based, in the order `fetch` was called) with a host `Response` of that status, body and headers; `url` is set on the instance to the request's | — |
| `respond <n> <status> chunks "<a>" "<b>" …` | the same, its body a `ReadableStream` that yields each chunk in a task of its own, the page settling between two | — |
| `fail <n>` | rejects the `n`-th request with `new TypeError("Failed to fetch")` — the Fetch standard's network error | — |

**The scripted `fetch`.** The prelude replaces `fetch` before the program loads, as it replaces
the clock. Each call is logged when it is made — `(fetch <n>: <METHOD> <path> <headers> <body>)`,
headers as sorted JSON with lower-cased names, the body as text (a `FormData` as its entries),
`credentials` when it is not `same-origin` — and stays pending until a `respond` or `fail` step.
An abort of a pending request rejects it with `signal.reason`, exactly as the host's `fetch` does,
and logs `(fetch <n> aborted: <reason's name>)`, so a cancelled `Restart` and a `Timeout` are both
visible in the transcript. A `data:` URL goes to the host's own `fetch` (what
`browser/tea/HttpResults` uses today). The fake builds real `Request` and `Response` objects, so
header normalisation, `ok`, `status`, `text()`, `body.getReader()` and the decoding are the DOM's
own in both happy-dom and Chrome (H5). A request still pending when the script ends is a failure of
the case, like an uncaught exception, so no fixture forgets one.

**Fixtures for R0 itself**: `browser/dom/ClickModifiers` (a handler logs the four modifiers and
the button of each click, and prevents one), and `browser/dom/ScriptedFetch` on the `page` test
platform's own `foreign` `fetch` call, proving the log, `respond`, `chunks`, `fail` and an abort
without any `Http` module.

## 2. The slices

Each slice: the spec section it builds, its fixtures (every one red before the slice), and what it
measures. Sizes as `schema.md` §16's: **S** one implementer-and-reviewer pass, **M** about two.
Every new module is beni over `Js` (`boundary.md` §4.2), catches only through `Js.catchIf` naming
each error (rule 9), and is priced with `bench/size.mjs` under `--release` against the page that
does not import it, which must not move by a byte.

### Routing

| # | Slice | Spec | Fixtures | Size |
|---|---|---|---|---|
| **U1** | **`Url` moves to core** (H7). `platforms/browser/Url.beni` → `core/Url.beni`, `fromString` over the host's `URL.parse` (H7 as amended 2026-10-02); `browser-tea` stops re-exporting `"Url"`; the browser modules import it as before | §9.8.13 (a) | `run/UrlBasics` (Node: `fromString`/`toString` on every part; the WHATWG normalisation — case, `..`, the default port, escapes, a bare `?` and `#`; user information and other schemes `Nothing`; `percentEncode`/`percentDecode` including a lone surrogate and a bad escape) — red today because a `node` program cannot import `Url`; `browser/tea/UrlAddress` unchanged | S |
| **U2** | **`Url.Builder`**, path segments encoded (H8) | §9.8.13 (b) | `run/UrlBuilder`: every `Root`, empty lists, a segment holding `/`, `?`, `#`, `%` and a space, query keys and values encoded, `int`, `toQuery []`, `custom` with a fragment | S |
| **U3** | **`Url.Parser` and `Url.Parser.Query`**, `map2`…`map8`, the two decoding changes (H8) | §9.8.13 (b) | `run/UrlParser`: Elm's own doc examples as assertions (`/blog/42`, `/tree/42`, trailing `/`, `top`, `oneOf` order, `custom` CSS file, `fragment`), a five-route table with `map2` and `map3`, a percent-encoded segment decoded, a segment that does not decode matching nothing, built-then-parsed round trips. `run/UrlQuery`: `string`/`int`/`enum` with a key missing, repeated, valueless (`?flag`), `+` as space, a bad escape skipped, `custom` with every value in order, `map2`…`map4` | M |
| **U4** | **Navigation, direct form**: `Key`, `key`, `pushUrl`, `replaceUrl`, `back`, `forward`, `load`, `reload`, `Error`, the `beni:navigate` announcement; `eachUrlChange`/`onUrlChange` hear pushes | §9.8.13 (c), all but link requests | `browser/tea/NavigatePush` (pushes and replaces from a command, `location` after each, `onUrlChange` once per push in order, two pushes in one command two messages, `back` and `forward` through the driver's history, `back key 0` nothing); `browser/tea/NavigateErrors` (`BadUrl` for an unparseable address, `CrossOrigin` for another origin, `load "javascript:…"` refused, every result shown) — `Throttled` cannot be forced in either DOM and is pinned by reading the code in review, with the post-condition check named in the slice's report; a successful `load` leaves the page, so no fixture asserts it (the README says so) | M |
| **U5** | **Link requests**: `Browser.UrlRequest`, `eachUrlRequest`, `onUrlRequest`, the guard of §9.8.13 (c) | §9.8.13 (c), *Link requests* | `browser/tea/LinkGuard`: one page of links — same-origin relative, absolute same-origin, another host, another port, `https` against the page's `http`, `target="_blank"`, `target="_self"`, `download`, a link inside a `<span>` (the composed path), a link whose own handler prevents the default; clicked plain, with each modifier and with `button:1`; each click's transcript says `Internal`/`External`/nothing and whether the default was prevented. `browser/tea/LinkOutsideMount`: a `mountAt` program follows a link in markup outside its mount | M |
| **U6** | **`Tea.document` and `Tea.application`**: `Document`, the title written in the render, `init` given the address and the key, the two subscriptions batched in, the defect at a non-`http(s)` address | §9.8.13 (d) | `browser/tea/Router` (the acceptance page: five routes from U3's parser, started at a deep link by a `url` step, a link click to each, `back`, the title after each step); `browser/tea/DocumentTitle` (a title that changes with the model, one that does not, the title and the body agreeing after a `flush`); `browser/tea/ApplicationNotHttp` — needs a driver option to start a page at a non-`http` address; if neither DOM allows one, the defect is pinned by a `build_test` assertion on the emitted check instead, and the slice says which | M |
| **U7** | **`beni serve` deep links by `Accept`** (H9) | `frontend.md` §10.4, amended | the `serve` black-box tests gain: `GET /users/jane.doe` with `Accept: text/html` → `index.html`, 200; without it → 404; `/a/b` with no `Accept` → `index.html` as before; a missing `.mjs` → 404 | S |

### HTTP

| # | Slice | Spec | Fixtures | Size |
|---|---|---|---|---|
| **R0** | **The driver** (§1 above): click modifiers, `back`/`forward`, `location`, the scripted `fetch` | — | `browser/dom/ClickModifiers`, `browser/dom/ScriptedFetch`; every browser run hash re-recorded once | M |
| **H-a** | **The request and its failures**: `request`, `riskyRequest`, `get`, `post`; `Header`; `emptyBody`, `stringBody`; `Expect x a` with `expectString`, `expectWhatever`, `expectStringResponse`; `Response`, `Metadata`; `Error` and `Problem`; steps 1–7 and table (c) of §9.8.12; the timeout. `get`/`post`/`getJson`/`postJson` of §9.8.8 are replaced and their users migrated in the same slice (`HttpResults`, `HttpDefect`, `DebouncedSearch` if it uses them, `bench/` pages) | §9.8.12 (a)–(d), (f) | `browser/tea/HttpRequestShape` (each method, headers in order, a name given twice, the program's `Content-Type` winning over `stringBody`'s, `riskyRequest`'s credentials — all read from the fetch log); `browser/tea/HttpFailures` (one row per constructor: `BadUrl` for an unparseable address and for `http://u:p@host/`, each `Problem` but `UnprintableBody` and `MultipartContentType`, `NetworkError` by `fail`, `BadStatus 404`, `Timeout` by `advance` past the timeout with the request pending and again with the body half read, a zero timeout at once); `browser/tea/HttpResponseMeta` (`expectStringResponse`: status, status text, lower-cased headers, a repeated header joined, `url`, a 404 body read); `browser/tea/HttpCancel` (a keyed `Restart` aborts the first request — `(fetch 1 aborted: AbortError)` — and its answer, given afterwards, reaches nothing); `browser/tea/HttpDefect` keeps pinning that an undocumented rejection stops the page | M |
| **H-b** | **JSON through schemas**: `expectJson` (and its `Accept`), `jsonBody` (and its `Content-Type`), `BadBody` with issues (H2), `UnprintableBody` | §9.8.12 (a), (b) step 4–7 | `browser/tea/HttpJson`: a record decoded, a body that is not JSON (`ParseFailed`), a body missing a field (`MissingKey` at its path), a 500 with a JSON body (`BadStatus`, not `BadBody`), a request body printed with a renamed key, one holding `NaN` refused before anything is sent (no fetch logged). Measured: the page against `HttpRequestShape`'s, the difference being the schema engine | S |
| **H-c** | **Multipart and progress**: `multipartBody`, `stringPart`, `MultipartContentType`; the tracker, `Progress`, `fractionSent`, `fractionReceived` | §9.8.12 (b), (e) | `browser/tea/HttpMultipart` (the parts in the fetch log, no `Content-Type` of the program's, the refusal); `browser/tea/HttpProgress` (a `chunks` answer of three chunks with and without `Content-Length`, each `Progress` sent as a message in order with the answer last, a `HEAD` with a `null` body, the fractions shown, a `Content-Length` smaller than the bytes received clamped to 1) | M |

**Order.** R0 first (U4–U6 and H-a–H-c need it); U1 → U2 → U3 need nothing of it and can run
beside it. Then U4 → U5 → U6, and H-a → H-b → H-c, the two chains in parallel worktrees (they touch
different modules; both touch `browser-tea`'s re-export list, a one-line merge). U7 any time. The
milestone's acceptance is U6's `Router` page plus a page that logs in with a bearer token from a
`post` and lists items with a `get` — `browser/tea/ApiAndRoutes`, added with whichever of U6 and
H-b lands second.

**Measured per slice** (`bench/size.mjs`, `--release`, brotli 11): the empty `Tea.element` page
must not move; a page importing the new modules and calling nothing must equal it; and each slice
records its own page's size and, for H-a, what a `get` with `expectString` costs over §9.8.9's
`Http` + `Time` page. No speed claim is needed (no hot path is added), but U5 records the cost of
the window `click` listener per click under happy-dom, as §9.8.10 did for the key handler.

## 3. Choices the specification took for the owner

Each is written into the spec as recommended. **Confirmed by the owner on 2026-10-02, all ten as
recommended, with one amendment to H7:** `Url` stays in core, but `Url.fromString` wraps the
host's WHATWG `URL.parse` (`new URL` inside a `Js.catchIf` that takes only `TypeError` where the
engine has no `URL.parse`) instead of the hand-written port of Elm's splitter, so beni sees the
address exactly as the browser navigates to and fetches it — scheme and host lower-cased, `..`
resolved, the default port dropped, escapes added. Elm's `Url` record stays, and so does its
`Nothing` for anything not `http`/`https`. `Url.Parser`, `Url.Parser.Query` and `Url.Builder`
stay beni code (`URLSearchParams` and `encodeURIComponent` may serve the builder and the query
parser where measured smaller or faster). `boundary.md` §9.8.13 (a) carries the amendment.

| # | Choice | Recommended (in the spec) | Alternative |
|---|---|---|---|
| **H1** | Which form gets Elm's names in `Http` | The **direct form**: `Http.get { url, expect } : Result x a` (suspends), `Expect x a` carrying the error type (Elm's `Resolver x a` under `Expect`'s names); the command form is `Cmd.task`/`Cmd.keyed` over it, as §9.8.11 says for every capability | Elm's names on command-returning wrappers (`Http.get : { url, expect : Expect msg } -> Cmd msg`) and the direct form as Elm's `Http.task` with `Resolver` — two parallel APIs to keep in step |
| **H2** | What `BadBody` carries | `BadBody (List Schema.Issue)`: typed, with each issue's path and code; text via `Schema.formatIssues` (schema S12) | Elm's `BadBody String`, the issues formatted by `Http` |
| **H3** | A forbidden request header (`Cookie`, `Host`, `Sec-…`) | Refused before sending: `BadRequest (ForbiddenHeader name)` — the host would drop it silently, a silent wrong answer | Pass it to the host and let it be dropped, as Elm and `fetch` do |
| **H4** | Upload progress | `fetch` everywhere; `Sending` reported coarsely (0, then all, when the answer's headers arrive), said so in the docs | Use `XMLHttpRequest` for a request whose tracker is set, for real upload progress — a second transport to keep in step with the first |
| **H5** | How page tests fake the server | The driver's scripted `fetch` building the DOM's own `Request`/`Response`, answered by `respond`/`fail` steps, on the virtual clock, identical in happy-dom and Chrome | A real HTTP server in the driver (Chrome already has one): real CORS and cookies, but timing is the network's and happy-dom's `fetch` would need the server too |
| **H6** | Elm's `Key` | Kept, opaque; `key ()` public; every push and replace **announced to every follower**, which is what closes the desync Elm's key fenced; the TEA test driver will replace the key to fake navigation | Elm's rule (only `Tea.application` mints a key) — then a program not on TEA cannot navigate, contradicting "TEA is a framework on top of beni"; or `browser-platform.md` §2.7's plain capability record |
| **H7** | Where `Url`, `Url.Parser`, `Url.Builder` live | **core**: pure, no page needed; a library or a Node program can use them | Keep them in `browser` with `Url` today; a later move breaks imports |
| **H8** | Percent decoding and encoding | Decode path segments in the parser; `+` is a space in a query; encode path segments in `Url.Builder` — Elm's three silent wrong answers fixed, and parse(build(x)) = x | Elm's exact behaviour (no segment decoding, `+` kept, segments written raw) |
| **H9** | `beni serve`'s deep-link fallback | Also by `Accept: text/html`, so a route with a `.` in its last segment survives a reload | Keep "no `.` in the last segment" only; such routes 404 on reload in development |
| **H10** | Command-returning navigation helpers | None: `Navigation.pushUrl` returns `Result Error ()` and an `update` writes `Cmd.task (λ() -> Navigation.pushUrl key url) Pushed` | Elm-shaped `Cmd msg` helpers (`Navigation.push : Key, String -> Cmd msg`) whose failure — a throttled or cross-origin push — must then be a defect, since a command with no tagger has nowhere to send it |

Smaller calls the spec made and lists as departures without an H number, each in its *Where this
departs* list: `Problem`'s constructors; `timeout` a `Duration`, zero meaning at once; the
program's `Content-Type` winning; no `reloadAndSkipCache`; `load` refusing `javascript:`; the link
guard adding `altKey`, `_self` and an already-prevented default, and covering the whole document;
`back`/`forward` sending nothing at the call; `Document.body` one `Html msg`; an application at a
non-`http(s)` address a defect at start.

## 4. Not in this plan

`Bytes` and `File` (and so `bytesBody`, `fileBody`, `expectBytes`); streaming request bodies;
`cache`/`redirect`/`referrerPolicy`/`keepalive`/`priority`/`integrity` options; `Http` on the
`node` platform; scroll restoration on `back` (`history.scrollRestoration`); hiding a deployment's
`"base"` from the router; a TEA test driver that fakes the key and `fetch` without a page (status
§6, Milestone 3 item 4); `Task.timeout`/`race` (effects), which a request's own `timeout` does not
wait for.
