# Dedicated workers

Use `Browser.Worker` on `browser` or `browser-tea`.
A `Worker.Program config state protocol` describes code for a separate module worker.
Keep it in a top-level declaration. Pass instance data through `config`.
The page holds a descriptor. Initialization and handlers run in the worker.
The compiler writes its entry under `_workers/`.

`Worker.Protocol call reply streamRequest error event chunk` names the message types.
State stays in the worker. `Worker.Calls request reply error` is call-only.
`Worker.CallsWithEvents request reply error event` adds events. These plain aliases
set absent roles to `⊥` and add no runtime code. A type alias cannot supply a
record field value: `Definition` still needs `stream = Worker.noStream`.

| Operation | Result |
|---|---|
| `Worker.open owner program config Worker.options` | waits for initialization; `Ok handle` or `Err { reason, cleanup }` |
| `Worker.call handle request` | waits for a reply; `Ok reply` or `Err (CallError error)` |
| `Worker.events handle` | the bounded event stream for this connection |
| `Events.next stream` | waits for `Item chunk`, `End`, or a typed read error; `Events.take chunk` reads the event |
| `Worker.close handle` | waits for cooperative cleanup; returns `Confirmed`, `Unconfirmed loss`, or `Abandoned` |
| `Worker.abort handle` | terminates a live native worker and returns `Abandoned`; an already closed handle returns `Confirmed` |

Open the worker in a `Task.scope`. Returning from that scope closes the worker.
`OpenReason` includes `WorkerLoadFailed`, `ReadyDeadlineExceeded`,
`InitializationFailed error`, and `HandshakeFailed transportError`.
`CallError` separates `Application error`, `PreparationFailed`, and `Transport`.
Event reads can fail with a transport error, `StreamClosed`, or `StreamUnresponsive`.
A defect stops the program. It is not an application error reply.
Abort does not confirm that finalizers ran.

## Tickets and cancellation

`Worker.send` returns a ticket for a prepared request. `Worker.await ticket` waits
for its reply. Awaiting an interrupted ticket cancels the awaiting fiber.
The statement after that await does not run.

Use a child fiber when the parent must continue. `Task.wait` reports `Cancelled`
without cancelling the parent:

```beni platform=browser
import Browser.Worker as Worker
import Task


pub cancelAndObserve : Worker.Ticket error reply → Worker.Cleanup × Bool
cancelAndObserve ticket =
    cleanup = Worker.cancel ticket
    awaiting = Task.spawn λ⊤ → Worker.await ticket
    interrupted =
        case Task.wait awaiting of
            Task.Cancelled →
                True
            Task.Done _ →
                False
    ( cleanup, interrupted )
```

## Values that cross

Config, requests, replies, application errors, and events need Wire evidence.
Primitives, records, tuples, tagged values, and Lists can cross when their contents can cross.
The runtime materializes List views before native cloning. It skips known stable branches.
Generic Programs keep normalization plans in both realms. Unused roles can remain unfixed.
Functions, fibers, scopes, DOM objects, and raw `Js.Value` cannot cross.

| Diagnostic | Cause |
|---|---|
| `worker_message_not_serializable` | a message contains a function or an unsupported native value; the error names the field path |
| `worker_realm_violation` | worker code reaches an operation that needs another realm, such as the page DOM |
| `worker_entry_not_static` | the launch cannot select a finite set of top-level Program declarations, or the launch function is aliased |
| `invalid_entry_kind` | a platform's `entryKinds` row has an invalid Program, runtime, constructor, launch, or type role |

`check` and `build` apply these checks without a bypass flag.
`invalid_entry_kind` is a platform metadata error. Check the row in `beni.json`.
The other errors below are application examples.

## Complete page recipes

- [A persistent hosted worker](worker-pages.md): the model holds the handle; Close and Abort control its lifetime.
- [A TEA worker command](worker-tea.md): `Cmd.keyed` with `Restart`, a scoped call, and an event reader.

Both examples are whole modules. Save one as `Main.beni`, check it with its platform,
build it, and serve the output over HTTP.

## Refused messages and entries

Do not put a function in a request type.

```beni platform=browser refused=worker_message_not_serializable
import Browser.Worker as Worker
import Task exposing (Scope)


pub launch :
      Scope
    , Worker.Program ⊤ ⊤ (Worker.Calls (⊤ → ⊤) String String)
    → ⊤
launch owner definition =
    _ = Worker.open owner definition ⊤ Worker.options
    ⊤
```

A launch cannot take an unknown Program parameter. Use a top-level Program reference.

```beni platform=browser refused=worker_entry_not_static
import Browser.Worker as Worker
import Task exposing (Scope)


pub launch :
      Scope
    , Worker.Program ⊤ ⊤ (Worker.Calls String String String)
    → ⊤
launch owner definition =
    _ = Worker.open owner definition ⊤ Worker.options
    ⊤
```

A worker cannot query the page DOM.

```beni platform=browser refused=worker_realm_violation
import Browser.Host.Document as Document
import Browser.Host.Window as Window
import Browser.Worker as Worker
import Task exposing (Scope)


worker : Worker.Program ⊤ ⊤ (Worker.Calls String String String)
worker =
    Worker.program
        { init = λ_ _ → Ok ⊤
        , start = λ_ _ → ⊤
        , handle =
            λ_ _ message →
                case Document.querySelector (Window.document ⊤) "body" of
                    Ok _ →
                        Ok message
                    Err _ →
                        Err "invalid selector"
        , stream = Worker.noStream
        }


pub launch : Scope → ⊤
launch owner =
    _ = Worker.open owner worker ⊤ Worker.options
    ⊤
```

Sources: `docs/design/workers.md` §2, §4–§8; `docs/design/workers-api.md` §1, §7; `docs/design/workers-emission.md` (discovery and projections).
