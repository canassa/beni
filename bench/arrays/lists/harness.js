// The driver of research/38 §16's list scenarios. Everything that is beni is imported from the
// compiled output (`beni-out/*`, which lists.mjs maps to the candidate's tree); `list-rt` is the
// candidate's runtime module (lists/core-*.js), which also supplies the harness's hooks: `fromJs`
// (a JS array in as a list, outside the timing), `toJs` (a list out, for the differential test) and
// `walk` (the DOM runtime's way through a list, for the TEA render). The timing loop is §15's.
import * as RT from 'list-rt';
const { fromJs, toJs, walk } = RT;
// the array-first sources of §17 keep a stack's top at the END
const topFirst = (s) => (RT.stackTopLast ? toJs(s).reverse() : toJs(s));
import * as Recur from 'beni-out/Recur.mjs';
import * as Lib from 'beni-out/Lib.mjs';
import * as Todo from 'beni-out/Todo.mjs';
import * as Paths from 'beni-out/Paths.mjs';

const now = () => performance.now();
let sink = null;
// WARM_MS lengthens the warm-up: §17's one-op-per-process runs start with cold core functions
const CFG = { minMs: 10, warmMs: +(globalThis.process?.env?.WARM_MS ?? 25), samples: 7, maxCallMs: 400, hugeMs: 1500 };
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

// ---- inputs, deterministic ------------------------------------------------------------------------
function ints(n, seed) {
  const out = [];
  for (let i = 0; i < n; i++) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; out.push((seed >>> 8) % 1000000); }
  return out;
}
const triple = (x) => x * 3 + 1;
const odd = (x) => x % 2 === 1;

// The DOM runtime's positional `For` over the rows, once per render (§15's `render`, walking the
// list through the candidate's `walk`): patch a row whose item is not the one shown last time, and
// check every row's `done` hole.
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

