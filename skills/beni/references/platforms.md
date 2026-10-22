# Platforms

A program is built for one platform. The platform owns `Program`, the type of `main`, and supplies
the host modules. Name it in `beni.json` (`"build": { "platform": "…" }`) or with
`--platform=<name>`. Six ship in the compiler.

| Platform | `main` | Runs where | Adds |
|---|---|---|---|
| `node` | `Node.Program` | Node | `Node`, `Io`, `Http.Server`, `WebSocket`, `Ssr`, `Random`, and `Html` |
| `browser` | `Browser.Program` | a page | `Browser`, `Cmd`, `Sub`, `Time`, `Dom`, `Http`, `WebSocket`, `Storage`, `Random`, `Browser.Events`, `Browser.Navigation`, and `Html` |
| `browser-tea` | `Tea.Program` | a page | `Tea`, over everything `browser` has |
| `browser-inline` | `Tea.Program` | a page | `Tea`, `Browser`, `Cmd`, `Sub`, `Html`; compiled, no runtime loop |
| `html` | none | — | the markup vocabulary the four above share |
| `cloudflare` | `Worker.Program` | a Cloudflare Worker | `Worker`: the request, the response, the bindings, Durable Object references |

`api-<platform>.md` lists each module's public interface. `websocket.md` tells how to use a
WebSocket on a server and in a page.

## `node`

- `main : Program` is a value: `Node.print text`, `Node.printLines lines`, `Node.exitWith message
  code`, or `Node.done`. A `node` program writes its standard output only through the `Program` it
  ends with.
- `main = Io.run λ⊤ → …` runs a fiber that can wait: `Io.sleep ms`, `Io.readFile path`
  (`Result FileError String`), `Deferred.wait`, `Task.sleep`.
- `Http.Server.listen { host, port } handler` starts a server; the handler is `Request → Response`
  and runs once per request, in a fiber of its own. `Server.text status body` is a response;
  `Server.wait server` waits until it closes; `Server.close server` stops it.
- `Ssr.render markup` renders an `Html msg` to a `String`.
- `Log` lines go to standard error, one `logfmt` line each.
- Run the output with `node out/_main.mjs`.

```beni platform=node
import Http.Server as Server exposing (Request, Response)
import Io
import Node exposing (Program)


main : Program
main = Io.run λ⊤ →
    case Server.listen { host = "127.0.0.1", port = 8080 } handle of
        Err _ →
            Node.exitWith "cannot listen on 8080" 1

        Ok server →
            Server.wait server
            Node.print "stopped"


handle : Request → Response
handle request =
    if request.path == "/" then
        Server.text 200 "hello"
    else
        Server.text 404 "not found"
```

## `cloudflare`

- `main = Worker.program { fetch = route, objects = [] }`. `fetch : Worker.Context, Request →
  Response` answers each request and may wait: `Task.sleep`, `Worker.forward ref request`,
  `Worker.callService service request`. Each request runs on a scheduler of its own, so a defect
  fails only that request.
- Read a request with `Worker.method`, `Worker.url`, `Worker.path`, `Worker.header request name`
  and `Worker.headers`. Build a response with `Worker.text status body`, `Worker.html status body`,
  `Worker.empty status`, `Worker.redirect request target status` and `Worker.withHeader response
  name value`. An invalid response (a status outside 200 to 599, a body on a 204, a bad header) is
  a 500, and one `console.error` line names the fault.
- The bindings: `Worker.var (Worker.env ctx) name` is a plain-text variable (`Maybe String`),
  `Worker.service` a service binding, `Worker.objects` a Durable Object namespace. Each answers
  `Nothing` when the configuration does not declare the name.
- A fiber that must run after the answer is started with `Task.spawnDetached`; it runs under
  `waitUntil`, and the platform stops it 25 seconds after the answer.
- Build with `beni build --platform=cloudflare --out=out Main.beni` and point `wrangler.jsonc`'s
  `main` at `out/_worker.mjs`. The entry file exports the Durable Object classes the app's
  `beni.json` lists under `"exports"`.

```beni platform=cloudflare
import Worker exposing (Context, Request, Response)


main : Worker.Program
main = Worker.program { fetch = route, objects = [] }


route : Context, Request → Response
route ctx request =
    case Worker.path request of
        "/" →
            Worker.text 200 "hello"

        "/greeting" →
            case Worker.var (Worker.env ctx) "GREETING" of
                Just greeting →
                    Worker.text 200 greeting

                Nothing →
                    Worker.text 500 "GREETING is not declared"

        _ →
            Worker.text 404 "not found"
```

## `browser`

`Browser.program { init, update, view }` is a page program with a model and no effects beyond its
handlers. `init : ⊤ → model` runs at mount. `Browser.mountAt program "cart"` mounts it in the element with
that id instead of `document.body`; `Browser.programs [ … ]` puts several on one page. The page renders
once per task, after the messages of that task, and patches only the holes whose values changed.

## `browser-tea`

The Elm Architecture over `browser`, in beni.

- `Tea.sandbox { init : ⊤ → model, update : msg, model → model, view : model → Html msg }`.
- `Tea.element { init : ⊤ → model × Cmd msg, update : msg, model → model × Cmd msg,
  view : model → Html msg, subscriptions : model → Sub msg }`.
- `Tea.document` adds a page title; `Tea.application` adds the URL (`Url`, `Key`, `onUrlChange`,
  `onUrlRequest`).

