// The driver of research/38 §15's scenarios. Everything that is beni is imported from the compiled
// output (`beni-out/*`, which `scenarios.mjs` maps to dist/beni or, for the proven-plain build,
// dist/beniP); `array-sibling` is the candidate's `Array.foreign.mjs`, the same module the compiled
// `_core/Array.mjs` imports. What is written here is only what is not beni: the decoder's hand-over
// of a fresh JS array (`fromJs`), the DOM runtime's keyed walk of `For` (`render`), the JavaScript
// APIs of scenario 6, and the timing loop.
import { fromJs, toJs, chunks } from 'array-sibling';
import * as Table from 'beni-out/Table.mjs';
import * as Decoded from 'beni-out/Decoded.mjs';
import * as Grid from 'beni-out/Grid.mjs';
import * as Life from 'beni-out/Life.mjs';
import * as Build from 'beni-out/Build.mjs';
import * as History from 'beni-out/History.mjs';
import * as Interop from 'beni-out/Interop.mjs';

// the timing loop is lib/measure.js, shared by every harness here
import { measure, keep, cellLine } from '../lib/measure.js';

// ---------------------------------------------------------------------------------------------
// Inputs, deterministic

const NIL = { $: 0, a: null, b: null };
const consOf = (arr) => { let l = NIL; for (let i = arr.length - 1; i >= 0; i--) l = { $: 1, a: arr[i], b: l }; return l; };
function jsonText(n) {
  const xs = [];
  let seed = 4242;
  for (let i = 0; i < n; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    xs.push({ id: i, name: `item ${i}`, price: ((seed >>> 4) % 100000) / 100, category: (seed >>> 16) % 20 });
  }
  return JSON.stringify(xs);
}
// What a compiled decoder does with a validated JSON array: one record per element, pushed into a
// fresh JS array it owns and hands over (research/34, schema.md: validation over raw host values).
function decode(text) {
  const raw = JSON.parse(text), out = [];
  for (let i = 0; i < raw.length; i++) { const r = raw[i]; out.push({ id: r.id, name: r.name, price: r.price, category: r.category }); }
  return fromJs(out);
}
// The DOM runtime's `For` over the rows, once per render, in the shape of platforms/browser's
// `forPosition`: the runtime keeps one record per row, walks the new sequence, patches a row whose
// item is not the one it showed last time (`i.x !== item`), and drops rows past the end; every
// row's `selected` hole is checked too. The walk goes through `chunks`, so no candidate copies the
// array to render it. (A keyed `For` adds one Map lookup per row, the same for every candidate.)
function render(model, rowsState) {
  const sel = model.selected, cs = chunks(model.rows);
  let k = 0, dirty = 0;
  for (let c = 0; c < cs.length; c++) {
    const ch = cs[c];
    for (let j = 0; j < ch.length; j++, k++) {
      const item = ch[j];
      const r = rowsState[k];
      if (r === undefined) { rowsState[k] = { x: item }; dirty++; } else if (r.x !== item) { r.x = item; dirty++; }
      if (item.id === sel) dirty++;
    }
  }
  if (rowsState.length > k) rowsState.length = k;
  keep(dirty);
  return rowsState;
}
const mounted = (model) => render(model, []);

// ---------------------------------------------------------------------------------------------
// Scenarios: each is a list of [label, n, fn] cells; `setup` state is built before timing.

function tableCells(N) {
  const m0 = Table.Table$create(N), snap0 = mounted(m0);
  const U = Table.Table$update;
  const cells = [];
  const first = (label, msg) => cells.push([`table/${label}/first`, N, () => render(U(msg, m0), snap0)]);
  const steady = (label, next) => { let s = m0, snap = mounted(m0), k = 0;
    cells.push([`table/${label}/steady`, N, () => { s = next(s, k++); snap = render(s, snap); return s; }]); };
  first('update one', Table.Table$updateLabel(N >> 1));
  steady('update one', (s, k) => U(Table.Table$updateLabel((k * 7919) % N), s));
  first('update every 10th', Table.Table$updateEvery10th);
  steady('update every 10th', (s) => U(Table.Table$updateEvery10th, s));
  first('swap', Table.Table$swap(1, N - 2));
  steady('swap', (s) => U(Table.Table$swap(1, N - 2), s));
  first('remove one', Table.Table$remove(N >> 1));
  steady('remove one + add one', (s, k) => U(Table.Table$addOne, U(Table.Table$remove(k + 1), s)));
  first('append 1000', Table.Table$append(1000));
  steady('select', (s, k) => U(Table.Table$select((k * 7919) % N), s));
  return cells;
}

