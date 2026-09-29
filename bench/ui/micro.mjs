// The static-heavy page (research 29 §11.1's E1) and its helper-heavy
// twins: in-page script time per message, the time of the first message
// after mount, and the mount itself. Research 29 §11's instrument, not the
// table's: `performance.now()` around the work, no paint, so the two must
// not be mixed.
//
//   node micro.mjs [--pages=5] [--samples=20] [--messages=100] [--out=out/micro.json]
//                  [--subjects=a,b] [--taskset=8-15]
//
// `out/extra-micro.json`, when present, adds subjects (an array of the same
// objects): a copy of an earlier build, say, measured in the same batch.
//
// On each fresh page: the mount time the page recorded, the first message
// alone, 300 warm-up messages, then `samples` runs of `messages` messages,
// each a click on `#bump` and the runtime's flush, so a render that waits
// for a microtask is inside the window. At 1x and 4x CPU throttling, and
// again with a forced layout after every message.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import { launch } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { median, quantile } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const pages = Number(arg("pages", "5"));
const samples = Number(arg("samples", "20"));
const messages = Number(arg("messages", "100"));
const out = join(root, arg("out", "out/micro.json"));

const all = [
  { name: "p2-static", kind: "script", src: "/apps/micro/p2/static.js" },
  { name: "solid2-inline", kind: "solid", entry: "static" },
  { name: "solid2-components", kind: "solid", entry: "helpers" },
  ...["inline", "helpers", "components"].flatMap((v) => [
    { name: `beni-${v}`, kind: "beni-micro", dir: `micro-${v}-dev` },
    { name: `beni-${v}-release`, kind: "beni-micro", dir: `micro-${v}-rel` },
  ]),
];
const extra = join(root, "out/extra-micro.json");
if (existsSync(extra)) all.push(...JSON.parse(readFileSync(extra, "utf8")));
const wanted = arg("subjects", null)?.split(",") ?? null;
const subjects = wanted === null ? all : all.filter((s) => wanted.includes(s.name));

const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(all);
const result = { chrome: browser.version, started: new Date().toISOString(), load: loadavg()[0], pages, samples, messages, rows: [] };

const loop = (n, layout) =>
  `(() => { const b = document.getElementById("bump"), f = window.__flush; const t = performance.now(); for (let i = 0; i < ${n}; i++) { b.click(); f();${layout ? " document.body.offsetHeight;" : ""} } return performance.now() - t; })()`;

for (const throttle of [1, 4]) {
  for (let p = 0; p < pages; p++) {
    for (let k = 0; k < subjects.length; k++) {
      const s = subjects[(p + k) % subjects.length];
      const page = await browser.newPage(`${origin}/s/${s.name}/`);
      await page.waitFor(`window.__flush !== undefined && document.getElementById("bump") !== null`);
      const mount = await page.eval("window.__mount");
      const text = await page.eval(`document.body.textContent.length`);
      const elements = await page.eval(`document.body.getElementsByTagName("*").length`);
      await page.send("Emulation.setCPUThrottlingRate", { rate: throttle });
      const first = await page.eval(loop(1, false));
      await page.eval(loop(300, false));
      const script = [];
      const layout = [];
      for (let i = 0; i < samples; i++) script.push(((await page.eval(loop(messages, false))) / messages) * 1000);
      for (let i = 0; i < samples; i++) layout.push((await page.eval(loop(messages, true))) / messages);
      await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });
      const shown = await page.eval(`document.body.textContent.length`);
      await page.close();
      result.rows.push({ subject: s.name, throttle, page: p, mount, first, script, layout, elements, text, shown });
      console.log(`${s.name.padEnd(26)} ${throttle}x #${p} mount ${mount.toFixed(2)} ms, first ${first.toFixed(3)} ms, µs/msg ${median(script).toFixed(2)}, +layout ms ${median(layout).toFixed(3)} (${elements} elements)`);
    }
  }
}
result.finished = new Date().toISOString();
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(result, null, 1));

// The table: medians over every sample of every page.
const fmt = (xs, d) => `${median(xs).toFixed(d)} [${quantile(xs, 0.25).toFixed(d)}–${quantile(xs, 0.75).toFixed(d)}]`;
console.log(`\n| subject | elements | mount ms, 1x | first message ms, 1x / 4x | µs per message, 1x | 4x | + forced layout ms, 1x | 4x |`);
console.log(`|---|--:|--:|--:|--:|--:|--:|--:|`);
for (const s of subjects) {
  const r1 = result.rows.filter((r) => r.subject === s.name && r.throttle === 1);
  const r4 = result.rows.filter((r) => r.subject === s.name && r.throttle === 4);
  console.log(
    `| ${s.name} | ${r1[0].elements} | ${fmt(r1.map((r) => r.mount), 2)} | ${median(r1.map((r) => r.first)).toFixed(3)} / ${median(r4.map((r) => r.first)).toFixed(3)} | ${fmt(r1.flatMap((r) => r.script), 2)} | ${fmt(r4.flatMap((r) => r.script), 2)} | ${fmt(r1.flatMap((r) => r.layout), 3)} | ${fmt(r4.flatMap((r) => r.layout), 3)} |`,
  );
}
server.close();
await browser.close();
