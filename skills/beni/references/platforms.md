# Platforms

A program is built for one platform. The platform owns `Program`, the type of `main`, and supplies
the host modules. Name it in `beni.json` (`"build": { "platform": "…" }`) or with
`--platform=<name>`. Five ship in the compiler.

| Platform | `main` | Runs where | Adds |
|---|---|---|---|
| `node` | `Node.Program` | Node | `Node`, `Io`, `Http.Server`, `Ssr`, `Random`, and `Html` |
| `browser` | `Browser.Program` | a page | `Browser`, `Cmd`, `Sub`, `Time`, `Dom`, `Http`, `Storage`, `Random`, `Log`, `Browser.Events`, `Browser.Navigation`, and `Html` |
| `browser-tea` | `Tea.Program` | a page | `Tea`, over everything `browser` has |
| `browser-inline` | `Tea.Program` | a page | `Tea`, `Browser`, `Cmd`, `Sub`, `Html`; compiled, no runtime loop |
| `html` | none | — | the markup vocabulary the four above share |

`api-<platform>.md` lists each module's public interface.

## `node`

- `main : Program` is a value: `Node.print text`, `Node.printLines lines`, `Node.exitWith message
  code`, or `Node.done`. A `node` program writes its standard output only through the `Program` it
  ends with.
- `main = Io.run λ⊤ → …` runs a fiber that may wait: `Io.sleep ms`, `Io.readFile path`
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
given `send : msg → ⊤`. A body may wait; it runs in a fiber of the program's scope.

| Command | Does |
|---|---|
| `Cmd.none`, `Cmd.batch cmds` | nothing; several |
| `Cmd.perform λsend → …` | runs the body |
| `Cmd.task (λ⊤ → work) Done` | runs `work`, which may wait, and sends `Done result` |
| `Cmd.keyed key policy λsend → …` | a body under a key; `Cmd.Restart` cancels the running one, `Cmd.Queue` waits for it, `Cmd.Ignore` drops the new one, `Cmd.Concurrent` runs both |
| `Cmd.cancel key`, `Cmd.cancelAll` | stops keyed work |
| `Cmd.afterRender λsend → …` | runs after the page is patched: focus, measure, scroll |
| `Cmd.map cmd key Wrap` | a child's commands under a parent's message |

**Subscriptions.** `subscriptions model` returns the set that should be live. After each message
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
- `Log.info`, `Log.warn`, `Log.error`.

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

## `html`

The vocabulary the page platforms and `Ssr` share: every element, attribute and event, with the
payload each event carries (`onInput` gives the input's value as a `String`; `onClick` gives the
`Event`). `Html.map`, `Html.text`, `Html.preventDefault`, `Html.key`. A program never names this
platform; the others include it.

Sources: `docs/design/boundary.md` §5, §9.1, §9.8, §9.10; `platforms/*/beni.json`; the modules' doc comments.
