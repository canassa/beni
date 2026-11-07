# Worker messages, options and limits

This file continues `workers.md`. It tells what goes between a page and a `Browser.Worker`, the
options of `Worker.open`, and what code a worker can use.

## Options

`Worker.options` has the defaults. Change a field with a record update:
`{ Worker.options | name = "primes", queuedRequests = 8 }`.

| Field | Default | Is |
|---|---|---|
| `name` | `""` | the worker's name in the browser's tools and in a defect report |
| `credentials` | `Worker.SameOrigin` | the credentials of the script request: `Omit`, `SameOrigin` or `Include` |
| `readyWithin` | 30 s | the longest time for `init` and `start` |
| `cleanupWithin` | 5 s | the longest time that `close` waits for the worker's cleanup |
| `heartbeatEvery` | 5 s | the page asks the worker for a sign of life at this interval |
| `leaseWithin` | 30 s | no answer in this time makes the worker lost; also the longest wait of `cancel` |
| `queuedRequests` | 64 | the most requests that are not done |
| `queuedEvents` | 64 | the most events that the page did not read |
| `queuedBytes` | 1 MiB (1 048 576) | the most bytes of requests that are not done, and of events that the page did not read |
| `policy` | `Nothing` | a Trusted Types policy for the script URL |

`open` checks the options before it starts a worker: each count and each duration must be above
zero, and `leaseWithin` must not be less than `heartbeatEvery`. Else it returns
`InvalidOptions`. A worker that computes without a pause for more than `leaseWithin` cannot
answer the heartbeat and becomes lost. For long work, make `leaseWithin` longer.

## Limits

- `send` returns `Err QueueFull`, and `call` returns `Err (Transport (SendFailed QueueFull))`,
  when `queuedRequests` requests are not done, or when the new request would put the bytes of the
  requests that are not done above `queuedBytes`. A reply has no limit.
- `emit` returns `Err EventQueueFull` when `queuedEvents` events are not read by the page, or when
  the new event would put their bytes above `queuedBytes`. The event is not sent. When the page
  reads an event with `next`, its count and bytes become free again.
- The size is an estimate: 8 bytes for each value, plus the UTF-8 bytes of each string.
- A page has at most 64 open workers.

## Events

`Worker.emit context event` sends an event from `init`, `start`, a handler or a fiber of the
worker. It never waits. It returns `Ok ⊤`, `Err EventQueueFull`, or `Err EventChannelClosed`
after the worker closed.

`Worker.events handle` is a `Stream TransportError event` from `Browser.WorkerStream`. Each call
returns the same stream. Read it with `WorkerStream.next stream`, which waits:

| Result | Means |
|---|---|
| `Ok (Item chunk)` | an event; `WorkerStream.take chunk` or `WorkerStream.value chunk` gives it |
| `Ok End` | the worker closed |
| `Err (Failed problem)` | the worker was aborted or lost |
| `Err StreamClosed` | another fiber waits on this stream now: a stream has one reader at a time |

`WorkerStream.release chunk` does nothing. The event is a copy and you can keep it.

```beni platform=browser
import Browser.Worker as Worker exposing (Handle)
import Browser.WorkerStream as WorkerStream


type Progress
    = Checked Int


type alias Primes =
    Worker.Protocol Int Int ⊥ String Progress ⊥


-- Reads events until the worker closes, and returns the last number checked.
lastChecked : Handle Primes, Int → Int
lastChecked handle last =
    case WorkerStream.next (Worker.events handle) of
        Ok (WorkerStream.Item chunk) →
            case WorkerStream.take chunk of
                Checked n →
                    lastChecked handle n

        Ok WorkerStream.End →
            last

        Err _ →
            last
```

## What can cross

The config, each request, reply, error and event is copied to the other side. Its type must be
made of these:

- `⊤`, `Bool`, `Int`, `Float`, `Char`, `String`;
- tuples, records, `List`, `Maybe`, `Result`, `Dict` and `Set`;
- custom types, recursive ones too, whose fields are of these types.

A function, a `Task.Fiber`, a `Scope`, a worker's `Handle` or `Context`, and other native types
cannot cross. A protocol that contains one is the error `worker_message_not_serializable`. The
message names the path of the field. The state never crosses, so this rule does not apply to it.

