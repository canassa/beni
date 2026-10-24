// S2 pricing emitter (scratch, not the research repo): tea-inline's big-table emitter, with flags
// that turn its output, one change at a time, into the shape beni-inline's S2 is to emit.
// Flags (env S2, letters, cumulative in the order measured):
//   g  synchronous passes inside beni's dispatch guard (D3), no microtask, beni's `on`
//   d  rows in a Dict ({entries, index}, core's ops) and the Dict row list: rows parallel to the
//      entries, the Dict's own index finds a row, `at`/`swap`/`each` edits, forward reconcile
//   m  (alternative to the parallel rows) the plan's literal id -> row Map, built lazily
//   l  the reconciler is LIS (one forward pass replaced)
//   y  `selected : Maybe Int`, boxed as core boxes it
//   v  typed pushes: each table decodes its own rows (validators), no structuredClone
//   c  code-point length for `len` cells
const { templateFiles } = await import(process.env.RR + "/frameworks/tea-inline/framework.js");

export const framework = "tea-inline";
export const params = {};
const F = new Set((process.env.S2 || "").split(""));
const P = F.has("p"), W = F.has("w"), H = F.has("h"), G = F.has("g"), D = F.has("d"), M = F.has("m"), LIS = F.has("l"), Y = F.has("y"), V = F.has("v"), CP = F.has("c");

const str = JSON.stringify;
const escText = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
const attrValue = (v) => (/^[\w.:-]+$/.test(v) ? v : `"${v.replace(/&/g, "&amp;").replace(/"/g, "&quot;")}"`);
const col = (t, name) => t.columns.find((c) => c.name === name);

// ---------------------------------------------------------------------------------------------
// Runtime files

const RUNTIME_TEA = null; // the template's own runtime.js

// beni-inline's S1 runtime (Inline.beni as built, written out as JavaScript): the dispatch guard
// with its mid-dispatch queue, `text`, `prop`, `on` through the guard. No scheduler.
const RUNTIME_BENI = `
let dead = false, busy = false, queue = null;
export function guard(f, a) {
  if (dead) return;
  if (busy) { (queue ||= []).push(f, a); return; }
  busy = true;
  let ok = false;
  try {
    f(a);
    while (queue !== null) { const q = queue; queue = null; for (let i = 0; i < q.length && !dead; i += 2) q[i](q[i + 1]); }
    ok = true;
  } finally { busy = false; if (!ok) { dead = true; queue = null; } }
}
export function stopAll() { dead = true; queue = null; }
export function revive() { dead = false; }
export function text(node, value) { value = String(value); if (node.textContent !== value) node.textContent = value; }
export function prop(node, value, key = "value") { if (node[key] !== value) node[key] = value; }
export function on(node, f, type = "click") { node.addEventListener(type, (e) => guard(f, e)); }
// The adapter's (excluded from the size): every pass is synchronous.
export const settled = () => Promise.resolve();
`;

// core/Dict, the subset a table reaches (backend.md §4, *Ordered dictionaries*), and Maybe.
const DICT_P = `
export const just = (a) => ({ $: 0, a });
export const nothing = { $: 1, a: null };
export const empty = () => ({ entries: [], index: new Map() });
export const size = (d) => d.entries.length;
export const member = (d, k) => d.index.has(k);
export const keyAt = (d, i) => (i < d.entries.length ? just(d.entries[i][0]) : nothing);
export function insert(d, k, v) { const e = d.index.get(k); if (e) e[1] = v; else { const n = [k, v]; d.entries.push(n); d.index.set(k, n); } return d; }
export function remove(d, k) { const e = d.index.get(k); if (e) { d.entries.splice(d.entries.indexOf(e), 1); d.index.delete(k); } return d; }
export function swap(d, a, b) {
  const x = d.index.get(a), y = d.index.get(b);
  if (x && y) { const e = d.entries, p = e.indexOf(x), q = e.indexOf(y); e[p] = y; e[q] = x; }
  return d;
}
export function update(d, k, f) { const e = d.index.get(k), r = f(e ? just(e[1]) : nothing); return r.$ === 0 ? insert(d, k, r.a) : remove(d, k); }
export function filter(d, f) { const r = empty(); for (const [k, v] of d.entries) if (f(k, v)) insert(r, k, v); return r; }
export function fromList(l) { const d = empty(); for (const [k, v] of l) insert(d, k, v); return d; }
export function foldl(d, a, f) { for (const [k, v] of d.entries) a = f(k, v, a); return a; }
export function keys(d) { return d.entries.map((e) => e[0]); }
export function sortBy(d, c, f) { const t = d.entries.map((e) => [f(e[0], e[1]), e]); t.sort((a, b) => c(a[0], b[0])); d.entries = t.map((x) => x[1]); return d; }
`;
const DICT = `
export const just = (a) => ({ $: 0, a });
export const nothing = { $: 1, a: null };
export const empty = () => ({ entries: [], index: new Map() });
export const size = (d) => d.entries.length;
export const member = (d, k) => d.index.has(k);
export const keyAt = (d, i) => (i < d.entries.length ? just(d.entries[i][0]) : nothing);
export function insert(d, k, v) {
  const p = d.index.get(k);
  if (p === undefined) { d.index.set(k, d.entries.length); d.entries.push([k, v]); } else d.entries[p][1] = v;
  return d;
}
export function remove(d, k) {
  let p = d.index.get(k);
  if (p !== undefined) {
    const e = d.entries;
    e.splice(p, 1);
    d.index.delete(k);
    for (; p < e.length; p++) d.index.set(e[p][0], p);
  }
  return d;
}
export function swap(d, a, b) {
  const p = d.index.get(a), q = d.index.get(b);
  if (p !== undefined && q !== undefined) { const e = d.entries, t = e[p]; e[p] = e[q]; e[q] = t; d.index.set(a, q); d.index.set(b, p); }
  return d;
}
export function update(d, k, f) {
  const p = d.index.get(k), r = f(p === undefined ? nothing : just(d.entries[p][1]));
  return r.$ === 0 ? insert(d, k, r.a) : remove(d, k);
}
export function filter(d, f) { const r = empty(); for (const [k, v] of d.entries) if (f(k, v)) insert(r, k, v); return r; }
export function fromList(l) { const d = empty(); for (const [k, v] of l) insert(d, k, v); return d; }
export function foldl(d, a, f) { for (const [k, v] of d.entries) a = f(k, v, a); return a; }
export function keys(d) { return d.entries.map((e) => e[0]); }
export function sortBy(d, c, f) {
  const t = d.entries.map((e) => [f(e[0], e[1]), e]);
  t.sort((a, b) => c(a[0], b[0]));
  d.entries = t.map((x) => x[1]);
  d.index.clear();
  d.entries.forEach((e, i) => d.index.set(e[0], i));
  return d;
}
`;

