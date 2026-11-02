# A worker command in TEA

Use the `browser-tea` platform. `Cmd.keyed` with `Restart` cancels the previous job
and waits for its cleanup before it starts the next one.

`Task.scope` owns open, call, and close. Its child fiber reads progress events and
sends TEA messages. Cancel that observer before explicit close. If the command is
cancelled, the scope cancels its children and closes the worker. If explicit
close is unconfirmed, this command aborts the worker before it returns.

```beni platform=browser-tea
import Browser.Worker as Worker
import Browser.WorkerStream as Events
import Cmd
import Html exposing (Html)
import Sub
import Task
import Tea


type alias Protocol =
    Worker.CallsWithEvents String String String String


worker : Worker.Program String String Protocol
worker =
    Worker.program
        { init = λ_ config → Ok config
        , start = λ_ _ → ⊤
        , handle =
            λcontext state message →
                _ = Worker.emit context "working"
                Task.yieldNow ⊤
                Ok (state ++ message)
        , stream = Worker.noStream
        }


type alias Model =
    status : String
    progress : String


type Msg
    = Run
    | Progress String
    | Finished String
    | Failed String


observe : Events.Stream Worker.TransportError String, Cmd.Send Msg → ⊤
observe stream send =
    case Events.next stream of
        Ok (Events.Item chunk) →
            send (Progress (Events.take chunk))
            observe stream send
        Ok Events.End →
            ⊤
        Err _ →
            send (Progress "event stream failed")


runJob : Cmd.Send Msg → ⊤
runJob send = Task.scope λowner →
    case Worker.open owner worker "worker: " Worker.options of
        Err _ →
            send (Failed "open failed")
        Ok handle →
            observer = Task.spawn λ⊤ → observe (Worker.events handle) send
            reply = Worker.call handle "hello"
            Task.cancel observer
            cleanup = Worker.close handle
            case cleanup of
                Worker.Confirmed →
                    case reply of
                        Ok text →
                            send (Finished text)
                        Err _ →
                            send (Failed "call failed")
                Worker.Unconfirmed _ →
                    _ = Worker.abort handle
                    send (Failed "cleanup unconfirmed; worker aborted")
                Worker.Abandoned →
                    send (Failed "worker abandoned")


update : Msg, Model → Model × Cmd.Cmd Msg
update msg model =
    case msg of
        Run →
            ( { model | status = "running" }, Cmd.keyed "worker" Cmd.Restart runJob )
        Progress text →
            ( { model | progress = text }, Cmd.none )
        Finished text →
            ( { model | status = text }, Cmd.none )
        Failed text →
            ( { model | status = text }, Cmd.none )


main : Tea.Program
main =
    Tea.element
        { init = λ⊤ → ( { status = "idle", progress = "" }, Cmd.none )
        , update = update
        , view =
            λmodel →
                <main>
                    <button onClick={Run}>run</button><output>{model.status}</output><p>{model.progress}</p>
                </main>
        , subscriptions = λ_ → Sub.none
        }
```

Sources: `docs/design/workers.md` §7–§8; `docs/design/workers-api.md` §1, §7; `docs/design/boundary.md` §9.8.