```beni platform=browser refused=worker_message_not_serializable
import Browser.Worker as Worker
import Task


type alias Job =
    name : String
    run : Int → Int


type alias Jobs =
    Worker.Protocol Job Int ⊥ String ⊥ ⊥


runner : Worker.Program ⊤ ⊤ Jobs
runner = Worker.program { init = λ_ _ → Ok ⊤, start = λ_ _ → ⊤, handle = λ_ _ job → Ok (job.run 1) }


launch : ⊤ → String
launch _ = Task.scope λowner →
    case Worker.open owner runner ⊤ Worker.options of
        Ok handle →
            _ = Worker.close handle
            "opened"

        Err _ →
            "not opened"
```

## What a worker can use

A worker has no `document` and no `window`. `beni build` checks the code that each worker program
can reach: `init`, `start`, `handle` and every function that they call. That code may use only
the names that exist on the worker's global object. Another name is the error
`worker_realm_violation`; the message names the operation and the chain of calls from the
program. Code that only the page reaches is not checked, also in the same module. A dedicated
worker may read `location.href`, use `navigator` and request an animation frame.

`Http` and `WebSocket` work in a worker. A relative URL resolves against the worker's script URL,
which is under `_workers/`, and not against the page. Write an absolute path, such as `/api/data`.
`Browser.Navigation.currentUrl` gives the worker's script URL.

```beni platform=browser
import Browser.Worker as Worker
import Http
import WebSocket


type alias Fetcher =
    Worker.Protocol String String ⊥ String ⊥ ⊥


fetcher : Worker.Program ⊤ ⊤ Fetcher
fetcher =
    Worker.program
        { init = λ_ _ → Ok ⊤
        , start = λ_ _ → ⊤
        , handle =
            λ_ _ path →
                case Http.get { url = path, expect = Http.expectString } of
                    Ok body →
                        Ok body

                    Err _ →
                        Err ("cannot read " ++ path)
        }


echoer : Worker.Program ⊤ ⊤ Fetcher
echoer =
    Worker.program
        { init = λ_ _ → Ok ⊤
        , start = λ_ _ → ⊤
        , handle =
            λ_ _ text →
                result = WebSocket.connect "/echo" [] λsocket →
                    _ = WebSocket.write socket text
                    WebSocket.read socket
                case result of
                    Ok (Ok reply) →
                        Ok reply

                    _ →
                        Err "the socket failed"
        }
```

## Trusted Types

When the page's Content Security Policy requires Trusted Types, give `open` a policy.

- `Worker.policyName text` checks a policy name: ASCII letters, digits and `-#=_/@.%`, not empty.
  Else `Err InvalidPolicyName`.
- `Worker.policy name` makes a policy: `Err TrustedTypesUnavailable` when the browser has no
  Trusted Types, `Err TrustedPolicyDenied` when the page's CSP does not allow the name.
- Put it in the options: `{ Worker.options | policy = Just policy }`. `open` then makes the
  worker's script URL with this policy. A default policy on the page is not used.
- With no policy in the options, a default policy that beni did not make gives
  `ScriptPolicy (PolicyRefused reason)` from `open`.
- A page with markup also needs `"trustedTypes": true` in `beni.json` (`markup.md`, *Trusted
  Types*). Then the CSP needs to name only the worker's policy:
  `require-trusted-types-for 'script'; trusted-types beni-workers`.

```beni platform=browser
import Browser.Worker as Worker exposing (Options)


-- The options for a page whose CSP has `trusted-types beni-workers`.
trustedOptions : ⊤ → Result Worker.PolicyError Options
trustedOptions _ =
    case Worker.policyName "beni-workers" of
        Err problem →
            Err problem

        Ok name →
            case Worker.policy name of
                Err problem →
                    Err problem

                Ok policy →
                    Ok { Worker.options | policy = Just policy }
```

Sources: `docs/design/workers.md` §4, §5, §6; `docs/design/workers-api.md` §1, §7;
`platforms/browser/Browser/Worker.beni`, `platforms/browser/Browser/WorkerStream.beni`.
