# WebSocket

A WebSocket carries text messages in both directions on one connection. The `node` platform has
the server side. The `browser` and `browser-tea` platforms have the page side. Each has a module
`WebSocket`.

## The operations that every platform has

| Operation | Does |
|---|---|
| `WebSocket.read socket` | waits for the next text message: `Ok text`, or `Err close` when the connection ended |
| `WebSocket.write socket text` | sends one message and never waits: `Err NotOpen` when the connection is closing or closed |
| `WebSocket.close socket { code, reason }` | starts the closing handshake |
| `WebSocket.buffered socket` | the bytes that are not sent yet |
| `WebSocket.protocol socket` | the subprotocol that the server chose, or `""` |

A `Close` is `{ code : Int, reason : String }`. A module that uses only these operations builds
on every platform, so a server and a page can share the code of their protocol. These versions
read text messages only: a binary message closes the connection with 1003.

## The server, on `node`

- `Http.Server.listenWith { host, port } { request, upgrade }` starts a server. `request` answers
  the usual requests. `upgrade : Request → Upgrade` answers a request for a WebSocket.
- `Server.accept session` opens the connection and calls `session socket`. The connection stays
  open while `session` runs. When `session` returns, an open connection is closed with 1000. A
  message longer than 1 MiB fails the connection with 1009.
- `Server.acceptWith { protocol, maxMessage } session` also chooses a subprotocol from
  `Server.protocols request` and sets the longest message.
- `Server.refuse response` sends `response`, and no WebSocket opens. A browser sends the header
  `origin`: compare it with the server's own address, and refuse a page of another site.
- `WebSocket.drain socket` waits until each `write` is handed to the network.
- `Server.close server` closes each connection with 1001.

```beni platform=node
import Http.Server as Server exposing (Request, Response, Upgrade)
import Io
import Node exposing (Program)
import WebSocket exposing (Socket)


main : Program
main = Io.run λ⊤ →
    case
        Server.listenWith { host = "127.0.0.1", port = 8080 }
            { request = handle, upgrade = upgrade }
    of
        Err _ →
            Node.exitWith "cannot listen on 8080" 1

        Ok server →
            Server.wait server
            Node.print "stopped"


handle : Request → Response
handle _ = Server.text 404 "not found"


upgrade : Request → Upgrade
upgrade request =
    if request.path == "/echo" then
        Server.accept echo
    else
        Server.refuse (Server.text 404 "no such socket")


-- Each message goes back to the client, until the connection ends.
echo : Socket → ⊤
echo socket =
    case WebSocket.read socket of
        Ok text →
            _ = WebSocket.write socket text
            echo socket

        Err _ →
            ⊤
```

## The page, on `browser-tea`

- `WebSocket.listen url protocols Tag` is a subscription: one connection while it is live. It
  sends `Opened socket`, then `Received text` for each message, then `Closed close`. When the
  connection never opens, it sends only `Failed error`. When the subscription goes, the socket is
  closed with 1000.
- `url` is relative to the page, so `/echo` is the server that served the page.
- The platform never connects again by itself. To connect again, remove the subscription for one
  render, then put it back.
- `WebSocket.send socket text Unsent` is the command of `write`. `WebSocket.disconnect socket
  close Failed` is the command of `close`.
- `WebSocket.connect url protocols use`, in the body of a command, waits until the connection
  opens and calls `use socket`. When `use` returns, the socket is closed with 1000.
- A `ConnectError` is `BadUrl`, `BadProtocol`, `Blocked` or `Unreachable`.

```beni platform=browser-tea
import Cmd exposing (Cmd)
import Html exposing (Html)
import Sub exposing (Sub)
import Tea
import WebSocket exposing (Socket)


type alias Model =
    socket : Maybe Socket
    heard : List String


type Msg
    = Heard WebSocket.Event
    | Ping
    | Unsent WebSocket.WriteError


init : ⊤ → Model × Cmd Msg
init ⊤ = ( { socket = Nothing, heard = [] }, Cmd.none )


update : Msg, Model → Model × Cmd Msg
update msg model =
    case msg of
        Heard (WebSocket.Opened socket) →
            ( { model | socket = Just socket }, Cmd.none )

        Heard (WebSocket.Received text) →
            ( { model | heard = List.push model.heard text }, Cmd.none )

        Heard _ →
            ( { model | socket = Nothing }, Cmd.none )

        Ping →
            case model.socket of
                Just socket →
                    ( model, WebSocket.send socket "ping" Unsent )

                Nothing →
                    ( model, Cmd.none )

        Unsent _ →
            ( model, Cmd.none )


view : Model → Html Msg
view model =
    <div>
        <button onClick={Ping}>ping</button>
        <ol><For each={model.heard} keyed={False}>{λtext → <li>{text}</li>}</For></ol>
    </div>


subscriptions : Model → Sub Msg
subscriptions _ = WebSocket.listen "/echo" [] Heard


main : Tea.Program
main = Tea.element { init = init, update = update, view = view, subscriptions = subscriptions }
```

## The object, on `cloudflare`

- A Durable Object's `request` handler answers an upgrade with `Object.accept ctx request tags`
  or `Object.acceptWith ctx request { protocol, tags }`: `Ok ( socket, response )`, the 101 to
  return, or `Err` (`NotAnUpgrade`, `TooManyTags`, `TooManySockets`, `ProtocolNotOffered`).
- There is no `read`. Each text message is a `message` event of the object, a close is `closed`
  with `{ code, reason }`, and a fault is `failed`; so the object can hibernate between events.
  A binary frame closes the socket with 1003.
- `WebSocket.write socket text` and `WebSocket.close socket { code, reason }` are the shared
  operations, with the `node` server's close codes. `WebSocket.id`, `WebSocket.tags` and
  `WebSocket.protocol` are kept with the socket across hibernation. `WebSocket.attach socket
  schema value` keeps a value of the program's with it, and `WebSocket.attachment` reads it back.
- `Object.sockets ctx` lists the open sockets; `Object.autoReply ctx request response` makes the
  host answer one text with another, without an event.

```beni platform=cloudflare
import Schema
import String
import WebSocket exposing (Socket)
import Worker exposing (Context, Request, Response)
import Worker.Object as Object


main : Worker.Program
main = Worker.program { fetch = route, objects = [ room ] }


room : Worker.Definition
room = Object.define "Room" Schema.string (λ_ → ⊤) { Object.none | request = join, message = heard }


join : Object.Context String, ⊤, Request → ⊤ × Response
join ctx _ request =
    case Object.accept ctx request [ "player" ] of
        Ok ( socket, response ) →
            _ = WebSocket.write socket "welcome"
            ( ⊤, response )

        Err _ →
            ( ⊤, Worker.text 426 "upgrade to a WebSocket" )


heard : Object.Context String, ⊤, Socket, String → ⊤
heard ctx _ socket text =
    _ = WebSocket.write socket "echo ${text}"
    ⊤


route : Context, Request → Response
route ctx request =
    case Worker.objects (Worker.env ctx) "ROOMS" Schema.string of
        Just rooms →
            case Worker.forward (Worker.byName rooms "main") request of
                Ok response →
                    response

                Err _ →
                    Worker.text 503 "the room is not available"

        Nothing →
            Worker.text 500 "ROOMS is not declared"
```

Sources: `docs/design/boundary.md` §9.10, §9.11, §9.12 (g); `examples/chat/`; the modules' doc comments.
