// Hot-path timing of every kept change that alters what runs (skill §1.4).
// Each pair is the original spelling and the kept one, as the compactor ships
// them, driven over the same inputs; alternating rounds, median of each.
//   node tools/timing.mjs [ROUNDS]
// In a browser: the same file is loaded by tools/timing.html (Chrome).

const ROUNDS = Number(globalThis.process?.argv?.[2] ?? 15);
const now = () => performance.now();

// ---- first/last/parentOf: `x!==null?x:f()` against `x??f()` ------------
// Instances as the compiler emits them (`{s,q,e}`), most with their ends in
// the template, some (1 in 8) with a slot at an end, as a row whose first
// node is a hole's is.
const slotOf = (node) => ({ p: null, m: node, cx: null, i: null, u: null, b: null, x: null, y: null, z: null, d: false });
const mk = (k) => {
  const node = { k };
  return k % 8 === 0 ? { s: null, q: slotOf(node), e: node } : { s: node, q: null, e: node };
};
const insts = Array.from({ length: 4096 }, (_, k) => mk(k));
const slots = Array.from({ length: 4096 }, (_, k) => (k % 4 === 0 ? { p: null, m: { parentNode: { k } } } : { p: { k }, m: null }));

const A = (s) => { if (s.u !== null && s.u.length !== 0) return n0(s.u[0]); return s.i !== null ? n0(s.i) : s.m; };
const n0 = (i) => (i.s !== null ? i.s : A(i.q));
const G0 = (s) => (s.p !== null ? s.p : s.m.parentNode);
const A1 = (s) => { if (s.u !== null && s.u.length !== 0) return n1(s.u[0]); return s.i !== null ? n1(s.i) : s.m; };
const n1 = (i) => i.s ?? A1(i.q);
const G1 = (s) => s.p ?? s.m.parentNode;

const pairs = {
  "first: !==null ?:": () => { let x = 0; for (let r = 0; r < 2000; r++) for (let k = 0; k < insts.length; k++) x ^= n0(insts[k]).k; return x; },
  "first: ??": () => { let x = 0; for (let r = 0; r < 2000; r++) for (let k = 0; k < insts.length; k++) x ^= n1(insts[k]).k; return x; },
  "parentOf: !==null ?:": () => { let x = 0; for (let r = 0; r < 2000; r++) for (let k = 0; k < slots.length; k++) x ^= G0(slots[k]).k; return x; },
  "parentOf: ??": () => { let x = 0; for (let r = 0; r < 2000; r++) for (let k = 0; k < slots.length; k++) x ^= G1(slots[k]).k; return x; },
};

// ---- childHtml's first mount: through `place` against `put` direct -------
// A fake parent that only counts, so the timing is the runtime's own work.
const parent = { c: 0, insertBefore(n, b) { this.c++; } };
const put = (p, i, before) => { const end = i.e; let n = i.s; for (;;) { const next = n.nextSibling; p.insertBefore(n, before); if (n === end) return; n = next; } };
const swap = () => { throw new Error("not reached"); };
const place = (s, i) => { if (s.i !== null) swap(s.i, i); else put(s.p !== null ? s.p : s.m.parentNode, i, s.m); s.i = i; };
const unit = (b, cx) => { const i = b.t.m(b.v, cx); i.t = b.t; i.b = b; return i; };
const kind = { m: (v, cx) => { const n = { nextSibling: null }; return { s: n, q: null, e: n }; }, p: () => {} };
const block = { t: kind, v: null };
const child0 = (s, b) => { if (s.i === null) place(s, unit(b, s.cx)); else s.i = null; };
const child1 = (s, b) => { if (s.i === null) { const i = unit(b, s.cx); put(s.p !== null ? s.p : s.m.parentNode, i, s.m); s.i = i; } else s.i = null; };
const fresh = () => Array.from({ length: 4096 }, () => slotOf(null));
for (const s of fresh()) s.p = parent;
pairs["childHtml first mount: place"] = () => { const ss = fresh(); for (const s of ss) s.p = parent; const t0 = now(); for (let r = 0; r < 100; r++) for (const s of ss) { s.i = null; child0(s, block); } return now() - t0; };
pairs["childHtml first mount: put"] = () => { const ss = fresh(); for (const s of ss) s.p = parent; const t0 = now(); for (let r = 0; r < 100; r++) for (const s of ss) { s.i = null; child1(s, block); } return now() - t0; };

// ---- a comment marker: a clone of the parsed `<!>` against createComment --
// Only in a page (Chrome): Node has no DOM.
if (globalThis.document) {
  const t = document.createElement("template");
  t.innerHTML = "<!>";
  const node = t.content.firstChild;
  const sink = document.createDocumentFragment();
  pairs["marker: template clone"] = () => { for (let k = 0; k < 50000; k++) sink.appendChild(node.cloneNode(true)); sink.textContent = ""; };
  pairs["marker: createComment"] = () => { for (let k = 0; k < 50000; k++) sink.appendChild(document.createComment("")); sink.textContent = ""; };
}

const names = Object.keys(pairs);
const times = Object.fromEntries(names.map((n) => [n, []]));
for (let r = 0; r < ROUNDS; r++) {
  for (const n of r % 2 ? [...names].reverse() : names) {
    const t0 = now();
    const v = pairs[n]();
    // The mount pairs time themselves (their setup is not the thing timed).
    times[n].push(n.startsWith("childHtml") ? v : now() - t0);
  }
}
const median = (a) => { const s = [...a].sort((x, y) => x - y); return s[s.length >> 1]; };
const out = names.map((n) => `${n.padEnd(34)} median ${median(times[n]).toFixed(2)} ms  (min ${Math.min(...times[n]).toFixed(2)})`).join("\n");
if (globalThis.document) globalThis.document.body.textContent = out;
console.log(out);
