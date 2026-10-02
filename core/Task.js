// The sibling JavaScript of `Task.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name, and nothing else. It is
// the fiber runtime of transparent-effects-proposal.md §16.4, whole: the
// suspension protocol the compiler's output speaks, the fiber record, the
// scheduler, interruption, finalisers and scopes. No platform is special
// here; the one host facility it picks by feature is the macrotask it
// escapes to.
//
// The protocol (§16.1). A call that parks returns `Y`, and leaves one
// pending suspension here: the wait it registered and an empty list of
// continuations. Each suspendable function the `Y` passes through appends
// the rest of itself (`andThen`), innermost first, and returns `Y` in turn,
// until the fiber's run loop takes the list onto the fiber's stack. A
// resumption pops one continuation at a time and calls it from the run
// loop, so a resumed stack is one frame deep. A call that answers with a
// value continues where it is: the fast path is one comparison.

// ---- The protocol -----------------------------------------------------------

// The one sentinel. An object no beni value can be: `Y` only ever travels
// between a `return` and the comparison that consumes it.
const Y = { waiting: true };

// The suspension being unwound: `{ ks, wait, interrupt }`, set by the call
// that parked and taken by the run loop. Null the rest of the time.
let pending = null;

export const andThen = (value, next) => {
  if (value !== Y) return next(value);
  pending.ks.push(next);
  return Y;
};

export const isWaiting = (value) => value === Y;

// ---- Fibers -----------------------------------------------------------------

// §6.4's record, with the continuation stack §6.4 says comes back under this
// lowering. One literal, keys always in this order, so one hidden class. A
// build that makes one — a fiber, or the record of finalisers outside any —
// has something to tear down, and so keeps the teardown (boundary.md
// §9.8.14): the two hooks are set here.
const newFiber = (parent) => {
  failure = failed;
  closing = closeAll;
  return {
    // Continuations, innermost last.
    stack: [],
    // null while it runs; then `{ $: "Done", a }` or `{ $: "Cancelled", a: null }`.
    outcome: null,
    // Functions called with the fiber when it ends.
    observers: null,
    parent,
    // The fibers `spawn` started from it, still running.
    children: null,
    // What `bracket` and `scope` registered, run last first on cancellation.
    finalizers: null,
    // How many `uninterruptible` regions it is inside.
    masks: 0,
    // An interrupt arrived: delivered at the next suspension point.
    interrupted: false,
    // Cancelling, or finishing: interrupts are ignored.
    unwinding: false,
    // The wait it is parked on, or null.
    parked: null,
    // The scope that started it, or null.
    scope: null,
  };
};

const cancelled = { $: "Cancelled", a: null };

// The fiber whose code is on the JavaScript stack; null outside any fiber
// (a module being loaded, `main` being evaluated).
let current = null;

// Where `spawn`, a finaliser's push and `uninterruptible` act outside any
// fiber (§16.4): nothing there can park, and nothing runs these finalisers.
// Made on first use, so that a build keeping only `openRoot` of this file
// keeps no call at the top level (research 40 §8, rule 5).
let outside = null;

const here = () => current ?? (outside ??= newFiber(null));

// ---- The scheduler (§7.5) ---------------------------------------------------

// Ready work, FIFO, as quadruples: the step that runs it and its three
// arguments. A fiber's is `resumeFiber` with the fiber, the value it resumes
// with, and the wait that value answers (null for a start or an interrupt);
// `soon`'s is `runSoon` with its record. A step answers whether it ran:
// a fiber's whose wait is no longer what the fiber is parked on is stale
// and does not count. The drain names no step, so a build whose only
// work is `soon`'s keeps no fiber (boundary.md §9.8.11).
const queue = [];
let head = 0;
let scheduled = false;

// Resumptions per drain before the rest continues in a macrotask, so a page
// renders and its timers fire (research/16 §5.5).
const budget = 64;

let port = null;
let portTask = null;
const macrotask = (task) => {
  const immediate = globalThis.setImmediate;
  if (typeof immediate === "function") {
    immediate(task);
    return;
  }
  if (port === null) {
    const channel = new globalThis.MessageChannel();
    channel.port1.onmessage = () => {
      const t = portTask;
      portTask = null;
      t();
    };
    port = channel.port2;
  }
  portTask = task;
  port.postMessage(null);
};

