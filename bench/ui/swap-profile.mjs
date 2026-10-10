// The swap's fixed cost per message on `browser-direct --release`, part by
// part (research 67 §2: 10–15 µs over vanilla at every N, P3 equal). A
// measurement for S7's design; it changes nothing in the compiler.
//
//   node scaling.mjs --build-only --sweeps=rows --points=rows=10/1000/10000/30000 \
//     --subjects=beni-direct-release,p3,vanillajs
//   node swap-profile.mjs [--taskset=8-15] [--pages=6] [--samples=4] [--out=…]
//
// From each N's release bundle it writes ablation copies, each removing one
// part of the swap's handler by hand:
//   built       as the compiler emitted it
//   nospread    the model record written in place (`d.a = …`), no spread
//   inplace     `List.swap` replaced by a swap of the plain array's two slots
//               (the list then stays a plain array; as built it is a trie
//               past 256 rows after the first swap)
//   both        nospread and inplace
//   nodispatch  both, and the listener calls the handler without `send`
//   instr       as built, with `performance.now()` around each part
// and measures each, with vanilla and P3, by untraced real clicks (research
// 60 §1's clock: a capture listener on `window` to a microtask queued by a
// bubble one). `instr` also records, per click, the time from the click's
// start to the listener, to the handler, the list operation, the spread and
// the DOM script; and, warm, each part alone in a loop in the page.

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import { execSync } from "node:child_process";
import { launch, sleep } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const flag = (name) => process.argv.includes(`--${name}`);
const NS = (arg("points", "10/1000/10000/30000")).split("/").map(Number);
const PAGES = Number(arg("pages", "6"));
const SAMPLES = Number(arg("samples", "4"));
const WARM = 5;

const shapes = {
  handler: "s=()=>{d={...d,a:r(d.a)};{let a=d.a;J(p,a)}}",
  listener: '.addEventListener("click",a=>{A(b,a)})',
};
// The swap's two indices, as rows.mjs writes them: 1 and N - 2.
const inPlace = (n) => `(x=>{const t=x[1];x[1]=x[${n - 2}];x[${n - 2}]=t;return x})`;

function variants(n) {
  const dir = `out/scaling/rows/${n}`;
  const src = readFileSync(join(root, dir, "beni-direct-rel/_main.mjs"), "utf8");
  for (const s of Object.values(shapes)) if (src.split(s).length !== 2) throw new Error(`N=${n}: the bundle's shape changed: ${s}`);
  const handler = (body) => src.replace(shapes.handler, body);
  const out = {
    built: src,
    nospread: handler("s=()=>{d.a=r(d.a);{let a=d.a;J(p,a)}}"),
    inplace: handler(`s=()=>{d={...d,a:${inPlace(n)}(d.a)};{let a=d.a;J(p,a)}}`),
    both: handler(`s=()=>{d.a=${inPlace(n)}(d.a);{let a=d.a;J(p,a)}}`),
    nodispatch: handler(`s=()=>{d.a=${inPlace(n)}(d.a);{let a=d.a;J(p,a)}}`).replace(shapes.listener, '.addEventListener("click",a=>{window.__th=performance.now();s()})'),
    instr: src
      .replace(
        shapes.handler,
        "s=()=>{const P=performance,t1=P.now(),L=r(d.a),t2=P.now();d={...d,a:L};const t3=P.now();{let a=d.a;J(p,a)}const t4=P.now();window.__parts.push([window.__tl,window.__th,t1,t2,t3,t4]);" +
          "window.__warm=(k)=>{const P=performance;let x=d.a,t=P.now();for(let i=0;i<k;i++)x=r(x);const tl=(P.now()-t)/k;let y=d;t=P.now();for(let i=0;i<k;i++)y={...y,a:x};const ts=(P.now()-t)/k;return{list:tl,spread:ts,trie:!Array.isArray(x)}}}",
      )
      .replace(shapes.listener, '.addEventListener("click",a=>{window.__tl=performance.now();A(()=>{window.__th=performance.now();b()},a)})'),
  };
  for (const [name, text] of Object.entries(out)) {
    const d = join(root, dir, `swap-${name}`);
    mkdirSync(d, { recursive: true });
    writeFileSync(join(d, "_main.mjs"), text);
  }
  return Object.keys(out);
}

const clickTimer = `() => {
  if (window.__clickTimes !== undefined) return true;
  window.__clickTimes = [];
  window.__parts = [];
  let depth = 0;
  let t0 = 0;
  addEventListener("click", () => { if (depth++ === 0) { t0 = performance.now(); window.__t0s.push(t0); } }, true);
  addEventListener("click", () => { if (--depth === 0) queueMicrotask(() => window.__clickTimes.push(performance.now() - t0)); });
  return true;
}`;

