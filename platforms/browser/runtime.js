// The browser platform's one runtime file (docs/design/backend.md §15.3–
// §15.5, §15.11): the program runtime and the `dom` lowering's markup
// runtime at once, so a delegated listener can hand a message to the
// program that owns the node it fired on (boundary.md §9.2).
//
// Parts are ported from dom-expressions' client runtime (MIT, © Ryan
// Carniato; references/dom-expressions/packages/runtime/src): `template`
// from client.js `template`, the class and style diffs from `className`
// and `style`, the delegated listener from `eventHandler`, and
// `reconcile` from reconcile.js (udomdiff) with its slot ownership tags
// removed, since every node here has one owning slot.
//
// **Markup is a block**, `{ t, v }`: `t` a kind `{ m(v, cx), p(inst, v) }`,
// which the compiler makes per source site, and `v` the values the kind
// writes. `m` mounts an instance, `p` patches one with new values. An
// instance owns a contiguous run of sibling nodes, from its first to its
// last: `s` and `e` when those are nodes of its template, else the slot
// `q` its run begins or ends with.
//
// A **slot** is where markup is placed: a parent (or null, when the
// marker's parent is the parent) and a marker to insert before (or null,
// to append). What it holds is an instance `i`, a list of instances `u`,
// or both for a `For` showing its fallback.
//
// A `List` is read as every sibling reads one — cons cells, `$ === 1` for
// a cell with `a` its head and `b` its tail — and a tuple as `{ a, b }`.
//
// The page is reached through `globalThis`, a capability of this file
// alone: the code the compiler emits touches only the nodes this file
// hands it.

// ---- Instances and their nodes ---------------------------------------

const first = (i) => (i.s !== null ? i.s : head(i.q));
const last = (i) => (i.e !== null ? i.e : tail(i.q));

// A slot's first and last node: what it holds, or its marker when it
// holds nothing.
const head = (s) => {
  if (s.u !== null && s.u.length !== 0) return first(s.u[0]);
  return s.i !== null ? first(s.i) : s.m;
};
const tail = (s) => {
  if (s.m !== null) return s.m;
  if (s.u !== null && s.u.length !== 0) return last(s.u[s.u.length - 1]);
  return last(s.i);
};

// Move an instance's nodes before `before` in `parent`, in order.
const put = (parent, i, before) => {
  const end = last(i);
  let n = first(i);
  for (;;) {
    const next = n.nextSibling;
    parent.insertBefore(n, before);
    if (n === end) return;
    n = next;
  }
};

// Take an instance's nodes out of the page.
const drop = (i) => {
  const end = last(i);
  let n = first(i);
  for (;;) {
    const next = n.nextSibling;
    n.remove();
    if (n === end) return;
    n = next;
  }
};

// Put `i` where `old` is, and take `old` out.
const swap = (old, i) => {
  const f = first(old);
  put(f.parentNode, i, f);
  drop(old);
};

// ---- Templates ---------------------------------------------------------

// `(html, flags)`: a cloner that parses `html` on its first call and clones
// the result after that. Flag 1: import rather than clone, so a custom
// element is upgraded; 2: the markup is wrapped in its namespace's root
// element, which is taken off; 4: the template is several nodes, and the
// cloner returns them in a fragment.
export const template = (html, flags) => {
  let node = null;
  return () => {
    if (node === null) {
      const document = globalThis.document;
      const t = document.createElement("template");
      t.innerHTML = html;
      node = t.content;
      if (flags & 2) node = node.firstChild;
      if (flags & 4) {
        if (flags & 2) {
          const f = document.createDocumentFragment();
          while (node.firstChild !== null) f.appendChild(node.firstChild);
          node = f;
        }
      } else node = node.firstChild;
    }
    return flags & 1 ? globalThis.document.importNode(node, true) : node.cloneNode(true);
  };
};

// ---- Slots -------------------------------------------------------------