// The row list over a Dict. R holds the rows in the Dict's order, parallel to its entries; a row
// is [node, set] with its key and its value. \`at(k)\` makes the one key's row match the Dict
// after an arm that inserted, removed or updated k; \`swap(a, b)\` exchanges two rows; \`each()\`
// repaints every row; the list itself, called, reconciles.
function rowsFileP() {
  return `// The keyed rows of a Dict (S2 target, pair index): R in the Dict's order, M from key to row.
export const tpl = (html) => { const t = document.createElement("template"); t.innerHTML = html; return t.content.firstChild; };
export function list(parent, get, build) {
  let R = [], M = new Map();
  const make = (k, v) => { const r = build(k, v); r.k = k; r.v = v; r[1](v); M.set(k, r); return r; };
  const L = (all) => {
    const E = get().entries, old = M, N = [];
    let kept = 0;
    M = new Map();
    R.forEach((r, i) => { r.p = i; });
    for (const [k, v] of E) {
      let r = old.get(k);
      if (r) { kept++; old.delete(k); M.set(k, r); if (all || r.v !== v) { r.v = v; r[1](v); } } else r = make(k, v);
      N.push(r);
    }
    R = N;
    if (!kept) { const f = new DocumentFragment(); for (const r of N) f.append(r[0]); parent.replaceChildren(f); return; }
    for (const r of old.values()) r[0].remove();
    const P = N.map((r) => r.p ?? -1), t = [], prev = [], stay = [];
    P.forEach((x, i) => {
      if (x < 0) return;
      let lo = 0, hi = t.length;
      while (lo < hi) { const m = (lo + hi) >> 1; P[t[m]] < x ? (lo = m + 1) : (hi = m); }
      prev[i] = lo ? t[lo - 1] : -1;
      t[lo] = i;
    });
    for (let i = t[t.length - 1]; i >= 0; i = prev[i]) stay[i] = 1;
    let next = null;
    for (let i = N.length; i--; ) { const n = N[i][0]; if (!stay[i]) parent.insertBefore(n, next); next = n; }
  };
  // After insert, remove or update of k (an existing key never moves; a new one is appended).
  L.at = (k) => {
    const e = get().index.get(k), r = M.get(k);
    if (!e) { if (r) { R.splice(R.indexOf(r), 1); M.delete(k); r[0].remove(); } }
    else if (r) { r.v = e[1]; r[1](r.v); }
    else { const n = make(k, e[1]); R.push(n); parent.append(n[0]); }
  };
  L.swap = (a, b) => {
    let A = M.get(a), B = M.get(b);
    if (!A || !B || A === B) return;
    let x = R.indexOf(A), y = R.indexOf(B);
    if (x > y) { [x, y] = [y, x]; [A, B] = [B, A]; }
    const n = B[0].nextSibling;
    R[x] = B; R[y] = A;
    parent.insertBefore(B[0], A[0]);
    parent.insertBefore(A[0], n);
  };
  return L;
}
`;
}