function decodedCells(N) {
  const text = jsonText(N), items = decode(text);
  return [
    [`decoded/decode`, N, () => decode(text)],
    [`decoded/count (foldl)`, N, () => Decoded.Decoded$countIn(items, 3)],
    [`decoded/total (foldl)`, N, () => Decoded.Decoded$total(items)],
    [`decoded/filter`, N, () => Decoded.Decoded$inCategory(items, 3)],
    [`decoded/sort + slice 20`, N, () => Decoded.Decoded$cheapest(items, 20)],
    [`decoded/1000 binary searches`, N, () => Decoded.Decoded$lookups(items, 1000)],
    [`decoded/page of 50 by get`, N, () => Decoded.Decoded$page(items, N >> 1, 50)],
  ];
}

function gridCells(W) {
  const g0 = Grid.Grid$make(W, W);
  const cells = [[`grid/make`, W * W, () => Grid.Grid$make(W, W)]];
  for (const k of [1, 100]) {
    cells.push([`grid/tick k=${k}/first`, W * W, () => Grid.Grid$tick(g0, k, 17)]);
    let g = g0, seed = 0;
    cells.push([`grid/tick k=${k}/steady`, W * W, () => (g = Grid.Grid$tick(g, k, seed++))]);
  }
  let g = g0;
  cells.push([`grid/life step`, W * W, () => (g = Life.Life$step(g))]);
  return cells;
}

function buildCells(n) {
  const samples = consOf(Array.from({ length: 100000 }, (_, i) => (i * 2654435761) >>> 8));
  return [
    [`build/collect by push`, n, () => Build.Build$collect(n)],
    [`build/histogram of 100 000`, n, () => Build.Build$histogram(samples, n)],
    [`build/coin-change table`, n, () => Build.Build$coins(n)],
  ];
}

function historyCells(N) {
  const h0 = History.History$start(N);
  let h = History.History$edits(h0, 150, 1), seed = 0;
  return [
    [`history/edit/first`, N, () => History.History$edits(h0, 1, 7)],
    [`history/edit/steady`, N, () => (h = History.History$edits(h, 1, seed++))],
    [`history/undo 100`, N, () => { let x = h; for (let i = 0; i < 100; i++) x = History.History$undo(x); return History.History$sum(x); }],
  ];
}

function interopCells(N) {
  const items = decode(jsonText(N));
  const lines = Interop.Interop$lines(items), edited = Interop.Interop$rename(lines, N >> 1);
  const prices = Interop.Interop$prices(items), eprices = Interop.Interop$reprice(prices, N >> 1);
  // a platform function building one DOM node per element walks the array as the runtime does
  const html = (a) => { const cs = chunks(a), out = []; for (const ch of cs) for (let i = 0; i < ch.length; i++) out.push(`<li data-id="${ch[i].id}">${ch[i].text}</li>`); return out.join(""); };
  const cells = [];
  for (const [st, ls, ps] of [['mapped', lines, prices], ['edited', edited, eprices]]) {
    cells.push([`interop/toJs/${st}`, N, () => toJs(ls)]);
    cells.push([`interop/JSON.stringify/${st}`, N, () => JSON.stringify(toJs(ls))]);
    cells.push([`interop/Math.max/${st}`, N, () => Math.max.apply(null, toJs(ps))]);
    cells.push([`interop/html list/${st}`, N, () => html(ls)]);
  }
  return cells;
}

