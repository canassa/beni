// research/42 §8's list cells: the shapes research/38 §16 found C's static rules could not reach,
// the ones it could, one read-only walk, and the TEA list under both runtime protocols. The beni
// modules are §16's (lists/src), through its rewrite of the list syntax; `list-rt` is the
// variant's list core. Timing loop as in lists/harness.js.
import * as RT from 'list-rt';
import * as Recur from 'beni-out/Recur.mjs';
import * as Lib from 'beni-out/Lib.mjs';
import * as Todo from 'beni-out/Todo.mjs';
import * as Paths from 'beni-out/Paths.mjs';

const { fromJs, toJs, walk } = RT;
const retain = RT.retain ?? ((x) => x), keep = RT.keep ?? ((x) => x);
const now = () => performance.now();
let sink = null;
const CFG = { minMs: 10, warmMs: 25, samples: 7, maxCallMs: 400, hugeMs: 1500 };
function measure(fn) {
  let t0 = now(), calls = 0;
  do { sink = fn(); calls++; } while ((calls < 3 && now() - t0 < CFG.maxCallMs) || now() - t0 < CFG.warmMs);
  const one = (now() - t0) / calls;
  const k = Math.max(1, Math.ceil(CFG.minMs / Math.max(one, 1e-6)));
  const S = one > CFG.hugeMs ? 1 : one > CFG.maxCallMs ? 3 : CFG.samples;
  const xs = [];
  for (let s = 0; s < S; s++) { const a = now(); for (let i = 0; i < k; i++) sink = fn(); xs.push(((now() - a) / k) * 1e6); }
  xs.sort((a, b) => a - b);
  const q = (p) => xs[Math.min(xs.length - 1, Math.floor(p * (xs.length - 1) + 0.5))];
  return { med: q(0.5), lo: xs[0], hi: xs[xs.length - 1], q1: q(0.25), q3: q(0.75), S };
}
function ints(n, seed) {
  const out = [];
  for (let i = 0; i < n; i++) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; out.push((seed >>> 8) % 1000000); }
  return out;
}
function render(model, rows) {
  let dirty = 0, n = 0;
  walk(model.items, (item, k) => {
    const r = rows[k];
    if (r === undefined) { rows[k] = { x: item }; dirty++; } else if (r.x !== item) { r.x = item; dirty++; }
    if (item.done) dirty++;
    n = k + 1;
  });
  if (rows.length > n) rows.length = n;
  sink = dirty;
  return rows;
}

export function cells(n) {
  const xs = keep(fromJs(ints(n, 4242)));
  const out = [
    ['prepend', 'x :: acc in a foldl, then reverse', n, () => Lib.Lib$prependFold(xs)],
    ['prepend', 'into a record field', n, () => Lib.Lib$recordFold(xs)],
    ['prepend', 'into a tuple (partition)', n, () => Lib.Lib$partitionFold(xs)],
    ['read', 'sum by x :: rest', n, () => Recur.Recur$sum(xs)],
    ['read', 'List.map', n, () => Lib.Lib$libMap(xs)],
  ];
  if (n <= 10000) out.push(['prepend', 'paths sharing tails, all kept', n, () => Paths.Paths$chainPaths(n)]);
  const U = Todo.Todo$update;
  for (const retains of [false, true]) {
    let s = Todo.Todo$create(n), snap = render(s, []), k = 0;
    if (retains) retain(s.items);
    out.push(['tea', `add + remove oldest, steady, ${retains ? 'runtime retains' : 'hands over'}`, n, () => {
      s = U(Todo.Todo$remove(++k), U(Todo.Todo$add, s)); snap = render(s, snap); if (retains) retain(s.items); return snap;
    }]);
  }
  return out;
}

export function run(name, n) {
  const p = (x) => +x.toPrecision(4);
  for (const [sc, op, nn, fn] of cells(n)) {
    if (typeof gc === 'function') gc();
    let r;
    try { r = measure(fn); } catch (e) { console.log(JSON.stringify({ engine: 'node', impl: name, sc, op, n: nn, err: String(e).slice(0, 80) })); continue; }
    console.log(JSON.stringify({ engine: 'node', impl: name, sc, op, n: nn, med: p(r.med), q1: p(r.q1), q3: p(r.q3), lo: p(r.lo), hi: p(r.hi), S: r.S }));
  }
}

const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(16); };
function dig(v) {
  if (typeof v === 'number') return String(v);
  if (v && typeof v === 'object' && 'a' in v && 'b' in v && !('$' in v) && !Array.isArray(v) && !('o' in v)) return `(${dig(v.a)}, ${dig(v.b)})`;
  return fnv(JSON.stringify(toJs(v)));
}
export function test() {
  const out = [];
  for (const n of [0, 1, 2, 3, 10, 257, 1000]) {
    for (const [sc, op, nn, fn] of cells(n)) {
      const d = op.startsWith('paths') ? (ps) => String(Paths.Paths$checksum(ps)) : sc === 'tea' ? (rows) => fnv(JSON.stringify(rows.map((r) => [r.x.id, r.x.done]))) : dig;
      out.push(`${sc} | ${op} | ${nn} | ${d(fn())} | ${d(fn())}`);
    }
  }
  // inputs unchanged after every builder has run over them, and a fold's result consed onto twice
  const xs = keep(fromJs(ints(300, 7))), before = fnv(JSON.stringify(toJs(xs)));
  const r = Lib.Lib$recordFold(xs), p = Lib.Lib$partitionFold(xs); Lib.Lib$prependFold(xs);
  out.push(`input unchanged ${fnv(JSON.stringify(toJs(xs))) === before} ${dig(r)} ${dig(p)}`);
  // the runtime keeps the rendered items; a later Add must not change what it keeps
  let m = Todo.Todo$create(300);
  for (let k = 1; k < 400; k++) {
    const held = m.items, hd = fnv(JSON.stringify(toJs(held)));
    if (k % 2) retain(held);
    m = Todo.Todo$update(k % 4 < 2 ? Todo.Todo$add : k % 4 === 2 ? Todo.Todo$toggle(k % 350) : Todo.Todo$remove(k), m);
    if (k % 2 && fnv(JSON.stringify(toJs(held))) !== hd) out.push(`RETAINED ITEMS CHANGED at ${k}`);
    if (k % 50 === 0) out.push(`tea ${k} ${m.nextId} ${fnv(JSON.stringify(toJs(m.items)))}`);
  }
  return out.join('\n');
}
