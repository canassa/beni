// The sibling JavaScript of `Browser.beni` (docs/design/boundary.md §4): a
// program is an array of mounts, `{ a, n, h }` (`program`'s is made in
// beni, in `Browser.beni`) — the record it was given,
// the id of the element it mounts at or null for `document.body`, and for
// a `hosted` program the function that turns it into a record the
// platform's runtime mounts — which only the runtime reads.
//
// Everything a hosted program adds to the render loop is here, so a page
// that mounts none ships none of it (research 40 §8, rule 2): the
// dispatcher, the after-render phase, `flush`'s guards and the waits of
// `Dom.rendered`. A sibling may not import another file (backend.md §2), so
// the runtime hands a hosted mount what it needs by value — its `flush`,
// and a function that sets the after-render phase and answers whether a
// flush is queued — and a flush is queued through the mount node's `send`,
// with `Skip`, which renders nothing.

export const hosted = (p) => [{ n: null, h: (root, flush, loop) => Host(p, root, flush, loop) }];

export const mountAt = (program, id) => program.map((m) => ({ a: m.a, n: id, h: m.h }));

export const programs = (list) => {
  const all = [];
  const items = Array.isArray(list) ? list : list.$plain();
  for (let k = 0; k < items.length; k++) for (const m of items[k]) all.push(m);
  return all;
};

// The runtime's loop, once a hosted program has mounted (null before), and
// what queues a flush: the last hosted mount node's `send`, with `Skip`.
let Flush = null;
let Loop = null;
let Nudge = null;
// A message no `update` sees: sent to queue a flush, and the render it
// queues shows what the program showed.
const Skip = {};
// After-render work queued since the last flush, and the resumes of the
// fibers waiting for its phase (`onRendered`), first queued first.
let Later = [];
let Waiters = [];
// A hosted program renders in a flush, or the after-render phase runs;
// and a message is being dispatched. `flush` does nothing during either:
// the flush already queued renders what the dispatch did.
let Busy = false;
let Dispatching = false;
// Messages sent while one was being dispatched, as apply, message pairs.
let Inbox = [];

// The after-render phase, which ends every flush once a hosted program
// has mounted: the fibers waiting in `Dom.rendered` resume, in the order
// they waited, then the work queued before this flush began runs, first
// queued first, each at once. Work queued, or a message sent, while it
// runs is the next flush's.
const Phase = () => {
  const resumes = Waiters;
  const work = Later;
  Waiters = [];
  Later = [];
  Busy = true;
  try {
    for (const resume of resumes) resume(null);
    for (const f of work) f();
  } finally {
    Busy = false;
  }
};

// A hosted mount, as the runtime reads one: `{ init, update, view }`
// whose `update` dispatches and whose `view` settles first, the model
// held here. `send` is the mount node's, which queues the render and its
// flush before it calls `update` (backend.md §15.11). The first `view`,
// at mount, is of `settle(host, init(host))`; every later one is in a
// flush, and settles and renders only when a message was applied since
// the last — a render `Skip` queued shows again what was shown.
const Host = (p, root, flush, loop) => {
  Flush = flush;
  Loop = loop;
  loop(Phase);
  const nudge = () => root.$$root(Skip);
  Nudge = nudge;
  let model = null;
  let started = false;
  let dirty = false;
  let shown = null;
  const host = {
    send: (msg) => root.$$root(msg),
    after: (f) => {
      Later.push(f);
      nudge();
    },
  };
  const apply = (msg) => {
    dirty = true;
    model = p.update(host, msg, model);
  };
  return {
    init: null,
    // Apply one message, and every message sent meanwhile after it, in
    // the order they were sent, each exactly once (boundary.md §9.8.4).
    update: (msg) => {
      if (msg === Skip) return null;
      if (Dispatching) {
        Inbox.push(apply, msg);
        return null;
      }
      Dispatching = true;
      try {
        apply(msg);
        for (let i = 0; i < Inbox.length; i += 2) Inbox[i](Inbox[i + 1]);
      } finally {
        Inbox = [];
        Dispatching = false;
      }
      return null;
    },
    view: () => {
      if (!started) {
        started = true;
        model = p.settle(host, p.init(host));
        return (shown = p.view(model));
      }
      if (!dirty) return shown;
      dirty = false;
      Busy = true;
      try {
        model = p.settle(host, model);
        return (shown = p.view(model));
      } finally {
        Busy = false;
      }
    },
  };
};

export const flush = (unit) => {
  if (Flush !== null && !Busy && !Dispatching) Flush();
  return null;
};

// At once when no flush is queued and no after-render work waits,
// otherwise at the start of the next flush's after-render phase.
export const onRendered = (resume) => {
  if (Flush === null || (!Loop(Phase) && Later.length === 0)) {
    resume(null);
    return null;
  }
  Waiters.push(resume);
  Nudge();
  return () => {
    const i = Waiters.indexOf(resume);
    if (i >= 0) Waiters.splice(i, 1);
    return null;
  };
};
