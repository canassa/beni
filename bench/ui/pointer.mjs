// What delegating the pointer events costs and saves, in headless Chrome
// (#557). One page in several builds: beni's apps/pointer/Main.beni, built
// by each compiler into out/<dir>/, and its Solid 2 twin,
// apps/solid2/src/pointer.jsx, built into out/solid2/pointer.js. On each
// fresh page, untrusted events, µs per event:
//   hit:     `pointermove`s on a target eight elements below the element
//            with the handler (the handler reads that element's box, and
//            the state is written);
//   miss:    the same on a target eight elements deep with no handler
//            above it;
//   rowdown: `pointerdown`s on row 500 of 1 000 rows, each with a handler;
//   rowmove: `pointermove`s on row 500, which has no move handler;
// and mount: a click that renders the thousand rows, ms to the render's end.
// Untrusted events are no turn in a beni build, so the figures compare the
// listeners and not the turn. Medians, never a geometric mean (CLAUDE.md
// rule 8).
//
//   <beni> build --platform=browser --no-cache --out=bench/ui/out/pointer-before bench/ui/apps/pointer/Main.beni
//   (cd bench/ui/apps/solid2 && npm ci && ENTRY=pointer npx vite build)
//   node bench/ui/pointer.mjs beni:pointer-before beni:pointer-after solid:pointer [--pages=7] [--samples=5]
//
// `boundary.md` §9.8.20, *As built, 2026-10-23*, has the figures.

import { launch } from "./lib/cdp.mjs";
import { serve } from "./lib/serve.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const pages = Number(arg("pages", "7"));
const samples = Number(arg("samples", "5"));
const subjects = process.argv
  .slice(2)
  .filter((a) => !a.startsWith("--"))
  .map((a) => {
    const [kind, name] = a.split(":");
    if (kind === "beni") return { name: a, kind: "beni", dir: name };
    if (kind === "solid") return { name: a, kind: "solid", entry: name };
    throw new Error(`a subject is beni:<out dir> or solid:<entry>, not ${a}`);
  });
if (subjects.length === 0) throw new Error("name at least one subject");
const { server, origin } = await serve(subjects.map((s) => ({ ...s, name: s.name.replace(":", "-") })));
const browser = await launch({ chrome: process.env.CHROME ?? "chromium" });

const inPage = `(async () => {
  const until = async (f) => { for (let i = 0; i < 400 && !f(); i++) await new Promise((r) => setTimeout(r, 5)); };
  await until(() => document.getElementById("leaf") !== null);
  const fire = (target, name, n) => {
    const t0 = performance.now();
    for (let i = 0; i < n; i++)
      target.dispatchEvent(new PointerEvent(name, { bubbles: true, cancelable: true, composed: true, clientX: 10 + (i & 7), clientY: 10, pointerId: 1, pointerType: "mouse", isPrimary: true }));
    return ((performance.now() - t0) * 1000) / n;
  };
  const settle = () => new Promise((r) => setTimeout(r, 0));
  const leaf = document.getElementById("leaf");
  const far = document.getElementById("far");
  fire(leaf, "pointermove", 2000); fire(far, "pointermove", 2000); await settle();
  const hit = [], miss = [], rowdown = [], rowmove = [];
  for (let s = 0; s < ${samples}; s++) {
    hit.push(fire(leaf, "pointermove", 2000)); await settle();
    miss.push(fire(far, "pointermove", 2000)); await settle();
  }
  // The render runs on a microtask after the click in both frameworks: wait
  // microtask by microtask, on a live list, until the thousand rows are in.
  const make = document.getElementById("make");
  const items = document.getElementsByTagName("li");
  const t0 = performance.now();
  make.click();
  for (let i = 0; i < 1000 && items.length !== 1000; i++) await Promise.resolve();
  const mount = performance.now() - t0;
  const rows = items.length;
  const row = document.querySelectorAll("li")[499];
  fire(row, "pointerdown", 2000); fire(row, "pointermove", 2000); await settle();
  for (let s = 0; s < ${samples}; s++) {
    rowdown.push(fire(row, "pointerdown", 2000)); await settle();
    rowmove.push(fire(row, "pointermove", 2000)); await settle();
  }
  return { hit, miss, rowdown, rowmove, mount, rows };
})()`;

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

const shapes = ["hit", "miss", "rowdown", "rowmove"];
const results = Object.fromEntries(subjects.map((s) => [s.name, { hit: [], miss: [], rowdown: [], rowmove: [], mount: [] }]));
for (let p = 0; p < pages; p++) {
  // Rotate the order, so no build is always the first on a warm browser.
  const order = subjects.map((_, i) => subjects[(i + p) % subjects.length]);
  for (const s of order) {
    const page = await browser.newPage(`${origin}/s/${s.name.replace(":", "-")}/`);
    const r = await page.eval(inPage);
    if (r.rows !== 1000) throw new Error(`${s.name}: ${r.rows} rows after 1 000 microtasks, not 1000`);
    for (const k of shapes) results[s.name][k].push(...r[k]);
    results[s.name].mount.push(r.mount);
    await browser.send("Target.closeTarget", { targetId: page.targetId });
  }
}
await browser.close();
server.close();

console.log(`Chrome: ${browser.version}; ${pages} pages, ${samples} samples of 2 000 events each; medians`);
console.log(["subject", ...shapes.map((k) => `${k} µs`), "mount ms"].join("\t"));
for (const s of subjects) {
  const r = results[s.name];
  console.log([s.name, ...shapes.map((k) => median(r[k]).toFixed(2)), median(r.mount).toFixed(2)].join("\t"));
}
console.log(JSON.stringify(results));