// ---- the cells: [scenario, op, n, fn] ------------------------------------------------------------
export const SIZES = [10, 100, 1000, 10000, 100000];
export function cells(n) {
  const arr = ints(n, 4242), xs = fromJs(arr), ys = fromJs(ints(n, 99));
  const sortedPrefix = fromJs(arr.map((_, i) => i)); // takeWhile on a sorted list keeps 90 %
  const lim = Math.floor(n * 0.9);
  const out = [
    ['1 by hand', 'map, recursive', n, () => Recur.Recur$mapRec(xs, triple)],
    ['1 by hand', 'filter, recursive', n, () => Recur.Recur$filterRec(xs, odd)],
    ['1 by hand', 'map, accumulator + reverse', n, () => Recur.Recur$mapAcc(xs, triple)],
    ['1 by hand', 'filter, accumulator + reverse', n, () => Recur.Recur$filterAcc(xs, odd)],
    ['2 x :: rest', 'sum', n, () => Recur.Recur$sum(xs)],
    ['2 x :: rest', 'sum, List.foldl', n, () => Recur.Recur$sumFold(xs)],
    ['2 x :: rest', 'takeWhile (90 %)', n, () => Recur.Recur$takeWhile(sortedPrefix, (x) => x < lim)],
    ['2 x :: rest', 'pairwise', n, () => Recur.Recur$pairwise(xs)],
    ['2 x :: rest', 'merge sort', n, () => Recur.Recur$mergeSort(xs)],
    ['2 x :: rest', 'merge sort, sorted input', n, () => Recur.Recur$mergeSort(sortedPrefix)],
    ['3 library', 'foldr building a list', n, () => Lib.Lib$foldrBuild(xs)],
    ['3 library', 'foldr sum', n, () => Lib.Lib$foldrSum(xs)],
    ['3 library', 'range + sum', n, () => Lib.Lib$rangeSum(n)],
    ['3 library', 'map2 (zip)', n, () => Lib.Lib$zip(xs, ys)],
    ['3 library', 'concatMap', n, () => Lib.Lib$concatMapPairs(xs)],
    ['3 library', 'append in a loop, acc ++ [x]', n, () => Lib.Lib$appendLoop(xs)],
    ['3 library', 'append two', n, () => Lib.Lib$appendTwo(xs, ys)],
    ['3 library', 'reverse', n, () => Lib.Lib$reverse(xs)],
    ['3 library', 'List.map', n, () => Lib.Lib$libMap(xs)],
    ['3 library', 'List.filter', n, () => Lib.Lib$libFilter(xs)],
    ['4 prepend in a fold', 'x :: acc, then reverse', n, () => Lib.Lib$prependFold(xs)],
    ['4 prepend in a fold', 'into a record field', n, () => Lib.Lib$recordFold(xs)],
    ['4 prepend in a fold', 'into a tuple (partition)', n, () => Lib.Lib$partitionFold(xs)],
    ['4 prepend in a fold', 'paths sharing tails, all kept', n, () => Paths.Paths$chainPaths(n)],
    ['4 prepend in a fold', 'undo stack (3 edits, 1 undo)', n, () => Paths.Paths$undoSession(n)],
  ];
  // 5: the TEA model. `first` starts from the same fresh model every call; `steady` threads it.
  const m0 = Todo.Todo$create(n), U = Todo.Todo$update;
  const snap0 = render(m0, []);
  out.push(['5 TEA list', 'add to front, first', n, () => render(U(Todo.Todo$add, m0), snap0.slice())]);
  { let s = m0, snap = render(m0, []), k = 0;
    out.push(['5 TEA list', 'add + remove oldest, steady', n, () => { s = U(Todo.Todo$remove(++k), U(Todo.Todo$add, s)); snap = render(s, snap); return snap; }]); }
  { let s = m0, snap = render(m0, []), k = 0;
    out.push(['5 TEA list', 'toggle one, steady', n, () => { s = U(Todo.Todo$toggle(1 + ((k++ * 7919) % n)), s); snap = render(s, snap); return snap; }]); }
  out.push(['5 TEA list', 'remove one, first', n, () => render(U(Todo.Todo$remove(n >> 1), m0), snap0.slice())]);
  { let snap = render(m0, []); out.push(['5 TEA list', 'render only', n, () => (snap = render(m0, snap))]); }
  return out;
}

// ---- timing ------------------------------------------------------------------------------------------
// One process per (candidate, size), driven by lists.mjs: `skip` names ops not to run at this size
// (over 3 s per call at the size before, or crashed here in an earlier attempt). A `start` line goes
// out before each cell, so a process that dies (heap exhausted) names the cell that killed it; a
// RangeError is recorded as a stack overflow.
export function run(name, n, skip) {
  const p = (x) => +x.toPrecision(4);
  for (const [sc, op, nn, fn] of cells(n)) {
    if (skip.includes(op) || (process.env.ONLY && !process.env.ONLY.split(';').includes(op))) continue;
    const base = { engine: 'node', impl: name, sc, op, n: nn };
    console.log(JSON.stringify({ start: op }));
    if (typeof gc === 'function') gc();
    let r;
    try { r = measure(fn); } catch (e) {
      if (e instanceof RangeError) { console.log(JSON.stringify({ ...base, overflow: true })); continue; }
      throw e;
    }
    console.log(JSON.stringify({ ...base, med: p(r.med), q1: p(r.q1), q3: p(r.q3), lo: p(r.lo), hi: p(r.hi), S: r.S }));
  }
}

// ---- stack safety (§17): every cell once at n, on whatever stack the process was given ----------------
export function stack(name, n, skip) {
  for (const [sc, op, , fn] of cells(n)) {
    if (skip.includes(op)) { console.log(JSON.stringify({ impl: name, sc, op, n, stack: 'not run' })); continue; }
    let r;
    try { sink = fn(); r = 'ok'; } catch (e) { r = e instanceof RangeError ? 'stack overflow' : String(e); }
    console.log(JSON.stringify({ impl: name, sc, op, n, stack: r }));
  }
}

