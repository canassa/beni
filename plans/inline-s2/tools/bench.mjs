// node bench.mjs <scenario> <reps-mode quick|full> label=outdir ... : rr's event timing (script µs, median) on built apps, one Chrome, interleaved order.
import fs from "node:fs"; import path from "node:path";
const RR = process.env.RR;
const [scenario, mode, ...apps] = process.argv.slice(2);
const sel = await import(RR + "/harness/selection.js");
const sc = await sel.loadScenario(scenario);
const { benchHandler, eventReps } = await import(RR + "/harness/bench/lib/driver.js");
const { benchActions } = await import(RR + `/harness/bench/${scenario}.js`);
const { listen } = await import(RR + "/harness/tunnel.js");
const { launch } = await import(RR + "/harness/chrome.js");
const list = apps.map((a) => { const [label, dir] = a.split("="); return { label, dir, key: `x/${label}` }; });
const server = await listen(benchHandler(new Map(list.map((a) => [a.key, path.join(a.dir, "dist")]))), 0);
const base = `http://127.0.0.1:${server.address().port}`;
const FLAGS = ["--disable-background-networking", "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows", "--disable-gpu", "--enable-precise-memory-info", "--window-size=1280,1000"];
const chrome = await launch({ args: FLAGS, profilePrefix: "rr-bench-chrome-" });
const m = mode === "full" ? { warmup: 3, minReps: 10, maxReps: 20, chunk: 10, tol: 0.05 } : { warmup: 2, minReps: 5, maxReps: 5, chunk: 5, tol: 0.05 };
const med = (xs) => { const s = [...xs].sort((a, b) => a - b); return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2; };
const results = {};
const rounds = Number(process.env.ROUNDS || 2);
try {
  for (let round = 0; round < rounds; round++) {
    const order = round % 2 ? [...list].reverse() : list;
    for (const a of order) {
      const spec = JSON.parse(fs.readFileSync(path.join(a.dir, "spec.json"), "utf8"));
      const ctx = { spec, ref: sc.mod, actions: benchActions(spec, sc.mod) };
      const ev = await eventReps(chrome, `${base}/${a.key}/`, ctx, { ...m, waitMs: 40, minWaitMs: 20 });
      for (const s of ev.samples) ((results[s.half] ||= {})[a.label] ||= []).push(s.scriptUs);
      if (ev.failures.length) console.error(a.label, "failures", ev.failures.slice(0, 2));
    }
  }
} finally { await chrome.close(); server.close(); server.closeAllConnections?.(); }
const labels = list.map((a) => a.label);
console.log(["event", ...labels.map((l) => l + " µs"), ...labels.slice(1).map((l) => `${l}/${labels[0]}`)].join("\t"));
for (const [half, by] of Object.entries(results)) {
  const ms = labels.map((l) => (by[l] ? med(by[l]) : NaN));
  console.log([half, ...ms.map((x) => x.toFixed(0)), ...ms.slice(1).map((x) => (x / ms[0]).toFixed(2))].join("\t"));
}
