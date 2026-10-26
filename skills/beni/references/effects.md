# Effects

beni has no effect syntax. The compiler infers, for every function, whether it reaches the host
(`impure`) and whether it can wait (`suspends`). You write a function that waits like any other,
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
- A generated reference writes a signature with no effect mark: `List a, (a → b) → List b`. A
  value whose result reaches the host ends in the comment `-- impure`; one that can wait ends in
  `-- suspends`: `Task.sleep : Duration → ⊤  -- suspends`, `Ref.get : Ref a → a  -- impure`.

## Fibers: `Task`

A fiber is one line of execution; many fibers take turns on one thread. `Task` is core.

| Function | Does |
|---|---|
| `Task.spawn (λ⊤ → work)` | starts a fiber in the current scope; returns a `Fiber a` |
| `Task.join fiber` | waits for its value |
| `Task.cancel fiber` | stops it; `bracket` releases run first |
| `Task.scope λscope → body` | a scope: every fiber spawned in it is joined or cancelled when `body` returns |
| `Task.bracket acquire release use` | `release` runs when `use` ends, also on cancellation; it gets the resource and an `Exit a`, which is `Done value` or `Cancelled` |
| `Task.sleep duration` | waits |
| `Task.timeout duration (λ⊤ → work)` | `Just` the value, or `Nothing` after the duration |
| `Task.race left right` | the first of two to finish; the other is cancelled at once and does not run again |
| `Task.retry schedule (λ⊤ → attempt)` | repeats a `Result` attempt as a `Schedule` says |
| `Task.forever (λ⊤ → work)` | runs `work` again and again; only a cancel stops it. It lets other fibers run after each run, and uses no stack |

Nothing a fiber starts outlives what started it, unless it is joined first. Cancellation is
delivered only where a fiber can wait.

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

### A scheduler of its own

Every fiber resumes through the program's one queue. `Task.scheduler hook` makes a queue of its
own, and `Task.withScheduler scheduler (λ⊤ → work)` runs `work` on it: `work`'s fiber resumes
through that queue while inside, and the fibers `work` starts belong to the scheduler. A defect
under a scheduler runs its `hook` and stops that scheduler alone: its fibers are cancelled and
their releases run; on `node` the throw then ends the process, as every defect does.
`Task.stopScheduler scheduler deadline done` cancels the fibers of one scheduler — the fibers
started under it and the fiber inside its `withScheduler`, whole — runs their releases, and calls
`done` with how many releases the deadline cut short; the fibers of every other scheduler run on.
A platform uses this to give each request or each object a runtime of its own.

```beni
import Task


pub apart : (⊤ → Int), (⊤ → Int) → Int
apart left right =
    own = Task.scheduler λ⊤ → ⊤
    a = Task.spawn λ⊤ → Task.withScheduler own left
    b = Task.spawn right
    Task.join a + Task.join b
```

## Cells and signals

- `Ref a`: a mutable cell. `Ref.make v`, `Ref.get r`, `Ref.set r v`, `Ref.update r f`,
  `Ref.modify r λv → ( result, v2 )`.
- `Deferred a`: a value set once. `Deferred.make ⊤`, `Deferred.complete d v`, `Deferred.wait d`
  waits until it is set, `Deferred.poll d`.
- `Clock.now ⊤` is the time in milliseconds on the calling fiber's clock. A test can run a fiber on
  a virtual clock with `Clock.run`.
- `Duration`: `Duration.millis n`, `Duration.seconds n`, `Duration.minutes n`.

A block value that a call makes has one type for a type variable inside a cell, a named type other
than `List`, or a function parameter. The first use fixes it. `r = Ref.make []` is one cell of one
list type, so a second use at another type is `type_mismatch`. An annotation cannot make it
general again: `r : Ref (List a)` is `rigid_mismatch`. A function binding makes a new cell for
each call, so it stays general: `fresh ⊤ = Ref.make []`. A value with no call, such as `[]`,
`Nothing` or a `λ`, stays general, and so does a call whose type holds its variable only in a
`List`, a tuple, a record or a function result, such as `xs = List.reverse []`.

A top-level value is computed once, when its module is loaded. When that computation is impure
and leaves such a type variable open, it is the error `impure_polymorphic_value`. Annotate the
value at one type, or give it a parameter.

```beni refused=impure_polymorphic_value
import Ref exposing (Ref)


pub cells = Ref.make []
```

```beni
import Ref exposing (Ref)


pub cells : Ref (List String)
cells = Ref.make []
```

## Permits: `Semaphore`

A `Semaphore` limits how many fibers do one thing at the same time. `Semaphore.make n` makes
`n` permits.

- `Semaphore.withPermit s (λ⊤ → work)` waits for a permit, runs `work` and gives the permit back
  when `work` ends. It also gives it back when the fiber is cancelled. Use this form first.
- `Semaphore.withPermits s n (λ⊤ → work)` does the same with `n` permits.
- `Semaphore.tryWithPermits s n (λ⊤ → work)` does not wait: `Just` the value, or `Nothing` and
  `work` does not run.