// `(parent, marker, cx)`: a slot, and the mount context what it holds is
// mounted with.
export const slot = (parent, marker, cx) => ({ p: parent, m: marker, cx, i: null, u: null, b: null, x: null, y: null, d: false });

const parentOf = (s) => (s.p !== null ? s.p : s.m.parentNode);

// A block mounted on its own: an instance that remembers its kind and the
// block it shows.
const unit = (b, cx) => {
  const i = b.t.m(b.v, cx);
  i.t = b.t;
  i.b = b;
  return i;
};

// `b` shown where `i` is: `i` patched when `b` is of its kind, else a new
// instance in its place. The instance now shown.
const patch = (i, b, cx) => {
  if (b === i.b) return i;
  if (b.t === i.t) {
    b.t.p(i, b.v);
    i.b = b;
    return i;
  }
  const n = unit(b, cx);
  swap(i, n);
  return n;
};

// Put a new instance in the slot, in place of what it held.
const place = (s, i) => {
  if (s.i !== null) swap(s.i, i);
  else put(parentOf(s), i, s.m);
  s.i = i;
};

// `(slot, block)`: an `Html` hole.
export const childHtml = (s, b) => {
  if (s.i === null) place(s, unit(b, s.cx));
  else s.i = patch(s.i, b, s.cx);
};

// `(slot, block or null)`: a `Maybe Html` hole; null empties the slot.
export const childMaybe = (s, b) => {
  if (b !== null) childHtml(s, b);
  else if (s.i !== null) {
    drop(s.i);
    s.i = null;
  }
};

// `(slot, list)`: a `List Html` hole, its blocks matched by position.
export const childList = (s, list) => {
  if (list === s.b) return;
  s.b = list;
  const u = s.u ?? (s.u = []);
  let k = 0;
  for (let at = list; at.$ === 1; at = at.b, k++) {
    if (k < u.length) u[k] = patch(u[k], at.a, s.cx);
    else {
      const i = unit(at.a, s.cx);
      put(parentOf(s), i, s.m);
      u.push(i);
    }
  }
  while (u.length > k) drop(u.pop());
};

// ---- Lists and conditionals (backend.md §15.5) ---------------------------

// A row is `{ m, p, i, f }` for a row compiled in place — `m(item,
// position, cx)` mounts an instance, `p(inst, item, position)` patches one
// — or `{ b, i, f }` for any other row, `b(item, position)` its block. `i`
// says whether the row reads its position; `f` is the fallback's block or
// null. The row's inputs are an array compared by identity, or null.

const mountRow = (row, item, position, cx) => {
  const i = row.b === undefined ? row.m(item, position, cx) : unit(row.b(item, position), cx);
  i.x = item;
  i.y = position;
  i.k = null;
  i.n = null;
  return i;
};

// The row patched with its item; a new instance when a block row's kind
// changed.
const patchRow = (row, i, item, position, cx) => {
  if (row.b === undefined) {
    row.p(i, item, position);
    return i;
  }
  const n = patch(i, row.b(item, position), cx);
  if (n !== i) {
    n.k = i.k;
    n.n = null;
  }
  return n;
};

const sameInputs = (a, b) => {
  if (a === b) return true;
  if (a === null || b === null || a.length !== b.length) return false;
  for (let k = 0; k < a.length; k++) if (a[k] !== b[k]) return false;
  return true;
};

// A `For`'s fallback: shown while the list is empty.
const fallback = (s, empty, f) => {
  if (empty && f !== null) {
    if (s.i === null) place(s, unit(f, s.cx));
    else s.i = patch(s.i, f, s.cx);
  } else if (s.i !== null) {
    drop(s.i);
    s.i = null;
  }
};

// A detached run of nodes that moves back into the list later.
let parked = null;
const park = (i) => {
  const f = first(i);
  if (f === last(i)) f.remove();
  else put(parked ?? (parked = globalThis.document.createDocumentFragment()), i, null);
};

