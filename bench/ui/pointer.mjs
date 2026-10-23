// What delegating the pointer events costs and saves, in headless Chrome
// (#557). Two builds of one page (apps/pointer/Main.beni): `before` with a
// listener on each element that has a pointer handler, `after` with the
// document's delegated walk. On each fresh page:
//   hit:   untrusted `pointermove`s on a target eight elements below the
//          element with the handler (the extractor reads that element's
//          box, and `update` runs), µs per event;
//   miss:  the same on a target eight elements deep with no handler above
//          it, µs per event;
//   mount: a click that renders a thousand rows, each with an
//          `onPointerDown`, ms to the render's end.
// Untrusted events are no turn in either build, so `hit` compares the two
// listeners and not the turn. Build the page with each compiler into
// bench/ui/out/ first, then name the two directories under out/:
//
//   <beni> build --platform=browser --no-cache --out=bench/ui/out/pointer-before bench/ui/apps/pointer/Main.beni
//   node bench/ui/pointer.mjs pointer-before pointer-after [pages] [samples]
//
// `boundary.md` §9.8.20, *As built, 2026-10-23*, has the figures.

import { launch } from "./lib/cdp.mjs";
import { serve } from "./lib/serve.mjs";

const [beforeDir, afterDir] = process.argv.slice(2, 4);
const pages = Number(process.argv[4] ?? "7");
const samples = Number(process.argv[5] ?? "5");

const subjects = [
  { name: "before", kind: "beni", dir: beforeDir },
  { name: "after", kind: "beni", dir: afterDir },
];
const { server, origin } = await serve(subjects);
const browser = await launch({ chrome: process.env.CHROME ?? "chromium" });

const inPage = `(async () => {
  const until = async (f) => { for (let i = 0; i < 400 && !f(); i++) await new Promise((r) => setTimeout(r, 5)); };
  await until(() => document.getElementById("leaf") !== null);
  const move = (target, n) => {
    const t0 = performance.now();
    for (let i = 0; i < n; i++)
      target.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, cancelable: true, composed: true, clientX: 10 + (i & 7), clientY: 10, pointerId: 1, pointerType: "mouse", isPrimary: true }));
    return ((performance.now() - t0) * 1000) / n;
  };
  const settle = () => new Promise((r) => setTimeout(r, 0));
  const leaf = document.getElementById("leaf");
  const far = document.getElementById("far");
  move(leaf, 2000); move(far, 2000); await settle();
  const hit = [], miss = [];
  for (let s = 0; s < ${samples}; s++) {
    hit.push(move(leaf, 2000)); await settle();
    miss.push(move(far, 2000)); await settle();
  }
  const make = document.getElementById("make");
  const t0 = performance.now();
  make.click();
  await new Promise((r) => queueMicrotask(r));
  const mount = performance.now() - t0;
  const rows = document.querySelectorAll("li").length;
  return { hit, miss, mount, rows };
})()`;

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

const results = { before: { hit: [], miss: [], mount: [] }, after: { hit: [], miss: [], mount: [] } };
for (let p = 0; p < pages; p++) {
  // Alternate the order, so neither build is always the first on a warm browser.
  const order = p % 2 === 0 ? ["before", "after"] : ["after", "before"];
  for (const name of order) {
    const page = await browser.newPage(`${origin}/s/${name}/`);
    const r = await page.eval(inPage);
    if (r.rows !== 1000) throw new Error(`${name}: ${r.rows} rows, not 1000`);
    results[name].hit.push(...r.hit);
    results[name].miss.push(...r.miss);
    results[name].mount.push(r.mount);
    await browser.send("Target.closeTarget", { targetId: page.targetId });
  }
}
await browser.close();
server.close();

console.log(`Chrome: ${browser.version}; ${pages} pages, ${samples} samples of 2 000 events each`);
for (const name of ["before", "after"]) {
  const r = results[name];
  console.log(`${name}: hit ${median(r.hit).toFixed(2)} µs/event, miss ${median(r.miss).toFixed(2)} µs/event, mount ${median(r.mount).toFixed(2)} ms (${r.mount.map((m) => m.toFixed(1)).join(" ")})`);
}
console.log(JSON.stringify(results));
