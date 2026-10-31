# Complete proposed page and worker

2026-10-30. **Proposed beni, not compiled:** the seven worker modules and
entry and realm contracts are specified in [workers-api.md](workers-api.md).
The [decided callback protocol](workers-callback-contracts.md) uses entryKinds metadata
and ownership checker v2, without new language syntax.
User function summaries are inferred; no user signature needs an ownership word.
The page uses browser-inline, whose genuinely suspending Cmd.perform kernel
is a prerequisite tracked in [#1306](https://github.com/canassa/beni/issues/1306).
There is no legacy renderer or handwritten JavaScript fallback. A page with
`<div id="root"></div>` is the normal browser mount host, not a worker loader.
No app worker manifest key is needed: `Jobs.program` is discovered at open.

## Request-handler worker: Jobs.beni

A small model is loaded once from configuration and retained across requests.
The model could instead own a GPU device or WASM instance: init registers its
cleanup on Worker.scope context; it never becomes part of a message. This
example uses immutable weights so both program shapes can borrow them safely.
Every user failure is typed; a programming defect uses the normal fatal path.

```text
import Browser.Worker as Worker
import Browser.WorkerStream as Stream
import Duration
import List
import Task

pub type Call = Predict Int
pub type StreamRequest = Frames Int
pub type alias Protocol = Worker.Protocol Call Int StreamRequest Error Event Int
pub type Error = EmptyModel | InvalidCount | OutputStopped
pub type Event = Alive | Progress Int
pub type alias Model = List Int

pub init : Worker.Context Event, List Int → Result Error Model
init context weights =
    if List.isEmpty weights then
        Err EmptyModel
    else
        Ok weights

pub start : Worker.Context Event, Model → ⊤
start context model =
    _ = Task.spawnIn (Worker.scope context) λ⊤ → pulse context
    ⊤

pulse : Worker.Context Event → ⊤
pulse context =
    Task.sleep (Duration.seconds 1)
    case Worker.emit context Alive of
        Ok ⊤ → pulse context
        Err _ → ⊤

pub handle : Worker.Context Event, Model, Call → Result Error Int
handle context model (Predict value) = Ok (value * List.sum model)

pub produce : Worker.Context Event, Model, StreamRequest, Stream.Sink Error Int → Result Error ⊤
produce context model (Frames count) sink =
    if count ≤ 0 then
        Err InvalidCount
    else
        frames context (List.sum model) sink 0 count

frames : Worker.Context Event, Int, Stream.Sink Error Int, Int, Int → Result Error ⊤
frames context weight sink index count =
    if index ≥ count then
        Ok ⊤
    else
        case Stream.write sink (weight * index) of
            Err _ → Err OutputStopped
            Ok ⊤ →
                case Worker.emit context (Progress index) of
                    Err _ → Err OutputStopped
                    Ok ⊤ → frames context weight sink (index + 1) count

pub program : Worker.Program (List Int) Model Protocol
program =
    Worker.program { init = init, start = start, handle = handle, stream = produce }
```

The root-scoped pulse illustrates genuinely unsolicited events. Event overflow
ends this optional pulse explicitly; it is not an ignored defect. Streaming
progress uses the same typed queue and deliberately reports OutputStopped if
it cannot publish. An application can choose another typed overflow policy.

## Page: Main.beni

Cancelling the stream cancels only its request scope. The root-owned model
remains available; a second Predict request on the same handle succeeds after
cancel has awaited producer cleanup. Passing Frames to call (or Predict to
stream) is a type mismatch, so WrongRequest does not exist.

Run opens one worker, consumes pushed events concurrently, calls Predict,
starts Frames, consumes/releases one chunk, cancels the stream, successfully
calls Predict again with the same model, stops its local
event reader and closes the worker. All paths stay in Task.scope; failure does
not leak a worker. The button is disabled while running. Explicit cleanup
status is shown, and an unconfirmed implicit finalizer remains fatal as §7
requires; showing it does not silently turn it into confirmed cleanup.

```text
import Browser
import Browser.Worker as Worker
import Browser.WorkerStream as Stream
import Cmd exposing (Cmd)
import Html exposing (Html)
import Jobs
import Duration
import Sub
import String
import Task
import Tea

type Msg = Run | Status String | Finished String
type alias Model =
    busy : Bool
    status : String

cleanupText : Worker.Cleanup → String
cleanupText cleanup =
    case cleanup of
        Worker.Confirmed → "cleanup confirmed"
        Worker.Unconfirmed _ → "cleanup unconfirmed"
        Worker.Abandoned → "cleanup abandoned"

watch : Stream.Stream Worker.TransportError Jobs.Event, (Msg → ⊤) → ⊤
watch events send =
    case Stream.next events of
        Err _ → send (Status "event channel ended")
        Ok Stream.End → ⊤
        Ok (Stream.Item chunk) →
            case Stream.value chunk of
                Jobs.Alive → send (Status "worker alive")
                Jobs.Progress n → send (Status ("progress " ++ String.fromInt n))
            Stream.release chunk
            watch events send

run : (Msg → ⊤) → ⊤
run send =
    Task.scope λscope →
        case Worker.open scope Jobs.program [ 2, 3, 5 ] Worker.options of
            Err failure → send (Finished ("open failed; " ++ cleanupText failure.cleanup))
            Ok worker →
                observer = Task.spawnIn scope λ⊤ → watch (Worker.events worker) send
                case Worker.call worker (Jobs.Predict 7) of
                    Err _ → send (Status "prediction failed")
                    Ok value → send (Status ("prediction " ++ String.fromInt value))
                case Worker.stream worker (Jobs.Frames 100) of
                    Err _ → send (Status "stream failed to open")
                    Ok frames →
                        case Stream.next frames of
                            Err _ → send (Status "stream read failed")
                            Ok Stream.End → send (Status "stream ended")
                            Ok (Stream.Item chunk) →
                                send (Status ("frame " ++ String.fromInt (Stream.value chunk)))
                                Stream.release chunk
                        stopped = Stream.cancel frames
                        send (Status ("stream " ++ cleanupText stopped))
                        case Worker.call worker (Jobs.Predict 11) of
                            Err _ → send (Status "post-cancel prediction failed")
                            Ok value → send (Status ("still usable: " ++ String.fromInt value))
                Task.cancel observer
                closed = Worker.close worker
                send (Finished (cleanupText closed))

update : Msg, Model → Model × Cmd Msg
update msg model =
    case msg of
        Run →
            if model.busy then
                ( model, Cmd.none )
            else
                ( { busy = True, status = "opening" }, Cmd.perform run )
        Status text → ( { model | status = text }, Cmd.none )
        Finished text → ( { busy = False, status = text }, Cmd.none )

view : Model → Html Msg
view model =
    <main>
        <button disabled={model.busy} onClick={Run}>Run worker</button>
        <output>{model.status}</output>
    </main>

main : Tea.Program
main =
    Browser.mountAt
        (Tea.element
            { init = λ⊤ → ( { busy = False, status = "ready" }, Cmd.none )
            , update = update
            , view = view
            , subscriptions = λ_ → Sub.none
            })
        "root"
```

## Same model through Elm-shaped worker: MachineJobs.beni

Replace only `Jobs.program` in the page's open call with `MachineJobs.program`
and add that import. Request, reply, error, event and chunk types are unchanged.
This adapter is useful when autonomous subscriptions and message-driven state
updates dominate. The direct handler above is shorter for scoped RPC because
returning the Result completes its token automatically.

```text
import Browser.Worker as Worker
import Browser.WorkerStream as Stream
import Jobs
import Duration
import Task

type Msg
    = Call Jobs.Call (Worker.Reply Jobs.Error Int)
    | Produce Jobs.StreamRequest (Stream.Sink Jobs.Error Int)
    | Pulse

init : Worker.Context Jobs.Event, List Int → Result Jobs.Error (Jobs.Model × Worker.Command Msg)
init context weights =
    case Jobs.init context weights of
        Err error → Err error
        Ok model → Ok ( model, Worker.none )

update : Worker.Context Jobs.Event, Msg, Jobs.Model → Jobs.Model × Worker.Command Msg
update context msg model =
    case msg of
        Call request reply →
            answer = Jobs.handle context model request
            command = Worker.performFor reply λsend →
                case Worker.respond reply answer of
                    Ok ⊤ → ⊤
                    Err _ → ⊤
            ( model, command )
        Produce request sink →
            command = Worker.performStream sink λsend →
                answer = Jobs.produce context model request sink
                case Worker.finish sink answer of
                    Ok ⊤ → ⊤
                    Err _ → ⊤
            ( model, command )
        Pulse →
            case Worker.emit context Jobs.Alive of
                Ok ⊤ → ( model, Worker.none )
                Err _ → ( model, Worker.none )

subscriptions : Jobs.Model → Worker.Subscription Msg
subscriptions model =
    Worker.subscription "pulse" λscope send →
        _ = Task.spawnIn scope λ⊤ → pulse send
        ⊤

pulse : (Msg → ⊤) → ⊤
pulse send =
    Task.sleep (Duration.seconds 1)
    send Pulse
    pulse send

pub program : Worker.Program (List Int) Jobs.Model Jobs.Protocol
program =
    Worker.machine
        { init = init
        , update = update
        , subscriptions = subscriptions
        , request = Call
        , stream = Produce
        }
```

The terminal methods reserve or refuse their runtime-owned token. Preparation
failures are remembered for TransportFailure after command cleanup; an Ok
reservation is also sent only after cleanup. No native send occurs inside the
impure respond/finish call. This example does not retry terminal reservations
or suppress defects. The adapter serializes update dispatch. Request-scoped
commands finish before a serial program admits another request, while root
subscription messages can still run; they may borrow only stable state captured
by an active command. Consuming/replacing that state while a command borrows it
is an ownership error, requiring a typed immutable snapshot or explicit Ref.
An abandoned Reply/Sink automatically settles with a typed channel-close outcome
after cleanup; a command cannot leave its caller parked forever by returning.
