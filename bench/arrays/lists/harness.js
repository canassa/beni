// The driver of research/38 §16's list scenarios. Everything that is beni is imported from the
// compiled output (`beni-out/*`, which lists.mjs maps to the candidate's tree); `list-rt` is the
// candidate's runtime module (lists/core-*.js), which also supplies the harness's hooks: `fromJs`
// (a JS array in as a list, outside the timing), `toJs` (a list out, for the differential test) and
// `walk` (the DOM runtime's way through a list, for the TEA render). The timing loop is §15's.
import * as RT from 'list-rt';
const { fromJs, toJs, walk } = RT;
// the array-first sources of §17 keep a stack's top at the END
const topFirst = (s) => (RT.stackTopLast ? toJs(s).slice().reverse() : toJs(s));
import * as Recur from 'beni-out/Recur.mjs';
import * as Lib from 'beni-out/Lib.mjs';
import * as Todo from 'beni-out/Todo.mjs';
import * as Paths from 'beni-out/Paths.mjs';

// the timing loop is lib/measure.js, shared by every harness here
import { measure, keep, cellLine } from '../lib/measure.js';

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
  keep(dirty);
  return rows;
}

// ---- the cells: [scenario, op, n, fn] ------------------------------------------------------------
export const SIZES = [10, 100, 1000, 10000, 100000];
const TEA = ["add to front, first", "add + remove oldest, steady", "toggle one, steady", "remove one, first", "render only"];
export function cells(n, pick = null) {
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
  // (built only when a TEA cell is wanted: `create` over a representation it does not suit can be slow)
  if (pick && !pick.some((op) => TEA.includes(op))) return out;
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
export function run(name, n, skip, cellsOf = cells, pick = null) {
  const only = pick ?? globalThis.process?.env?.ONLY?.split(";");
  const all = cellsOf(n, only);
  for (let k = 0; k < all.length; k++) {
    const [sc, op, nn, fn0, per = 1] = all[k];
    if (skip.includes(op) || (only && !only.includes(op))) continue;
    // a candidate that writes in place (native) gets fresh inputs for every cell
    const fn = RT.MUTABLE ? cellsOf(n, only)[k][3] : fn0;
    const base = { engine: 'node', impl: name, sc, op, n: nn };
    console.log(JSON.stringify({ start: op }));
    if (typeof gc === 'function') gc();
    let r;
    try { r = measure(fn, per); } catch (e) {
      if (e instanceof RangeError && /call stack/.test(e.message)) { console.log(JSON.stringify({ ...base, overflow: true })); continue; }
      throw e;
    }
    console.log(cellLine(base, r));
  }
}

// ---- stack safety (§17): every cell once at n, on whatever stack the process was given ----------------
export function stack(name, n, skip, cellsOf = cells, pick = null) {
  for (const [sc, op, , fn] of cellsOf(n, pick)) {
    if (pick && !pick.includes(op)) continue;
    if (skip.includes(op)) { console.log(JSON.stringify({ impl: name, sc, op, n, stack: 'not run' })); continue; }
    console.log(JSON.stringify({ start: op }));
    let r;
    try { keep(fn()); r = "ok"; } catch (e) { r = e instanceof RangeError && /call stack/.test(e.message) ? "stack overflow" : String(e); }
    console.log(JSON.stringify({ impl: name, sc, op, n, stack: r }));
  }
}

// ---- memory: one call in this process, at one size ------------------------------------------------
// peak = the process's resident high-water mark across the call, reset just before it through
// /proc/self/clear_refs (Linux), minus the resident size then; retained = heap still used after two
// full GCs while holding the result, minus before the call (the inputs are held throughout)
let held = null;
const fs = globalThis.process?.getBuiltinModule?.('node:fs');
const status = (k) => +new RegExp(k + ":\\s+(\\d+)").exec(fs.readFileSync("/proc/self/status", "utf8"))[1];
export function mem(name, op, n, cellsOf = cells) {
  held = cellsOf(n, [op]);
  const cell = held.find((c) => c[1] === op);
  gc(); gc();
  fs.writeFileSync("/proc/self/clear_refs", "5");
  const rss0 = status("VmRSS"), h0 = process.memoryUsage().heapUsed;
  let res, err = null;
  try { res = cell[3](); } catch (e) { err = e instanceof RangeError ? "overflow" : String(e); }
  const peakKB = status("VmHWM") - rss0;
  gc(); gc();
  const h1 = process.memoryUsage().heapUsed;
  keep(res);
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
const pathSet = (ps) => fnv(JSON.stringify(toJs(ps).map((p) => toJs(p).slice().sort((a, b) => a - b)).sort((p, q) => p.length - q.length)));
export function test() {
  const out = [];
  for (const n of [0, 1, 2, 3, 10, 257, 1000]) {
    for (const [sc, op, nn, fn0, k] of cells(n).map((c, k) => [...c, k])) {
      // a candidate that writes in place (native) gets fresh inputs for every cell, so a cell is
      // judged on its own writes and not on an earlier cell's
      const fn = RT.MUTABLE ? cells(n)[k][3] : fn0;
      // a TEA cell returns the render's row state: its rows' ids and `done`s
      // (both compared as sets, because the array-first versions of §17 keep a different order: a
      // path root first, the paths oldest first, a new TEA row last)
      const d = op.startsWith('paths') ? pathSet : op.startsWith('undo') ? (t) => `(${t.a}, ${fnv(JSON.stringify(topFirst(t.b)))})` : sc.startsWith('5') ? (rows) => fnv(JSON.stringify(byId(rows.map((r) => r.x)).map((x) => [x.id, x.done]))) : dig;
      const once = () => { try { return d(fn()); } catch (e) { return `threw ${String(e).slice(0, 60)}`; } };
      out.push(`${sc} | ${op} | ${nn} | ${once()} | ${once()}`);
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