function rowsFile() {
  const find = M
    ? `let index;
  const row = (k) => (index ||= new Map(R.map((r) => [r.k, r]))).get(k);`
    : "";
  const at = M
    ? `L.at = (k) => {
    const d = get(), j = d.index.get(k), r = row(k);
    if (j === undefined) { if (r) { r[0].remove(); R.splice(R.indexOf(r), 1); index = null; } }
    else if (r) { r.v = d.entries[j][1]; r[1](r.v); }
    else { const n = make(k, d.entries[j][1]); R.push(n); parent.append(n[0]); index = null; }
  };`
    : `L.at = (k) => {
    const d = get(), j = d.index.get(k);
    if (j === undefined) { const i = R.findIndex((r) => r.k === k); if (i >= 0) R.splice(i, 1)[0][0].remove(); }
    else if (R[j]?.k === k) { const r = R[j]; r.v = d.entries[j][1]; r[1](r.v); }
    else if (j === R.length && d.entries.length === j + 1) { const n = make(k, d.entries[j][1]); R.push(n); parent.append(n[0]); }
    else {
      const i = R.findIndex((r) => r.k === k), v = d.entries[j][1];
      let r;
      if (i < 0) r = make(k, v); else { r = R.splice(i, 1)[0]; r.v = v; r[1](v); }
      parent.insertBefore(r[0], R[j]?.[0] ?? null);
      R.splice(j, 0, r);
    }
  };`;
  const order = LIS
    ? `    const P = N.map((r) => r.p ?? -1), t = [], prev = [], stay = [];
    P.forEach((x, i) => {
      if (x < 0) return;
      let lo = 0, hi = t.length;
      while (lo < hi) { const m = (lo + hi) >> 1; P[t[m]] < x ? (lo = m + 1) : (hi = m); }
      prev[i] = lo ? t[lo - 1] : -1;
      t[lo] = i;
    });
    for (let i = t[t.length - 1]; i >= 0; i = prev[i]) stay[i] = 1;
    let next = null;
    for (let i = N.length; i--; ) { const n = N[i][0]; if (!stay[i]) parent.insertBefore(n, next); next = n; }`
    : `    let at = parent.firstChild;
    for (const r of N) r[0] === at ? (at = at.nextSibling) : parent.insertBefore(r[0], at);`;
  return `// The keyed rows of a Dict (S2 target).
export const tpl = (html) => { const t = document.createElement("template"); t.innerHTML = html; return t.content.firstChild; };
export function list(parent, get, build) {
  let R = [];
  ${find}
  const make = (k, v) => { const r = build(k, v); r.k = k; r.v = v; r[1](v); return r; };
  const L = (all) => {
    const E = get().entries, old = new Map(), N = [];
    let kept = 0;
    R.forEach((r, i) => { r.p = i; old.set(r.k, r); });
    for (const [k, v] of E) {
      let r = old.get(k);
      if (r) { kept++; old.delete(k); if (all || r.v !== v) { r.v = v; r[1](v); } } else r = make(k, v);
      N.push(r);
    }
    R = N;${M ? " index = null;" : ""}
    if (!kept) { const f = new DocumentFragment(); for (const r of N) f.append(r[0]); parent.replaceChildren(f); return; }
    for (const r of old.values()) r[0].remove();
${order}
  };
  ${at}
  L.swap = (a, b) => {
    const d = get();
    let x = d.index.get(a), y = d.index.get(b);
    if (x === undefined || y === undefined || x === y) return;
    if (x > y) [x, y] = [y, x];
    const A = R[x], B = R[y], n = B[0].nextSibling;
    R[x] = B; R[y] = A;
    parent.insertBefore(B[0], A[0]);
    parent.insertBefore(A[0], n);
  };
${W ? "" : `  L.each = () => { const E = get().entries; R.forEach((r, j) => { r.v = E[j][1]; r[1](r.v); }); };`}
  return L;
}
`;
}

// ---------------------------------------------------------------------------------------------
// Cells

function fmt(c, v) {
  switch (c.format) {
    case "plain": return v;
    case "grouped": return `group(${v})`;
    case "unit": return `\`\${group(${v})} ${c.unit}\``;
    case "currency": return `money(${str(c.symbol)}, ${v})`;
    case "percent": return `percent(${v})`;
  }
  throw new Error(`unknown number format ${c.format}`);
}
const DATE_FORMAT = { "mon-d": "monD", "d-mon": "dMon", "mm-dd": "mmDd" };
function exprCode(e) {
  switch (e[0]) {
    case "*": return `item.${e[1]} * item.${e[2]}`;
    case "+": return `item.${e[1]} + item.${e[2]}`;
    case "len": return CP ? `cpLength(item.${e[1]})` : `item.${e[1]}.length`;
    case ">": return `item.${e[1]} > ${e[2]}`;
    case "==": return `item.${e[1]} == ${str(e[2])}`;
    case "f": return `item.${e[1]}`;
    case "if": return `${exprCode(e[1])} ? ${str(e[2])} : ${str(e[3])}`;
  }
  throw new Error(`unknown expression ${JSON.stringify(e)}`);
}

// A JavaScript validator of one decoded row, the shape beni's schema reader writes for a record
// of the row's type (S1's per-type function: a field test, then a fresh record).
function rowValidator(t) {
  const tests = [];
  const fields = [];
  for (const c of t.columns) {
    const n = c.name;
    switch (c.kind) {
      case "id": break;
      case "label": case "text": case "status": tests.push(`typeof x.${n} !== "string"`); fields.push(n); break;
      case "number": case "date": tests.push(`!Number.isSafeInteger(x.${n})`); fields.push(n); break;
      case "flag": tests.push(`typeof x.${n} !== "boolean"`); fields.push(n); break;
    }
  }
  return `(x) => typeof x !== "object" || x === null || Array.isArray(x) || !Number.isSafeInteger(x.id)${tests.map((s) => " || " + s).join("")} ? undefined : { id: x.id${fields.map((n) => `, ${n}: x.${n}`).join("")} }`;
}

// ---------------------------------------------------------------------------------------------
// One table