// The rows `a` were become the rows `b`, moving as few as it can: udomdiff
// over instances rather than nodes, each instance a run of siblings.
const reconcile = (parent, a, b, after) => {
  let aEnd = a.length;
  let bEnd = b.length;
  let aStart = 0;
  let bStart = 0;
  let map = null;
  while (aStart < aEnd || bStart < bEnd) {
    if (a[aStart] === b[bStart]) {
      aStart++;
      bStart++;
      continue;
    }
    while (aEnd > aStart && bEnd > bStart && a[aEnd - 1] === b[bEnd - 1]) {
      aEnd--;
      bEnd--;
    }
    if (aEnd === aStart) {
      const node = bEnd < b.length ? (bStart !== 0 ? last(b[bStart - 1]).nextSibling : first(b[bEnd])) : after;
      while (bStart < bEnd) put(parent, b[bStart++], node);
    } else if (bEnd === bStart) {
      while (aStart < aEnd) {
        if (map === null || !map.has(a[aStart])) drop(a[aStart]);
        aStart++;
      }
    } else if (a[aStart] === b[bEnd - 1] && b[bStart] === a[aEnd - 1]) {
      const node = last(a[--aEnd]).nextSibling;
      put(parent, b[bStart++], last(a[aStart++]).nextSibling);
      put(parent, b[--bEnd], node);
      a[aEnd] = b[bEnd];
    } else {
      if (map === null) {
        map = new Map();
        for (let i = bStart; i < bEnd; i++) map.set(b[i], i);
      }
      const index = map.get(a[aStart]);
      if (index !== undefined) {
        if (bStart < index && index < bEnd) {
          let i = aStart;
          let sequence = 1;
          while (++i < aEnd && i < bEnd) {
            const t = map.get(a[i]);
            if (t === undefined || t !== index + sequence) break;
            sequence++;
          }
          if (sequence > index - bStart) {
            const node = first(a[aStart]);
            while (bStart < index) put(parent, b[bStart++], node);
          } else {
            const old = a[aStart++];
            put(parent, b[bStart++], first(old));
            park(old);
          }
        } else aStart++;
      } else drop(a[aStart++]);
    }
  }
};

// The keyed list when every item's key is the key of the row already at
// its position and last render's keys were distinct: nothing moves and
// the key map stands, so only the rows whose item or inputs changed run.
// A selection or a label edit takes this path. False, having patched the
// rows before it, at the first key that differs, when the list is longer
// or shorter than the rows; `forKeyed` then goes through the whole list,
// where a row already patched is by then as last time.
const inPlace = (s, items, keyOf, row, same) => {
  const old = s.u;
  let position = 0;
  for (let at = items; at.$ === 1; at = at.b, position++) {
    if (position === old.length) return false;
    let i = old[position];
    const item = at.a;
    const key = keyOf === null ? item : keyOf(item);
    if (i.k !== key) return false;
    if (!same || i.x !== item) {
      const n = patchRow(row, i, item, position, s.cx);
      if (n !== i) {
        old[position] = n;
        s.x.set(key, n);
        n.y = position;
        i = n;
      }
      i.x = item;
    }
  }
  return position === old.length;
};

