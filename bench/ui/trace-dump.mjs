// One sample of the table benchmark, and the renderer main thread's trace
// events between the click and the commit that ends it: what the `script`
// and `paint` columns are made of.
//
//   node trace-dump.mjs --subject=beni --benchmark=04_select1k [--min=0.05]

import { benchmarks } from "./lib/benchmarks.mjs";
import { launch, sleep, traced } from "./lib/cdp.mjs";
import { serve } from "./lib/serve.mjs";
import { subjects } from "./lib/subjects.mjs";
import { analyse, categories, computeResultsCPU } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const subject = subjects.find((s) => s.name === arg("subject", "beni"));
const bench = benchmarks.find((b) => b.id === arg("benchmark", "04_select1k"));
const min = Number(arg("min", "0.05"));
const more = arg("categories", "").split(",").filter((c) => c !== "");

const browser = await launch({ chrome: arg("chrome", undefined) });
const { server, origin } = await serve(subjects);
const page = await browser.newPage(`${origin}/s/${subject.name}/`);
await bench.init(page);
await page.eval("window.gc && window.gc()");
const box = await page.locate(bench.target);
const events = await traced(page, [...categories, ...more], async () => {
  if (bench.throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: bench.throttle });
  await page.press(box);
  await sleep(bench.settle ?? 500);
  if (bench.throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });
});
const cpu = computeResultsCPU(events);
const r = analyse(events);
const click = events.find((e) => e.name === "EventDispatch" && e.args?.data?.type === "click");
console.log(`${subject.name} ${bench.id}: total ${r.total.toFixed(2)} script ${r.script.toFixed(2)} paint ${r.paint.toFixed(2)}`);
for (const e of events
  .filter((e) => e.ph === "X" && e.pid === click.pid && e.tid === click.tid && e.ts >= cpu.tsStart && e.ts <= cpu.tsEnd && e.dur / 1000 >= min)
  .sort((a, b) => a.ts - b.ts)) {
  const detail = e.args?.data?.type ?? e.args?.data?.functionName ?? "";
  console.log(`${((e.ts - cpu.tsStart) / 1000).toFixed(3).padStart(8)} ${(e.dur / 1000).toFixed(3).padStart(7)}  ${e.name} ${detail}`);
}
await page.close();
server.close();
await browser.close();
