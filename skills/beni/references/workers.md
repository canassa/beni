# Browser workers

A worker runs a beni program on its own thread, next to a page. The page sends it requests and
gets replies. A long computation in a worker does not stop the page. `Browser.Worker` has the
API, on the `browser` and `browser-tea` platforms. The worker is a dedicated worker: one page
owns it.

You write no JavaScript and no script URL. `beni build` finds each worker program that the page
opens and writes it as an entry of its own under `out/_workers/`.

## The protocol

A protocol names the types that cross between the page and the worker. It is a type alias of
`Worker.Protocol call reply streamRequest error event chunk`:

| Role | Is |
|---|---|
| `call` | a request that the page sends |
| `reply` | the value that a handler returns for a request |
| `streamRequest` | reserved: write `⊥` |
| `error` | the error that `init` or a handler returns |
| `event` | a value that the worker emits at any time; `⊥` when there are none |
| `chunk` | reserved: write `⊥` |

## The program

`Worker.program definition` makes a `Worker.Program config state protocol`. Declare it at the top
level: `Worker.open` takes only a top-level program, or an `if` or `case` that selects one. A
program made at run time is the error `worker_entry_not_static`. A `Definition` has three
functions. Each one gets a `Context event`.

- `init : Context event, config → Result error state` runs once, when the worker starts. `config`
  is the value that the page gives to `open`. `Ok state` makes the worker ready. `Err e` stops
  it, and `open` returns `InitializationFailed e`. `init` can wait.
- `start : Context event, state → ⊤` runs after `init` and before the worker is ready. It must
  not wait: a `start` that can suspend is the error `sync_boundary`. To run work for the life of
  the worker, start a fiber: `Task.spawnIn (Worker.scope context) λ⊤ → work`.
- `handle : Context event, state, call → Result error reply` answers one request. `Ok reply` and
  `Err error` go back to the page. A handler can wait: `Task.sleep`, `Http.get`, another worker.

The worker runs one handler at a time, in the order that the requests arrive. Each handler gets
the same `state`. The state stays in the worker and never crosses, so it can hold anything, a
`Handle` of another worker too.

The functions of a `Context`:

- `Worker.scope context` is the worker's root scope in `init` and `start`, and the scope of the
  request in `handle`. A fiber that you spawn in the request scope stops when the handler ends.
- `Worker.emit context event` sends an event to the page. See `worker-messages.md`.
- `Worker.connection context` is `Nothing` in `init` and `start`, and `Just` an id in `handle`.

```beni platform=browser
import Browser.Worker as Worker exposing (Context)
import Task


type Request
    = CountPrimes Int


type Progress
    = Checked Int


type alias Primes =
    Worker.Protocol Request Int ⊥ String Progress ⊥


-- The config and the state are the largest number that a request may ask for.
primes : Worker.Program Int Int Primes
primes =
    Worker.program
        { init = λ_ limit → if limit > 1 then Ok limit else Err "the limit must be above 1"
        , start = λ_ _ → ⊤
        , handle = answer
        }


answer : Context Progress, Int, Request → Result String Int
answer context limit request =
    case request of
        CountPrimes n →
            if n > limit then Err "the number is above the limit" else Ok (count context 2 n 0)


count : Context Progress, Int, Int, Int → Int
count context at n found =
    if at > n then
        found
    else
        _ = if Int.mod at 10000 == 0 then Worker.emit context (Checked at) else Ok ⊤
        count context (at + 1) n (if isPrime at 2 then found + 1 else found)


isPrime : Int, Int → Bool
isPrime n d = if d * d > n then True else if Int.mod n d == 0 then False else isPrime n (d + 1)


-- Opens the worker in a scope, sends one request, and closes the worker when the scope ends.
countTo : Int → String
countTo n = Task.scope λowner →
    case Worker.open owner primes 1000000 Worker.options of
        Err _ →
            "the worker did not start"

        Ok handle →
            case Worker.call handle (CountPrimes n) of
                Ok found →
                    String.fromInt found

                Err _ →
                    "the request failed"
```