// `(slot, items, keyOf, row, inputs)`: the keyed list. `keyOf` is null to
// key by the item itself. A row keeps its nodes while its key is in the
// list; items that share a key are matched by their rank among them, so
// every item renders once. A row whose item, position (when it reads it)
// and inputs are all as last time is not run at all, and the rows move
// only when the order of keys changed. `s.d` says last render's keys were
// distinct, which is what lets `inPlace` keep the key map.
export const forKeyed = (s, items, keyOf, row, inputs) => {
  const same = s.b !== null && sameInputs(s.y, inputs);
  if (!(items === s.b && same)) {
    s.b = items;
    s.y = inputs;
    if (s.d && inPlace(s, items, keyOf, row, same)) {
      fallback(s, items.$ !== 1, row.f);
      return;
    }
    let distinct = true;
    const old = s.u ?? [];
    const byKey = s.x;
    const next = [];
    const map = new Map();
    let moved = false;
    let position = 0;
    for (let at = items; at.$ === 1; at = at.b, position++) {
      const item = at.a;
      const key = keyOf === null ? item : keyOf(item);
      let i = byKey === null ? undefined : byKey.get(key);
      if (i !== undefined) {
        if (i.n === null) byKey.delete(key);
        else byKey.set(key, i.n);
        i.n = null;
        if (!same || i.x !== item || (row.i && i.y !== position)) {
          const was = i.y;
          const n = patchRow(row, i, item, position, s.cx);
          if (n !== i) {
            old[was] = n;
            i = n;
          }
        }
        if (!moved && old[position] !== i) moved = true;
      } else {
        i = mountRow(row, item, position, s.cx);
        moved = true;
      }
      i.x = item;
      i.y = position;
      i.k = key;
      const h = map.get(key);
      if (h === undefined) map.set(key, i);
      else {
        distinct = false;
        let t = h;
        while (t.n !== null) t = t.n;
        t.n = i;
      }
      next.push(i);
    }
    if (next.length !== old.length) moved = true;
    if (moved) {
      const parent = parentOf(s);
      if (old.length === 0) {
        const f = globalThis.document.createDocumentFragment();
        for (const i of next) put(f, i, null);
        parent.insertBefore(f, s.i !== null ? first(s.i) : s.m);
      } else if (next.length === 0 && parent.firstChild === first(old[0]) && parent.lastChild === last(old[old.length - 1])) {
        // The rows are all the parent holds: empty it at once, as Solid
        // does, rather than remove a thousand rows one by one.
        parent.textContent = "";
      } else reconcile(parent, old, next, last(old[old.length - 1]).nextSibling);
      if (parked !== null) parked = null;
    }
    s.u = next;
    s.x = map;
    s.d = distinct;
  }
  fallback(s, items.$ !== 1, row.f);
};

// `(slot, items, row, inputs)`: the list matched by position; row `k`
// shows item `k`, and rows past the end are removed.
export const forPosition = (s, items, row, inputs) => {
  const same = s.b !== null && sameInputs(s.y, inputs);
  if (!(items === s.b && same)) {
    s.b = items;
    s.y = inputs;
    const u = s.u ?? (s.u = []);
    let k = 0;
    for (let at = items; at.$ === 1; at = at.b, k++) {
      const item = at.a;
      if (k < u.length) {
        const i = u[k];
        if (!same || i.x !== item) {
          u[k] = patchRow(row, i, item, k, s.cx);
          u[k].x = item;
        }
      } else {
        const i = mountRow(row, item, k, s.cx);
        put(parentOf(s), i, s.i !== null ? first(s.i) : s.m);
        u.push(i);
      }
    }
    while (u.length > k) drop(u.pop());
  }
  fallback(s, items.$ !== 1, row.f);
};

// `(slot, key, block)`: a keyed `Show` showing its body. A new key, or a
// slot that showed the fallback, remounts; the same key patches.
export const show = (s, key, b) => {
  if (s.i !== null && s.y !== true && s.x === key) s.i = patch(s.i, b, s.cx);
  else place(s, unit(b, s.cx));
  s.x = key;
  s.y = false;
};

// `(slot, fallback or null)`: a keyed `Show` on `Nothing`.
export const hide = (s, f) => {
  if (f === null) {
    if (s.i !== null) {
      drop(s.i);
      s.i = null;
    }
  } else if (s.y === true && s.i !== null) s.i = patch(s.i, f, s.cx);
  else place(s, unit(f, s.cx));
  s.x = null;
  s.y = true;
};

// ---- Attributes (backend.md §15.3, §15.6) --------------------------------

// `(el, name, value)`: the attribute, or none when `value` is null.
export const attr = (el, name, value) => {
  if (value === null) el.removeAttribute(name);
  else el.setAttribute(name, value);
};