function retained(build) {
  gc(); gc();
  const base = process.memoryUsage().heapUsed;
  let held = build();
  gc(); gc();
  const used = process.memoryUsage().heapUsed - base;
  keep(held); held = null;
  return used;
}

// `n` (a cell's size label) builds only that size's inputs: all.mjs runs one cell per process
const at = (n, k, f) => (n === undefined || n === k ? f() : []);
export const SCENARIOS = {
  table: (n) => [...at(n, 1000, () => tableCells(1000)), ...at(n, 10000, () => tableCells(10000))],
  decoded: (n) => [...at(n, 10000, () => decodedCells(10000)), ...at(n, 100000, () => decodedCells(100000))],
  grid: (n) => [...at(n, 10000, () => gridCells(100)), ...at(n, 1000000, () => gridCells(1000))],
  build: (n) => [...at(n, 1000, () => buildCells(1000)), ...at(n, 100000, () => buildCells(100000))],
  history: (n) => at(n, 10000, () => historyCells(10000)),
  interop: (n) => [...at(n, 10000, () => interopCells(10000)), ...at(n, 100000, () => interopCells(100000))],
};

// `skip` names cells (`op@n`) not to run: all.mjs passes the ones that crashed or ran over its cap in
// an earlier attempt, and a `start` line before each cell names the one a dead process was running
export function run(name, only, skip = [], pick = null) {
  // a cell over 1 s a call at the smaller size is not run at the larger one (it would be over 10 s)
  const slow = new Set();
  for (const sc of only) {
    for (const [op, n, fn] of SCENARIOS[sc](pick && pick.length === 1 ? +pick[0].split('@')[1] : undefined)) {
      if (pick && !pick.includes(`${op}@${n}`)) continue;
      if (skip.includes(`${op}@${n}`)) continue;
      if (slow.has(op)) { console.log(JSON.stringify({ engine: 'node', impl: name, sc, op, n, skipped: 'over 1 s a call, or failed, at the size before' })); continue; }
      slow.add(op); // until it finishes in time
      console.log(JSON.stringify({ start: `${op}@${n}` }));
      if (typeof gc === 'function') gc();
      let r;
      try { r = measure(fn); } catch (e) {
        if (e instanceof RangeError && /call stack/.test(e.message)) { console.log(JSON.stringify({ engine: "node", impl: name, sc, op, n, overflow: true })); continue; }
        throw e;
      }
      if (r.med <= 1e9) slow.delete(op);
      console.log(cellLine({ engine: 'node', impl: name, sc, op, n }, r));
    }
  }
  if (only.includes('history') && typeof gc === 'function' && globalThis.process?.memoryUsage) {
    // retained bytes: the history after 150 one-cell edits (100 past versions + the current one), and
    // one version for scale; elements are small integers, so this is the containers alone
    const N = 10000;
    const one = retained(() => History.History$start(N));
    const hist = retained(() => History.History$edits(History.History$start(N), 150, 1));
    console.log(JSON.stringify({ engine: 'node', impl: name, sc: 'history', op: 'retained/one version', n: N, bytes: one }));
    console.log(JSON.stringify({ engine: 'node', impl: name, sc: 'history', op: 'retained/101 versions', n: N, bytes: hist }));
  }
}

// ---------------------------------------------------------------------------------------------
// The differential test: every scenario once, on the same inputs, reduced to one string per step.

