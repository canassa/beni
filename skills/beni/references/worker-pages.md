# A persistent hosted worker

Use the `browser` platform. Open inside `Task.scope` and send the handle into the model.
The observer consumes events. `Task.wait observer` keeps the owner scope alive.
A Deferred keeps it alive after the observer stops, until Close confirms or Abort
terminates the worker. Returning from the scope closes the worker, so do not
return immediately after Opened.

Close cancels the observer before cooperative cleanup. Unconfirmed cleanup keeps the
handle in the model so Abort remains available. Abort terminates the worker, then stops
the observer. The example handles both buttons and keeps worker state outside the page.

```beni platform=browser
import Browser
import Browser.Worker as Worker
import Browser.WorkerStream as Events
import Deferred
import Hosted
import Html exposing (Html)
import Task


type alias Protocol =
    Worker.CallsWithEvents String String String String


worker : Worker.Program String String Protocol
worker =
    Worker.program
        { init = λ_ config → Ok config
        , start =
            λcontext _ →
                _ = Worker.emit context "ready"
                ⊤
        , handle =
            λcontext state message →
                _ = Worker.emit context "request received"
                Ok (state ++ message)
        , stream = Worker.noStream
        }


type alias Session =
    handle : Worker.Handle Protocol
    observer : Task.Fiber ⊤
    finished : Deferred.Deferred ⊤


type Model
    = Idle String
    | Opening
    | Running Session String
    | Closing Session


type Msg
    = Open
    | Opened Session
    | Progress String
    | Close
    | Abort
    | Closed Worker.Cleanup
    | Failed String


observe : Events.Stream Worker.TransportError String, (Msg → ⊤) → ⊤
observe stream send =
    case Events.next stream of
        Ok (Events.Item chunk) →
            send (Progress (Events.take chunk))
            observe stream send
        Ok Events.End →
            ⊤
        Err _ →
            send (Failed "event stream failed")


openWorker : (Msg → ⊤) → ⊤
openWorker send = Task.scope λowner →
    case Worker.open owner worker "worker: " Worker.options of
        Err _ →
            send (Failed "open failed")
        Ok handle →
            observer = Task.spawn λ⊤ → observe (Worker.events handle) send
            finished = Deferred.make ⊤
            send (Opened { handle = handle, observer = observer, finished = finished })
            case Worker.call handle "hello" of
                Ok text →
                    send (Progress text)
                    ⊤
                Err _ →
                    send (Failed "call failed")
            _ = Task.wait observer
            Deferred.wait finished


stop : Session, Bool, (Msg → ⊤) → ⊤
stop session abort send =
    cleanup =
        if abort then
            abandoned = Worker.abort session.handle
            Task.cancel session.observer
            abandoned
        else
            Task.cancel session.observer
            Worker.close session.handle
    case cleanup of
        Worker.Unconfirmed _ →
            ⊤
        _ →
            _ = Deferred.complete session.finished ⊤
            ⊤
    send (Closed cleanup)


status : Model → String
status model =
    case model of
        Idle text →
            text
        Opening →
            "opening"
        Running _ text →
            text
        Closing _ →
            "closing"


main : Browser.Program
main =
    Browser.hosted
        { init = λ_ → Idle "closed"
        , update =
            λowner msg model →
                outlet = Hosted.outlet owner
                case ( msg, model ) of
                    ( Open, Idle _ ) →
                        Task.start (λ⊤ → openWorker (Hosted.emit outlet _)) λ_ → ⊤
                        Opening
                    ( Opened session, Opening ) →
                        Running session "ready"
                    ( Progress text, Running session _ ) →
                        Running session text
                    ( Close, Running session _ ) →
                        Task.start (λ⊤ → stop session False (Hosted.emit outlet _)) λ_ → ⊤
                        Closing session
                    ( Abort, Running session _ ) →
                        Task.start (λ⊤ → stop session True (Hosted.emit outlet _)) λ_ → ⊤
                        Closing session
                    ( Closed cleanup, Closing session ) →
                        case cleanup of
                            Worker.Confirmed →
                                Idle "closed"
                            Worker.Unconfirmed _ →
                                Running session "cleanup unconfirmed; abort is available"
                            Worker.Abandoned →
                                Idle "abandoned"
                    ( Failed text, Running session _ ) →
                        Running session text
                    ( Failed _, Closing _ ) →
                        model
                    ( Failed text, _ ) →
                        Idle text
                    _ →
                        model
        , settle = λ_ model → model
        , view =
            λmodel →
                <main>
                    <button onClick={Open}>open</button><button onClick={Close}>close</button><button onClick={Abort}>abort</button><output>{status model}</output>
                </main>
        }
```

## A progress loop

Each `Item` holds a chunk. Take its value once, publish it, then read the next step.
`End` stops the loop. Return a read failure to the caller.

```beni platform=browser
import Browser.Worker as Worker
import Browser.WorkerStream as Events


pub publish :
      Events.Stream Worker.TransportError event
    , (event → ⊤)
    → Result (Events.ReadError Worker.TransportError) ⊤
publish stream send =
    case Events.next stream of
        Ok (Events.Item chunk) →
            send (Events.take chunk)
            publish stream send
        Ok Events.End →
            Ok ⊤
        Err reason →
            Err reason
```

Start the loop in a child fiber. Cancel that observer before calling `Worker.close`.
The TEA recipe shows this order with a call and an owned scope.

Sources: `docs/design/workers.md` §7–§8; `docs/design/workers-api.md` §1, §7; `docs/design/boundary.md` §9.8.