const schedule = (task, a, b, c) => {
  queue.push(task, a, b, c);
  if (scheduled) return;
  scheduled = true;
  queueMicrotask(drain);
};

const resumeFiber = (fiber, value, wait) => {
  if (wait !== null && fiber.parked !== wait) return false;
  run(fiber, value);
  return true;
};

const enqueue = (fiber, value, wait) => schedule(resumeFiber, fiber, value, wait);

// A fiber that throws is a defect (boundary.md §9.8.10 (c)): the scheduler
// stops, the platform's hook runs, and the throw goes on to the host; the
// teardown starts in a macrotask after it (§9.8.14). Not a `catch`: nothing
// is caught (CLAUDE.md rule 9).
let defect = null;
export const onDefect = (f) => {
  defect = f;
  return null;
};

// The runtime's state (boundary.md §9.8.14 (b)): 0 running; 1 stopping, when
// nothing runs until the teardown starts; 2 tearing down, when only fibers
// unwinding run; 3 stopped for good. A drain runs only at 0 and 2.
let phase = 0;

// The teardown's part of a throw out of the drain, and of `shutdown`: set by
// the first fiber or finaliser made (`newFiber`), so a build with neither —
// which has nothing to tear down — keeps none of it.
let failure = null;
let closing = null;

const drain = () => {
  if (phase & 1) return;
  let count = 0;
  let ok = false;
  try {
    while (head < queue.length) {
      // Stopped by the work just run (`shutdown`): the rest waits for the
      // teardown, the drain this queues finding nothing to do until then.
      if (count === budget || phase === 1) {
        ok = true;
        macrotask(drain);
        return;
      }
      const task = queue[head];
      const a = queue[head + 1];
      const b = queue[head + 2];
      const c = queue[head + 3];
      queue[head] = queue[head + 1] = queue[head + 2] = queue[head + 3] = undefined;
      head += 4;
      if (task(a, b, c)) count += 1;
    }
    ok = true;
  } finally {
    if (!ok) {
      if (failure !== null) failure();
      else {
        phase = 1;
        if (defect !== null) defect(null);
      }
    }
  }
  queue.length = 0;
  head = 0;
  scheduled = false;
};

// What stops the runtime, whoever asks: `shutdown` from a platform, or a
// throw out of the drain. Nothing runs from now on but the teardown, which
// starts in a macrotask, after the host has reported a throw in flight
// (§9.8.14 (b)); in a build with no fiber there is none.
export const shutdown = (ms, over) => {
  if (phase === 0) phase = 1;
  if (closing !== null) closing(ms, over);
  return null;
};

// The drain's guard saw a throw, which goes on to the host once this
// returns. The state the throw left behind is reset first. The first one
// is the defect: the runtime stops and the teardown is scheduled, the
// fiber that threw (the culprit) noted for it, and the platform's hook
// stops the page. One while tearing down is a cleanup's (§9.8.14 (g)): the
// fiber goes on to its next finaliser, the drain in a new macrotask.
const failed = () => {
  const fiber = current;
  current = null;
  pending = null;
  soonRunning = null;
  if (outside !== null) outside.masks = 0;
  // A throw that stopped the page on its way here — an `update` a body's
  // send ran — has already made the runtime stop: it is still the defect.
  if (phase < 2) {
    culprit = fiber;
    stopping();
    if (defect !== null) defect(null);
    return;
  }
  if (fiber !== null && fiber.outcome === null) {
    recover(fiber);
    enqueue(fiber, null, null);
  }
  macrotask(drain);
};

// ---- The run loop -----------------------------------------------------------

