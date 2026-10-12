// Why `05_swap1k` is bimodal for every subject (research 74). The same
// sample as `bench.mjs` — fresh page, the benchmark's warm-up, one traced
// click, js-framework-benchmark's `script` figure — under conditions that
// separate the DOM work from Chrome's CPU throttling:
//
//   <subject> swap@R   the real swap at throttling rate R (1, 2 or 4)
//   swap-nowarm@4      vanilla's swap measured right after `run`, no warm-up swaps
//   adjacent@4         vanilla's page, the click replaced by one insertBefore of
//                      row 3 before row 2 (neighbours, not 2 and 999)
//   noop@4             the click replaced by a listener that does nothing
//   spinK@R            the click replaced by a pure-JS loop, K µs when optimised
//                      (calibrated unthrottled; run once, cold, it costs more:
//                      spinK@1 is its real cost); no DOM work at all
//
// Every condition is in one batch, rotated per iteration. A sample is "fast"
// when its script time is within 0.15 ms of the condition's minimum.
//
//   node swap-modes.mjs [--n=30] [--taskset=24-31] [--out=results/…json]
//   node swap-modes.mjs --others=06_remove-one-1k,04_select1k [--n=…] [--out=…]
//   node swap-modes.mjs --report=results/…json

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import { benchmarks } from "./lib/benchmarks.mjs";
import { launch, sleep, traced } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { subjects } from "./lib/subjects.mjs";
import { analyse, categories, median, quantile } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const swap = benchmarks.find((b) => b.id === "05_swap1k");
const run = benchmarks.find((b) => b.id === "04_select1k"); // its init is `run` alone

// A capture listener on `window` that takes the click before the app sees it.
const override = (body) =>
  `window.addEventListener("click", (e) => { if (e.target.id !== "swaprows") return; e.stopImmediatePropagation(); ${body} }, true)`;
const spin = (k) => `{ let x = 0; for (let i = 0; i < ${k}; i++) x = (x * 31 + i) | 0; window.__x = x; }`;

function report(result) {
  const by = new Map();
  for (const s of result.samples) (by.get(s.condition) ?? by.set(s.condition, []).get(s.condition)).push(s);
  const f = (x) => (Number.isNaN(x) ? "—" : x.toFixed(3));
  console.log(`| condition | n | min | median | mean | p25–p75 | fast | fast median | slow median | slow excess p10–p90 |`);
  console.log(`|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|`);
  for (const [name, ss] of by) {
    const xs = ss.map((s) => s.script);
    const lo = Math.min(...xs);
    const fast = xs.filter((x) => x <= lo + 0.15);
    const slow = xs.filter((x) => x > lo + 0.15);
    const mean = xs.reduce((a, b) => a + b, 0) / xs.length;
    const excess = slow.map((x) => x - median(fast));
    console.log(
      `| ${name} | ${xs.length} | ${f(lo)} | ${f(median(xs))} | ${f(mean)} | ${f(quantile(xs, 0.25))}–${f(quantile(xs, 0.75))} | ${fast.length} | ${f(median(fast))} | ${f(median(slow))} | ${slow.length ? `${f(quantile(excess, 0.1))}–${f(quantile(excess, 0.9))}` : "—"} |`,
    );
  }
  const inClick = result.samples.filter((s) => s.layoutInClick > 0 || s.styleInClick > 0).length;
  console.log(`\nsamples with a Layout or UpdateLayoutTree inside the click: ${inClick} of ${result.samples.length}`);
}

if (arg("report", null) !== null) {
  report(JSON.parse(readFileSync(join(root, arg("report")), "utf8")));
  process.exit(0);
}

const n = Number(arg("n", "30"));
const out = join(root, arg("out", "out/swap-modes.json"));
const taskset = arg("taskset", null);
const browser = await launch({ chrome: arg("chrome", undefined), taskset });
const { server, origin } = await serve(subjects);

// Iterations of `spin` per µs, unthrottled, on a vanilla page.
const calibrate = async () => {
  const page = await browser.newPage(`${origin}/s/vanillajs/`);
  const rates = [];
  for (let i = 0; i < 7; i++)
    rates.push(await page.eval(`(() => { const t = performance.now(); ${spin(2_000_000)} return 2_000_000 / ((performance.now() - t) * 1000); })()`));
  await page.close();
  return median(rates);
};
const perUs = await calibrate();
console.log(`spin: ${perUs.toFixed(1)} iterations per µs`);