// `(el, namespace, name, value)`: an attribute of a namespace (`xlink:href`).
export const attrNS = (el, namespace, name, value) => {
  if (value === null) el.removeAttributeNS(namespace, name.slice(name.indexOf(":") + 1));
  else el.setAttributeNS(namespace, name, value);
};

// The names whose flag is `True`, a name holding whitespace being several.
const classSet = (list) => {
  const names = new Set();
  for (let at = list; at.$ === 1; at = at.b) {
    if (!at.a.b) continue;
    for (const name of at.a.a.split(/[\t\n\f\r ]+/)) if (name !== "") names.add(name);
  }
  return names;
};

// `(el, list, previous)`: the element has exactly the classes the list
// names; what only the previous list held is removed.
export const classes = (el, list, previous) => {
  const next = classSet(list);
  const old = previous === null ? null : classSet(previous);
  if (old !== null) for (const name of old) if (!next.has(name)) el.classList.remove(name);
  for (const name of next) if (old === null || !old.has(name)) el.classList.add(name);
};

// Each property's last value.
const styleMap = (list) => {
  const values = new Map();
  for (let at = list; at.$ === 1; at = at.b) values.set(at.a.a, at.a.b);
  return values;
};

// `(el, list, previous)`: each property set to its last value in the list,
// an empty value removing it; a property only the previous list set is
// removed.
export const styles = (el, list, previous) => {
  const next = styleMap(list);
  const old = previous === null ? null : styleMap(previous);
  const style = el.style;
  if (old !== null) for (const name of old.keys()) if (!next.has(name)) style.removeProperty(name);
  for (const [name, value] of next) if (old === null || old.get(name) !== value) style.setProperty(name, value);
};

// Elm's rule: a URL whose scheme is `javascript:`, or `data:text/html`,
// with any whitespace or control character where a browser ignores one,
// runs script, so it is written as nothing.
const scriptUrl =
  /^[\s\x00-\x20]*(j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:|d\s*a\s*t\s*a\s*:\s*t\s*e\s*x\s*t\s*\/\s*h\s*t\s*m\s*l\s*[,;])/i;
export const safeUrl = (url) => (scriptUrl.test(url) ? "" : url);

// `(el, markup)`: the `raw` escape hatch, markup text written unescaped.
export const rawHtml = (el, markup) => {
  el.innerHTML = markup;
};

// `(parent, marker, value)`: a text hole's node, inserted before the marker
// (or last, for none).
export const insertText = (parent, marker, value) => parent.insertBefore(globalThis.document.createTextNode(value), marker);

// ---- Events (backend.md §15.3) -------------------------------------------

// An event node holds its handler as `$$<name>`, a payload extractor as
// `$$<name>X` when the handler takes a payload, its declaration's
// `preventDefault` (1) and `stopPropagation` (2) as `$$<name>F`, and the
// mount context of the `Html.map`s it is inside as `$$cx`. A program's
// mount node holds its `send` as `$$root`.

// The payload of an event whose handler takes the event itself.
export const identity = (event) => event;

// Send the message `node`'s handler makes of `event` to the program whose
// mount node is nearest above it, through every `Html.map` it is inside,
// innermost first. The search starts at the node's parent: a program
// renders only inside its mount node, so a mount node's own handler is
// the program's around it.
const fire = (node, event, key, flags) => {
  if (flags & 1) event.preventDefault();
  const x = node[`${key}X`];
  let msg = x === undefined ? node[key] : node[key](x(event));
  for (let c = node.$$cx; c !== undefined && c !== null; c = c.up) msg = c.f(msg);
  let root = node.parentNode;
  while (root !== null && root.$$root === undefined) root = root.parentNode;
  if (root !== null) root.$$root(msg);
  if (flags & 2) event.stopPropagation();
};