const run = (fiber, start) => {
  const outer = current;
  current = fiber;
  fiber.parked = null;
  let value = start;
  for (;;) {
    if (fiber.interrupted && fiber.masks === 0 && !fiber.unwinding) {
      unwind(fiber);
      value = null;
    }
    const next = fiber.stack.pop();
    value = next(value);
    if (fiber.outcome !== null) break;
    if (value === Y) {
      const p = pending;
      pending = null;
      for (let i = p.ks.length - 1; i >= 0; i--) fiber.stack.push(p.ks[i]);
      if (p.interrupt) {
        // Cancelled by itself (a joined fiber that was cancelled), or an
        // interrupt delivered at this suspension point: unwind now,
        // whatever the masks say, since there is no value to go on with.
        unwind(fiber);
        value = null;
        continue;
      }
      if (expired && cleaning !== null && cleaning.has(fiber)) {
        // Past the teardown's deadline a finaliser runs only to its first
        // wait, and the fiber goes on to its next (§9.8.14 (f)).
        abandon(fiber, p.wait);
        value = null;
        continue;
      }
      fiber.parked = p.wait;
      break;
    }
  }
  current = outer;
};

// Park the current fiber until `register`'s resume is called, or answer at
// once when it is called before `register` returns. `register` returns a
// canceller, or null.
const suspend = (register) => {
  const fiber = current;
  if (fiber.interrupted && fiber.masks === 0 && !fiber.unwinding) {
    pending = { ks: [], wait: null, interrupt: true };
    return Y;
  }
  const wait = { done: false, sync: true, ready: false, value: null, cancel: null };
  const resume = (value) => {
    if (wait.done) return;
    wait.done = true;
    if (wait.sync) {
      wait.ready = true;
      wait.value = value;
      return;
    }
    enqueue(fiber, value, wait);
  };
  const cancel = register(resume);
  wait.sync = false;
  if (wait.ready) return wait.value;
  wait.cancel = cancel;
  pending = { ks: [], wait, interrupt: false };
  return Y;
};

// The current fiber cancels itself: there is no value to return.
const selfCancel = () => {
  current.interrupted = true;
  pending = { ks: [], wait: null, interrupt: true };
  return Y;
};

// ---- Ending, and interruption (§6.2) ----------------------------------------

const done = (value) => ({ $: "Done", a: value });

const complete = (fiber, outcome) => {
  fiber.outcome = outcome;
  fiber.stack = null;
  live -= 1;
  if (fiber.scope !== null) fiber.scope.children.delete(fiber);
  else if (fiber.parent !== null) {
    if (fiber.parent.children !== null) fiber.parent.children.delete(fiber);
  } else unlist(fiber);
  const observers = fiber.observers;
  fiber.observers = null;
  if (observers !== null) for (const o of observers) o(fiber);
  if (live === 0 && phase === 2) allEnded();
};

const observe = (fiber, observer) => {
  if (fiber.observers === null) fiber.observers = [observer];
  else fiber.observers.push(observer);
};

const unobserve = (fiber, observer) => {
  if (fiber.observers === null) return;
  const i = fiber.observers.indexOf(observer);
  if (i >= 0) fiber.observers.splice(i, 1);
};

// Interrupt `fiber`: resume it at once if it is parked where it may be
// interrupted — its wait's canceller runs and the wait's later answer is
// dropped — or latch the interrupt for its next suspension point.
const interrupt = (fiber) => {
  if (fiber.outcome !== null || fiber.unwinding) return;
  fiber.interrupted = true;
  const wait = fiber.parked;
  if (wait === null || fiber.masks !== 0) return;
  fiber.parked = null;
  wait.done = true;
  // Queued before its canceller runs, so a canceller that throws cannot
  // leave a fiber that never unwinds (boundary.md §9.8.14 (d) step 1).
  enqueue(fiber, null, null);
  if (wait.cancel !== null) wait.cancel(null);
};

// Park until every one of `fibers` has ended; null at once when they have.
const waitAll = (fibers) => {
  let left = 0;
  for (const f of fibers) if (f.outcome === null) left += 1;
  if (left === 0) return null;
  return suspend((resume) => {
    const each = () => {
      left -= 1;
      if (left === 0) resume(null);
    };
    for (const f of fibers) if (f.outcome === null) observe(f, each);
    return () => {
      for (const f of fibers) unobserve(f, each);
    };
  });
};

// Interrupt `fibers` and wait for them, then go on with `value`.
const cancelAll = (fibers, value) => {
  for (const f of fibers) interrupt(f);
  const r = waitAll(fibers);
  if (r !== Y) return value;
  pending.ks.push(() => value);
  return Y;
};