// ---- memory: one call in this process, at one size ------------------------------------------------
// peak = the process's resident high-water mark across the call, reset just before it through
// /proc/self/clear_refs (Linux), minus the resident size then; retained = heap still used after two
// full GCs while holding the result, minus before the call (the inputs are held throughout)
let keep = null;
const fs = globalThis.process?.getBuiltinModule?.('node:fs');
const status = (k) => +new RegExp(k + ":\\s+(\\d+)").exec(fs.readFileSync("/proc/self/status", "utf8"))[1];
export function mem(name, op, n) {
  keep = cells(n);
  const cell = keep.find((c) => c[1] === op);
  gc(); gc();
  fs.writeFileSync("/proc/self/clear_refs", "5");
  const rss0 = status("VmRSS"), h0 = process.memoryUsage().heapUsed;
  let res, err = null;
  try { res = cell[3](); } catch (e) { err = e instanceof RangeError ? "overflow" : String(e); }
  const peakKB = status("VmHWM") - rss0;
  gc(); gc();
  const h1 = process.memoryUsage().heapUsed;
  sink = res;
  console.log(JSON.stringify({ engine: "node", impl: name, sc: cell[0], op, n, peakKB, retained: err ? null : h1 - h0, err }));
}

// ---- the differential test: every cell once at several sizes, reduced to one string each -------------
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(16); };
function dig(v) {
  if (typeof v === 'number') return String(v);
  // a TEA model's rows are compared by id: the array-first `Add` (§17) appends where the cons one prepends
  if (v && typeof v === 'object' && 'items' in v) return `model ${v.nextId} ${fnv(JSON.stringify(byId(toJs(v.items))))}`;
  if (v && typeof v === 'object' && 'a' in v && 'b' in v && !('$' in v) && !('n' in v) && v.constructor === Object) return `(${dig(v.a)}, ${dig(v.b)})`;
  return fnv(JSON.stringify(toJs(v)));
}
const byId = (items) => items.slice().sort((x, y) => x.id - y.id);
const pathSet = (ps) => fnv(JSON.stringify(toJs(ps).map((p) => toJs(p).sort((a, b) => a - b)).sort((p, q) => p.length - q.length)));
export function test() {
  const out = [];
  for (const n of [0, 1, 2, 3, 10, 257, 1000]) {
    for (const [sc, op, nn, fn] of cells(n)) {
      // a TEA cell returns the render's row state: its rows' ids and `done`s
      // (both compared as sets, because the array-first versions of §17 keep a different order: a
      // path root first, the paths oldest first, a new TEA row last)
      const d = op.startsWith('paths') ? pathSet : op.startsWith('undo') ? (t) => `(${t.a}, ${fnv(JSON.stringify(topFirst(t.b)))})` : sc.startsWith('5') ? (rows) => fnv(JSON.stringify(byId(rows.map((r) => r.x)).map((x) => [x.id, x.done]))) : dig;
      out.push(`${sc} | ${op} | ${nn} | ${d(fn())} | ${d(fn())}`);
    }
  }
  // inputs unchanged, and the TEA model threaded through many messages
  const xs = fromJs(ints(300, 7)), before = fnv(JSON.stringify(toJs(xs)));
  Recur.Recur$mergeSort(xs); Recur.Recur$pairwise(xs); Lib.Lib$appendTwo(xs, xs); Lib.Lib$prependFold(xs);
  out.push(`input unchanged ${fnv(JSON.stringify(toJs(xs))) === before}`);
  let m = Todo.Todo$create(300);
  for (let k = 1; k < 400; k++) {
    m = Todo.Todo$update(k % 3 === 0 ? Todo.Todo$add : k % 3 === 1 ? Todo.Todo$toggle(k % 350) : Todo.Todo$remove(k), m);
    if (k % 50 === 0) out.push(`tea ${k} ${dig(m)}`);
  }
  return out.join('\n');
}
