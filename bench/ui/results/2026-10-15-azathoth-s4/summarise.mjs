// Raw sample summaries; no trimming, averaging across operations, or rankings.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { median, quantile } from "../../lib/trace.mjs";
const dir = fileURLToPath(new URL("./", import.meta.url));
const subjects = ["vanillajs", "solid1", "solid2", "beni-release", "beni-direct-release", "p3"];
const labels = ["vanilla", "Solid 1", "Solid 2", "tea", "direct", "P3"];
const table = JSON.parse(readFileSync(dir + "table.json"));
const sweeps = JSON.parse(readFileSync(dir + "sweeps.json"));
const cell = (xs) => xs.length === 0 ? "—" : `${median(xs).toFixed(3)} [${quantile(xs, .25).toFixed(3)}–${quantile(xs, .75).toFixed(3)}] (${xs.length})`;
const header = (first) => `| ${first} | ${labels.join(" | ")} |\n|---|${subjects.map(() => "--:").join("|")}|\n`;
let text = "**Table: script ms at rate 1, median [p25–p75] (n).**\n\n" + header("operation");
for (const b of table.batches) text += `| ${b.benchmark} | ${subjects.map((name) => cell(table.samples.filter((s) => s.benchmark === b.benchmark && s.subject === name).map((s) => s.script))).join(" | ")} |\n`;
text += "\n";
for (const sweep of sweeps.sweeps) for (const op of sweep.ops) {
  text += `**${sweep.id} / ${op}: ${sweep.what}.**\n\n` + header(op === "stream" || sweep.id === "burst" ? "K" : "N");
  for (const p of sweep.params) text += `| ${p} | ${subjects.map((name) => cell(sweeps.samples.filter((s) => s.sweep === sweep.id && s.op === op && s.param === p && s.subject === name).map((s) => s.script))).join(" | ")} |\n`;
  text += "\n";
}
writeFileSync(dir + "timings.md", text);
const loads = [...table.batches, ...sweeps.batches].map((b) => b.load);
console.log(JSON.stringify({ tableSamples: table.samples.length, sweepSamples: sweeps.samples.length, loads: { min: Math.min(...loads), median: median(loads), max: Math.max(...loads) }, failures: sweeps.failures, skipped: sweeps.skipped, tableStarted: table.started, tableFinished: table.finished, sweepStarted: sweeps.started, sweepFinished: sweeps.finished }, null, 2));