const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(16); };
const dig = (a) => fnv(JSON.stringify(toJs(a)));
const listDig = (l) => { const xs = []; for (; l.$ === 1; l = l.b) xs.push(l.a); return fnv(JSON.stringify(xs)); };
export function test() {
  const out = [];
  const log = (k, v) => out.push(`${k} ${v}`);
  for (const N of [1000, 1025, 10000]) {
    const m0 = Table.Table$create(N), d0 = dig(m0.rows);
    const U = Table.Table$update;
    let s = m0;
    const msgs = [Table.Table$updateLabel(N >> 1), Table.Table$updateEvery10th, Table.Table$swap(1, N - 2), Table.Table$remove(N >> 1),
      Table.Table$append(1000), Table.Table$addOne, Table.Table$select(5), Table.Table$swap(0, 0), Table.Table$updateLabel(N + 5000)];
    for (const [j, msg] of msgs.entries()) { log(`table ${N} first ${j}`, dig(U(msg, m0).rows)); }
    for (let k = 0; k < 60; k++) { s = U(msgs[k % msgs.length], s); s = U(Table.Table$remove(k + 1), s); log(`table ${N} steady ${k}`, `${dig(s.rows)} ${s.selected} ${s.nextId}`); }
    // no-op identity (report 38 §7): swapping a row with itself and an out-of-range update
    log(`table ${N} identity`, `${U(Table.Table$swap(3, 3), m0).rows === m0.rows} ${U(Table.Table$updateLabel(N + 1), m0).rows === m0.rows}`);
    if (dig(m0.rows) !== d0) log(`table ${N} INPUT CHANGED`, '');
  }
  for (const N of [1000, 10000]) {
    const items = decode(jsonText(N));
    log(`decoded ${N}`, [Decoded.Decoded$countIn(items, 3), Decoded.Decoded$total(items).toFixed(2), dig(Decoded.Decoded$inCategory(items, 3)),
      dig(Decoded.Decoded$cheapest(items, 20)), Decoded.Decoded$lookups(items, 1000).toFixed(2), listDig(Decoded.Decoded$page(items, N >> 1, 50)),
      Decoded.Decoded$inCategory(items, 99) === items, Decoded.Decoded$page(items, N - 10, 50).$].join(' '));
  }
  for (const W of [30, 100]) {
    const g0 = Grid.Grid$make(W, W), d0 = dig(g0.cells);
    let g = g0;
    for (let t = 0; t < 30; t++) { g = Grid.Grid$tick(g, t % 2 ? 100 : 1, t); log(`grid ${W} tick ${t}`, `${Grid.Grid$population(g)} ${dig(g.cells)}`); }
    // life runs from the fresh board: after the ticks above the cells may be a trie, and the
    // proven-plain build's claim (every generation comes from `initialize`) would be false
    g = g0;
    for (let t = 0; t < 4; t++) { g = Life.Life$step(g); log(`grid ${W} life ${t}`, dig(g.cells)); }
    if (dig(g0.cells) !== d0) log(`grid ${W} INPUT CHANGED`, '');
  }
  for (const n of [1000, 5000]) {
    const samples = consOf(Array.from({ length: 20000 }, (_, i) => (i * 2654435761) >>> 8));
    log(`build ${n}`, [dig(Build.Build$collect(n)), dig(Build.Build$histogram(samples, n)), dig(Build.Build$coins(n)), Build.Build$total(Build.Build$coins(n))].join(' '));
  }
  {
    const h0 = History.History$start(10000);
    let h = History.History$edits(h0, 150, 1);
    log('history edits', `${History.History$sum(h)} ${dig(h.current)} ${History.History$sum(h0)}`);
    for (let i = 0; i < 101; i++) { h = History.History$undo(h); if (i % 10 === 0 || i > 97) log(`history undo ${i}`, History.History$sum(h)); }
  }
  for (const N of [1000, 10000]) {
    const items = decode(jsonText(N));
    const lines = Interop.Interop$lines(items), edited = Interop.Interop$rename(lines, N >> 1);
    const prices = Interop.Interop$prices(items), ep = Interop.Interop$reprice(prices, N >> 1);
    log(`interop ${N}`, [fnv(JSON.stringify(toJs(lines))), fnv(JSON.stringify(toJs(edited))), Math.max.apply(null, toJs(prices)), Math.min.apply(null, toJs(ep)), dig(lines), fnv(JSON.stringify(chunks(edited).flat())), fnv(JSON.stringify(chunks(lines).flat()))].join(' '));
  }
  return out.join('\n');
}
