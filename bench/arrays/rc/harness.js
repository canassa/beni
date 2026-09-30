// The driver of research/42's scenarios: research/38 §15's six, the same compiled beni, and the
// same timing loop (scenarios/harness.js), with the ownership protocol made explicit. Everything
// that is beni comes from `beni-out/*` (the variant's tree, rc/rc.mjs); `array-sibling` is the
// variant's `Array.foreign.mjs`; `rc-variant` holds the variant's side of the JavaScript
// boundary:
//
//   keep(v)       the harness keeps v and will use it again: R1/R2 pin it (§3, rule O7), R0 and
//                 the baselines do nothing
//   give*(v)      the harness passes a value it keeps to a function whose interface consumes it
//                 uniquely: R0 copies the consumed part (S3); everyone else passes it as it is
//                 (pinned, so R1/R2 copy on write by themselves)
//   retain(rows)  the DOM runtime keeps the rows it rendered (`s.b` in forPosition) until the
//                 next render: R1/R2 pin them; R0 must copy them before the next update
//
// Two protocols for the TEA table (§6.1): `retains`, the runtime as it is written today, and
// `hands over`, a runtime that gives the model to `update` and keeps nothing that can see a
// write (no `s.b` identity skip on a counted array). The baselines are the same under both.
import { fromJs, toJs, chunks } from 'array-sibling';
import * as V from 'rc-variant';
import * as Table from 'beni-out/Table.mjs';
import * as Decoded from 'beni-out/Decoded.mjs';
import * as Grid from 'beni-out/Grid.mjs';
import * as Life from 'beni-out/Life.mjs';
import * as Build from 'beni-out/Build.mjs';
import * as History from 'beni-out/History.mjs';
import * as Interop from 'beni-out/Interop.mjs';

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
function decode(text) {
  const raw = JSON.parse(text), out = [];
  for (let i = 0; i < raw.length; i++) { const r = raw[i]; out.push({ id: r.id, name: r.name, price: r.price, category: r.category }); }
  return fromJs(out);
}
// scenarios/harness.js's render: the runtime's positional `For`, walking the rows through `chunks`
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
  sink = dirty;
  return rowsState;
}
const mounted = (model) => render(model, []);

function tableCells(N) {
  const m0 = V.keep(Table.Table$create(N)), snap0 = mounted(m0);
  const U = Table.Table$update;
  const cells = [];
  const first = (label, msg) => cells.push([`table/${label}/first`, N, () => render(U(msg, V.giveModel(m0)), snap0)]);
  // `retains`: the runtime keeps the rendered rows until the next render
  const steadyR = (label, next) => { let s = V.giveModel(m0), snap = mounted(s); V.retain(s.rows); let k = 0;
    cells.push([`table/${label}/steady, runtime retains`, N, () => { s = next(s, k++, V.giveRetained); snap = render(s, snap); V.retain(s.rows); return s; }]); };
  // `hands over`: nothing but `update` holds the model between messages
  const steadyH = (label, next) => { let s = V.giveModel(m0), snap = mounted(s), k = 0;
    cells.push([`table/${label}/steady, hands over`, N, () => { s = next(s, k++, (m) => m); snap = render(s, snap); return s; }]); };
  const steady = (label, next) => { steadyR(label, next); steadyH(label, next); };
  first('update one', Table.Table$updateLabel(N >> 1));
  steady('update one', (s, k, g) => U(Table.Table$updateLabel((k * 7919) % N), g(s)));
  steady('update every 10th', (s, k, g) => U(Table.Table$updateEvery10th, g(s)));
  first('swap', Table.Table$swap(1, N - 2));
  steady('swap', (s, k, g) => U(Table.Table$swap(1, N - 2), g(s)));
  first('remove one', Table.Table$remove(N >> 1));
  steady('remove one + add one', (s, k, g) => U(Table.Table$addOne, U(Table.Table$remove(k + 1), g(s))));
  first('append 1000', Table.Table$append(1000));
  steady('select', (s, k, g) => U(Table.Table$select((k * 7919) % N), g(s)));
  return cells;
}

function decodedCells(N) {
  const text = jsonText(N), items = V.keep(decode(text));
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
  const g0 = V.keep(Grid.Grid$make(W, W));
  const cells = [[`grid/make`, W * W, () => Grid.Grid$make(W, W)]];
  for (const k of [1, 100]) {
    cells.push([`grid/tick k=${k}/first`, W * W, () => Grid.Grid$tick(V.giveGrid(g0), k, 17)]);
    let g = V.giveGrid(g0), seed = 0;
    cells.push([`grid/tick k=${k}/steady`, W * W, () => (g = Grid.Grid$tick(g, k, seed++))]);
  }
  let g = Grid.Grid$make(W, W);
  cells.push([`grid/life step`, W * W, () => (g = Life.Life$step(g))]);
  return cells;
}

