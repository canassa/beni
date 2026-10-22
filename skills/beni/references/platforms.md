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
- A Durable Object is `Worker.Object.define name schema restore handlers`, listed in `objects`
  and in `beni.json`'s `"exports"`. `schema` is the object's protocol, the type of the messages
  it receives. `restore ctx` builds the state at each start, from `Worker.Storage`. Each handler
  of `Handlers` takes the state and returns the next one; `Object.none` has a handler for each
  kind that keeps the state. Events run one at a time: `request` (a `Worker.forward` from the
  Worker), `received` (a message), `alarm`, `tick`/`ticked` (a timer the state names), and the
  WebSocket handlers.
- Reach an object with `Worker.objects (Worker.env ctx) "NAME" schema`, then `Worker.byName`,
  `Worker.unique` or `Worker.byId`. `Worker.forward ref request` sends a request. `Object.post
  ref message` sends a message and waits for nothing. `Object.ask ref schema (λreply → message)`
  sends a message with a `Reply` and waits for `Object.reply reply value`; a cycle between
  objects is `Err Cycle`, a message that does not parse is `Err Unreadable`, and a `Reply` that
  no one can answer is `Err NoReply`. `Object.self ctx` is the object's own ref; inside an
  object, `Object.env ctx` holds the bindings.
- `Worker.Storage.get ctx schema key`, `put`, `delete` and `keys ctx prefix` are the object's
  key-value store, through schemas. A `put` over 2 000 000 bytes is `Err TooLarge`.
- A defect in a handler stops the object: its fibers are cancelled, their `Task.bracket`
  releases run, the request in flight fails, and the next event starts a new instance.

```beni platform=cloudflare
import Schema
import String
import Worker exposing (Context, Request, Response)
import Worker.Object as Object
import Worker.Storage as Storage


main : Worker.Program
main = Worker.program { fetch = route, objects = [ counter ] }


type alias State =
    count : Int


counter : Worker.Definition
counter = Object.define "Counter" Schema.int restore { Object.none | request = serve }


restore : Object.Context Int → State
restore ctx =
    case Storage.get ctx Schema.int "count" of
        Ok (Just count) →
            { count = count }

        _ →
            { count = 0 }


serve : Object.Context Int, State, Request → State × Response
serve ctx state request =
    next = { state | count = state.count + 1 }
    _ = Storage.put ctx Schema.int "count" next.count
    ( next, Worker.text 200 (String.fromInt next.count) )


route : Context, Request → Response
route ctx request =
    case Worker.objects (Worker.env ctx) "COUNTERS" Schema.int of
        Just counters →
            case Worker.forward (Worker.byName counters "main") request of
                Ok response →
                    response

                Err _ →
                    Worker.text 503 "the counter is not available"

        Nothing →
            Worker.text 500 "COUNTERS is not declared"
```

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
(`lists.md`, *Ownership*). For view helpers, see `markup.md`, *Helpers on `browser-inline`*.

## `html`

The vocabulary the page platforms and `Ssr` share: every element, attribute and event, with the
payload each event carries (`onInput` gives the input's value as a `String`; `onClick` gives the
`Event`; the pointer events give an `Html.Pointer`, read with `Html.localX` and `Html.localY`).
`Html.map`, `Html.text`, `Html.preventDefault`, `Html.key`. A program never names this platform;
the others include it.

Sources: `docs/design/boundary.md` §5, §9.1, §9.8, §9.10, §9.12; `platforms/*/beni.json`; the modules' doc comments.
