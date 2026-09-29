// Where one operation's script time goes: repeats it in a page under the
// V8 sampling profiler and prints the functions with the most self time,
// and the in-page milliseconds per operation.
//
//   node profile.mjs --subject=beni --op=select [--repeat=200] [--throttle=4]
//
// Ops: select (rows 2 and 3 in turn), update, swap, remove (row 4, the page
// refilled every 500), replace, append (after a clear every 5), clear (after
// a run; only the clear is timed, the profile holds both). A beni subject is
// flushed after each click through its runtime's `flush`, so the render is
// inside the loop; the others render inside the click.

import { launch } from "./lib/cdp.mjs";
import { serve } from "./lib/serve.mjs";
import { subjects } from "./lib/subjects.mjs";
import { median } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const subject = subjects.find((s) => s.name === arg("subject", "beni"));
const op = arg("op", "select");
const repeat = Number(arg("repeat", "200"));
const throttle = Number(arg("throttle", "4"));

const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(subjects);

// Self time per function over a profile's samples; with `--under=<name>`,
// only the samples with that function on the stack.
const under = arg("under", null);
const selfTime = (profile, into) => {
  const byId = new Map(profile.nodes.map((n) => [n.id, n]));
  const parent = new Map();
  for (const n of profile.nodes) for (const c of n.children ?? []) parent.set(c, n.id);
  if (under !== null) {
    profile.samples = profile.samples.filter((s) => {
      for (let id = s; id !== undefined; id = parent.get(id)) if (byId.get(id).callFrame.functionName === under) return true;
      return false;
    });
  }
  for (const s of profile.samples) {
    const f = byId.get(s).callFrame;
    const key = `${f.functionName || "(anonymous)"} ${f.url.replace(origin, "")}:${f.lineNumber + 1}`;
    into.set(key, (into.get(key) ?? 0) + 1);
  }
  return profile.samples.length;
};
const print = (self, total, head) => {
  console.log(head);
  for (const [k, c] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 25)) console.log(`${((100 * c) / total).toFixed(1).padStart(5)}%  ${k}`);
};

// `--cold=<pages>`: the operation as the table benchmark meets it — once, on
// a fresh page, after only its warm-up — profiled on each page and summed.
const cold = Number(arg("cold", "0"));
if (cold > 0) {
  const { benchmarks } = await import("./lib/benchmarks.mjs");
  const bench = benchmarks.find((b) => b.id === op);
  const self = new Map();
  let total = 0;
  for (let k = 0; k < cold; k++) {
    const page = await browser.newPage(`${origin}/s/${subject.name}/`);
    await bench.init(page);
    const box = await page.locate(bench.target);
    await page.send("Profiler.enable");
    await page.send("Profiler.setSamplingInterval", { interval: 25 });
    if (bench.throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: bench.throttle });
    await page.send("Profiler.start");
    await page.press(box);
    await new Promise((r) => setTimeout(r, bench.settle ?? 500));
    const { profile } = await page.send("Profiler.stop");
    await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    // Only the samples that ran script: idle is most of the window.
    const idle = new Set(profile.nodes.filter((n) => n.callFrame.functionName === "(idle)").map((n) => n.id));
    profile.samples = profile.samples.filter((s) => !idle.has(s));
    total += selfTime(profile, self);
    await page.close();
  }
  print(self, total, `${subject.name} ${op}, cold on ${cold} pages at ${bench.throttle}x: ${total} busy samples of 25 µs (${((total * 0.025) / cold).toFixed(2)} ms per page)`);
  server.close();
  await browser.close();
  process.exit(0);
}

const page = await browser.newPage(`${origin}/s/${subject.name}/`);
await page.waitFor(`document.getElementById("run") !== null`);
const flushUrl = subject.kind === "beni" ? `/out/${subject.dir}/_platform/_browser/runtime.foreign.mjs` : null;
await page.eval(`(async () => {
  window.__flushNow = ${flushUrl === null ? "() => {}" : `(await import(${JSON.stringify(flushUrl)})).flush`};
  const flush = window.__flushNow;
  const q = (s) => document.querySelector(s);
  const click = (el) => { el.click(); flush(); };
  window.__op = {
    select: (i) => click(q("tbody > tr:nth-of-type(" + (2 + (i % 2)) + ") > td:nth-of-type(2) > a")),
    update: () => click(q("#update")),
    swap: () => click(q("#swaprows")),
    remove: (i) => { if (i % 500 === 499) click(q("#run")); else click(q("tbody > tr:nth-of-type(4) > td:nth-of-type(3) > a > span")); },
    replace: () => click(q("#run")),
    append: (i) => { if (i % 5 === 4) click(q("#clear")); click(q("#add")); },
    clear: () => { click(q("#run")); const t = performance.now(); click(q("#clear")); return performance.now() - t; },
  };
  click(q("#run"));
})()`);
const setup = async () => {
  for (let i = 0; i < 50; i++) await page.eval(`window.__op[${JSON.stringify(op)}](${i})`);
};
await setup();
await page.send("Emulation.setCPUThrottlingRate", { rate: throttle });
await page.send("Profiler.enable");
await page.send("Profiler.setSamplingInterval", { interval: 50 });
await page.send("Profiler.start");
const times = await page.eval(`(() => { const ts = []; for (let i = 0; i < ${repeat}; i++) { const t = performance.now(); const r = window.__op[${JSON.stringify(op)}](i); ts.push(typeof r === "number" ? r : performance.now() - t); } return ts; })()`);
const { profile } = await page.send("Profiler.stop");
await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });

const byId = new Map(profile.nodes.map((n) => [n.id, n]));
const self = new Map();
const counts = new Map();
for (const s of profile.samples) counts.set(s, (counts.get(s) ?? 0) + 1);
const total = profile.samples.length;
for (const [id, c] of counts) {
  const f = byId.get(id).callFrame;
  const key = `${f.functionName || "(anonymous)"} ${f.url.replace(origin, "")}:${f.lineNumber + 1}`;
  self.set(key, (self.get(key) ?? 0) + c);
}
const rows = [...self].sort((a, b) => b[1] - a[1]).slice(0, 25);
console.log(`${subject.name} ${op} x${repeat} at ${throttle}x: in-page median ${median(times).toFixed(3)} ms per op`);
for (const [k, c] of rows) console.log(`${((100 * c) / total).toFixed(1).padStart(5)}%  ${k}`);
server.close();
await browser.close();