function tableFile(t) {
  const used = new Set();
  const use = (...names) => names.forEach((n) => used.add(n));
  const hasSelect = t.columns.some((c) => c.select);
  const L = "L";
  const sel = Y ? "s.selected.a" : "s.selected"; // the selected key (Nothing's is null)
  const nothing = Y ? "nothing" : "null";
  if (Y) use("just", "nothing");
  const sched = (x) => (G ? `${x};` : `schedule(${x});`);
  // Runs after an arm that wrote `selected`: the old and the new selected rows (D: by key).
  const selector = hasSelect && D ? (o) => `${o}${Y ? ".a" : ""} != null && ${L}.at(${o}${Y ? ".a" : ""}); ${sel} != null && ${L}.at(${sel});` : null;

  let html = `<h2>${escText(t.title)}</h2><div>`;
  html += t.ops.map((o) => `<button data-role=${attrValue(o.name)}>${escText(o.text)}</button>`).join("");
  html += "</div><table>";
  if (t.thead) html += `<thead><tr>${t.columns.map((c) => `<th>${escText(c.header)}`).join("")}</tr>`;
  html += "<tbody>";
  html = html.replace(/<\/tr>(?=<tbody>)/, "");

  const key = D ? "k" : "item.id";
  let n = 0;
  const cells = [], once = [], paints = [], events = [];
  const E = (k) => `E[${k}]`;
  for (const c of t.columns) {
    const td = n++;
    switch (c.kind) {
      case "id":
        cells.push("");
        once.push(`${E(td)}.textContent = ${key};`);
        break;
      case "label": case "text": {
        const value = `item.${c.name}`;
        if (c.select) {
          const a = n++;
          cells.push(`<a data-role=${attrValue(c.select)}></a>`);
          paints.push(`text(${E(a)}, ${value});`);
          if (D) use("member"), events.push(`on(${E(a)}, () => {`, "  if (!member(s.rows, k)) return;", "  const o = s.selected;", `  s.selected = ${Y ? "just(k)" : "k"};`, `  ${selector("o")}`, "});");
          else if (G) events.push(`on(${E(a)}, () => {`, "  if (!s.rows.some((x) => x.id === item.id)) return;", "  const was = s.selected;", "  s.selected = item.id;", `  ${L}.get(was)?.[2](); mark();`, "});");
          else events.push(`on(${E(a)}, () => {`, "  if (!s.rows.some((x) => x.id === item.id)) return;", "  const was = s.selected;", "  s.selected = item.id;", `  schedule(${L}.get(was)?.[2], mark);`, "});");
          use("text", "on");
        } else { cells.push(""); paints.push(`text(${E(td)}, ${value});`); use("text"); }
        break;
      }
      case "number": cells.push(""); paints.push(`text(${E(td)}, ${fmt(c, `item.${c.name}`)});`); use("text"); break;
      case "date": cells.push(""); paints.push(`text(${E(td)}, ${DATE_FORMAT[c.format]}(item.${c.name}));`); use("text"); break;
      case "status": { const b = n++; cells.push(`<${c.tag}></${c.tag}>`); paints.push(`text(${E(b)}, item.${c.name});`); use("text"); break; }
      case "flag": {
        const i = n++;
        cells.push(`<input type=checkbox data-role=${attrValue(c.toggle)}>`);
        paints.push(`prop(${E(i)}, item.${c.name}, "checked");`);
        if (D) events.push(`on(${E(i)}, () => {`, `  update(s.rows, k, (m) => (m.$ === 0 && (m.a.${c.name} = !m.a.${c.name}), m));`, `  ${L}.at(k);`, "});"), use("update");
        else events.push(`on(${E(i)}, () => {`, "  const row = s.rows.find((x) => x.id === item.id);", "  if (!row) return;", `  row.${c.name} = !row.${c.name};`, `  ${sched("set()")}`, "});");
        use("prop", "on");
        break;
      }
      case "computed": {
        cells.push("");
        const e = c.expr;
        const value = e[0] === "if" || e[0] === "len" ? exprCode(e) : fmt(c, exprCode(e));
        paints.push(`text(${E(td)}, ${value});`);
        if (e[0] === "len" && CP) use("cpLength");
        use("text");
        break;
      }
      case "remove": {
        const a = n++;
        const attrs = `data-role=${attrValue(c.role)}`;
        if (c.glyph) { n++; cells.push(`<${c.element} ${attrs}><span aria-hidden=true>${escText(c.text)}</span></${c.element}>`); }
        else cells.push(`<${c.element} ${attrs}>${escText(c.text)}</${c.element}>`);
        if (D) events.push(`on(${E(a)}, () => {`, ...(hasSelect ? ["  const o = s.selected;"] : []), "  remove(s.rows, k);",
          ...(hasSelect ? [`  if (${sel} === k) s.selected = ${nothing};`] : []), `  ${L}.at(k);`, ...(hasSelect ? [`  ${selector("o")}`] : []), "});"), use("remove");
        else events.push(`on(${E(a)}, () => {`, "  const at = s.rows.findIndex((x) => x.id === item.id);", "  if (at < 0) return;", "  s.rows.splice(at, 1);",
          ...(hasSelect ? ["  if (s.selected === item.id) s.selected = null;"] : []), `  ${L}.drop(item.id);`, "});");
        use("on");
        break;
      }
      case "bump": {
        const b = n++;
        cells.push(`<button data-role=${attrValue(c.role)}>${escText(c.text)}</button>`);
        if (D) events.push(`on(${E(b)}, () => {`, `  update(s.rows, k, (m) => (m.$ === 0 && (m.a.${c.column} += ${c.delta}), m));`, `  ${L}.at(k);`, "});"), use("update");
        else events.push(`on(${E(b)}, () => {`, "  const row = s.rows.find((x) => x.id === item.id);", "  if (!row) return;", `  row.${c.column} += ${c.delta};`, `  ${sched("set()")}`, "});");
        use("on");
        break;
      }
      case "spacer": cells.push(""); break;
      default: throw new Error(`unknown column kind ${c.kind}`);
    }
  }
  const row = `<tr data-role=row>${cells.map((c) => `<td>${c}`).join("")}`;

  let mark = [];
  if (t.marker) {
    const m = t.marker;
    const test = D ? `${sel} === k` : "s.selected === item.id";
    const v = m.attr === "class" ? `${test} ? ${str(m.value)} : "", "className"` : `${test} ? ${str(m.value)} : null, "ariaSelected"`;
    if (D) paints.push(`prop(tr, ${v});`);
    else { mark = [`const mark = () => prop(tr, ${v});`]; paints.push("mark();"); }
    use("prop");
  }

  const pools = [], fields = [];
  for (const c of t.columns) {
    switch (c.kind) {
      case "label": {
        const words = c.pools.map((p, i) => { pools.push(`const ${c.name}Words${i} = ${str(p)};`); return `\${pick(r = next(r), ${c.name}Words${i})}`; });
        fields.push(`${c.name}: \`${words.join(" ")}\``);
        break;
      }
      case "text": pools.push(`const ${c.name}Words = ${str(c.pool)};`); fields.push(`${c.name}: pick(r = next(r), ${c.name}Words)`); break;
      case "number": fields.push(`${c.name}: between(r = next(r), ${c.min}, ${c.max})`); break;
      case "date": fields.push(`${c.name}: between(r = next(r), 1, 365)`); break;
      case "status": pools.push(`const ${c.name}Options = ${str(c.options)};`); fields.push(`${c.name}: pick(r = next(r), ${c.name}Options)`); break;
      case "flag": fields.push(`${c.name}: (r = next(r)) % 2 === 1`); break;
    }
  }
  fields.push("id: s.nextId++");

  const sortCmp = (o) => {
    const c = o.column === "id" ? { kind: "id", name: "id" } : col(t, o.column);
    const [a, b] = o.dir === "desc" ? ["b", "a"] : ["a", "b"];
    const k = (x) => (c.kind === "status" ? `${c.name}Options.indexOf(${x}.${c.name})` : `${x}.${c.name}`);
    if (c.kind === "id") return `(a, b) => ${a}.id - ${b}.id`;
    const cmp = c.kind === "label" || c.kind === "text" ? `(${k(a)} < ${k(b)} ? -1 : ${k(a)} > ${k(b)} ? 1 : 0)` : `${k(a)} - ${k(b)}`;
    return `(a, b) => ${cmp} || a.id - b.id`;
  };
  const effect = (o, v0 = "item") => {
    const c = col(t, o.column);
    const v = `${v0}.${c.name}`;
    switch (c.kind) {
      case "label": case "text": return `${v} += ${str(o.suffix)}`;
      case "number": return `${v} += ${o.delta}`;
      case "date": return `${v} = ((${v} - 1 + ${o.days}) % 365) + 1`;
      case "status": return `${v} = ${c.name}Options[(${c.name}Options.indexOf(${v}) + 1) % ${c.options.length}]`;
      case "flag": return `${v} = !${v}`;
    }
    throw new Error(`updateEvery on a ${c.kind} column`);
  };
  const selWrite = (body) => (hasSelect && D ? ["const o = s.selected;", ...body, selector("o")] : body);
  const ops = [];
  t.ops.forEach((o, k) => {
    let body = [];
    if (D) {
      switch (o.kind) {
        case "create": body = [`s.rows = make(empty(), ${o.count});`, ...(hasSelect ? [`s.selected = ${nothing};`] : []), `${L}();`]; use("empty"); if (hasSelect) body = selWrite(body); break;
        case "append": body = W ? [`make(s.rows, ${o.count}, ${L});`] : [`make(s.rows, ${o.count});`, `${L}();`]; break;
        case "updateEvery": body = W ? [`for (let i = 0; i < size(s.rows); i += ${o.k}) { const k = keyAt(s.rows, i).a; update(s.rows, k, (m) => (m.$ === 0 && (${effect(o, "m.a")}), m)); ${L}.at(k); }`] : [`keys(s.rows).forEach((k, i) => i % ${o.k} || update(s.rows, k, (m) => (m.$ === 0 && (${effect(o, "m.a")}), m)));`, `${L}.each();`]; use(...(W ? ["size", "keyAt", "update"] : ["keys", "update"])); break;
        case "clear": body = ["s.rows = empty();", ...(hasSelect ? [`s.selected = ${nothing};`] : []), `${L}();`]; use("empty"); if (hasSelect) body = selWrite(body); break;
        case "swap": body = [`if (size(s.rows) > ${o.j}) {`, `  const a = keyAt(s.rows, ${o.i}).a, b = keyAt(s.rows, ${o.j}).a;`, "  swap(s.rows, a, b);", `  ${L}.swap(a, b);`, "}"]; use("size", "keyAt", "swap"); break;
        case "sort": body = [`sortBy(s.rows, ${sortCmp(o)}, (k, v) => v);`, `${L}();`]; use("sortBy"); break;
        case "removeChecked": body = [`s.rows = filter(s.rows, (k, item) => !item.${o.column});`, ...(hasSelect ? [`member(s.rows, ${sel}) || (s.selected = ${nothing});`] : []), `${L}();`]; use("filter"); if (hasSelect) { use("member"); body = selWrite(body); } break;
        default: throw new Error(o.kind);
      }
    } else {
      switch (o.kind) {
        case "create": body = [`s.rows = make(${o.count});`, ...(hasSelect ? ["s.selected = null;"] : []), (G ? `${L}();` : `schedule(${L});`)]; break;
        case "append": body = [`const added = make(${o.count});`, "s.rows.push(...added);", `${L}.add(added);`]; break;
        case "updateEvery": body = [`for (let i = 0; i < s.rows.length; i += ${o.k}) {`, "  const item = s.rows[i];", `  ${effect(o)};`, `  ${G ? `${L}.get(item.id)?.[1]();` : `schedule(${L}.get(item.id)?.[1]);`}`, "}"]; break;
        case "clear": body = ["s.rows = [];", ...(hasSelect ? ["s.selected = null;"] : []), (G ? `${L}();` : `schedule(${L});`)]; break;
        case "swap": body = [`if (s.rows.length > ${o.j}) {`, `  const a = s.rows[${o.i}];`, `  const b = s.rows[${o.j}];`, `  s.rows[${o.i}] = b;`, `  s.rows[${o.j}] = a;`, `  ${L}.swap(b.id, a.id);`, "}"]; break;
        case "sort": body = [`s.rows = s.rows.slice().sort(${sortCmp(o)});`, (G ? `${L}();` : `schedule(${L});`)]; break;
        case "removeChecked": body = [`s.rows = s.rows.filter((item) => !item.${o.column});`, ...(hasSelect ? ["keepSelected(s);"] : []), (G ? `${L}();` : `schedule(${L});`)]; break;
      }
    }
    ops.push(`on(E[${k}], () => {`, ...body.map((l) => "  " + l), "});");
  });
  use("on");
  if (!G) use("schedule");
  if (!D && t.ops.some((o) => o.kind === "removeChecked") && hasSelect) used.add("keepSelected");

  const scenarioNames = new Set(["state"]);
  const allText = [...paints, ...events, ...ops, ...fields].join("\n");
  for (const name of ["next", "pick", "between", "group", "money", "percent", "monD", "dMon", "mmDd"]) if (new RegExp(`\\b${name}\\(`).test(allText)) scenarioNames.add(name);
  if (used.has("keepSelected")) scenarioNames.add("keepSelected");
  if (used.has("cpLength")) scenarioNames.add("cpLength");

  const make = D
    ? [W ? "const make = (d, n, l) => {" : "const make = (d, n) => {", "  let r = s.rng;", `  while (n--) { const id = s.nextId++; insert(d, id, { ${fields.slice(0, -1).join(", ")}${fields.length > 1 ? ", " : ""}id }); }`, "  s.rng = r;", "  return d;", "};"]
    : ["const make = (n) => {", "  let r = s.rng;", "  const out = [];", `  while (n--) out.push({ ${fields.join(", ")} });`, "  s.rng = r;", "  return out;", "};"];
  // The id is drawn last in both: in D the fields are drawn first by evaluation order of the
  // record, so the id is taken before them; correct the order: draw cells, then the id.
  if (D) make[2] = `  while (n--) { const v = { ${fields.slice(0, -1).join(", ")} }; v.id = s.nextId++; insert(d, v.id, v);${W ? " l && l.at(v.id);" : ""} }`;
  if (D) use("insert");
  const initial = t.initialRows ? [D ? `make(s.rows, ${t.initialRows});` : `s.rows = make(${t.initialRows});`] : [];

  // Typed pushes (v): this table's own decoding of the rows a push carries.
  const pushes = [];
  if (V && H) {
    const ty = { id: 0, number: 0, date: 0, label: 1, text: 1, status: 1, flag: 2 };
    pushes.push(`const shape = ${str([["id", 0], ...t.columns.filter((c) => c.kind in ty && c.kind !== "id").map((c) => [c.name, ty[c.kind]])])};`);
  } else if (V) {
    pushes.push(`const valid = ${rowValidator(t)};`);
    pushes.push(`const decode = (raw) => { if (!Array.isArray(raw)) return; const out = []; for (const x of raw) { const v = valid(x); if (v === undefined) return; out.push(${D ? "[v.id, v]" : "v"}); } return out; };`);
    const strCols = t.columns.filter((c) => ["label", "text", "status"].includes(c.kind)).map((c) => c.name);
    const intCols = t.columns.filter((c) => ["number", "date"].includes(c.kind)).map((c) => c.name);
    const boolCols = t.columns.filter((c) => c.kind === "flag").map((c) => c.name);
    pushes.push(`const cell = (column, x) => ${[
      ...strCols.map((n) => `column === ${str(n)} ? typeof x === "string"`),
      ...intCols.map((n) => `column === ${str(n)} ? Number.isSafeInteger(x)`),
      ...boolCols.map((n) => `column === ${str(n)} ? typeof x === "boolean"`),
    ].map((s) => s + " : ").join("")}false;`);
  }

  const list = D
    ? [`const ${L} = list(E[${t.ops.length}], () => s.rows, (k, item) => {`, "  const tr = row.cloneNode(true);", '  const E = tr.querySelectorAll("*");', '  tr.setAttribute("data-key", k);',
      ...once.map((l) => "  " + l), ...events.map((l) => "  " + l), `  return [tr, (v) => { item = v; ${paints.join(" ")} }];`, "});"]
    : [`const ${L} = rows(E[${t.ops.length}], () => s.rows, (item) => {`, "  const tr = row.cloneNode(true);", '  const E = tr.querySelectorAll("*");', '  tr.setAttribute("data-key", item.id);',
      ...once.map((l) => "  " + l), ...mark.map((l) => "  " + l), "  const set = (fresh = item) => {", "    item = fresh;", ...paints.map((l) => "    " + l), "  };",
      ...events.map((l) => "  " + l), `  return [tr, set${t.marker ? ", mark" : ""}];`, "});"];

  const handle = V && H ? `[s, ${L}, shape]` : V ? `[s, ${L}, decode, cell]` : `[s, ${L}]`;
  const lines = [
    `const s = state(${t.rng});`, ...pools, "", ...make, ...initial, "", `const row = tpl(${str(row)});`, ...list, "", ...ops, "", ...pushes, `return ${handle};`,
  ];
  const body = lines.map((l) => (l ? "  " + l : l)).join("\n");
  const rt = ["text", "prop", "on", "schedule"].filter((x) => used.has(x));
  const dictNames = ["just", "nothing", "empty", "size", "member", "keyAt", "insert", "remove", "swap", "update", "filter", "keys", "sortBy"].filter((x) => used.has(x));
  return `import { ${rt.join(", ")} } from "../runtime.js";
import { ${D ? "list" : "rows"}, tpl } from "../rows.js";
${dictNames.length ? `import { ${dictNames.join(", ")} } from "../dict.js";\n` : ""}import { ${[...scenarioNames].join(", ")} } from "../scenario.js";
import { W } from "./table.js";

W.push([${str(html)}, (E) => {
${body}
}]);
`;
}