function buildCells(n) {
  const samples = consOf(Array.from({ length: 100000 }, (_, i) => (i * 2654435761) >>> 8));
  const cells = [
    [`build/collect by push`, n, () => Build.Build$collect(n)],
    [`build/histogram of 100 000`, n, () => Build.Build$histogram(samples, n)],
    [`build/coin-change table`, n, () => Build.Build$coins(n)],
  ];
  if (Build.Build$histogramNoInline && n <= 1000) cells.push([`build/histogram, no inlining`, n, () => Build.Build$histogramNoInline(samples, n)]);
  return cells;
}

function historyCells(N) {
  const h0 = V.keep(History.History$start(N));
  let h = History.History$edits(History.History$start(N), 150, 1), seed = 0;
  const hk = V.keep(History.History$edits(History.History$start(N), 150, 1));
  return [
    [`history/edit/first`, N, () => History.History$edits(h0, 1, 7)],
    [`history/edit/steady`, N, () => (h = History.History$edits(h, 1, seed++))],
    [`history/undo 100`, N, () => { let x = hk; for (let i = 0; i < 100; i++) x = History.History$undo(x); return History.History$sum(x); }],
  ];
}

function interopCells(N) {
  const items = V.keep(decode(jsonText(N)));
  const lines = V.keep(Interop.Interop$lines(items)), edited = V.keep(Interop.Interop$rename(V.giveArray(lines), N >> 1));
  const prices = V.keep(Interop.Interop$prices(items)), eprices = V.keep(Interop.Interop$reprice(V.giveArray(prices), N >> 1));
  const html = (a) => { const cs = chunks(a), out = []; for (const ch of cs) for (let i = 0; i < ch.length; i++) out.push(`<li data-id="${ch[i].id}">${ch[i].text}</li>`); return out.join(""); };
  const cells = [];
  for (const [st, ls, ps] of [['mapped', lines, prices], ['edited', edited, eprices]]) {
    cells.push([`interop/toJs/${st}`, N, () => toJs(ls)]);
    cells.push([`interop/JSON.stringify/${st}`, N, () => JSON.stringify(toJs(ls))]);
    cells.push([`interop/Math.max/${st}`, N, () => Math.max.apply(null, toJs(ps))]);
    cells.push([`interop/html list/${st}`, N, () => html(ls)]);
  }
  // one write to an array JavaScript was handed: R1/R2 must copy it, R0 copies before the call
  cells.push([`interop/reprice after toJs`, N, () => { toJs(prices); return Interop.Interop$reprice(V.giveArray(prices), 3); }]);
  return cells;
}

function retained(build) {
  gc(); gc();
  const base = process.memoryUsage().heapUsed;
  let keep = build();
  gc(); gc();
  const used = process.memoryUsage().heapUsed - base;
  sink = keep; keep = null;
  return used;
}

export const SCENARIOS = {
  table: () => [...tableCells(1000), ...tableCells(10000)],
  decoded: () => [...decodedCells(10000), ...decodedCells(100000)],
  grid: () => [...gridCells(100), ...gridCells(1000)],
  build: () => [...buildCells(1000), ...buildCells(100000)],
  history: () => historyCells(10000),
  interop: () => [...interopCells(10000), ...interopCells(100000)],
};

