// The in-place oracle for lists (research report 140). The compiler writes
// this file as `_core/_sanitize.mjs` in place of the sanitiser only under the
// hidden, test-only `--lists-in-place`, and only when a module it wrote
// imports it. It has the sanitiser's exports, so the lowering is the
// sanitiser's: each list write the checker accepted is a call of `list`.
//
// An accepted write edits its base's own array: the writer of `core/List`
// computes the written list, and `list` copies it into the base, which it
// answers. Every holder of the base then sees the write, and the answer is
// the base itself, so an identity compare answers what the target lowering's
// (`backend.md` §4, *Every platform edits in place*) answers. A program whose
// output under this build is the plain build's reads no list that an
// in-place write changed under it, through its elements or its identity.
//
// The forms (`core/List.beni`):
// - A plain array is written in place.
// - A view is never written (`backend.md` §4, *The representation: a plain
//   array*): its write answers a new plain array, and the view and its base
//   array keep their elements.
// - A trie header, which the target has no more, takes the written list's
//   fields in place: a trie answer's own, or, for a plain answer, a view of
//   it from 0. Every holder of the header sees the write.

const plainOf = (r) => (Array.isArray(r) ? r : r.$plain());

// A view's `$plain()`, for a trie header that became a view from 0.
function viewPlain() {
  if (this.p === null) this.p = this.b.slice(this.o);
  return this.p;
}

const intoHeader = (header, result) => {
  for (const key of Object.keys(header)) delete header[key];
  if (Array.isArray(result)) {
    Object.assign(header, { b: result, o: 0, length: result.length, p: null, $plain: viewPlain });
  } else {
    Object.assign(header, result);
  }
};

// `core/List`'s `outside`: `i` is no index below `n`.
const outside = (i, n) => i >>> 0 !== i || i >= n;

// Each writer on a plain array, as `backend.md` §4 (*The representation: a
// plain array*, *Writes*) lowers it: one store, a `push`, a `pop` or a
// `splice`, and the array answered. Out of range, the list itself, as
// `core/List` answers. Without them a write would cost what `core/List`'s
// copy costs, and a loop that pushes would be quadratic.
const plainWriters = {
  set: (a, i, v) => { if (!outside(i, a.length)) a[i] = v; return a; },
  update: (a, i, f) => { if (!outside(i, a.length)) a[i] = f(a[i]); return a; },
  push: (a, v) => { a.push(v); return a; },
  pop: (a) => { if (a.length !== 0) a.pop(); return a; },
  swap: (a, i, j) => {
    if (!outside(i, a.length) && !outside(j, a.length) && i !== j) { const x = a[i]; a[i] = a[j]; a[j] = x; }
    return a;
  },
  insertAt: (a, i, v) => { if (!outside(i, a.length + 1)) a.splice(i, 0, v); return a; },
  removeAt: (a, i) => { if (!outside(i, a.length)) a.splice(i, 1); return a; },
  append: (a, ys) => {
    const src = plainOf(ys);
    const n = src.length;
    for (let k = 0; k < n; k++) a.push(src[k]);
    return a;
  },
};

// The writer a site names: the sanitiser's site text starts with it.
const named = (site) => plainWriters[/List\.(\w+)/.exec(site)?.[1]];

// The written list `result` made the base's own: copied into its array, or
// into its header. `site` names the write.
export const settle = (base, result, site) => {
  if (result === base) return base;
  if (Array.isArray(base)) {
    // A writer's answer that is not its base is fresh: it shares no array
    // with the base, so the copy reads none of the cells it writes.
    const src = plainOf(result);
    if (src === base) return base;
    const n = src.length;
    for (let i = 0; i < n; i++) base[i] = src[i];
    base.length = n;
    return base;
  }
  // A view of `core/List` starts at 1 or later; a header made a view from 0
  // here is still edited in place.
  if (base.o > 0) return Array.isArray(result) ? result : plainOf(result).slice();
  intoHeader(base, result);
  return base;
};

// A write that may park (a suspendable twin, `name$s`, whose callback may
// wait): `core/List`'s writer runs, and its answer, which may come after
// the fiber resumes, goes to `settle` where the lowering waits for it.
export const start = (site, writer, base, ...rest) => writer(base, ...rest);

// `List.<writer>(base, …rest)`, edited in place.
export const list = (site, writer, base, ...rest) => {
  if (Array.isArray(base)) {
    const native = named(site);
    if (native !== undefined) return native(base, ...rest);
  }
  return settle(base, writer(base, ...rest), site);
};

// `[ x, …xs, … ]`: an item before a construction's base goes in front of
// the base (`backend.md` §4, *Writes*), and the base is the answer.
export const front = (x, xs, site) => {
  if (Array.isArray(xs)) {
    xs.unshift(x);
    return xs;
  }
  const r = [x, ...plainOf(xs)];
  if (xs.o > 0) return r;
  intoHeader(xs, r);
  return xs;
};

// A writer handed on as a value (`apply List.push xs`).
export const writer = (site, f) => (base, ...rest) => list(site, f, base, ...rest);

export const len = (xs) => xs.length;

export const same = (a, b) => a === b;

// A record update under the sanitiser (research report 142). In place the
// lowering writes the stores itself and never calls this: it is here so that
// the two runtimes have one set of exports.
export const record = (base, copy) => copy;