const HELPER_FILE = `export function section(parent, i, html) {
  parent.insertAdjacentHTML("beforeend", \`<section data-key=t\${i} data-role=table>\${html}\`);
  return parent.lastChild.querySelectorAll("button,tbody");
}
export const W = [,];
`;

// ---------------------------------------------------------------------------------------------
// The app: tables and the external arms.

function appFile(spec) {
  const imports = spec.tables.map((t) => `import "./tables/${t.id}.js";`).join("\n");
  const sched = (x) => (G ? `${x}();` : `schedule(${x});`);
  const sel = Y ? "s.selected.a" : "s.selected";
  if (!D) {
    // tea-inline's own receive, with synchronous passes under g.
    return `import { ${G ? "guard, stopAll, revive" : "flush, cancel, schedule"} } from "./runtime.js";
import { keepSelected } from "./scenario.js";
import { W, section } from "./tables/table.js";
${imports}

export function start(root) {
  ${G ? "revive();" : ""}
  root.insertAdjacentHTML("beforeend", "<div data-role=page>");
  const board = root.lastChild;
  const views = W.map(([html, table], i) => table(section(board, i, html)));
  ${G ? "views.forEach(([, list]) => list());" : "schedule(views.map(([, list]) => list));\n  flush();"}
  function receive(msg) {
    if (msg.type === "snapshot") {
      for (const id in msg.state.tables) {
        const [s, list] = views[id.slice(1)];
        Object.assign(s, structuredClone(msg.state.tables[id]));
        ${sched("list")}
      }
      return;
    }
    const [s, list] = views[msg.table.slice(1)];
    switch (msg.type) {
      case "serverRows":
        s.rows = structuredClone(msg.rows);
        keepSelected(s);
        s.nextId = s.rows.reduce((max, item) => Math.max(max, item.id + 1), s.nextId);
        ${sched("list")}
        break;
      case "serverUpdate":
        for (const { id, value } of msg.changes) {
          const item = s.rows.find((x) => x.id === id);
          if (item) { item[msg.column] = value; ${G ? "list.get(id)?.[1]();" : "schedule(list.get(id)?.[1]);"} }
        }
        break;
      case "serverDelete": {
        const gone = new Set(msg.ids);
        s.rows = s.rows.filter((item) => !gone.has(item.id));
        keepSelected(s);
        ${sched("list")}
        break;
      }
    }
  }
  ${G ? "const deliver = receive; receive = (msg) => guard(deliver, msg);" : ""}
  function stop() { ${G ? "stopAll()" : "cancel()"}; board.remove(); }
  return { receive${G ? ": (msg) => guard(receive, msg)" : ""}, stop };
}
`.replace(/  const deliver = receive; receive = \(msg\) => guard\(deliver, msg\);\n/, "");
  }
  // D: the Dict program. Rows are copied into a fresh Dict (fromList); edits by key.
  const decodeRows = V && H ? "decodeRows(v[2], msg.rows)" : V ? "v[2](msg.rows)" : "structuredClone(msg.rows).map((r) => [r.id, r])";
  const selectorAfter = `o${Y ? ".a" : ""} != null && list.at(o${Y ? ".a" : ""}); ${sel} != null && list.at(${sel});`;
  return `import { guard, stopAll, revive } from "./runtime.js";
import { fromList, foldl, member, update, remove, nothing } from "./dict.js";
import { W, section } from "./tables/table.js";
${imports}
${H ? SHAPES : ""}
export function start(root) {
  ${G ? "revive();" : ""}
  root.insertAdjacentHTML("beforeend", "<div data-role=page>");
  const board = root.lastChild;
  const views = W.map(([html, table], i) => table(section(board, i, html)));
  views.forEach(([, list]) => list());
  function receive(msg) {
    if (msg.type === "snapshot") {
      const next = [];
      for (const id in msg.state.tables) {
        const v = views[id.slice(1)], t = msg.state.tables[id];
        ${V ? `const rows = ${H ? "decodeRows(v[2], t.rows)" : "v[2](t.rows)"};
        if (!rows || !(t.selected === null || Number.isSafeInteger(t.selected)) || !Number.isSafeInteger(t.nextId) || !Number.isSafeInteger(t.rng)) return;
        next.push([v, rows, t]);` : "next.push([v, structuredClone(t.rows).map((r) => [r.id, r]), t]);"}
      }
      for (const [[s, list], rows, t] of next) {
        s.rows = fromList(rows); s.selected = ${Y ? "t.selected === null ? nothing : { $: 0, a: t.selected }" : "t.selected"}; s.nextId = t.nextId; s.rng = t.rng;
        list();
      }
      return;
    }
    const v = views[msg.table.slice(1)];
    if (!v) return;
    const [s, list] = v, o = s.selected;
    switch (msg.type) {
      case "serverRows": {
        const rows = ${decodeRows};
        if (!rows) return;
        s.rows = fromList(rows);
        member(s.rows, ${sel}) || (s.selected = ${Y ? "nothing" : "null"});
        s.nextId = foldl(s.rows, s.nextId, (k, r, m) => Math.max(m, k + 1));
        list();
        break;
      }
      case "serverUpdate": {
        const c = msg.column;
        for (const { id, value } of msg.changes) {
          ${V ? `if (!Number.isSafeInteger(id) || !${H ? "validCell(v[2], c, value)" : "v[3](c, value)"}) return;` : ""}
          update(s.rows, id, (m) => (m.$ === 0 && (m.a[c] = value), m));${W ? " list.at(id);" : ""}
        }
        ${W ? "" : "list.each();"}
        break;
      }
      case "serverDelete":
        for (const id of msg.ids) { remove(s.rows, id);${W ? " list.at(id);" : ""} }
        member(s.rows, ${sel}) || (s.selected = ${Y ? "nothing" : "null"});
        ${W ? "" : "list();"}
        break;
    }
    ${selectorAfter}
  }
  function stop() { stopAll(); board.remove(); }
  return { receive: (msg) => guard(receive, msg), stop };
}
`;
}