export function run(name, only) {
  const p = (x) => +x.toPrecision(4);
  for (const sc of only.filter((s) => SCENARIOS[s])) {
    for (const [op, n, fn] of SCENARIOS[sc]()) {
      if (process.env.ONLY && !op.includes(process.env.ONLY)) continue;
      // cow's 100 000-element builds cost 21–39 s a call (research/38 §15.7): not rerun here
      if (name === 'cow' && sc === 'build' && n === 100000) continue;
      if (typeof gc === 'function') gc();
      const r = measure(fn);
      console.log(JSON.stringify({ engine: 'node', impl: name, sc, op, n, med: p(r.med), q1: p(r.q1), q3: p(r.q3), lo: p(r.lo), hi: p(r.hi), S: r.S }));
    }
  }
  if (only.includes('memory') && typeof gc === 'function') {
    const out = (op, n, bytes) => console.log(JSON.stringify({ engine: 'node', impl: name, sc: 'memory', op, n, bytes }));
    const N = 10000;
    out('retained/history, one version', N, retained(() => History.History$start(N)));
    out('retained/history, 101 versions', N, retained(() => History.History$edits(History.History$start(N), 150, 1)));
    out('retained/table model', N, retained(() => Table.Table$create(N)));
    // a model after 200 messages handed over, and after 200 with the runtime retaining
    const drive = (retains) => { let s = V.giveModel(Table.Table$create(N)); for (let k = 0; k < 200; k++) { s = Table.Table$update(Table.Table$updateLabel((k * 7919) % N), retains ? V.giveRetained(s) : s); if (retains) V.retain(s.rows); } return s; };
    out('retained/table model after 200 updates, hands over', N, retained(() => drive(false)));
    out('retained/table model after 200 updates, runtime retains', N, retained(() => drive(true)));
    out('retained/grid 1000x1000 after 100 ticks', 1e6, retained(() => { let g = V.giveGrid(Grid.Grid$make(1000, 1000)); for (let t = 0; t < 100; t++) g = Grid.Grid$tick(g, 100, t); return g; }));
  }
}

// ---------------------------------------------------------------------------------------------
// The differential test: scenarios/harness.js's checks, with the protocol above, plus the escape
// checks of §5.1. `mech` lines report whether a write actually landed in place: they differ by
// design between variants and are printed apart, not compared.

