# Fibers, concurrency and cancellation: what a `Task` runtime must do

**Commissioned by** a one-line brief — *"Effect-TS-like control over fibers, concurrency, etc."* —
and by the fact that [`boundary.md`](../boundary.md) settled the architecture and said nothing about
the runtime. `fast-compiler.md` §3.1 settled that the language is pure and effects are values
interpreted by a platform; `boundary.md` §3 settled that a platform-provided effect is an ordinary
`foreign` at effect type and that ports stay asynchronous. What none of them settled is **what the
thing interpreting those values is allowed to do.** A `Task e a` that can only be run one after
another is a different language from one that can fan out, bound its own concurrency, cancel what it
no longer needs and release what it acquired.

**The brief's own hypothesis is that we have the right architecture and a poor runtime.** §1 and §2
test it against both sources. It survives, with one correction: the gap is not only richness, it is
that Elm's scheduler contains a *documented* capability its code does not implement (§1.3).

**The test stays the one this series uses.** A capability is admitted when it can be typed such that
well-typed code still cannot crash — and for a runtime that test has a second half, because a
scheduler can satisfy the type and still leak a process, drop a finaliser or wedge the event loop.
So every primitive in §5 is judged twice: *can it be typed*, and *what does the runtime have to
promise*.

**Sources.** The vendored `references/elm-core` read directly — `Elm/Kernel/Scheduler.js` (195
lines), `Elm/Kernel/Process.js`, `Process.elm`, `Task.elm`, `Elm/Kernel/Platform.js. Effect-TS
**3.22.2** read from an installed copy of the published package rather than from GitHub, so every
line quoted is the code that actually ships; file paths below are inside `node_modules/effect/dist/esm/`.
Primary documentation and source for ZIO 2, Cats Effect 3, Trio, kotlinx.coroutines, Swift's
stdlib and `golang.org/x/sync/errgroup`; MDN and the TC39 proposal repositories for the JavaScript
baseline. **Original measurements were run for this report** — §3 — on Node v24.19.0 / Intel N100 /
Linux, and every figure labelled *measured here* is reproducible from a script quoted inline. Where
a number is published by someone else it is attributed; where none exists the report says
**no verified number found** rather than estimating.

---

## 1. Elm's scheduler, read line by line

### 1.1 It is 195 lines and the architecture is right

`references/elm-core/src/Elm/Kernel/Scheduler.js` is the whole concurrency runtime. A `Task` is a
tagged record with one of five tags — `SUCCEED`, `FAIL`, `BINDING`, `AND_THEN`, `ON_ERROR` — plus
`RECEIVE` for effect-manager mailboxes. A *process* is `{ id, root, stack, mailbox }`, and
`_Scheduler_step` (lines 151–194) is a `while (proc.__root)` loop that rewrites `root` and `stack`
until it hits something it cannot advance:

```js
else if (rootTag === __1_BINDING)
{
    proc.__root.__kill = proc.__root.__callback(function(newRoot) {
        proc.__root = newRoot;
        _Scheduler_enqueue(proc);
    });
    return;
}
```

That is the whole asynchrony mechanism, and it is a good one. A `binding` hands the outside world a
one-shot resume callback and **the outside world hands back a canceller**, stored in `__kill`. It is
the same shape as Effect's `Async` op (§2.1), it is the same shape as Swift's
`withTaskCancellationHandler`, and it predates both. `_Scheduler_kill` (lines 102–115) invokes it:

```js
var task = proc.__root;
if (task.$ === __1_BINDING && task.__kill) { task.__kill(); }
proc.__root = null;
```

**The kill slot is used in practice, not vestigial.** `elm/http`'s `_Http_toTask` returns
`function() { xhr.__isAborted = true; xhr.abort(); }` from its binding
([elm/http `src/Elm/Kernel/Http.js`](https://raw.githubusercontent.com/elm/http/master/src/Elm/Kernel/Http.js),
fetched 2026-09-14), and `_Process_sleep` returns `function() { clearTimeout(id); }`. Two of the six
`_Scheduler_binding` call sites in `elm/core` are synchronous and correctly return nothing.

**So the brief is right about the architecture.** The five tags, the heap-allocated continuation
stack, the work queue and the canceller slot are the same four ideas Effect-TS's fiber runtime is
built from. What follows is the list of things this code does not do.

### 1.2 Nothing in `elm/core` runs two tasks concurrently

`Task.elm:139-143`, verbatim:

```elm
map2 : (a -> b -> result) -> Task x a -> Task x b -> Task x result
map2 func taskA taskB =
  taskA
    |> andThen (\a -> taskB
    |> andThen (\b -> succeed (func a b)))
