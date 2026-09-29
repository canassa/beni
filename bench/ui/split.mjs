// A beni page's script split in two, from the trace of the table
// benchmark's measured click: the delegated listener (the message, and so
// `update`) and the microtask after it (the render). Medians over fresh
// pages.
//
//   node split.mjs --subject=beni --benchmarks=05_swap1k,06_remove-one-1k [--n=10]

import { benchmarks } from "./lib/benchmarks.mjs";
import { launch, sleep, traced } from "./lib/cdp.mjs";
import { serve } from "./lib/serve.mjs";
import { subjects } from "./lib/subjects.mjs";
import { analyse, categories, computeResultsCPU, median } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const subject = subjects.find((s) => s.name === arg("subject", "beni"));
const wanted = arg("benchmarks", "05_swap1k").split(",");
const n = Number(arg("n", "10"));

const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(subjects);
console.log(`| ${subject.name} | script | listener (update) | render (microtask) |`);
console.log("|---|--:|--:|--:|");
for (const bench of benchmarks.filter((b) => wanted.includes(b.id))) {
  const rows = [];
  for (let k = 0; k < n; k++) {
    const page = await browser.newPage(`${origin}/s/${subject.name}/`);
    await bench.init(page);
    await page.eval("window.gc && window.gc()");
    const box = await page.locate(bench.target);
    const events = await traced(page, categories, async () => {
      if (bench.throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: bench.throttle });
      await page.press(box);
      await sleep(bench.settle ?? 500);
      if (bench.throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    });
    await page.close();
    const cpu = computeResultsCPU(events);
    const inside = events.filter((e) => e.ph === "X" && e.ts >= cpu.tsStart && e.ts <= cpu.tsEnd);
    const listener = inside.filter((e) => e.name === "FunctionCall" && e.args?.data?.functionName === "delegated").reduce((a, e) => a + e.dur, 0) / 1000;
    const micro = inside.filter((e) => e.name === "FunctionCall" && e.args?.data?.functionName !== "delegated").reduce((a, e) => a + e.dur, 0) / 1000;
    rows.push({ script: analyse(events).script, listener, micro });
  }
  const m = (k) => median(rows.map((r) => r[k])).toFixed(2);
  console.log(`| ${bench.id} (${n}) | ${m("script")} | ${m("listener")} | ${m("micro")} |`);
}
server.close();
await browser.close();