// The bottom of every fiber's stack: its children are cancelled and waited
// for, then it is done.
const finish = (value) => {
  const fiber = current;
  fiber.unwinding = true;
  if (fiber.children !== null && fiber.children.size !== 0) {
    const r = cancelAll([...fiber.children], value);
    if (r === Y) {
      pending.ks.push(finished);
      return Y;
    }
  }
  complete(fiber, done(value));
  return value;
};

const finished = (value) => {
  complete(current, done(value));
  return value;
};

// Replace `fiber`'s stack with its cancellation: its children first, then
// its finalisers, last first, then its end (§16.4, the owner's A11). Each
// finaliser runs above a boundary, so a teardown can cut what it left on
// the stack back to the next one (boundary.md §9.8.14 (d) step 3); the
// fibers inside one are `cleaning`.
const unwind = (fiber) => {
  fiber.unwinding = true;
  fiber.parked = null;
  fiber.stack.length = 0;
  fiber.stack.push(ended);
  const fins = fiber.finalizers;
  fiber.finalizers = null;
  if (fins !== null) {
    for (const fin of fins) {
      fiber.stack.push(boundary, () => {
        (cleaning ??= new Set()).add(current);
        return fin(null);
      });
    }
  }
  fiber.stack.push(stopChildren);
};

let cleaning = null;

const boundary = (value) => {
  cleaning.delete(current);
  return value;
};

// Discard what the finaliser `fiber` is inside left on its stack: it goes
// on to its next finaliser, the one it was in counting as run.
const cutBack = (fiber) => {
  const stack = fiber.stack;
  while (stack.length !== 0 && stack.pop() !== boundary);
  cleaning.delete(fiber);
};

const stopChildren = () => {
  const fiber = current;
  if (fiber.children === null || fiber.children.size === 0) return null;
  return cancelAll([...fiber.children], null);
};

const ended = () => {
  complete(current, cancelled);
  return null;
};

// ---- The API ----------------------------------------------------------------

const fork = (parent, work, scope) => {
  const fiber = newFiber(parent);
  fiber.stack.push(finish, () => work(null));
  live += 1;
  if (scope !== null) {
    fiber.scope = scope;
    scope.children.add(fiber);
    if (scope.closed) fiber.interrupted = true;
  } else if (parent !== null) {
    if (parent.children === null) parent.children = new Set();
    parent.children.add(fiber);
  } else roots.push(fiber);
  // Started while the runtime stops: cancelled before it runs.
  if (phase !== 0) fiber.interrupted = true;
  enqueue(fiber, null, null);
  return fiber;
};

export const callback = (register) =>
  suspend((resume) => {
    const cancel = register(resume);
    return typeof cancel === "function" ? cancel : null;
  });

// Outside any fiber but inside work `soon` runs, a child belongs to that
// work and is cancelled when it returns — where a fiber's `finish` would
// have cancelled it (boundary.md §9.8.11 (b)). It cannot have run yet: it
// is queued behind the work.
const endSoon = (s) => {
  for (const f of s.kids) interrupt(f);
};

export const spawn = (work) => {
  if (current !== null || soonRunning === null) return fork(current, work, null);
  const s = soonRunning;
  const child = fork(null, work, null);
  s.kids ??= [];
  s.kids.push(child);
  s.end = endSoon;
  return child;
};

export const spawnIn = (scope, work) => fork(current, work, scope);

export const start = (work, report) => {
  const fiber = fork(null, work, null);
  observe(fiber, (f) => report(f.outcome));
  return null;
};

const joined = (outcome) => (outcome.$ === "Done" ? outcome.a : selfCancel());

const outcomeOf = (fiber) =>
  suspend((resume) => {
    const o = (f) => resume(f.outcome);
    observe(fiber, o);
    return () => unobserve(fiber, o);
  });

export const join = (fiber) => {
  if (fiber.outcome !== null) return joined(fiber.outcome);
  const r = outcomeOf(fiber);
  if (r !== Y) return joined(r);
  pending.ks.push(joined);
  return Y;
};

