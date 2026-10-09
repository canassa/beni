// How a row's events find their row (docs/design/browser-direct.md §4.2,
// §6.1, slice S2): five forms of the same rows page, measured against each
// other in one batch, untraced, from real clicks.
//
//   node rowstate.mjs [--pages=10] [--sizes=1000,10000,30000]
//                     [--forms=a,b] [--out=results/<date>-rowstate.json]
//                     [--taskset=8-15] [--chrome=<path>]
//
// Every form is the code `browser-direct` emits for a keyed `For` of
// js-framework-benchmark's rows — a row template cloned per row, its nodes
// walked to, an instance `{ e, it, a, t }` per row in an array, and a click
// on a row's label selecting the row by its item — written by hand so that
// only one thing differs between them:
//
//   - `expando`: the shipping form. One listener on the `<tbody>`; the row's
//     element holds its instance as `$r` and the label its body as `$click`,
//     and the walk goes from the target up to a row of its list.
//   - `perrow`: no walk and no expando: each row's label gets a listener of
//     its own at `make`, a closure over its instance.
//   - `index`: one listener, no expando: the walk goes up to the `<tbody>`'s
//     child, finds its instance by its index among the `<tbody>`'s children,
//     and the handler node by the instance's own node handles.
//   - `keymap`: one listener, no expando: the row's key is read from the
//     page (its first cell's text) and its instance found in a `Map` that
//     `make` fills.
//   - `weakmap`: one listener: a `WeakMap` from a row's element to its
//     instance and one from a handler node to its body.
//
// Two measures per page: the mount — a real click on `#go` makes every row
// — and a row's event — a real click on row 7's label once mounted. Each is
// timed in the page from a capture-phase click listener on `window` to a
// microtask a bubble-phase one queues, as `mount.mjs` times one. Bytes: each
// form's script minified by terser, then brotli 11.
//
// Run it from `nix develop .#browser`. About three minutes at the defaults.