- Fibers get permits in the order they started to wait. A request waits while an earlier request
  waits.
- A request for more permits than there are waits until all are free. Then it counts all of its
  `n` as taken, so give back the same `n`. A request for 0 or fewer does not wait.
- `Semaphore.acquire s n` and `Semaphore.release s n` are the manual pair. One fiber can take a
  permit and a different fiber can give it back. Nothing gives back a permit that you `acquire`:
  if you do not `release` it, it is lost. After `acquire` returns, the permits are yours. If your
  fiber can be cancelled before it calls `release`, give them back in `Task.onExit`, or use
  `withPermits`, which does that for you. A cancelled `acquire` that is still waiting takes nothing.
- `Semaphore.available s` is the number of free permits. `Semaphore.resize s n` changes the
  number of permits.

```beni
import Semaphore exposing (Semaphore)
import Task


pub fetchAll : Semaphore, List String, (String → Int) → List Int
fetchAll pool urls fetch =
    fibers = List.map urls λurl → Task.spawn λ⊤ → Semaphore.withPermit pool λ⊤ → fetch url
    Task.joinAll fibers


pub enter : Semaphore → ⊤
enter slots = Semaphore.acquire slots 1


pub leave : Semaphore → ⊤
leave slots = Semaphore.release slots 1
```

## Values between fibers: `Queue`

A `Queue a` passes values from fibers that offer to fibers that take, first in, first out.

- `Queue.bounded n` holds at most `n` values. An offer to a full queue waits for room.
- `Queue.dropping n` refuses a new value when it is full. `Queue.sliding n` drops the oldest
  value to make room. `Queue.unbounded ⊤` is never full. A capacity below 1 is 1.
- `Queue.offer q v` answers `True` when the queue accepts `v`. It answers `False` when a
  `dropping` queue refuses `v`, or when the queue has ended. `Queue.offerAll q vs` answers the
  values that it did not accept.
- `Queue.take q` waits while the queue is empty and answers `Just` the oldest value.
  `Queue.takeAll q` waits while the queue is empty and then takes every value.
  `Queue.takeN q n` waits until there are `n` values, or the queue is full, or it has ended.
- `Queue.poll q` and `Queue.size q` do not wait.
- `Queue.end q` ends the queue. Later offers answer `False`. The values in the queue are still
  taken. After them, `take` answers `Nothing`. A loop that takes until `Nothing` stops there.
- Fibers that wait to take get values in the order they started to wait. A take never goes before
  a fiber that waits.
- A cancelled wait loses no value. A taker that was given a value but was cancelled before it ran
  puts the value back at the front. An offer that the queue accepted stays in the queue.

## Gates: `Latch`

A `Latch` is a gate. `Latch.make False` makes a closed latch, and `Latch.make True` an open one.

- `Latch.wait l` returns at once when `l` is open. Otherwise it waits.
- `Latch.open l` opens it and lets every waiting fiber go on, in order. `Latch.close l` closes it.
- `Latch.release l` lets the waiting fibers go on but keeps the latch closed. A later wait waits.
- `Latch.isOpen l` tells which.

```beni
import Latch exposing (Latch)
import Queue exposing (Queue)
import Task exposing (Fiber)


pub work : Queue String, (String → ⊤) → ⊤
work jobs handle =
    case Queue.take jobs of
        Just job →
            handle job
            work jobs handle

        Nothing →
            ⊤


pub worker : Queue String, (String → ⊤) → Fiber ⊤
worker jobs handle = Task.spawn λ⊤ → work jobs handle


pub ticker : Latch, (⊤ → ⊤) → ⊤
ticker gate tick = Task.forever λ⊤ →
    Latch.wait gate
    tick ⊤
```

## Where a program can wait

`main` is evaluated once, when the program starts, and must not wait.

- On `node`, `main = Io.run λ⊤ → …` starts a fiber that can wait: `Io.sleep ms`,
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
  each `String → ⊤`. A line below `Info` is not written. `Log.setMinimum Log.Debug` changes that
  minimum for the whole program, and `Log.minimum Log.Debug λ⊤ → …` for one function. The default
  sink is the console at the line's level; the `node` platform writes one `logfmt` line per entry
  to standard error.
- On a page, a command's body has the log context of the `update` arm that made the command. The
  context stops at the body: a message that the body sends runs its `update` with the program's
  context.
- A log line is text. Format a value yourself; `Debug.toString`'s text is not a promise.

```beni
import Log


pub save : Int → ⊤
save ms =
    if ms > 1000 then
        Log.warn "saving took ${ms} ms"
```

Sources: `docs/design/transparent-effects-proposal.md` §2, §14.7, §16, §17.3, §17.5, §17.7, §17.9; `docs/design/checker-v2.md` §8.4; `core/Task.beni`; `core/Semaphore.beni`; `core/Queue.beni`; `core/Latch.beni`; `core/Log.beni`; `platforms/node/Io.beni`.