export const wait = (fiber) => {
  if (fiber.outcome !== null) return fiber.outcome;
  return outcomeOf(fiber);
};

export const cancel = (fiber) => {
  if (fiber === current) return selfCancel();
  if (fiber.outcome !== null) return null;
  interrupt(fiber);
  const r = waitAll([fiber]);
  return r === Y ? Y : null;
};

export const yieldNow = (unit) => {
  const fiber = current;
  if (fiber.interrupted && fiber.masks === 0 && !fiber.unwinding) return selfCancel();
  const wait = { done: false, sync: false, ready: false, value: null, cancel: null };
  pending = { ks: [], wait, interrupt: false };
  enqueue(fiber, null, wait);
  return Y;
};

export const openScope = (unit) => {
  const scope = { children: new Set(), finalizer: null, closed: false };
  scope.finalizer = () => cancelAll([...scope.children], null);
  const fiber = here();
  if (fiber.finalizers === null) fiber.finalizers = [];
  fiber.finalizers.push(scope.finalizer);
  return scope;
};

const dropFinalizer = (fiber, fin) => {
  const fins = fiber.finalizers;
  if (fins === null) return;
  const i = fins.lastIndexOf(fin);
  if (i >= 0) fins.splice(i, 1);
};

export const closeScope = (scope, value) => {
  const fiber = here();
  const r = cancelAll([...scope.children], value);
  if (r !== Y) {
    dropFinalizer(fiber, scope.finalizer);
    return value;
  }
  pending.ks.push(() => {
    dropFinalizer(fiber, scope.finalizer);
    return value;
  });
  return Y;
};

export const running = (fiber) => fiber.outcome === null;

// Work run in no fiber, where a fiber started now would first run
// (boundary.md §9.8.11): `{ w }`, the work until it runs.
// Work that runs owns what it `spawn`s, as a fiber does its children: they
// are cancelled when it returns (`spawn` below), so a body keeps the
// structure a fiber gave it. No fiber is made: the record is the work's
// own, and `end` is set only by a `spawn`, so a build that never spawns
// keeps nothing of cancellation here.
let soonRunning = null;

const runSoon = (s) => {
  const w = s.w;
  s.w = null;
  // Program code, which no longer runs once the runtime stops: dropped.
  if (phase !== 0) return false;
  const outer = soonRunning;
  soonRunning = s;
  w(null);
  soonRunning = outer;
  if (s.end !== null) s.end(s);
  return true;
};

export const soon = (work) => {
  const s = { w: work, end: null };
  schedule(runSoon, s, null, null);
  return s;
};

export const queued = (s) => s.w !== null;

// A scope that no fiber's finalisers close, for a platform whose program
// outlives every call: one literal, the shape of `openScope`'s. It is a
// root until `closeRoot` closes it.
export const openRoot = (unit) => {
  const scope = { children: new Set(), finalizer: null, closed: false };
  roots.push(scope);
  return scope;
};

export const closeRoot = (scope) => {
  unlist(scope);
  scope.closed = true;
  for (const f of [...scope.children]) interrupt(f);
  return null;
};

// ---- Shutdown (boundary.md §9.8.14) -----------------------------------------

// Every root, in the order it was made: each scope `openRoot` made that
// `closeRoot` has not closed, and each fiber with neither a parent nor a
// scope — `start`'s, and `spawn`'s outside any fiber — that has not ended.
const roots = [];

const unlist = (root) => {
  const i = roots.indexOf(root);
  if (i >= 0) roots.splice(i, 1);
};

// The fibers that have not ended, so the teardown knows when it is over.
let live = 0;

// The teardown's: the fiber whose throw was the defect, the deadline and
// `done` `shutdown` was given, its timer, whether it has passed, how many
// finalisers it cut short, and the fibers the sweep has still to reach.
let culprit = null;
let deadline = -1;
let whenDone = null;
let deadlineTimer = null;
let expired = false;
let abandoned = 0;
let sweeping = null;
let swept = 0;

// Stop, and schedule the teardown once.
let torn = false;
const stopping = () => {
  if (phase === 0) phase = 1;
  scheduled = true;
  if (torn) return;
  torn = true;
  macrotask(teardown);
};