## Open, call and close

`Worker.open scope program config options` starts a worker and waits until `init` and `start`
are done. It returns `Ok handle`, or `Err { reason, cleanup }`. The `scope` owns the worker: when
the scope ends, the worker closes. Open it in a `Task.scope`, in a fiber that the page starts:
`Task.start` in the `update` of `Browser.hosted`, or a command body on `browser-tea`.

`countTo`, in the example of *The program*, opens `primes`, sends one request, and closes the
worker when its scope ends.

| Function | Does |
|---|---|
| `Worker.call handle request` | sends one request and waits: `Result (CallError error) reply` |
| `Worker.prepare value` | makes a `Prepared value` for `send`; returns `Ok` for each value that can cross |
| `Worker.send handle prepared` | sends and does not wait: `Result SendError (Ticket error reply)` |
| `Worker.await ticket` | waits for the reply of a ticket; a second `await` gives the same result |
| `Worker.discard prepared` | drops a prepared message; a `send` of it is then `Err ChannelClosed` |
| `Worker.cancel ticket` | stops a request and waits for the handler's cleanup: a `Cleanup` |
| `Worker.close handle` | stops the worker and waits for its cleanup: a `Cleanup` |
| `Worker.abort handle` | terminates the worker at once; no cleanup runs: a `Cleanup` |
| `Worker.events handle` | the stream of the worker's events; see `worker-messages.md` |

`send` and `await` put several requests in flight. Await them in any order. A prepared message is
sent once: a second `send` of it is `Err ChannelClosed`.

### The errors

`OpenError error` is `{ reason : OpenReason error, cleanup : Cleanup }`. The reasons:

| `OpenReason` | When |
|---|---|
| `InvalidOptions problem` | an option is not valid: `NonPositiveLimit "queuedRequests"`, `InvalidDuration "leaseWithin"`, … |
| `InitializationFailed e` | `init` returned `Err e` |
| `ReadyDeadlineExceeded` | `init` and `start` did not end within `readyWithin` |
| `ClosedBeforeReady` | the worker closed before it was ready |
| `WorkerLoadFailed`, `InvalidScriptUrl`, `WorkerSecurityDenied`, `UnsupportedWorkerKind` | the browser did not load the worker's script, refused its URL, or has no `Worker` |
| `ScriptPolicy problem`, `TrustedScriptUrlRejected` | Trusted Types refused the script URL; see `worker-messages.md` |
| `HandshakeFailed problem` | a `TransportError` before the worker was ready; `SendFailed QueueFull` when the page has 64 open workers |

`CallError error`, from `call` and `await`:

| `CallError` | When |
|---|---|
| `Application e` | the handler returned `Err e` |
| `PreparationFailed problem` | the request could not be prepared |
| `Transport problem` | the request or the worker failed: a `TransportError` |

`TransportError`:

| `TransportError` | When |
|---|---|
| `SendFailed problem` | a `SendError`; `call` after `close` gives `SendFailed ChannelClosed` |
| `PeerClosed` | the worker closed before it replied |
| `PeerUnresponsive` | the worker did not answer the heartbeat within `leaseWithin` |
| `CleanupAbandoned` | `abort` terminated the worker |
| `MessageDeserializationFailed` | the browser could not read a message |
| `ProtocolVersionMismatch` | the worker is from a different build |

`SendError`, from `send`: `ChannelClosed` (the worker is closed or lost, or the prepared message
was sent or discarded), `QueueFull` (see the limits in `worker-messages.md`), `WorkerCloneRejected failure` (the browser
refused to copy the message).

`Cleanup`, from `cancel`, `close` and `abort`, and in an `OpenError`:

| `Cleanup` | Means |
|---|---|
| `Confirmed` | the worker ran its finalizers and told the page |
| `Unconfirmed loss` | no confirmation came: `ReadyExpired`, `LeaseExpired` or `ConnectionLost` |
| `Abandoned` | `abort` terminated the worker; its finalizers did not run |

### Cancel, close and abort

