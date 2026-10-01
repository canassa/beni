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
// lowering. One literal, keys always in this order, so one hidden class.
const newFiber = (parent) => ({
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
});

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

// Ready fibers, FIFO, as triples: the fiber, the value it resumes with, and
// the wait that value answers (null for a start or an interrupt). A triple
// whose wait is no longer what the fiber is parked on is stale and skipped.
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

const enqueue = (fiber, value, wait) => {
  queue.push(fiber, value, wait);
  if (scheduled) return;
  scheduled = true;
  queueMicrotask(drain);
};

// A fiber that throws is a defect (boundary.md §9.8.10 (c)): the scheduler
// stops — `scheduled` stays set, so nothing drains again — the platform's
// hook runs, and the throw goes on to the host. Not a `catch`: nothing is
// caught (CLAUDE.md rule 9).
let defect = null;
export const onDefect = (f) => {
  defect = f;
  return null;
};

const drain = () => {
  let count = 0;
  let ok = false;
  try {
    while (head < queue.length) {
      if (count === budget) {
        ok = true;
        macrotask(drain);
        return;
      }
      const fiber = queue[head];
      const value = queue[head + 1];
      const wait = queue[head + 2];
      queue[head] = queue[head + 1] = queue[head + 2] = undefined;
      head += 3;
      if (wait !== null && fiber.parked !== wait) continue;
      count += 1;
      run(fiber, value);
    }
    ok = true;
  } finally {
    if (!ok && defect !== null) defect(null);
  }
  queue.length = 0;
  head = 0;
  scheduled = false;
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
  if (fiber.scope !== null) fiber.scope.children.delete(fiber);
  else if (fiber.parent !== null && fiber.parent.children !== null) fiber.parent.children.delete(fiber);
  const observers = fiber.observers;
  fiber.observers = null;
  if (observers !== null) for (const o of observers) o(fiber);
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
  if (wait.cancel !== null) wait.cancel(null);
  enqueue(fiber, null, null);
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
// its finalisers, last first, then its end (§16.4, the owner's A11).
const unwind = (fiber) => {
  fiber.unwinding = true;
  fiber.parked = null;
  fiber.stack.length = 0;
  fiber.stack.push(ended);
  const fins = fiber.finalizers;
  fiber.finalizers = null;
  if (fins !== null) for (const fin of fins) fiber.stack.push(() => fin(null));
  fiber.stack.push(stopChildren);
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
  if (scope !== null) {
    fiber.scope = scope;
    scope.children.add(fiber);
    if (scope.closed) fiber.interrupted = true;
  } else if (parent !== null) {
    if (parent.children === null) parent.children = new Set();
    parent.children.add(fiber);
  }
  enqueue(fiber, null, null);
  return fiber;
};

export const callback = (register) =>
  suspend((resume) => {
    const cancel = register(resume);
    return typeof cancel === "function" ? cancel : null;
  });

export const spawn = (work) => fork(current, work, null);

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

// A scope that no fiber's finalisers close, for a platform whose program
// outlives every call: one literal, the shape of `openScope`'s.
export const openRoot = (unit) => ({ children: new Set(), finalizer: null, closed: false });

export const closeRoot = (scope) => {
  scope.closed = true;
  for (const f of [...scope.children]) interrupt(f);
  return null;
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
