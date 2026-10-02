// The sibling JavaScript of `Hosted.beni` (docs/design/boundary.md §4,
// §9.8): one export per `foreign` value, under the same name. A `Host` is
// the runtime's object for one running program, `{ send, after }`: `send`
// dispatches a message to the program's `update`, `after` queues a
// function into the after-render phase of the next flush (backend.md
// §15.11). Everything here reaches the page only through it.

// ---- Keys: by their types' identities, then by their types' `compare` -----

// `{ t, c, v }`: the identity of the key's type, the compiler's string
// (static-dispatch-spike.md §8.6); the type's own `compare`, the `where`
// clause's evidence; and the value (boundary.md §9.8.3).
export const keyOf = (compare, type, value) => ({ t: type, c: compare, v: value });

// Two keys of one identity are of one type, so either's `compare` orders
// both; keys of two types are ordered by their identities' text.
export const compareKeys = (a, b) => {
  if (a === b) return "EQ";
  if (a.t !== b.t) return a.t < b.t ? "LT" : "GT";
  return a.c(a.v, b.v);
};

// ---- Outlets ----------------------------------------------------------------

export const outlet = (host) => ({ h: host, open: true });

export const emit = (o, msg) => {
  if (o.open) o.h.send(msg);
  return null;
};

export const close = (o) => {
  o.open = false;
  return null;
};

// ---- Jobs: a command's body -------------------------------------------------

// A job is the body itself, a function of its `send`.
export const job = (body) => body;

export const mapJob = (j, tag) => (send) => j((m) => send(tag(m)));

// The body's own value, or the fiber runtime's sentinel when it parked:
// either way this call's caller receives what the body returned.
export const runJob = (j, send) => j(send);

export const callJob = (j, send) => j(send);

// ---- After-render work ------------------------------------------------------

// `{ f, t }`: the body, and the tagger its messages go through or null.
export const later = (body) => ({ f: body, t: null });

export const mapLater = (l, tag) => {
  const inner = l.t;
  return { f: l.f, t: inner === null ? tag : (m) => tag(inner(m)) };
};

export const afterRender = (host, l) => {
  const tag = l.t;
  host.after(() => l.f((m) => host.send(tag === null ? m : tag(m))));
  return null;
};

// ---- Subscriptions ----------------------------------------------------------

// `{ b, t }`: the body a fiber runs, or the listener a `hook` adds — handed
// what each value goes to, it returns what removes it — and the tagger of
// what it sends.
export const tap = (body, tag) => ({ b: body, t: tag });

export const hook = (start, tag) => ({ b: start, t: tag });

export const mapTap = (tp, f) => {
  const inner = tp.t;
  return { b: tp.b, t: (x) => f(inner(x)) };
};

// `{ h, b, t, open, x, q }`: the program, the tap's body or listener, the
// current taggers, whether it is open, and for a listener run with no fiber
// what removes it once added and the values sent and not yet delivered
// (null while no delivery is queued).
export const relay = (host, tp) => ({ h: host, b: tp.b, t: [tp.t], open: true, x: null, q: null });

// One value, through every current tagger of an open relay. (Not `send`:
// a parameter of that name elsewhere in this file would keep it alive in a
// build that never reaches it, `src/js/Minify.zig`.)
const tagged = (r, value) => {
  if (r.open) for (const t of r.t) r.h.send(t(value));
  return null;
};

// The body's own value, or the fiber runtime's sentinel when it parked:
// either way this call's caller receives what the body returned.
export const run = (r) => r.b((value) => tagged(r, value));

// The relays whose listener is added, which the program's stop removes.
const heard = new Set();
let released = false;

// A listener with no fiber (boundary.md §9.8.5). `queue` is core's
// `Task.soon`: the listener is added where the fiber that ran it would
// first have run, and the first value sent queues one delivery where that
// fiber's resumption would have landed; values sent before it runs, or
// while it sends, join it, and it sends them all in order. `onShutdown` is
// core's, handed what removes every listener still added.
export const listen = (r, queue, onShutdown) => {
  queue(() => {
    if (!r.open) return null;
    if (!released) {
      released = true;
      onShutdown(() => {
        for (const h of heard) h.x(null);
        heard.clear();
        return null;
      });
    }
    heard.add(r);
    r.x = r.b((value) => {
      if (r.q !== null) {
        r.q.push(value);
        return null;
      }
      r.q = [value];
      queue(() => {
        for (let i = 0; i < r.q.length; i++) tagged(r, r.q[i]);
        r.q = null;
        return null;
      });
      return null;
    });
    return null;
  });
  return null;
};

export const starter = (r) => r.b;

export const deliver = (r, value) => tagged(r, value);

export const retap = (r, list) => {
  const taggers = [];
  const items = Array.isArray(list) ? list : list.$plain();
  for (let k = 0; k < items.length; k++) taggers.push(items[k].t);
  r.t = taggers;
  return null;
};

export const closeRelay = (r) => {
  r.open = false;
  return null;
};

export const unhear = (r) => {
  r.open = false;
  const x = r.x;
  if (x !== null) {
    r.x = null;
    heard.delete(r);
    x(null);
  }
  return null;
};
