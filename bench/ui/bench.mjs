// The table benchmark (research 29 §1): js-framework-benchmark's nine CPU
// operations, click to paint from a Chrome trace, with the official
// throttling. One long-lived headless Chrome; every (subject, operation,
// iteration) in a fresh page; the subject order rotated each iteration so
// no subject is always measured at the same point of a drift.
//
//   node bench.mjs [--subjects=beni,solid2,p2] [--benchmarks=04_select1k,...]
//                  [--n=10] [--out=out/cpu.json] [--taskset=4-7] [--chrome=<path>]
//
// `--taskset` pins Chrome (and so its renderers) to those CPUs. The output
// is every sample; `report.mjs` turns it into tables.

import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import { benchmarks as allBenchmarks } from "./lib/benchmarks.mjs";
import { launch, sleep, traced } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { subjects as allSubjects } from "./lib/subjects.mjs";
import { analyse, categories } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const pick = (all, key, list) => (list === null ? all : list.split(",").map((n) => all.find((x) => x[key] === n) ?? (() => { throw new Error(`unknown ${n}`); })()));
// A beni subject whose build `build.mjs` could not make holds `.skipped`,
// the compiler's reason: it is skipped, said so, and never measured.
const skipped = (s) => (s.dir !== undefined && existsSync(join(root, "out", s.dir, ".skipped")) ? readFileSync(join(root, "out", s.dir, ".skipped"), "utf8") : null);
const subjects = pick(allSubjects, "name", arg("subjects", "beni,beni-release,beni-direct,beni-direct-release,solid2,solid1,p2,p3,vanillajs")).filter((s) => {
  const why = skipped(s);
  if (why !== null) console.log(`skipped ${s.name}: ${why}`);
  return why === null;
});
const benchmarks = pick(allBenchmarks, "id", arg("benchmarks", null));
const n = Number(arg("n", "10"));
const out = join(root, arg("out", "out/cpu.json"));
const taskset = arg("taskset", null);

const browser = await launch({ chrome: arg("chrome", undefined), taskset });
const { server, origin } = await serve(allSubjects);
let built = {};
try {
  built = JSON.parse(readFileSync(join(root, "out/built.json"), "utf8"));
} catch {}
const result = {
  chrome: browser.version,
  node: process.version,
  beni: built.beni,
  cpu: execSync("grep -m1 'model name' /proc/cpuinfo").toString().split(":")[1].trim(),
  taskset,
  started: new Date().toISOString(),
  n,
  batches: [],
  samples: [],
};

const measure = async (subject, bench) => {
  const page = await browser.newPage(`${origin}/s/${subject.name}/`);
  try {
    await bench.init(page);
    await sleep(100);
    await page.eval("window.gc && window.gc()");
    const box = await page.locate(bench.target);
    await sleep(50);
    const events = await traced(page, categories, async () => {
      if (bench.throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: bench.throttle });
      await page.press(box);
      await sleep(bench.settle ?? 500);
      if (bench.throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    });
    if (!(await page.eval(bench.done))) throw new Error("the post-condition does not hold");
    return analyse(events);
  } finally {
    await page.close();
  }
};

for (const bench of benchmarks) {
  result.batches.push({ benchmark: bench.id, load: loadavg()[0], at: new Date().toISOString() });
  for (let i = 0; i < n; i++) {
    for (let k = 0; k < subjects.length; k++) {
      const subject = subjects[(i + k) % subjects.length];
      let r = null;
      for (let attempt = 0; attempt < 3 && r === null; attempt++) {
        try {
          r = await measure(subject, bench);
        } catch (e) {
          console.error(`${subject.name} ${bench.id} #${i}: ${e.message}${attempt < 2 ? ", again" : ""}`);
        }
      }
      if (r === null) continue;
      result.samples.push({ subject: subject.name, benchmark: bench.id, iteration: i, load: loadavg()[0], ...r });
      console.log(`${bench.id} ${subject.name.padEnd(13)} #${i} total ${r.total.toFixed(2).padStart(7)} script ${r.script.toFixed(2).padStart(6)} paint ${r.paint.toFixed(2).padStart(6)}`);
    }
  }
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(result, null, 1));
}
result.finished = new Date().toISOString();
writeFileSync(out, JSON.stringify(result, null, 1));
server.close();
await browser.close();
