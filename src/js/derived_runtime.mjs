// The derived-comparison runtime (docs/design/backend.md §4, *Derived
// comparisons do not grow the native stack*). The compiler writes this file
// as `_core/_derived.mjs` when a module it wrote imports from it.
//
// A derived `eq` or `compare` that can recurse takes a depth after its two
// values. Past the limit it hands its steps (a generator) to `deep`, which
// runs them from an explicit stack. `request` is the depth that asks a
// function for its steps, or a forwarder for its tail call as `[f, args…]`,
// instead of the answer; anything at or past it is a request.
const request = 2 ** 30;

export const deep = (g, d) => {
  if (d >= request) return g;
  const waiting = [];
  let t = g;
  let v;
  while (true) {
    if (typeof t === "object") {
      if (t.next === undefined) {
        // A forwarder's tail call, `[f, args…]`: make it as a request.
        const f = t.shift();
        t.push(request);
        t = f.apply(null, t);
        continue;
      }
      const n = t.next(v);
      v = n.value;
      if (typeof v === "object") {
        // Steps or a request: yielded, `t` waits for its answer; returned,
        // it answers for `t`.
        if (!n.done) waiting.push(t);
        t = v;
        continue;
      }
    } else {
      // An answer: a Bool, or an Order, which is a bare tag string.
      v = t;
    }
    if (waiting.length === 0) return v;
    t = waiting.pop();
  }
};

// `List.eq` and `List.compare` as derived code calls them: the loops of
// core/List.js, handing their depth to every element, or their steps to
// `deep` when asked.
export const listEq = (m0, xs, ys, depth) => {
  if (depth >= request) return listSteps(m0, xs, ys, true);
  let a = xs;
  let b = ys;
  while (a.$ === 1 && b.$ === 1) {
    if (!m0(a.a, b.a, depth)) return false;
    a = a.b;
    b = b.b;
  }
  return a.$ === b.$;
};

export const listCompare = (m0, xs, ys, depth) => {
  if (depth >= request) return listSteps(m0, xs, ys, false);
  let a = xs;
  let b = ys;
  while (a.$ === 1 && b.$ === 1) {
    const o = m0(a.a, b.a, depth);
    if (o !== "EQ") return o;
    a = a.b;
    b = b.b;
  }
  if (a.$ === b.$) return "EQ";
  return a.$ === 0 ? "LT" : "GT";
};

const listSteps = function* (m0, a, b, eq) {
  while (a.$ === 1 && b.$ === 1) {
    let o = m0(a.a, b.a, request);
    if (typeof o === "object") o = yield o;
    if (eq ? !o : o !== "EQ") return o;
    a = a.b;
    b = b.b;
  }
  if (eq) return a.$ === b.$;
  if (a.$ === b.$) return "EQ";
  return a.$ === 0 ? "LT" : "GT";
};