- `Worker.cancel ticket` stops the handler of the request: its fiber is cancelled and its
  finalizers run. A request that waits in the queue is removed. `cancel` waits at most
  `leaseWithin` and returns `Confirmed`, `Unconfirmed LeaseExpired` or `Abandoned`. When the reply
  came first, `cancel` returns `Confirmed` and `await` still gives the reply. A second `cancel`
  returns the same result.
- A cancelled fiber that waits in `Worker.call` cancels its request in the same way.
- **An `await` of a cancelled ticket cancels the fiber that awaits.** It does not return. To keep
  the fiber, await in a child: `Task.wait (Task.spawn λ⊤ → Worker.await ticket)` gives
  `Task.Cancelled`.
- `Worker.close handle` stops new requests, cancels the running handler, runs the worker's
  finalizers and waits at most `cleanupWithin`. A pending `await` then gives
  `Err (Transport PeerClosed)`, and the event stream ends. A second `close` returns `Confirmed`.
- `Worker.abort handle` terminates the worker at once and returns `Abandoned`. No finalizer runs.
  A pending `await` gives `Err (Transport CleanupAbandoned)`.

### An unconfirmed cleanup stops the program

When a scope ends, it closes each worker that it owns. **When that close returns `Unconfirmed`,
the program stops** with the defect `Worker cleanup was not confirmed`, as for an uncaught
exception. The same is true when a cancelled `await` or `call` cannot confirm its `cancel`. A
worker that loops and never yields cannot answer, so its cleanup is not confirmed. Thus, when a
call gives `Transport PeerUnresponsive`, or `close` returns `Unconfirmed`, call `Worker.abort` on
the handle before the scope ends.

```beni platform=browser
import Browser.Worker as Worker exposing (Handle, Ticket)
import Task


type alias Jobs =
    Worker.Protocol Int Int ⊥ String ⊥ ⊥


-- Two requests in flight; the reply of the second is read first.
both : Handle Jobs → String
both handle =
    case ( submit handle 1, submit handle 2 ) of
        ( Ok first, Ok second ) →
            b = show (Worker.await second)
            a = show (Worker.await first)
            a ++ " " ++ b

        _ →
            "the queue is full or the worker is closed"


submit : Handle Jobs, Int → Result Worker.SendError (Ticket String Int)
submit handle n =
    case Worker.prepare n of
        Ok prepared →
            Worker.send handle prepared

        Err _ →
            Err Worker.ChannelClosed


-- An await in a child fiber, so that a cancelled ticket cancels only the child.
awaitInChild : Ticket String Int → String
awaitInChild ticket =
    case Task.wait (Task.spawn λ⊤ → show (Worker.await ticket)) of
        Task.Done text →
            text

        Task.Cancelled →
            "cancelled"


show : Result (Worker.CallError String) Int → String
show result =
    case result of
        Ok n →
            String.fromInt n

        Err (Worker.Application why) →
            "refused: " ++ why

        Err (Worker.Transport Worker.PeerUnresponsive) →
            "the worker does not answer"

        Err _ →
            "the request failed"


-- After a lost worker, abort it: the scope's own close could not be confirmed.
stop : Handle Jobs → ⊤
stop handle =
    case Worker.close handle of
        Worker.Unconfirmed _ →
            _ = Worker.abort handle
            ⊤

        _ →
            ⊤
```

## Defects

A defect in a worker stops the page, as a defect in the page does: in development the page
shows its crash screen, in a release build it logs the defect and stops. This is true for a
defect in `init`, in `start`, in a handler and in a fiber that no request waits for. A defect is
never an `Err`, and the `call` that waits does not return. One second later, the page terminates
each worker that is still open and logs the list as `abandonedWorkers` on the console.

`Err` from `init` or from a handler is not a defect: the page gets it as `InitializationFailed`
or `Application`.

`worker-messages.md` has the options and their defaults, the limits, events, the types that can
cross, what code a worker can use, and Trusted Types.

Sources: `docs/design/workers.md` §7, §8; `docs/design/workers-api.md` §1;
`platforms/browser/Browser/Worker.beni`.
