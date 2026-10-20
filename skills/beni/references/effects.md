# Effects

beni has no effect syntax. The compiler infers, for every function, whether it reaches the host
(`impure`) and whether it may wait (`suspends`). You write a function that waits like any other,
and you call it like any other.

## The model

- `user = getUser id` performs the request and binds the result. There is no `Task e a` and no
  `andThen` chain. On a page platform, `update` returns a `Cmd` that names the work, and the
  work's body is ordinary code like this (`platforms.md`).
- `List.map users λu → save u` calls an effectful callback. One `List.map` serves pure and
  effectful callbacks.
- A failure you expect is a `Result`. There are no exceptions. A defect — a bug in the program,
  the platform or the host — stops the program with a report.
- A function that must not wait is `sync`; the compiler checks it where a platform asks for it
  (an event handler, a `view`). You never write the word.
- In a generated reference, a type shows its class after the result: `(a → b !e1) → List b !e1`,
  `Duration → ⊤ !suspends`, `Ref a → a !impure`.

## Fibers: `Task`

A fiber is one line of execution; many fibers take turns on one thread. `Task` is core.

| Function | Does |
|---|---|
| `Task.spawn (λ⊤ → work)` | starts a fiber in the current scope; returns a `Fiber a` |
| `Task.join fiber` | waits for its value |
| `Task.cancel fiber` | stops it; `bracket` releases run first |
| `Task.scope λscope → body` | a scope: every fiber spawned in it is joined or cancelled when `body` returns |
| `Task.bracket acquire release use` | `release` runs when `use` ends, also on cancellation |
| `Task.sleep duration` | waits |
| `Task.timeout duration (λ⊤ → work)` | `Just` the value, or `Nothing` after the duration |
| `Task.race left right` | the first of two to finish; the other is cancelled |
| `Task.retry schedule (λ⊤ → attempt)` | repeats a `Result` attempt as a `Schedule` says |

Nothing a fiber starts outlives what started it, unless it is joined first. Cancellation is
delivered only where a fiber may wait.

```beni
import Duration
import Task


pub both : (⊤ → Int), (⊤ → Int) → Int
both left right =
    scope ← Task.scope
    a = Task.spawn left
    b = Task.spawn right
    Task.join a + Task.join b


pub patient : (⊤ → Int) → Maybe Int
patient work = Task.timeout (Duration.seconds 2) work
```

## Cells and signals

- `Ref a`: a mutable cell. `Ref.make v`, `Ref.get r`, `Ref.set r v`, `Ref.update r f`,
  `Ref.modify r λv → ( result, v2 )`.
- `Deferred a`: a value set once. `Deferred.make ⊤`, `Deferred.complete d v`, `Deferred.wait d`
  waits until it is set, `Deferred.poll d`.
- `Clock.now ⊤` is the time in milliseconds on the calling fiber's clock. A test can run a fiber on
  a virtual clock with `Clock.run`.
- `Duration`: `Duration.millis n`, `Duration.seconds n`, `Duration.minutes n`.

## Where a program may wait

`main` is evaluated once, when the program starts, and must not wait.

- On `node`, `main = Io.run λ⊤ → …` starts a fiber that may wait: `Io.sleep ms`,
  `Io.readFile path`, `Http.Server.listen`, `Deferred.wait`.
- On `browser-tea`, work that waits runs in a command's body (`platforms.md`): `Cmd.task`,
  `Cmd.perform`, `Cmd.keyed`. An event handler and `view` must not wait.
- On `browser`, a handler sends a message and does nothing else.

```beni platform=node
import Io
import Node exposing (Program)


main : Program
main = Io.run λ⊤ →
    Io.sleep 10
    case Io.readFile "config.txt" of
        Ok text →
            Node.print text

        Err Io.NotFound →
            Node.exitWith "no config.txt" 1

        Err _ →
            Node.exitWith "cannot read config.txt" 1
```

## `Debug` and `Log`

- `Debug.log "label" value` prints and returns the value. `Debug.toString value` renders any
  value. A `--release` build refuses a program that reaches `Debug` (`debug_in_release`).
- `Log` is for a shipped program: `Log.trace`, `Log.debug`, `Log.info`, `Log.warn`, `Log.error`,
  each `String → ⊤`. A line below `Info` is not written. The default sink is the console at the
  line's level; the `node` platform writes one `logfmt` line per entry to standard error.
- A log line is text. Format a value yourself; `Debug.toString`'s text is not a promise.

```beni
import Log


pub save : Int → ⊤
save ms =
    if ms > 1000 then
        Log.warn "saving took ${ms} ms"
```

Sources: `docs/design/transparent-effects-proposal.md` §2, §14.7, §16; `core/Task.beni`; `core/Log.beni`; `platforms/node/Io.beni`.