import { execSync, spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import { brotliCompressSync, constants } from "node:zlib";
import { launch } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { median, quantile } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const pages = Number(arg("pages", "10"));
const sizes = arg("sizes", "1000,10000,30000").split(",").map(Number);
const date = new Date().toISOString().slice(0, 10);
const out = join(root, arg("out", `results/${date}-rowstate.json`));

// ---- The forms ------------------------------------------------------------

const timer = `
window.__clickTimes = [];
let depth = 0, t0 = 0;
addEventListener("click", () => { if (depth++ === 0) t0 = performance.now(); }, true);
addEventListener("click", () => { if (--depth === 0) queueMicrotask(() => window.__clickTimes.push(performance.now() - t0)); });
`;

// What every form shares: the page, the row template, the items, the
// guard, `make`'s walk and the handler the label's click sends to.
const shared = (n) => `
document.body.innerHTML = '<button id="go">go</button><p id="sel"></p><table><tbody id="tbody"></tbody></table>';
const tbody = document.getElementById("tbody");
const sel = document.getElementById("sel");
const tpl = document.createElement("template");
tpl.innerHTML = '<tr><td class="col-md-1"> </td><td class="col-md-4"><a class="lbl"> </a></td><td class="col-md-1"></td><td class="col-md-6"></td></tr>';
const T = tpl.content.firstChild;
const items = Array.from({ length: ${n} }, (_, i) => ({ id: i + 1, label: "row " + (i + 1) }));
let dead = false, running = false;
const send = (f, x) => { if (dead || running) return; running = true; let ok = false; try { f(x); ok = true; } finally { running = false; if (!ok) dead = true; } };
let selected = 0;
const hSelect = (id) => { selected = id; sel.textContent = String(id); };
const L = { p: tbody, n: null, r: [] };
const walk = (e, it) => {
  const c1 = e.firstChild, t = c1.firstChild, a = c1.nextSibling.firstChild, lt = a.firstChild;
  t.data = String(it.id);
  lt.data = it.label;
  return { e, it, l: L, a, t: lt };
};
`;

const forms = {
  expando: `
const body = (ev, r) => { hSelect(r.it.id); };
const make = (it) => { const e = T.cloneNode(true); const r = walk(e, it); e.$r = r; r.a.$click = body; return r; };
const buffer = [];
tbody.addEventListener("click", (event) => {
  buffer.length = 0;
  for (let node = event.target; node !== null && node !== event.currentTarget; node = node.parentNode) {
    const r = node.$r;
    if (r !== undefined && r.l !== L) { buffer.length = 0; continue; }
    const h = node.$click;
    if (h !== undefined) buffer.push(h);
    if (r !== undefined) { for (const b of buffer) send((e) => b(e, r), event); return; }
  }
});
`,
  perrow: `
const body = (ev, r) => { hSelect(r.it.id); };
const make = (it) => { const e = T.cloneNode(true); const r = walk(e, it); r.a.addEventListener("click", (event) => send((x) => body(x, r), event)); return r; };
`,
  index: `
const body = (ev, r) => { hSelect(r.it.id); };
const make = (it) => { const e = T.cloneNode(true); return walk(e, it); };
const buffer = [];
tbody.addEventListener("click", (event) => {
  const top = event.currentTarget;
  let row = event.target;
  while (row !== null && row.parentNode !== top) row = row.parentNode;
  if (row === null) return;
  const r = L.r[Array.prototype.indexOf.call(top.children, row)];
  for (let node = event.target; node !== row.parentNode; node = node.parentNode) {
    if (node === r.a) send((e) => body(e, r), event);
  }
});
`,
  keymap: `
const body = (ev, r) => { hSelect(r.it.id); };
const keys = new Map();
const make = (it) => { const e = T.cloneNode(true); const r = walk(e, it); keys.set(it.id, r); return r; };
tbody.addEventListener("click", (event) => {
  const top = event.currentTarget;
  let row = event.target;
  while (row !== null && row.parentNode !== top) row = row.parentNode;
  if (row === null) return;
  const r = keys.get(Number(row.firstChild.textContent));
  for (let node = event.target; node !== row.parentNode; node = node.parentNode) {
    if (node === r.a) send((e) => body(e, r), event);
  }
});
`,
  weakmap: `
const body = (ev, r) => { hSelect(r.it.id); };
const rows = new WeakMap(), handlers = new WeakMap();
const make = (it) => { const e = T.cloneNode(true); const r = walk(e, it); rows.set(e, r); handlers.set(r.a, body); return r; };
const buffer = [];
tbody.addEventListener("click", (event) => {
  buffer.length = 0;
  for (let node = event.target; node !== null && node !== event.currentTarget; node = node.parentNode) {
    const r = rows.get(node);
    const h = handlers.get(node);
    if (h !== undefined) buffer.push(h);
    if (r !== undefined) { for (const b of buffer) send((e) => b(e, r), event); return; }
  }
});
`,
};
const wantedForms = arg("forms", Object.keys(forms).join(",")).split(",");

// The mount, the same for every form: every row made into one fragment.
const mount = `
document.getElementById("go").addEventListener("click", () => send(() => {
  const f = document.createDocumentFragment();
  for (const it of items) { const r = make(it); f.appendChild(r.e); L.r.push(r); }
  tbody.appendChild(f);
}, null), { once: true });
window.__ready = true;
`;

const subjects = [];
const bytes = {};
for (const n of sizes) {
  for (const form of wantedForms) {
    const dir = `out/rowstate/${n}`;
    mkdirSync(join(root, dir), { recursive: true });
    const script = `${timer}${shared(n)}${forms[form]}${mount}`;
    writeFileSync(join(root, dir, `${form}.mjs`), script);
    subjects.push({ name: `${n}.${form}`, form, n, kind: "script", module: true, src: `/${dir}/${form}.mjs` });
    if (n === sizes[0]) {
      const min = spawnSync("npx", ["--no-install", "terser", "--module", "-c", "-m"], { cwd: root, input: forms[form], encoding: "utf8" });
      const text = min.status === 0 ? min.stdout : forms[form];
      bytes[form] = brotliCompressSync(Buffer.from(text), { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
    }
  }
}

// ---- Measuring ------------------------------------------------------------

const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(subjects);
const git = (cmd) => execSync(`git ${cmd}`, { cwd: root }).toString().trim();
const result = { chrome: browser.version, node: process.version, commit: git("rev-parse HEAD"), taskset: arg("taskset", null), started: new Date().toISOString(), pages, bytes, rows: [] };

for (const n of sizes) {
  const of = subjects.filter((s) => s.n === n);
  for (let p = 0; p < pages; p++) {
    for (let k = 0; k < of.length; k++) {
      const s = of[(p + k) % of.length];
      const page = await browser.newPage(`${origin}/s/${s.name}/`);
      await page.waitFor("window.__ready === true");
      await page.eval("window.gc && window.gc()");
      await page.click(`document.getElementById("go")`);
      await page.waitFor("window.__clickTimes.length === 1");
      if (!(await page.eval(`document.querySelectorAll("#tbody tr").length === ${n}`))) throw new Error(`${s.name}: not ${n} rows`);
      await page.click(`document.querySelectorAll("#tbody a")[6]`);
      await page.waitFor("window.__clickTimes.length === 2");
      if (!(await page.eval(`document.getElementById("sel").textContent === "7"`))) throw new Error(`${s.name}: row 7 not selected`);
      const [mountMs, eventMs] = await page.eval("window.__clickTimes");
      await page.close();
      result.rows.push({ n, form: s.form, page: p, load: loadavg()[0], mount: mountMs, event: eventMs });
      console.log(`${String(n).padStart(6)} ${s.form.padEnd(8)} #${p} mount ${mountMs.toFixed(3)} ms, event ${eventMs.toFixed(3)} ms`);
    }
  }
}
result.finished = new Date().toISOString();
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(result, null, 1));

console.log(`\n| rows | form | mount ms, median [q1–q3] | × expando | row event ms, median [q1–q3] | bytes (brotli) |`);
console.log(`|--:|---|--:|--:|--:|--:|`);
for (const n of sizes) {
  const of = (form, key) => result.rows.filter((r) => r.n === n && r.form === form).map((r) => r[key]);
  const base = median(of("expando", "mount"));
  for (const form of wantedForms) {
    const m = of(form, "mount");
    const e = of(form, "event");
    console.log(`| ${n} | ${form} | ${median(m).toFixed(3)} [${quantile(m, 0.25).toFixed(3)}–${quantile(m, 0.75).toFixed(3)}] | ${(median(m) / base).toFixed(2)} | ${median(e).toFixed(3)} [${quantile(e, 0.25).toFixed(3)}–${quantile(e, 0.75).toFixed(3)}] | ${bytes[form]} |`);
  }
}
server.close();
await browser.close();