// `--only=instr,vanillajs`: these variants only.
const only = arg("only", null)?.split(",") ?? null;
const subjects = [];
for (const n of NS) {
  for (const v of variants(n)) subjects.push({ name: `${n}.${v}`, n, variant: v, kind: "beni", dir: `scaling/rows/${n}/swap-${v}` });
  subjects.push({ name: `${n}.vanillajs`, n, variant: "vanillajs", kind: "script", src: `/out/scaling/rows/${n}/vanilla.js` });
  subjects.push({ name: `${n}.p3`, n, variant: "p3", kind: "script", src: `/out/scaling/rows/${n}/p3.js`, module: true });
}
if (only !== null) subjects.splice(0, subjects.length, ...subjects.filter((s) => only.includes(s.variant)));

const byId = (id) => `document.getElementById(${JSON.stringify(id)})`;
const done = (k, n) => `(() => { const r = document.querySelector("tbody")?.children[1]; return r !== undefined && r.firstChild.textContent === ${JSON.stringify(String(k % 2 === 1 ? n - 1 : 2))}; })()`;

// `--summarise`: only the summary, of a result file a run wrote.
const out = join(root, arg("out", "results/2026-10-10-s3-swap-profile.json"));
const result = flag("summarise") ? JSON.parse(readFileSync(out, "utf8")) : await measure();

async function measure() {
const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(subjects);
const result = {
  chrome: browser.version,
  commit: execSync("git rev-parse HEAD", { cwd: root }).toString().trim(),
  cpu: execSync("grep -m1 'model name' /proc/cpuinfo").toString().split(":")[1].trim(),
  taskset: arg("taskset", null),
  pages: PAGES,
  samples: SAMPLES,
  started: new Date().toISOString(),
  samplesOut: [],
  parts: [],
  warm: [],
};

// Rounds: each subject visited once a round, in an order shuffled per round
// (a fixed seed), so the machine's load drifts across all of them alike.
let seed = 1;
const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
for (let pageIndex = 0; pageIndex < PAGES; pageIndex++) {
  const order = [...subjects];
  for (let i = order.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [order[i], order[j]] = [order[j], order[i]];
  }
  for (const s of order) {
    const page = await browser.newPage(`${origin}/s/${s.name}/`);
    try {
      await page.waitFor(`${byId("swap")} !== null && document.querySelector("tbody")?.children.length === ${s.n}`, 60000);
      await page.eval("window.__t0s = []; window.__tl = 0; window.__th = 0; true");
      await page.eval(`(${clickTimer})()`);
      let k = 0;
      for (let i = 0; i < WARM; i++) {
        await page.click(byId("swap"));
        k++;
        await page.waitFor(done(k, s.n), 60000);
      }
      await page.eval("window.__clickTimes.splice(0); window.__parts.splice(0); window.__t0s.splice(0); true");
      for (let j = 0; j < SAMPLES; j++) {
        await sleep(50);
        await page.eval("window.gc && window.gc()");
        const box = await page.locate(byId("swap"));
        await sleep(20);
        await page.press(box);
        k++;
        await page.waitFor(done(k, s.n), 60000);
        const times = await page.eval("window.__clickTimes.splice(0)");
        const t0s = await page.eval("window.__t0s.splice(0)");
        if (times.length !== 1) throw new Error(`${s.name}: expected one timed click, got ${times.length}`);
        result.samplesOut.push({ n: s.n, variant: s.variant, page: pageIndex, sample: j, load: loadavg()[0], ms: times[0] });
        if (s.variant === "instr") {
          const [tl, th, t1, t2, t3, t4] = (await page.eval("window.__parts.splice(0)"))[0];
          const t0 = t0s[0];
          result.parts.push({ n: s.n, page: pageIndex, sample: j, total: times[0], toListener: tl - t0, guard: th - tl, toHandler: t1 - th, list: t2 - t1, spread: t3 - t2, dom: t4 - t3, after: times[0] - (t4 - t0) });
        }
      }
      if (s.variant === "instr") result.warm.push({ n: s.n, page: pageIndex, ...(await page.eval("window.__warm(2000)")) });
    } finally {
      await page.close();
    }
    console.log(`${s.name} page ${pageIndex}`);
  }
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(result, null, 1));
}
server.close();
await browser.close();
return result;
}

// The summary: medians per N and variant; mean parts.
const med = (xs) => {
  const a = [...xs].sort((x, y) => x - y);
  return a.length === 0 ? NaN : a.length % 2 ? a[(a.length - 1) / 2] : (a[a.length / 2 - 1] + a[a.length / 2]) / 2;
};
const mean = (xs) => xs.reduce((x, y) => x + y, 0) / xs.length;
const summary = {};
for (const n of NS) {
  summary[n] = {};
  for (const v of [...new Set(subjects.map((s) => s.variant))]) summary[n][v] = med(result.samplesOut.filter((x) => x.n === n && x.variant === v).map((x) => x.ms));
  const ps = result.parts.filter((x) => x.n === n);
  summary[n].instrParts = Object.fromEntries(["toListener", "guard", "toHandler", "list", "spread", "dom", "after"].map((k) => [k, { mean: mean(ps.map((p) => p[k])), median: med(ps.map((p) => p[k])) }]));
  summary[n].warmParts = result.warm.filter((x) => x.n === n);
}
result.summary = summary;
writeFileSync(out, JSON.stringify(result, null, 1));
console.log(JSON.stringify(summary, null, 1));