// Shape-driven row validation (core validShape over a shape row): 0 Int, 1 String, 2 Bool.
const SHAPES = `
const TESTS = [Number.isSafeInteger, (x) => typeof x === "string", (x) => typeof x === "boolean"];
function decodeRows(shape, raw) {
  if (!Array.isArray(raw)) return;
  const out = [];
  for (const x of raw) {
    if (typeof x !== "object" || x === null || Array.isArray(x)) return;
    const v = {};
    for (const [n, t] of shape) { if (!TESTS[t](x[n])) return; v[n] = x[n]; }
    out.push([v.id, v]);
  }
  return out;
}
const validCell = (shape, c, x) => shape.some(([n, t]) => n === c && n !== "id" && TESTS[t](x));
`;

export function emit(spec) {
  const base = templateFiles({ name: "big-table", title: "Big table", extra: ["rows.js", "scenario.js"] });
  const files = { ...base, "src/app.js": appFile(spec), "src/tables/table.js": HELPER_FILE };
  if (G) {
    files["src/runtime.js"] = RUNTIME_BENI;
    // the adapter imports settled from runtime.js: kept.
    if (!D) files["src/rows.js"] = files["src/rows.js"].replace(/^import \{ schedule \} from "\.\/runtime\.js";$/m, "").replace(/schedule\(\(\) => \{/g, "(() => {").replace(/\}\);\n  \};/g, "})();\n  };");
  }
  if (D) { files["src/rows.js"] = P ? rowsFileP() : rowsFile(); files["src/dict.js"] = P ? DICT_P : DICT; }
  if (CP) files["src/scenario.js"] += `\nexport const cpLength = (s) => { let n = 0; for (const _ of s) n++; return n; };\n`;
  if (D) files["src/scenario.js"] = files["src/scenario.js"].replace("rows: []", "rows: empty()").replace(/^/, 'import { empty } from "./dict.js";\n');
  if (Y) files["src/scenario.js"] = files["src/scenario.js"].replace("selected: null", "selected: nothing").replace(/^/, 'import { nothing } from "./dict.js";\n');
  for (const t of spec.tables) files[`src/tables/${t.id}.js`] = tableFile(t);
  return { files, style: {} };
}