```

`map3`–`map5` nest the same way and `sequence` is `List.foldr (map2 (::)) (succeed [])`
(`Task.elm:185`), so **every combinator in the module is sequential, transitively, from one
definition**. The module documents this itself rather than hiding it (`Task.elm:133-135`): *"Say we
were doing HTTP requests instead. `map2` does each task in order, so it would try the first request
and only continue after it succeeds."*

**Elm does have concurrency — one level up, where the `Task` language cannot reach it.** The `Task`
effect manager's `onEffects` is `sequence (List.map (spawnCmd router) commands)` and `spawnCmd` is
`Elm.Kernel.Scheduler.spawn` (`Task.elm:338,350`), so **separate `Cmd`s issued from one `update`
each get their own process and do run concurrently.** The consequence is exact and is the real
shape of the gap: *to run two HTTP requests in parallel in Elm you must leave the `Task` language,
issue two commands, add two `Msg` constructors and two `Maybe` fields to the model, and reassemble
the pair by hand in `update`.* The concurrency exists; it is just not expressible as a value.

### 1.3 `Process.elm` documents a fairness property the scheduler does not implement

`Process.elm:56-57` says of `spawn`: *"The Elm runtime will interleave their progress. So if a task
is taking too long, we will pause it at an `andThen` and switch over to other stuff."*

`_Scheduler_step` has no operation counter and no yield. `AND_THEN` pushes a frame and continues the
same `while` loop; the only three exits are a `BINDING`, an empty mailbox at a `RECEIVE`, and an
exhausted stack. **Measured here** (transcribing the vendored scheduler verbatim, spawning two
five-`andThen` processes and recording the order in which their callbacks fire):

```
interleaving at andThen: AAAAABBBBB
```

The processes do not interleave. A pure `andThen` loop with no `binding` in it occupies the
scheduler until it finishes, which on the browser's main thread is a frozen page. The doc comment
describes Effect's behaviour (§2.2), not Elm's.

### 1.4 The other four gaps, stated precisely

- **`Process.spawn : Task x a -> Task y Id` discards the result.** `_Scheduler_spawn` wraps
  `_Scheduler_rawSpawn`, whose process record has no observer list and no outcome slot, so nothing
  can ever learn what a spawned task produced. You can start work; you cannot collect it. This is
  exactly Trio's `start_soon`, which returns nothing — except Trio refuses on purpose and supplies a
  nursery instead, and Elm supplies nothing.
- **Cancellation costs a round trip through `update`.** `kill` needs an `Id`, `spawn` yields one
  only as a `Task`, and the only way to hold one is to run that task to completion, tag the result
  as a `Msg` and store it in the model. By the time you can cancel, a frame has passed.
- **No scope, no finaliser, no `acquireRelease`.** The process record is
  `{ $, __id, __root, __stack, __mailbox }` — there is no parent, no child set and no finaliser
  list. `_Scheduler_kill` sets `proc.__root = null` and returns; nothing runs on the way out. A
  killed process leaks whatever it held.
- **No bound, no timeout, no retry.** There is nothing to bound, since there is no parallel
  combinator to bound. `Process.sleep` plus hand-written recursion is the whole toolkit.

**Conclusion on the brief's hypothesis: confirmed, and sharper than stated.** The architecture is
sound and the missing pieces are all *additions to the process record and the step loop* — an
outcome slot, an observer list, a parent link, a finaliser list and an operation counter. None of
them changes the shape of a `Task`. §5 costs that out; §3 measures it.
