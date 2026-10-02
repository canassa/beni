// The sibling JavaScript of `Hosted.beni` (docs/design/boundary.md §4,
// §9.8): one export per `foreign` value, under the same name. A `Host` is
// the runtime's object for one running program, `{ send, after }`: `send`
// dispatches a message to the program's `update`, `after` queues a
// function into the after-render phase of the next flush (backend.md
// §15.11). Everything here reaches the page only through it.

// ---- Keys: compared by value ---------------------------------------------

// The rank of a value's kind: `()`, a `Bool`, a number, a string (a
// `String` or a `Char`), then everything built of fields — a constructor,
// a record, a tuple, a list cell.
const rank = (v) => {
  if (v === null || v === undefined) return 0;
  switch (typeof v) {
    case "boolean":
      return 1;
    case "number":
      return 2;
    case "string":
      return 3;
    default:
      return 4;
  }
};

// A list in any of its forms (backend.md §4, *Lists are arrays*: a plain
// array, a view, a trie) as a plain array, so that two equal lists are
// built alike: a view's or a trie's fields are how it is stored, not what
// it holds. Every other value is itself.
const plain = (v) => (v != null && typeof v.$plain === "function" ? v.$plain() : v);

// A total order on the values a key can hold, by value alone: two values
// are equal exactly when they are built alike. Fields are compared in the
// order of their names, so a record's literal order does not matter.
const order = (x, y) => {
  if (x === y) return 0;
  const a = plain(x);
  const b = plain(y);
  const ra = rank(a);
  const rb = rank(b);
  if (ra !== rb) return ra - rb;
  if (ra === 0) return 0;
  if (ra < 4) return a < b ? -1 : a > b ? 1 : 0;
  const ka = Object.keys(a).sort();
  const kb = Object.keys(b).sort();
  if (ka.length !== kb.length) return ka.length - kb.length;
  for (let i = 0; i < ka.length; i++) {
    if (ka[i] !== kb[i]) return ka[i] < kb[i] ? -1 : 1;
  }
  for (const k of ka) {
    const c = order(a[k], b[k]);
    if (c !== 0) return c;
  }
  return 0;
};

// The key's own `compare` is not called: it is what admits the type.
export const key = (compare, k) => k;

export const compareKeys = (a, b) => {
  const c = order(a, b);
  return c < 0 ? "LT" : c > 0 ? "GT" : "EQ";
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
