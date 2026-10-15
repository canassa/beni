const Task$Cancelled = { $: "Cancelled", a: null };
const Task$host = (x$1) => x$1;
const Task$sentinel = { waiting: true };
let Task$pending = null;
const Task$andThen = (value$1, next$2) => {
  if (value$1 === Task$sentinel) {
    Task$pending.ks.push(next$2);
    return Task$sentinel;
  } else {
    return next$2(value$1);
  }
};
const Task$isWaiting = (value$1) => value$1 === Task$sentinel;
const Task$park = (w$1, intr$2) => {
  Task$pending = { interrupt: intr$2, ks: [], wait: w$1 };
  return Task$sentinel;
};
const Task$cancelled = Task$host(Task$Cancelled);
let Task$current = null;
let Task$outside = null;
let Task$fibered = false;
const Task$newFiber = (parent$1, stack$2) => {
  Task$fibered = true;
  return { children: null, finalizers: null, interrupted: false, masks: 0, observers: null, outcome: null, parent: parent$1, parked: null, scope: null, stack: stack$2, unwinding: false };
};
const Task$here = () => {
  const c$1 = Task$current;
  if (c$1 === null) {
    const o$2 = Task$outside;
    if (o$2 === null) {
      const f$3 = Task$newFiber(null, []);
      Task$outside = f$3;
      return f$3;
    } else {
      return o$2;
    }
  } else {
    return c$1;
  }
};
let Task$slotted = false;
const Task$slotsOf = (from$1) => {
  if (from$1 === undefined) {
    return undefined;
  } else {
    const src$2 = from$1 === null ? Task$outside : from$1;
    return src$2 === null ? undefined : src$2.slots;
  }
};
const Task$deliverable = (fiber$1) => fiber$1.interrupted && fiber$1.masks === 0 && !fiber$1.unwinding;
const Task$copy = (set$1) => globalThis.Array.from(set$1);
let Task$spawning = false;
const Task$none = (set$1) => set$1 === null || set$1.size === 0;
const Task$queue = [];
let Task$head = 0;
let Task$scheduled = false;
let Task$port = null;
const Task$portTasks = [];
const Task$macrotask = (task$1) => {
  const immediate$2 = globalThis.setImmediate;
  if (typeof immediate$2 === "function") {
    return immediate$2(task$1);
  } else {
    if (Task$port === null) {
      const channel$3 = new globalThis.MessageChannel();
      channel$3.port1.onmessage = ($p$1) => Task$portTasks.shift()();
      Task$port = channel$3.port2;
    }
    Task$portTasks.push(task$1);
    return Task$port.postMessage(null);
  }
};
let Task$hosting = false;
let Task$turn = null;
let Task$phase = 0;
const Task$drainFrom = (count$1) => {
  for (;;) {
    const h$2 = Task$head;
    if (h$2 >= Task$queue.length) {
      return true;
    } else {
      if (count$1 === 64 || Task$phase === 1) {
        Task$macrotask(Task$drain);
        return false;
      } else {
        const task$3 = Task$queue[h$2];
        const a$4 = Task$queue[h$2 + 1];
        const b$5 = Task$queue[h$2 + 2];
        const c$6 = Task$queue[h$2 + 3];
        Task$queue[h$2] = null;
        Task$queue[h$2 + 1] = null;
        Task$queue[h$2 + 2] = null;
        Task$queue[h$2 + 3] = null;
        Task$head = h$2 + 4;
        count$1 = task$3(a$4, b$5, c$6) ? count$1 + 1 : count$1;
      }
    }
  }
};
let Task$soonRunning = null;
let Task$culprit = null;
let Task$torn = false;
let Task$whenDone = null;
let Task$deadlineTimer = null;
let Task$expired = false;
let Task$cleaning = null;
let Task$finalising = false;
let Task$live = 0;
const Task$roots = [];
const Task$unlist = (root$1) => {
  const i$2 = Task$roots.indexOf(root$1);
  i$2 >= 0 ? Task$roots.splice(i$2, 1) : null;
};
let Task$abandoned = 0;
const Task$allEnded = () => {
  Task$phase = 3;
  const t$1 = Task$deadlineTimer;
  if (t$1 !== null) {
    globalThis.clearTimeout(t$1);
  }
  Task$deadlineTimer = null;
  const told$2 = Task$whenDone;
  return told$2 === null ? null : told$2(Task$abandoned);
};
const Task$complete = (fiber$1, outcome$2) => {
  fiber$1.outcome = outcome$2;
  fiber$1.stack = null;
  Task$live = Task$live - 1;
  const sc$3 = fiber$1.scope;
  if (!(sc$3 === null)) {
    sc$3.children.delete(fiber$1);
  } else {
    if (Task$spawning && !(fiber$1.parent === null)) {
      const parent$5 = fiber$1.parent;
      if (parent$5.children !== null) {
        parent$5.children.delete(fiber$1);
      }
    } else {
      Task$unlist(fiber$1);
    }
  }
  const observers$4 = fiber$1.observers;
  fiber$1.observers = null;
  if (observers$4 !== null) {
    for (const o$6 of observers$4) {
      o$6(fiber$1);
    }
  }
  return Task$live === 0 && Task$phase === 2 ? Task$allEnded() : null;
};
const Task$ended = ($p$2) => Task$complete(Task$current, Task$cancelled);
const Task$boundary = (value$1) => {
  Task$cleaning.delete(Task$current);
  return value$1;
};
const Task$cleaningSet = () => {
  const c$1 = Task$cleaning;
  if (c$1 === null) {
    const s$2 = new globalThis.Set();
    Task$cleaning = s$2;
    return s$2;
  } else {
    return c$1;
  }
};
const Task$cleanups = (fiber$1) => {
  const fins$2 = fiber$1.finalizers;
  fiber$1.finalizers = null;
  const stack$3 = fiber$1.stack;
  if (fins$2 !== null) {
    for (const fin$4 of fins$2) {
      stack$3.push(Task$boundary, ($p$3) => {
        Task$cleaningSet().add(Task$current);
        return fin$4(null);
      });
    }
  }
};
const Task$halt = (fiber$1) => {
  if (!(fiber$1.outcome === null) || fiber$1.unwinding) {
    return null;
  } else {
    fiber$1.interrupted = true;
    const w$2 = fiber$1.parked;
    if (w$2 === null || fiber$1.masks !== 0) {
      return null;
    } else {
      fiber$1.parked = null;
      w$2.done = true;
      Task$enqueue(fiber$1, null, null);
      const canceller$3 = w$2.cancel;
      return canceller$3 === null ? null : canceller$3(null);
    }
  }
};
const Task$suspend = (register$1) => {
  const fiber$2 = Task$current;
  if (Task$deliverable(fiber$2)) {
    return Task$park(null, true);
  } else {
    const w$3 = { cancel: null, done: false, ready: false, sync: true, value: null };
    const wake$4 = (value$6) => {
      if (w$3.done) {
        return null;
      } else {
        w$3.done = true;
        if (w$3.sync) {
          w$3.ready = true;
          w$3.value = value$6;
          return null;
        } else {
          return Task$enqueue(fiber$2, value$6, w$3);
        }
      }
    };
    const canceller$5 = register$1(wake$4);
    w$3.sync = false;
    if (w$3.ready) {
      return w$3.value;
    } else {
      w$3.cancel = canceller$5;
      return Task$park(w$3, false);
    }
  }
};
const Task$observe = (fiber$1, observer$2) => {
  if (fiber$1.observers === null) {
    fiber$1.observers = [observer$2];
    return null;
  } else {
    return fiber$1.observers.push(observer$2);
  }
};
const Task$unobserve = (fiber$1, observer$2) => {
  const os$3 = fiber$1.observers;
  if (os$3 === null) {
    return null;
  } else {
    const i$4 = os$3.indexOf(observer$2);
    return i$4 >= 0 ? os$3.splice(i$4, 1) : null;
  }
};
const Task$waitAll = (fibers$1) => {
  let left$2 = 0;
  for (const f$3 of fibers$1) {
    if (f$3.outcome === null) {
      left$2 = left$2 + 1;
    }
  }
  if (left$2 === 0) {
    return null;
  } else {
    return Task$suspend((wake$4) => {
      const each$5 = ($p$6) => {
        left$2 = left$2 - 1;
        return left$2 === 0 ? wake$4(null) : null;
      };
      for (const f$6 of fibers$1) {
        if (f$6.outcome === null) {
          Task$observe(f$6, each$5);
        }
      }
      return ($p$7) => {
        for (const f$7 of fibers$1) {
          Task$unobserve(f$7, each$5);
        }
        return null;
      };
    });
  }
};
const Task$cancelEvery = (fibers$1) => {
  for (const f$2 of fibers$1) {
    Task$halt(f$2);
  }
  return Task$waitAll(fibers$1);
};
const Task$stopChildren = ($p$10) => {
  const children$1 = Task$current.children;
  if (Task$none(children$1)) {
    return null;
  } else {
    return Task$cancelEvery(Task$copy(children$1));
  }
};
const Task$unwind = (fiber$1) => {
  fiber$1.unwinding = true;
  fiber$1.parked = null;
  const stack$2 = fiber$1.stack;
  stack$2.length = 0;
  stack$2.push(Task$ended);
  if (Task$finalising) {
    Task$cleanups(fiber$1);
  }
  Task$spawning ? stack$2.push(Task$stopChildren) : null;
};
const Task$pushBack = (stack$1, ks$2, i$3) => {
  while (!(i$3 < 0)) {
    stack$1.push(ks$2[i$3]);
    i$3 = i$3 - 1;
  }
};
const Task$inCleanup = (fiber$1) => {
  const c$2 = Task$cleaning;
  return !(c$2 === null) && c$2.has(fiber$1);
};
const Task$popTo = (stack$1) => {
  while (stack$1.length !== 0) {
    if (stack$1.pop() === Task$boundary) {
      return;
    }
  }
};
const Task$cutBack = (fiber$1) => {
  Task$popTo(fiber$1.stack);
  Task$cleaning.delete(fiber$1);
  Task$cleanups(fiber$1);
};
const Task$abandon = (fiber$1, w$2) => {
  w$2.done = true;
  Task$abandoned = Task$abandoned + 1;
  Task$cutBack(fiber$1);
  const canceller$3 = w$2.cancel;
  return canceller$3 === null ? null : canceller$3(null);
};
const Task$loop = (fiber$1, first$2) => {
  for (;;) {
    let $t$12;
    if (Task$deliverable(fiber$1)) {
      Task$unwind(fiber$1);
      $t$12 = null;
    } else {
      $t$12 = first$2;
    }
    const value$3 = $t$12;
    const next$4 = fiber$1.stack.pop();
    const result$5 = next$4(value$3);
    if (!(fiber$1.outcome === null)) {
      return;
    } else {
      if (result$5 === Task$sentinel) {
        const p$6 = Task$pending;
        Task$pending = null;
        const ks$7 = p$6.ks;
        Task$pushBack(fiber$1.stack, ks$7, ks$7.length - 1);
        if (p$6.interrupt) {
          Task$unwind(fiber$1);
          first$2 = null;
        } else {
          if (Task$finalising && Task$expired && Task$inCleanup(fiber$1)) {
            Task$abandon(fiber$1, p$6.wait);
            first$2 = null;
          } else {
            fiber$1.parked = p$6.wait;
            return;
          }
        }
      } else {
        first$2 = result$5;
      }
    }
  }
};
const Task$run = (fiber$1, first$2) => {
  const outer$3 = Task$current;
  Task$current = fiber$1;
  fiber$1.parked = null;
  Task$loop(fiber$1, first$2);
  Task$current = outer$3;
};
const Task$resumeFiber = (fiber$1, value$2, w$3) => {
  if (!(w$3 === null) && !(fiber$1.parked === w$3)) {
    return false;
  } else {
    Task$run(fiber$1, value$2);
    return true;
  }
};
const Task$enqueue = (fiber$1, value$2, w$3) => Task$schedule(Task$resumeFiber, fiber$1, value$2, w$3);
const Task$expire = () => {
  Task$deadlineTimer = null;
  Task$expired = true;
  const c$1 = Task$cleaning;
  if (!Task$finalising || c$1 === null) {
    return null;
  } else {
    let ok$2 = false;
    try {
      for (const fiber$3 of Task$copy(c$1)) {
        const w$4 = fiber$3.parked;
        if (w$4 !== null) {
          fiber$3.parked = null;
          Task$enqueue(fiber$3, null, null);
          Task$abandon(fiber$3, w$4);
        }
      }
      ok$2 = true;
      return null;
    } finally {
      if (!ok$2) {
        Task$macrotask(Task$expire);
      }
    }
  }
};
let Task$deadline = 0 - 1;
const Task$arm = () => {
  Task$deadlineTimer = globalThis.setTimeout(Task$expire, Task$deadline);
};
const Task$sweeping = [];
let Task$deferring = false;
let Task$deferral = null;
let Task$swept = 0;
const Task$sweep = () => {
  for (;;) {
    const i$1 = Task$swept;
    if (i$1 < Task$sweeping.length) {
      Task$swept = i$1 + 1;
      Task$halt(Task$sweeping[i$1]);
    } else {
      return;
    }
  }
};
const Task$recover = (fiber$1) => {
  fiber$1.interrupted = true;
  fiber$1.parked = null;
  fiber$1.masks = 0;
  if (Task$finalising && Task$inCleanup(fiber$1)) {
    Task$cutBack(fiber$1);
  } else {
    if (!fiber$1.unwinding) {
      Task$unwind(fiber$1);
    } else {
      const stack$2 = fiber$1.stack;
      if (stack$2.length === 0) {
        stack$2.push(Task$ended);
      }
      Task$spawning ? stack$2.push(Task$stopChildren) : null;
    }
  }
};
const Task$teardown = () => {
  if (Task$phase === 1) {
    Task$phase = 2;
    if (Task$whenDone !== null) {
      Task$arm();
    }
    for (const root$4 of Task$roots) {
      if (root$4.stack === undefined) {
        root$4.closed = true;
        for (const f$5 of root$4.children) {
          Task$sweeping.push(f$5);
        }
      } else {
        Task$sweeping.push(root$4);
      }
    }
    if (Task$deferring) {
      Task$deferral.roots(Task$roots, Task$cancelled);
    }
  }
  let ok$1 = false;
  try {
    Task$sweep();
    ok$1 = true;
  } finally {
    if (!ok$1) {
      Task$macrotask(Task$teardown);
    }
  }
  const c$2 = Task$culprit;
  if (c$2 !== null) {
    Task$culprit = null;
    if (c$2.outcome === null) {
      Task$recover(c$2);
      Task$enqueue(c$2, null, null);
    }
  }
  const o$3 = Task$outside;
  if (!(!Task$finalising || o$3 === null || Task$none(o$3.finalizers))) {
    const fiber$6 = Task$newFiber(null, []);
    Task$live = Task$live + 1;
    fiber$6.finalizers = o$3.finalizers;
    o$3.finalizers = null;
    o$3.masks = 0;
    Task$unwind(fiber$6);
    Task$enqueue(fiber$6, null, null);
  }
  return Task$live === 0 ? Task$allEnded() : Task$drain();
};
const Task$stopping = () => {
  if (Task$phase === 0) {
    Task$phase = 1;
  }
  Task$scheduled = true;
  if (Task$torn) {
    return null;
  } else {
    Task$torn = true;
    return Task$macrotask(Task$teardown);
  }
};
let Task$defect = null;
const Task$failed = () => {
  const fiber$1 = Task$current;
  Task$current = null;
  Task$pending = null;
  Task$soonRunning = null;
  const o$2 = Task$outside;
  if (o$2 !== null) {
    o$2.masks = 0;
  }
  if (Task$phase < 2) {
    Task$culprit = fiber$1;
    Task$stopping();
    const d$3 = Task$defect;
    return d$3 === null ? null : d$3(null);
  } else {
    if (!(fiber$1 === null) && fiber$1.outcome === null) {
      Task$recover(fiber$1);
      Task$enqueue(fiber$1, null, null);
    }
    return Task$macrotask(Task$drain);
  }
};
const Task$guard = () => {
  if (Task$fibered) {
    return Task$failed();
  } else {
    Task$phase = 1;
    const d$1 = Task$defect;
    return d$1 === null ? null : d$1(null);
  }
};
const Task$drainNow = () => {
  if ((Task$phase & 1) !== 0) {
    return null;
  } else {
    let ok$1 = false;
    let $t$13;
    try {
      const r$3 = Task$drainFrom(0);
      ok$1 = true;
      $t$13 = r$3;
    } finally {
      if (!ok$1) {
        Task$guard();
      }
    }
    const emptied$2 = $t$13;
    if (emptied$2) {
      Task$queue.length = 0;
      Task$head = 0;
      Task$scheduled = false;
      return null;
    } else {
      return null;
    }
  }
};
const Task$drain = () => Task$turn === null ? Task$drainNow() : Task$turn(Task$drainNow);
const Task$schedule = (task$1, a$2, b$3, c$4) => {
  Task$queue.push(task$1, a$2, b$3, c$4);
  if (Task$scheduled) {
    return null;
  } else {
    Task$scheduled = true;
    return Task$hosting ? null : globalThis.queueMicrotask(Task$drain);
  }
};
const Task$fromHost = (f$1) => {
  if (Task$scheduled) {
    return f$1(null);
  } else {
    Task$hosting = true;
    let ok$2 = false;
    try {
      f$1(null);
      ok$2 = true;
    } finally {
      Task$hosting = false;
      if (!(ok$2 || !Task$scheduled)) {
        globalThis.queueMicrotask(Task$drain);
      }
    }
    return Task$scheduled ? Task$drain() : null;
  }
};
const Task$onTurn = (f$1) => {
  Task$turn = f$1;
  return null;
};
const Task$onDefect = (f$1) => {
  Task$defect = f$1;
  return null;
};
let Task$soonQueued = false;
let Task$releasing = false;
const Task$releases = [];
const Task$releaseAll = () => {
  while (Task$releases.length !== 0) {
    Task$releases.shift()(null);
  }
  return null;
};
const Task$onShutdown = (f$1) => {
  Task$releasing = true;
  return Task$releases.push(f$1);
};
const Task$stopQueue = () => {
  if (Task$phase === 0) {
    Task$phase = 1;
  }
};
const Task$closeAll = (ms$1, over$2) => {
  if (!(Task$whenDone === null) || Task$phase === 3) {
    return null;
  } else {
    Task$whenDone = over$2;
    Task$deadline = ms$1;
    if (Task$phase === 2) {
      Task$arm();
    }
    return Task$stopping();
  }
};
const Task$shutdown = (ms$1, over$2) => {
  if (Task$soonQueued) {
    Task$stopQueue();
  }
  if (Task$releasing) {
    globalThis.queueMicrotask(Task$releaseAll);
  }
  return Task$fibered ? Task$closeAll(ms$1, over$2) : null;
};
const Task$selfCancel = () => {
  Task$current.interrupted = true;
  return Task$park(null, true);
};
const Task$finished = (value$1) => {
  Task$complete(Task$current, Task$host({ $: "Done", a: value$1 }));
  return value$1;
};
const Task$finish = (value$1) => {
  const fiber$2 = Task$current;
  fiber$2.unwinding = true;
  if (!Task$spawning) {
    return Task$finished(value$1);
  } else {
    const children$3 = fiber$2.children;
    if (Task$none(children$3)) {
      return Task$finished(value$1);
    } else {
      return Task$andThen(Task$cancelEvery(Task$copy(children$3)), ($t$15) => Task$finished(value$1));
    }
  }
};
const Task$fork = (parent$1, work$2, sc$3, from$4) => {
  const fiber$5 = Task$newFiber(parent$1, [Task$finish, work$2]);
  if (Task$slotted) {
    fiber$5.slots = Task$slotsOf(from$4);
  }
  Task$live = Task$live + 1;
  if (!(sc$3 === null)) {
    fiber$5.scope = sc$3;
    if (sc$3.closed) {
      fiber$5.interrupted = true;
    } else {
      if (sc$3.finalizer === null) {
        sc$3.finalizer = false;
        Task$roots.push(sc$3);
      }
    }
    sc$3.children.add(fiber$5);
  } else {
    if (Task$spawning && !(parent$1 === null)) {
      if (parent$1.children === null) {
        parent$1.children = new globalThis.Set();
      }
      parent$1.children.add(fiber$5);
    } else {
      Task$roots.push(fiber$5);
    }
  }
  if (Task$phase !== 0) {
    fiber$5.interrupted = true;
  }
  Task$enqueue(fiber$5, null, null);
  return fiber$5;
};
const Task$callback = (register$1) => Task$suspend((wake$2) => {
  const canceller$3 = register$1(wake$2);
  return typeof canceller$3 === "function" ? canceller$3 : null;
});
const Task$spawnIn = (sc$1, work$2) => Task$fork(Task$current, work$2, sc$1, Task$current);
const Task$cleansUp = () => Task$fibered;
const Task$cancel = (fiber$1) => {
  const f$2 = fiber$1;
  if (f$2 === Task$current) {
    return Task$selfCancel();
  } else {
    if (!(f$2.outcome === null)) {
      return null;
    } else {
      Task$halt(f$2);
      return Task$waitAll([f$2]);
    }
  }
};
const Task$addFinalizer = (fiber$1, fin$2) => {
  Task$finalising = true;
  const fins$3 = fiber$1.finalizers;
  if (fins$3 === null) {
    fiber$1.finalizers = [fin$2];
  } else {
    fins$3.push(fin$2);
  }
};
const Task$runSoon = (s$1) => {
  const w$2 = s$1.w;
  s$1.w = null;
  if (Task$phase !== 0) {
    return false;
  } else {
    const outer$3 = Task$soonRunning;
    Task$soonRunning = s$1;
    w$2(null);
    Task$soonRunning = outer$3;
    if (Task$spawning) {
      const end$4 = s$1.end;
      if (!(end$4 == null)) {
        end$4(s$1);
      }
    }
    return true;
  }
};
const Task$soon = (work$1) => {
  Task$soonQueued = true;
  const s$2 = { w: work$1 };
  Task$schedule(Task$runSoon, s$2, null, null);
  return s$2;
};
const Task$openRoot = () => ({ children: new globalThis.Set(), closed: false, finalizer: null });
const Task$mask = () => {
  const f$1 = Task$here();
  f$1.masks = f$1.masks + 1;
  return null;
};
const Task$unmask = (value$1) => {
  const f$2 = Task$here();
  f$2.masks = f$2.masks - 1;
  return value$1;
};
const Task$pushFinalizer = (resource$1, fin$2) => {
  Task$addFinalizer(Task$here(), fin$2);
  return resource$1;
};
const Task$popFinalizer = (value$1) => {
  const fins$2 = Task$here().finalizers;
  if (fins$2 !== null) {
    fins$2.pop();
  }
  return value$1;
};
const Task$uninterruptible = (work$1) => Task$unmask(work$1(Task$mask()));
const Task$uninterruptible$s = (work$1) => Task$andThen(work$1(Task$mask()), ($t$19) => Task$unmask($t$19));
const Task$after = ($p$20, value$1) => value$1;
const Task$bracket$s = (acquire$1, release$2, use$3) => Task$andThen(Task$uninterruptible$s(acquire$1), ($t$21) => {
  const resource$4 = $t$21;
  return Task$andThen(use$3(Task$pushFinalizer(resource$4, () => release$2(resource$4, Task$Cancelled))), ($t$23) => {
    const result$5 = $t$23;
    return Task$uninterruptible$s(() => Task$andThen(release$2(resource$4, { $: "Done", a: Task$popFinalizer(result$5) }), ($t$24) => Task$after($t$24, result$5)));
  });
});
export { Task$andThen, Task$isWaiting, Task$fromHost, Task$onTurn, Task$onDefect, Task$onShutdown, Task$shutdown, Task$callback, Task$spawnIn, Task$cleansUp, Task$cancel, Task$soon, Task$openRoot, Task$uninterruptible, Task$uninterruptible$s, Task$bracket$s };
//# sourceMappingURL=Task.mjs.map