const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(16); };
const flat = (a) => chunks(a).flat();
const dig = (a) => fnv(JSON.stringify(flat(a)));
const listDig = (l) => { const xs = []; for (; l.$ === 1; l = l.b) xs.push(l.a); return fnv(JSON.stringify(xs)); };
export function test() {
  const out = [], mech = [];
  const log = (k, v) => out.push(`${k} ${v}`);
  for (const N of [1000, 1025, 10000]) {
    const m0 = V.keep(Table.Table$create(N)), d0 = dig(m0.rows);
    const U = Table.Table$update;
    const msgs = [Table.Table$updateLabel(N >> 1), Table.Table$updateEvery10th, Table.Table$swap(1, N - 2), Table.Table$remove(N >> 1),
      Table.Table$append(1000), Table.Table$addOne, Table.Table$select(5), Table.Table$swap(0, 0), Table.Table$updateLabel(N + 5000)];
    for (const [j, msg] of msgs.entries()) { log(`table ${N} first ${j}`, dig(U(msg, V.giveModel(m0)).rows)); }
    for (const retains of [false, true]) {
      let s = V.giveModel(m0), snap = mounted(s);
      if (retains) V.retain(s.rows);
      for (let k = 0; k < 60; k++) {
        const held = retains ? s.rows : null, hd = retains ? dig(held) : null;
        s = U(msgs[k % msgs.length], retains ? V.giveRetained(s) : s);
        s = U(Table.Table$remove(k + 1), s);
        snap = render(s, snap);
        if (retains) { if (dig(held) !== hd) log(`table ${N} RETAINED ROWS CHANGED at ${k}`, ''); V.retain(s.rows); }
        log(`table ${N} steady ${k}`, `${dig(s.rows)} ${s.selected} ${s.nextId} ${fnv(JSON.stringify(snap.map((r) => r.x.id)))}`);
      }
    }
    log(`table ${N} identity`, `${U(Table.Table$swap(3, 3), V.giveModel(m0)).rows === m0.rows || V.NAME === 'R0'} ${U(Table.Table$updateLabel(N + 1), V.giveModel(m0)).rows === m0.rows || V.NAME === 'R0'}`);
    if (dig(m0.rows) !== d0) log(`table ${N} INPUT CHANGED`, '');
    // mechanism: does a handed-over model's UpdateLabel keep the same rows object?
    { const a = V.giveModel(Table.Table$create(N)); const b = U(Table.Table$updateLabel(3), a); const c = U(Table.Table$updateLabel(4), b); mech.push(`table ${N} handed-over update in place: ${c.rows === b.rows}`); }
  }
  for (const N of [1000, 10000]) {
    const items = V.keep(decode(jsonText(N))), d0 = dig(items);
    log(`decoded ${N}`, [Decoded.Decoded$countIn(items, 3), Decoded.Decoded$total(items).toFixed(2), dig(Decoded.Decoded$inCategory(items, 3)),
      dig(Decoded.Decoded$cheapest(items, 20)), Decoded.Decoded$lookups(items, 1000).toFixed(2), listDig(Decoded.Decoded$page(items, N >> 1, 50)),
      Decoded.Decoded$inCategory(items, 99) === items, Decoded.Decoded$page(items, N - 10, 50).$].join(' '));
    if (dig(items) !== d0) log(`decoded ${N} INPUT CHANGED`, '');
  }
  for (const W of [30, 100]) {
    const g0 = V.keep(Grid.Grid$make(W, W)), d0 = dig(g0.cells);
    let g = V.giveGrid(g0);
    for (let t = 0; t < 30; t++) { g = Grid.Grid$tick(g, t % 2 ? 100 : 1, t); log(`grid ${W} tick ${t}`, `${Grid.Grid$population(g)} ${dig(g.cells)}`); }
    // a board handed over, then kept and ticked twice: both results must agree
    const gk = V.keep(g), a = Grid.Grid$tick(V.giveGrid(gk), 5, 99), b = Grid.Grid$tick(V.giveGrid(gk), 5, 99);
    log(`grid ${W} kept twice`, `${dig(a.cells) === dig(b.cells)} ${dig(a.cells)}`);
    g = Grid.Grid$make(W, W);
    for (let t = 0; t < 4; t++) { g = Life.Life$step(g); log(`grid ${W} life ${t}`, dig(g.cells)); }
    if (dig(g0.cells) !== d0) log(`grid ${W} INPUT CHANGED`, '');
    { let h = V.giveGrid(Grid.Grid$make(W, W)); h = Grid.Grid$tick(h, 1, 1); const c1 = h.cells; h = Grid.Grid$tick(h, 1, 2); mech.push(`grid ${W} steady tick in place: ${h.cells === c1}`); }
  }
  for (const n of [1000, 5000]) {
    const samples = consOf(Array.from({ length: 20000 }, (_, i) => (i * 2654435761) >>> 8));
    const row = [dig(Build.Build$collect(n)), dig(Build.Build$histogram(samples, n)), dig(Build.Build$coins(n)), Build.Build$total(Build.Build$coins(n))];
    log(`build ${n}`, row.join(' '));
    if (Build.Build$histogramNoInline) mech.push(`build ${n} histogram without inlining agrees: ${dig(Build.Build$histogramNoInline(samples, n)) === row[1]}`);
  }
  {
    const h0 = V.keep(History.History$start(10000));
    let h = History.History$edits(h0, 150, 1);
    log('history edits', `${History.History$sum(h)} ${dig(h.current)} ${History.History$sum(h0)}`);
    h = V.keep(h);
    const k = History.History$edits(h, 3, 5);
    log('history kept', `${History.History$sum(h)} ${History.History$sum(k)}`);
    for (let i = 0; i < 101; i++) { h = History.History$undo(h); if (i % 10 === 0 || i > 97) log(`history undo ${i}`, History.History$sum(h)); }
    // undo then edit: the version that came out of the list is still in older histories
    let u = History.History$edits(History.History$start(1000), 5, 1); const u1 = V.keep(History.History$undo(u)); const s1 = History.History$sum(u1);
    const e = History.History$edits(u1, 3, 9); log('history undo then edit', `${History.History$sum(u1) === s1} ${History.History$sum(e)}`);
  }
  for (const N of [1000, 10000]) {
    const items = V.keep(decode(jsonText(N)));
    const lines = V.keep(Interop.Interop$lines(items)), edited = Interop.Interop$rename(V.giveArray(lines), N >> 1);
    const prices = V.keep(Interop.Interop$prices(items)), ep = Interop.Interop$reprice(V.giveArray(prices), N >> 1);
    log(`interop ${N}`, [fnv(JSON.stringify(toJs(lines))), fnv(JSON.stringify(toJs(edited))), Math.max.apply(null, toJs(prices)), Math.min.apply(null, toJs(ep)), dig(lines), dig(edited)].join(' '));
    // §5.1: an array handed to JavaScript and then written in beni — JavaScript's copy must not move
    const fresh = Interop.Interop$prices(items);
    const js = toJs(fresh), before = JSON.stringify(js);
    const after = Interop.Interop$reprice(V.giveArray(fresh), 7);
    log(`escape ${N}`, `${JSON.stringify(js) === before} ${toJs(after)[7]}`);
    // and the same array NOT handed over first: the write may land in place (mechanism only)
    const f2 = Interop.Interop$prices(items), r2 = Interop.Interop$reprice(f2, 7);
    mech.push(`interop ${N} fresh reprice in place: ${r2 === f2}`);
  }
  return { out: out.join('\n'), mech: mech.join('\n') };
}
