// One operation's script cut in two, in the page, cold as the table
// benchmark meets it: on a fresh page after the benchmark's own warm-up,
// under its throttle, `performance.now()` around a synthetic click on its
// target (the click half: a beni page's delegated listener and `update`,
// Solid 1's whole operation) and then around the microtasks the click
// queued (beni's render, Solid 2's flush). The second half is read by a
// microtask queued after the click returns, so it runs after the one the
// framework queued. Medians and interquartile ranges over fresh pages.
//
//   node halves.mjs [--subjects=beni,solid2,solid1,p2] [--benchmarks=05_swap1k,06_remove-one-1k]
//                   [--n=20] [--taskset=8-15] [--out=out/halves.json]

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { loadavg } from "node:os";
import { benchmarks as all } from "./lib/benchmarks.mjs";
import { launch, sleep } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { subjects as allSubjects } from "./lib/subjects.mjs";
import { median, quantile } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const names = arg("subjects", "beni,solid2,solid1,p2").split(",");
const subjects = names.map((n) => allSubjects.find((s) => s.name === n));
const wanted = arg("benchmarks", "05_swap1k,06_remove-one-1k").split(",");
const n = Number(arg("n", "20"));
const out = arg("out", null);

const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(allSubjects);
const samples = [];
const fmt = (xs) => `${median(xs).toFixed(3)} [${quantile(xs, 0.25).toFixed(3)}–${quantile(xs, 0.75).toFixed(3)}]`;

for (const bench of all.filter((b) => wanted.includes(b.id))) {
  const load = loadavg()[0];
  for (let i = 0; i < n; i++) {
    for (let k = 0; k < subjects.length; k++) {
      const subject = subjects[(i + k) % subjects.length];
      const page = await browser.newPage(`${origin}/s/${subject.name}/`);
      try {
        await bench.init(page);
        await sleep(100);
        await page.eval("window.gc && window.gc()");
        await sleep(50);
        if (bench.throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: bench.throttle });
        const r = await page.eval(`new Promise((done) => {
          const el = ${bench.target};
          const P = window.__probe;
          if (P !== undefined) for (const k of Object.keys(P)) delete P[k];
          const t0 = performance.now();
          el.click();
          const t1 = performance.now();
          queueMicrotask(() => {
            const t2 = performance.now();
            setTimeout(() => done([t1 - t0, t2 - t1, P === undefined ? null : { ...P, t1, t2 }]), 0);
          });
        })`);
        if (bench.throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });
        await sleep(50);
        if (!(await page.eval(bench.done))) throw new Error("the post-condition does not hold");
        samples.push({ subject: subject.name, benchmark: bench.id, click: r[0], micro: r[1], total: r[0] + r[1], probe: r[2] });
      } finally {
        await page.close();
      }
    }
  }
  console.log(`\n${bench.id} at ${bench.throttle}x, n = ${n}, load ${load.toFixed(2)}: ms, median [IQR]`);
  console.log("| subject | click (listener) | microtask (render) | both |\n|---|--:|--:|--:|");
  for (const s of subjects) {
    const xs = samples.filter((x) => x.subject === s.name && x.benchmark === bench.id);
    console.log(`| ${s.name} | ${fmt(xs.map((x) => x.click))} | ${fmt(xs.map((x) => x.micro))} | ${fmt(xs.map((x) => x.total))} |`);
  }
  // A probed build (probe.mjs): its render cut at the seams.
  const seams = [
    ["to the flush", "t1", "flush"],
    ["view", "flush", "view"],
    ["to the list", "view", "list"],
    ["fast path, whole", "list", "fast"],
    ["  its start (patched)", "list", "prefix"],
    ["  its ends and pairs", "prefix", "ends"],
    ["  its middle's lookups", "ends", "middle"],
    ["  its rows", "middle", "rows"],
    ["  its key-map sweep", "rows", "tsweep"],
    ["  its reconcile (DOM)", "tsweep", "fast"],
    ["full pass", "fast", "pass"],
    ["key-map sweep", "pass", "sweep"],
    ["reconcile (DOM)", "sweep", "moved"],
    ["after the list", "moved", "end"],
    ["to the next microtask", "end", "t2"],
  ];
  for (const s of subjects) {
    const ps = samples.filter((x) => x.subject === s.name && x.benchmark === bench.id && x.probe?.flush !== undefined).map((x) => x.probe);
    if (ps.length === 0) continue;
    console.log(`\n${s.name}'s render at its seams, ms, median [IQR] (${ps.length})\n| seam | ms |\n|---|--:|`);
    for (const [label, a, b] of seams) {
      const xs = ps.filter((p) => p[a] !== undefined && p[b] !== undefined).map((p) => p[b] - p[a]);
      if (xs.length > 0) console.log(`| ${label} | ${fmt(xs)} |`);
    }
  }
}
if (out !== null) writeFileSync(join(root, out), JSON.stringify({ chrome: browser.version, n, samples }, null, 1));
server.close();
await browser.close();