const swapDone = swap.done;
const subjectNames = ["vanillajs", "beni-direct-release", "p3"];
// `--others=<ids>`: instead, those benchmarks, every subject, at their official rate and at 1.
const others = arg("others", null);
const conditions = others !== null
  ? others.split(",").flatMap((id) => {
      const b = benchmarks.find((x) => x.id === id);
      return subjectNames.flatMap((subject) => [...new Set([b.throttle, 1])].map((rate) => ({ name: `${subject} ${id}@${rate}`, subject, rate, init: b.init, target: b.target, done: b.done, settle: b.settle })));
    })
  : [
  ...subjectNames.flatMap((subject) =>
    [4, 1].map((rate) => ({ name: `${subject} swap@${rate}`, subject, rate, init: swap.init, done: swapDone })),
  ),
  { name: "vanillajs swap@2", subject: "vanillajs", rate: 2, init: swap.init, done: swapDone },
  { name: "vanillajs swap-nowarm@4", subject: "vanillajs", rate: 4, init: run.init, done: swapDone },
  { name: "adjacent@4", subject: "vanillajs", rate: 4, init: run.init, install: override(`const t = document.getElementById("tbody"); t.insertBefore(t.children[2], t.children[1]);`), done: "true" },
  { name: "noop@4", subject: "vanillajs", rate: 4, init: run.init, install: override(""), done: "true" },
  ...[30, 100, 300].flatMap((us) =>
    [4, 1].map((rate) => ({ name: `spin${us}@${rate}`, subject: "vanillajs", rate, init: run.init, install: override(spin(Math.round(us * perUs))), done: "true" })),
  ),
];

const result = { chrome: browser.version, taskset, started: new Date().toISOString(), load: loadavg()[0], n, perUs, samples: [] };

const measure = async (c) => {
  const page = await browser.newPage(`${origin}/s/${c.subject}/`);
  try {
    await c.init(page);
    if (c.install) await page.eval(c.install);
    await sleep(100);
    await page.eval("window.gc && window.gc()");
    const box = await page.locate(c.target ?? swap.target);
    await sleep(50);
    const events = await traced(page, categories, async () => {
      if (c.rate > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: c.rate });
      await page.press(box);
      await sleep(c.settle ?? 500);
      if (c.rate > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    });
    if (!(await page.eval(c.done))) throw new Error("the post-condition does not hold");
    const r = analyse(events);
    // Did the click force a style recalc or a layout (H2)?
    const click = events.find((e) => e.name === "EventDispatch" && e.args?.data?.type === "click");
    const inside = (e) => e.ph === "X" && e.pid === click.pid && e.tid === click.tid && e.ts >= click.ts && e.ts + e.dur <= click.ts + click.dur;
    return {
      ...r,
      click: click.dur / 1000,
      layoutInClick: events.filter((e) => inside(e) && e.name === "Layout").length,
      styleInClick: events.filter((e) => inside(e) && e.name === "UpdateLayoutTree").length,
    };
  } finally {
    await page.close();
  }
};

for (let i = 0; i < n; i++) {
  for (let k = 0; k < conditions.length; k++) {
    const c = conditions[(i + k) % conditions.length];
    let r = null;
    for (let attempt = 0; attempt < 3 && r === null; attempt++) {
      try {
        r = await measure(c);
      } catch (e) {
        console.error(`${c.name} #${i}: ${e.message}`);
      }
    }
    if (r === null) continue;
    result.samples.push({ condition: c.name, iteration: i, load: loadavg()[0], ...r });
    console.log(`${c.name.padEnd(30)} #${String(i).padStart(2)} script ${r.script.toFixed(3)} click ${r.click.toFixed(3)}`);
  }
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(result, null, 1));
}
result.finished = new Date().toISOString();
result.loadEnd = loadavg()[0];
writeFileSync(out, JSON.stringify(result, null, 1));
server.close();
await browser.close();
report(result);
