// P3, research 60: what message-indexed rendering (research 58 §9) would
// emit for the table app, `apps/beni/Main.beni`. Written by hand, using only
// what research 58 §4 says a whole-program compiler can prove from that
// source; never the best JavaScript a person could write for the page.
//
// The model half is beni's own output, verbatim: `next`, `pick`,
// `buildFrom`, `build`, `replace`, `at` and `swapRows` as the development
// build emits them, each `update` branch as the body of its constructor's
// handler, over core's modules imported from that build (`build.mjs` makes
// `out/beni-dev`). So `List` is beni's array-backed list, a trie when `cons`
// builds it, exactly as in beni.
//
// The view half, and the fact behind each part:
// - W2, constancy: `view`'s jumbotron is literal, and the six `button` calls
//   pass literals, so all of it is template text; each `onClick={Run}` is a
//   listener on its button calling that constructor's handler.
// - The row: `.id` is the key, so `row.id` is fixed for an instance: the id
//   text and the two handlers' payload are written once, at mount. The row
//   has two groups: `label` (reads row.label) and `class` (reads
//   model.selected and row.id, through `rowClass`).
// - W1 per constructor, and its edit script on the keyed list:
//     Run, RunLots  rows ← a list built from `[]`: not derived from the old
//                   one, so its keys may meet old ones: the generic keyed
//                   edit (`reconcile`).
//     Add           rows ← model.rows ++ fresh: the old list is a prefix, so
//                   the edit is "append": new instances at the end, none
//                   visited.
//     Update        rows ← List.indexedMap … { row | label }: the map idiom,
//                   rows[*].label with length, order and keys kept;
//                   research 58 §5(a): a walk comparing each element with
//                   its instance's item. `reconcile`'s trimming is that walk.
//     SwapRows      rows ← List.indexedMap … b | a | row: the map idiom
//                   again, whose elements may come from other positions, so
//                   keys may move: `reconcile` (its crossed-ends case makes
//                   the two moves).
//     Remove        rows ← List.filter: order kept, some removed (§5(a)'s
//                   one-pass merge): `reconcile`'s trimming finds the gap.
//     Clear         rows ← []: the edit is "clear"; the `<tbody>` holds only
//                   the list (the template says so), so `textContent = ""`.
//     Select        selected: every row's `class` group (W3), a walk over
//                   the instances comparing each row's class.
// - Events: a direct listener on each button, which the page mounts once
//   and never removes; inside the list, one listener on the `<tbody>`, the
//   list's parent, which walks from the target to the row (research 58 §4:
//   "delegation inside rows" is what remains of the runtime).
// - Rendering is staged: a handler applies its list edit (the DOM moves,
//   inserts and removals) and marks rows and groups; the flush at the end of
//   the dispatch runs the marked groups, each comparing what it reads with
//   what it last wrote ("analysis says possibly changed, a compare says
//   changed").

import { Basics$append } from "../../out/beni-dev/_core/Basics.mjs";
import { Int$mod } from "../../out/beni-dev/_core/Int.mjs";
import { List$append, List$base, List$cons, List$filter, List$get, List$indexedMap, List$offset } from "../../out/beni-dev/_core/List.mjs";
import { Maybe$withDefault } from "../../out/beni-dev/_core/Maybe.mjs";

// ---- The dispatch loop (apps/scaling/common.mjs's p3Loop) -----------------

let dirty = 0;
let scheduled = false;
let turning = false;
let dead = false;
const flush = () => {
  scheduled = false;
  let ok = false;
  try {
    render();
    ok = true;
  } finally {
    if (!ok) dead = true;
  }
};
const schedule = () => {
  if (!scheduled) {
    scheduled = true;
    if (!turning) queueMicrotask(() => scheduled && !dead && flush());
  }
};
const mark = (groups) => {
  dirty |= groups;
  schedule();
};
const send = (trusted, handler, a, b) => {
  if (dead) return;
  const outer = trusted && !turning;
  let ok = false;
  if (outer) turning = true;
  try {
    handler(a, b);
    ok = true;
  } finally {
    if (outer) turning = false;
    if (!ok) dead = true;
  }
  if (outer && scheduled) flush();
};
let marked = [];
const markRow = (i) => {
  if (!i.m) {
    i.m = true;
    marked.push(i);
  }
  schedule();
};