// The one listener per delegated event name: from the target up, every
// node with a handler for the event, until one stops it. An event inside
// a program mounted in another's markup goes on into the outer one, as
// the DOM's own bubbling does, and each handler's message goes to the
// program that rendered it.
const delegated = (event) => {
  const key = `$$${event.type}`;
  for (let node = event.target; node !== null; node = node.parentNode) {
    if (node[key] !== undefined && !node.disabled) {
      const flags = node[`${key}F`] ?? 0;
      fire(node, event, key, flags);
      if (flags & 2) return;
    }
  }
};

const registered = new Set();

// `(names)`: listen for each delegated event name once.
export const delegate = (names) => {
  for (const name of names) {
    if (registered.has(name)) continue;
    registered.add(name);
    globalThis.document.addEventListener(name, delegated);
  }
};

// `(data)`: the program's start data — the delegated names of every
// module the build wrote.
export const start = (data) => {
  if (data.delegate !== undefined) delegate(data.delegate);
};

// `(el, name, flags)`: a listener of the element's own for an event that
// is not delegated; it reads the handler the node holds when it fires.
export const listen = (el, name, flags) => {
  const key = `$$${name}`;
  el.addEventListener(name, (event) => {
    if (el[key] !== undefined) fire(el, event, key, flags);
  });
};

// ---- The markup primitives (language.md §11.13) ----------------------------

const textKind = {
  m: (v) => {
    const n = globalThis.document.createTextNode(v);
    return { s: n, q: null, e: n, d: v };
  },
  p: (i, v) => {
    if (v !== i.d) {
      i.d = v;
      i.s.data = v;
    }
  },
};

// `Html.text`: the text, as a text hole shows it.
export const text = (s) => ({ t: textKind, v: s });

// A map's instance is its markup's, mounted with a context that sends
// through `f` and then through the contexts it was mounted in. A new `f`
// is written into the context, so no handler inside changes.
const mapKind = {
  m: (v, cx) => {
    const c = { f: v[1], up: cx };
    const h = slot(null, null, c);
    h.i = unit(v[0], c);
    return { s: null, q: h, e: null, c };
  },
  p: (i, v) => {
    i.c.f = v[1];
    i.q.i = patch(i.q.i, v[0], i.c);
  },
};

// `Html.map`: the same markup, its messages passed through `f`.
export const map = (html, f) => ({ t: mapKind, v: [html, f] });

// ---- The program and its render loop (backend.md §15.11) -----------------

// Programs with a render queued, rendered by one microtask flush.
let queued = [];
let scheduled = false;

// Render every program a message is waiting on. A message sent while this
// runs queues the next flush.
export const flush = () => {
  scheduled = false;
  const renders = queued;
  queued = [];
  for (const render of renders) render();
};

// `(program)`: start every program the value holds (`Browser.js`: an array
// of `{ a, n }`), in order, so one may mount at an element an earlier one
// rendered. A mount node that is missing, or that holds a program already,
// is a fault of the page, thrown before that program renders anything.
export const run = (program) => {
  const document = globalThis.document;
  for (const m of program) {
    const root = m.n === null ? document.body : document.getElementById(m.n);
    if (root === null) throw new Error(`no element has the id "${m.n}" to mount a program at`);
    if (root.$$root !== undefined) {
      throw new Error(`${m.n === null ? "the page's body" : `the element "${m.n}"`} already holds a program`);
    }
    mount(m.a, root);
  }
};

// Render `view init` after the children of `root`, and mark `root` with
// the program's `send`, which puts every message through `update`: the
// model is rendered on the next flush, however many messages arrive
// before it.
const mount = (program, root) => {
  const s = slot(root, null, null);
  let model = program.init;
  let waiting = false;
  const render = () => {
    waiting = false;
    childHtml(s, program.view(model));
  };
  root.$$root = (msg) => {
    model = program.update(msg, model);
    if (waiting) return;
    waiting = true;
    queued.push(render);
    if (scheduled) return;
    scheduled = true;
    queueMicrotask(() => {
      if (scheduled) flush();
    });
  };
  childHtml(s, program.view(model));
};