**Commands.** A `Cmd msg` is data: it names work and does none. The work is a **body**, a function
given `send : msg → ⊤`. A body can wait; it runs in a fiber of the program's scope.

| Command | Does |
|---|---|
| `Cmd.none`, `Cmd.batch cmds` | nothing; several |
| `Cmd.perform λsend → …` | runs the body |
| `Cmd.task (λ⊤ → work) Done` | runs `work`, which can wait, and sends `Done result` |
| `Cmd.keyed key policy λsend → …` | a body under a key; `Cmd.Restart` cancels the running one, `Cmd.Queue` waits for it, `Cmd.Ignore` drops the new one, `Cmd.Concurrent` runs both |
| `Cmd.cancel key`, `Cmd.cancelAll` | stops keyed work |
| `Cmd.afterRender λsend → …` | runs after the page is patched: focus, measure, scroll |
| `Cmd.log level line` | writes `line` with core's `Log` at `level`, with no annotation of `update`'s |
| `Cmd.map cmd key Wrap` | a child's commands under a parent's message |

**Subscriptions.** `subscriptions model` returns the set that must be live. After each message
the page starts what arrived and cancels what left. `Sub.none`, `Sub.batch`, `Time.every duration
Tick`, `Browser.Events.onKeyDown`, `onKeyUp`, `onResize`, `onAnimationFrame`, `Sub.map`.

**Host modules.** Each failure is a value, never a crash.

- `Http.get { url, expect = Http.expectString }` waits and returns `Result Http.Error String`;
  `Http.post`, `Http.request`; `Http.expectJson` for a type with a `codec`. Call them inside a
  command's body.
- `Dom.focus id`, `Dom.blur id`: `Result Dom.Error ⊤`, at once; after a render, inside
  `Cmd.afterRender`.
- `Storage.get Storage.Local key : Maybe String`; `Storage.set area key value : Result Storage.Error ⊤`
  (`QuotaExceeded`, `Unavailable`); `Storage.remove`.
- `Time.now ⊤ : Posix`; `Time.sleep duration` waits; `Time.every`.
- `Random.generate generator Made : Cmd msg`; `Random.int lo hi`, `Random.float`, `Random.map`.
- `Browser.Navigation.pushUrl key url Failed`, `replaceUrl`, `load`.
- `Log` is core's: `Log.info line` inside a body, `Cmd.log Log.Info line` from `update`. A line
  below `Info` is not written until `Log.setMinimum` lowers the minimum, in `init` for example.

```beni platform=browser-tea
import Cmd exposing (Cmd)
import Html exposing (Html)
import Http
import Sub exposing (Sub)
import Tea
import Time


type alias Model =
    ticks : Int
    body : String


type Msg
    = Tick Time.Posix
    | Fetch
    | Got (Result Http.Error String)


init : ⊤ → Model × Cmd Msg
init ⊤ = ( { ticks = 0, body = "" }, Cmd.none )


update : Msg, Model → Model × Cmd Msg
update msg model =
    case msg of
        Tick _ →
            ( { model | ticks = model.ticks + 1 }, Cmd.none )

        Fetch →
            ( model
            , Cmd.task (λ⊤ → Http.get { url = "/api/body", expect = Http.expectString }) Got
            )

        Got (Ok body) →
            ( { model | body = body }, Cmd.none )

        Got (Err _) →
            ( { model | body = "failed" }, Cmd.none )


view : Model → Html Msg
view model =
    <div>
        <p>{model.ticks} ticks</p>
        <button onClick={Fetch}>Fetch</button>
        <pre>{model.body}</pre>
    </div>


subscriptions : Model → Sub Msg
subscriptions _ = Time.every (Time.seconds 1) Tick


main : Tea.Program
main = Tea.element { init = init, update = update, view = view, subscriptions = subscriptions }
```

## `browser-inline`

The same `Tea.sandbox` and `Tea.element` as `browser-tea`, so one source builds on both. The
program is compiled, not run: each constructor is recognised where it is called, and the page ships
only what it reaches. Lists are edited in place here, so the ownership checker's errors apply
(`lists.md`, *Ownership*).

A view may call a markup-returning helper in its own module; the compiler writes its markup
at that call site. Markup held or passed as data is still a compiler limitation, as is a helper
argument whose effectful evaluation would need sharing across binding functions. Keep the
source program and report that limitation; do not rewrite its evaluation to make it compile.
Only proven pure and total arm values may be evaluated eagerly. Other values run in the selected
arm, with current model values on reveal. An effectful helper argument used only by an event is
evaluated when its selected binding refreshes, retained for dispatch, and never rerun by a click.
A public helper exported by `--library` is a markup value and receives the existing unsupported
markup-value diagnostic; a successful build must never silently omit that export.
The detailed eligibility and lifetime contract is `docs/design/browser-inline.md` §8.2/§8.4.

## `html`

The vocabulary the page platforms and `Ssr` share: every element, attribute and event, with the
payload each event carries (`onInput` gives the input's value as a `String`; `onClick` gives the
`Event`; the pointer events give an `Html.Pointer`, read with `Html.localX` and `Html.localY`).
`Html.map`, `Html.text`, `Html.preventDefault`, `Html.key`. A program never names this platform;
the others include it.

Sources: `docs/design/boundary.md` §5, §9.1, §9.8, §9.10, §9.12; `platforms/*/beni.json`; the modules' doc comments.