// ---- The model half: beni's output, verbatim -------------------------------

const Main$Maybe$Nothing = { $: "Nothing", a: null };
const Main$adjectives = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy", "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"];
const Main$colours = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "brown", "white", "black", "orange"];
const Main$nouns = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger", "pizza", "mouse", "keyboard"];
const Main$next = (seed$1) => Int$mod(seed$1 * 16807, 1073741789);
const Main$pick = (words$1, count$2, seed$3) => Maybe$withDefault(List$get(words$1, Int$mod(seed$3, count$2)), "");
const Main$buildFrom = (id$1, first$2, seed$3, rows$4) => {
  while (!(id$1 < first$2)) {
    const a$5 = Main$next(seed$3);
    const c$6 = Main$next(a$5);
    const n$7 = Main$next(c$6);
    const label$8 = `${Main$pick(Main$adjectives, 25, a$5)} ${Main$pick(Main$colours, 11, c$6)} ${Main$pick(Main$nouns, 13, n$7)}`;
    const $t$1 = id$1 - 1;
    seed$3 = n$7;
    rows$4 = List$cons({ id: id$1, label: label$8 }, rows$4);
    id$1 = $t$1;
  }
  return { a: rows$4, b: seed$3 };
};
const Main$build = (count$1, id$2, seed$3) => Main$buildFrom(id$2 + count$1 - 1, id$2, seed$3, []);
const Main$replace = (model$1, count$2) => {
  const $t$2 = Main$build(count$2, model$1.nextId, model$1.seed);
  const rows$3 = $t$2.a;
  const seed$4 = $t$2.b;
  return { ...model$1, rows: rows$3, nextId: model$1.nextId + count$2, seed: seed$4 };
};
const Main$at = (rows$1, index$2) => List$get(rows$1, index$2);
const Main$swapRows = (rows$1) => {
  const $t$3 = Main$at(rows$1, 1);
  const $t$4 = Main$at(rows$1, 998);
  $j$0$1: {
    if ($t$3.$ === "Just") {
      if ($t$4.$ === "Just") {
        const a$2 = $t$3.a;
        const b$3 = $t$4.a;
        return List$indexedMap(rows$1, (i$4, row$5) => {
          if (i$4 === 1) {
            return b$3;
          } else {
            return i$4 === 998 ? a$2 : row$5;
          }
        });
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return rows$1;
};

let model = { nextId: 1, rows: [], seed: 42, selected: Main$Maybe$Nothing };

// ---- The view half ----------------------------------------------------------

const root = (() => {
  const t = document.createElement("template");
  t.innerHTML = "<div class=container><div class=jumbotron><div class=row><div class=col-md-6><h1>beni keyed</h1></div><div class=col-md-6><div class=row><div class=\"col-sm-6 smallpad\"><button type=button class=\"btn btn-primary btn-block\" id=run>Create 1,000 rows</button></div><div class=\"col-sm-6 smallpad\"><button type=button class=\"btn btn-primary btn-block\" id=runlots>Create 10,000 rows</button></div><div class=\"col-sm-6 smallpad\"><button type=button class=\"btn btn-primary btn-block\" id=add>Append 1,000 rows</button></div><div class=\"col-sm-6 smallpad\"><button type=button class=\"btn btn-primary btn-block\" id=update>Update every 10th row</button></div><div class=\"col-sm-6 smallpad\"><button type=button class=\"btn btn-primary btn-block\" id=clear>Clear</button></div><div class=\"col-sm-6 smallpad\"><button type=button class=\"btn btn-primary btn-block\" id=swaprows>Swap Rows</button></div></div></div></div></div><table class=\"table table-hover table-striped test-data\"><tbody></tbody></table><span class=\"preloadicon glyphicon glyphicon-remove\"aria-hidden=true></span></div>";
  return t.content.firstChild;
})();
const buttons = root.firstChild.firstChild.lastChild.firstChild;
const tbody = root.firstChild.nextSibling.firstChild;
const rowProto = (() => {
  const t = document.createElement("template");
  t.innerHTML = '<tr><td class=col-md-1> </td><td class=col-md-4><a> </a></td><td class=col-md-1><a><span class="glyphicon glyphicon-remove"aria-hidden=true></span></a></td><td class=col-md-6>';
  return t.content.firstChild;
})();

// The `class` group's expression, `rowClass model row`.
const rowClass = (s, id) => (s.$ === "Just" && s.a === id ? "danger" : "");

// A row instance: `e` its `<tr>`, `k` its key, `it` the item it shows, and
// one slot per group: `l` the label it wrote (to the text node `lb`), `c`
// the class.
const make = (x) => {
  const e = rowProto.cloneNode(true);
  const td = e.firstChild;
  const a = td.nextSibling.firstChild;
  const lb = a.firstChild;
  const c = rowClass(model.selected, x.id);
  const i = { e, k: x.id, it: x, lb, l: x.label, c, m: false };
  td.firstChild.data = x.id;
  lb.data = x.label;
  if (c !== "") e.className = c;
  e.$r = i;
  a.$h = Select;
  a.parentNode.nextSibling.firstChild.$h = Remove;
  return i;
};
let insts = [];

// The keyed list's generic edit: `rows` replaces what the instances show.
// Instances with the same key at the front and at the back are kept, and
// marked when their item changed; crossed ends are two moves; what remains
// in the middle is matched by key, the unmatched old rows removed and the
// rest put in order from the back.
const keep = (i, x) => {
  if (i.it !== x) {
    i.it = x;
    markRow(i);
  }
};
const reconcile = (rows) => {
  const b = List$base(rows);
  const o = List$offset(rows);
  const old = insts;
  const m = old.length;
  let s = 0;
  let ea = m;
  let eb = rows.length;
  for (;;) {
    while (s < ea && s < eb && old[s].k === b[o + s].id) {
      keep(old[s], b[o + s]);
      s++;
    }
    while (s < ea && s < eb && old[ea - 1].k === b[o + eb - 1].id) keep(old[--ea], b[o + --eb]);
    if (ea - s < 2 || eb - s < 2 || old[s].k !== b[o + eb - 1].id || old[ea - 1].k !== b[o + s].id) break;
    const x = old[s];
    const y = old[ea - 1];
    const after = y.e.nextSibling;
    tbody.insertBefore(y.e, x.e);
    tbody.insertBefore(x.e, after);
    old[s] = y;
    old[ea - 1] = x;
  }
  if (s === ea && s === eb) return;
  const mid = [];
  if (s === ea) {
    const f = document.createDocumentFragment();
    for (let j = s; j < eb; j++) {
      const i = make(b[o + j]);
      mid.push(i);
      f.appendChild(i.e);
    }
    tbody.insertBefore(f, ea < m ? old[ea].e : null);
  } else if (s === eb) {
    if (s === 0 && ea === m) tbody.textContent = "";
    else for (let j = s; j < ea; j++) old[j].e.remove();
  } else {
    const byKey = new Map();
    for (let j = s; j < ea; j++) {
      const i = old[j];
      if (byKey.has(i.k)) i.e.remove();
      else byKey.set(i.k, i);
    }
    let kept = 0;
    for (let j = s; j < eb; j++) {
      const x = b[o + j];
      let i = byKey.get(x.id);
      if (i === undefined) i = make(x);
      else {
        byKey.delete(x.id);
        keep(i, x);
        kept++;
      }
      mid.push(i);
    }
    if (kept === 0 && s === 0 && ea === m) {
      tbody.textContent = "";
      const f = document.createDocumentFragment();
      for (const i of mid) f.appendChild(i.e);
      tbody.appendChild(f);
    } else {
      for (const i of byKey.values()) i.e.remove();
      let before = ea < m ? old[ea].e : null;
      for (let j = mid.length - 1; j >= 0; j--) {
        const e = mid[j].e;
        if (e.nextSibling !== before || e.parentNode === null) tbody.insertBefore(e, before);
        before = e;
      }
    }
  }
  insts = s === 0 && ea === m ? mid : old.slice(0, s).concat(mid, old.slice(ea));
};

// ---- The handlers: one per constructor ----------------------------------------

const Run = () => {
  model = Main$replace(model, 1000);
  reconcile(model.rows);
};
const RunLots = () => {
  model = Main$replace(model, 10000);
  reconcile(model.rows);
};
const Add = () => {
  const $t$5 = Main$build(1000, model.nextId, model.seed);
  const rows$3 = $t$5.a;
  const seed$4 = $t$5.b;
  const n = model.rows.length;
  model = { ...model, rows: List$append(model.rows, rows$3), nextId: model.nextId + 1000, seed: seed$4 };
  const b = List$base(model.rows);
  const o = List$offset(model.rows);
  const f = document.createDocumentFragment();
  for (let j = n; j < model.rows.length; j++) {
    const i = make(b[o + j]);
    insts.push(i);
    f.appendChild(i.e);
  }
  tbody.appendChild(f);
};
const Update = () => {
  const old = model.rows;
  model = { ...model, rows: List$indexedMap(model.rows, (i$5, row$6) => (Int$mod(i$5, 10) === 0 ? { ...row$6, label: Basics$append(row$6.label, " !!!") } : row$6)) };
  if (model.rows !== old) reconcile(model.rows);
};
const Clear = () => {
  model = { ...model, rows: [] };
  if (insts.length > 0) {
    tbody.textContent = "";
    insts = [];
  }
};
const SwapRows = () => {
  const old = model.rows;
  model = { ...model, rows: Main$swapRows(model.rows) };
  if (model.rows !== old) reconcile(model.rows);
};
const Select = (id$7) => {
  model = { ...model, selected: { $: "Just", a: id$7 } };
  mark(1);
};
const Remove = (id$8) => {
  const old = model.rows;
  model = { ...model, rows: List$filter(model.rows, (row$9) => row$9.id !== id$8) };
  if (model.rows !== old) reconcile(model.rows);
};

// ---- The flush: the marked groups ------------------------------------------------

const render = () => {
  const d = dirty;
  dirty = 0;
  const ms = marked;
  marked = [];
  for (const i of ms) {
    i.m = false;
    const x = i.it.label;
    if (x !== i.l) i.lb.data = i.l = x;
  }
  if (d & 1) {
    const s = model.selected;
    for (const i of insts) {
      const c = rowClass(s, i.it.id);
      if (c !== i.c) i.e.className = i.c = c;
    }
  }
};

// ---- Events, and the mount ------------------------------------------------------

const w0 = buttons.firstChild;
const w1 = w0.nextSibling;
const w2 = w1.nextSibling;
const w3 = w2.nextSibling;
const w4 = w3.nextSibling;
const w5 = w4.nextSibling;
w0.firstChild.addEventListener("click", (e) => send(e.isTrusted, Run));
w1.firstChild.addEventListener("click", (e) => send(e.isTrusted, RunLots));
w2.firstChild.addEventListener("click", (e) => send(e.isTrusted, Add));
w3.firstChild.addEventListener("click", (e) => send(e.isTrusted, Update));
w4.firstChild.addEventListener("click", (e) => send(e.isTrusted, Clear));
w5.firstChild.addEventListener("click", (e) => send(e.isTrusted, SwapRows));
tbody.addEventListener("click", (e) => {
  // A handler may detach its row (Remove does, at once): the walk stops there.
  for (let t = e.target; t !== tbody && t !== null; t = t.parentNode) {
    if (t.$h !== undefined) {
      let r = t;
      while (r.$r === undefined) r = r.parentNode;
      send(e.isTrusted, t.$h, r.$r.it.id);
    }
  }
});
document.body.appendChild(root);