// `shutdown`'s part here: the first call's deadline and `done`; a second
// call does nothing.
const closeAll = (ms, over) => {
  if (whenDone !== null || phase === 3) return;
  whenDone = over;
  deadline = ms;
  if (phase === 2) deadlineTimer = globalThis.setTimeout(expire, deadline);
  stopping();
};

// The sweep (§9.8.14 (d) step 1): every root scope closed and every fiber
// of every root interrupted, in the order they were made — each parked
// fiber's canceller runs now, so what the host holds is released before any
// finaliser runs — then the culprit unwound, and a fiber started for the
// finalisers a throw left outside any fiber. A canceller that throws is
// reported by the host; the sweep goes on at the next fiber, in a new
// macrotask. Then the drain unwinds them all.
const teardown = () => {
  if (phase === 1) {
    phase = 2;
    if (whenDone !== null) deadlineTimer = globalThis.setTimeout(expire, deadline);
    sweeping = [];
    for (const root of roots) {
      if (root.stack !== undefined) sweeping.push(root);
      else {
        root.closed = true;
        for (const f of root.children) sweeping.push(f);
      }
    }
  }
  let ok = false;
  try {
    while (swept < sweeping.length) interrupt(sweeping[swept++]);
    ok = true;
  } finally {
    if (!ok) macrotask(teardown);
  }
  if (culprit !== null) {
    const fiber = culprit;
    culprit = null;
    if (fiber.outcome === null) {
      recover(fiber);
      enqueue(fiber, null, null);
    }
  }
  if (outside !== null && outside.finalizers !== null && outside.finalizers.length !== 0) {
    const fiber = newFiber(null);
    live += 1;
    fiber.finalizers = outside.finalizers;
    outside.finalizers = null;
    outside.masks = 0;
    unwind(fiber);
    enqueue(fiber, null, null);
  }
  if (live === 0) allEnded();
  else drain();
};

// Put a fiber whose code threw back on the road to its end: out of the
// finaliser it was in, to the next; or, if it was not unwinding, unwound.
const recover = (fiber) => {
  fiber.interrupted = true;
  fiber.parked = null;
  fiber.masks = 0;
  if (cleaning !== null && cleaning.has(fiber)) cutBack(fiber);
  else if (!fiber.unwinding) unwind(fiber);
  else {
    // Thrown out of a canceller while it cancelled its children.
    if (fiber.stack.length === 0) fiber.stack.push(ended);
    fiber.stack.push(stopChildren);
  }
};

// The deadline (§9.8.14 (f)): each fiber waiting inside a finaliser stops
// waiting and goes on to its next, and from now on a finaliser runs only to
// its first wait.
const expire = () => {
  deadlineTimer = null;
  expired = true;
  if (cleaning === null) return;
  // A canceller that throws is reported by the host; the rest go on in a
  // new macrotask.
  let ok = false;
  try {
    for (const fiber of [...cleaning]) {
      const wait = fiber.parked;
      if (wait === null) continue;
      fiber.parked = null;
      enqueue(fiber, null, null);
      abandon(fiber, wait);
    }
    ok = true;
  } finally {
    if (!ok) macrotask(expire);
  }
};

const abandon = (fiber, wait) => {
  wait.done = true;
  abandoned += 1;
  cutBack(fiber);
  if (wait.cancel !== null) wait.cancel(null);
};

// Every fiber has ended: the runtime stops for good, and `done` is told how
// many finalisers the deadline cut short.
const allEnded = () => {
  phase = 3;
  if (deadlineTimer !== null) globalThis.clearTimeout(deadlineTimer);
  deadlineTimer = null;
  const told = whenDone;
  if (told !== null) told(abandoned);
};

export const mask = (unit) => {
  here().masks += 1;
  return unit;
};

export const unmask = (value) => {
  here().masks -= 1;
  return value;
};

export const pushFinalizer = (resource, fin) => {
  const fiber = here();
  if (fiber.finalizers === null) fiber.finalizers = [];
  fiber.finalizers.push(fin);
  return resource;
};

export const popFinalizer = (value) => {
  const fins = here().finalizers;
  if (fins !== null) fins.pop();
  return value;
};
