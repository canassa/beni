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

// `{ b, t }`: the body a fiber runs, and the tagger of what it sends.
export const tap = (body, tag) => ({ b: body, t: tag });

export const mapTap = (tp, f) => {
  const inner = tp.t;
  return { b: tp.b, t: (x) => f(inner(x)) };
};

export const relay = (host, tp) => ({ h: host, b: tp.b, t: [tp.t], open: true });

// The body's own value, or the fiber runtime's sentinel when it parked:
// either way this call's caller receives what the body returned.
export const run = (r) =>
  r.b((value) => {
    if (!r.open) return null;
    for (const t of r.t) r.h.send(t(value));
    return null;
  });

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
