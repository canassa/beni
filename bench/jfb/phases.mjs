// Where an operation's click-to-paint time goes, from the runner's own
// traces (bench/jfb/work/webdriver-ts/traces/, one per measured iteration,
// kept until the next run): for each framework, the medians over its
// iterations of the main thread's script (FunctionCall), style
// (UpdateLayoutTree), Layout, PrePaint and Paint durations between the
// click and the first Commit after it. Research 83 §4 reads the swap with it.
//
//   node bench/jfb/phases.mjs 05_swap1k

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const traces = fileURLToPath(new URL("work/webdriver-ts/traces/", import.meta.url));
const id = process.argv[2] ?? "05_swap1k";
const phases = ["FunctionCall", "UpdateLayoutTree", "Layout", "PrePaint", "Paint", "total"];
const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};

const byFramework = new Map();
for (const file of readdirSync(traces).filter((f) => f.includes(`_${id}_`) && !f.startsWith("error-"))) {
  const framework = file.slice(0, file.indexOf(`_${id}_`)).replace(/-keyed$/, "");
  const raw = JSON.parse(readFileSync(join(traces, file), "utf8"));
  const events = raw.traceEvents ?? raw;
  const click = events.find((e) => e.name === "EventDispatch" && e.args?.data?.type === "click");
  if (click === undefined) continue;
  const main = events.filter((e) => e.pid === click.pid && e.tid === click.tid && e.ph === "X" && e.ts >= click.ts).sort((a, b) => a.ts - b.ts);
  const commit = main.find((e) => e.name === "Commit");
  if (commit === undefined) continue;
  const sums = Object.fromEntries(phases.map((p) => [p, 0]));
  // Top-level slices only: a Paint inside a Paint is counted once.
  let coveredUntil = 0;
  for (const e of main) {
    if (e.ts > commit.ts) break;
    if (!phases.includes(e.name) || e.ts < coveredUntil) continue;
    sums[e.name] += e.dur / 1000;
    coveredUntil = e.ts + e.dur;
  }
  sums.total = (commit.ts + commit.dur - click.ts) / 1000;
  if (!byFramework.has(framework)) byFramework.set(framework, []);
  byFramework.get(framework).push(sums);
}

console.log(`| framework (${id}, ms, median of n) | n | ${phases.join(" | ")} |`);
console.log(`|---|--:|${phases.map(() => "--:").join("|")}|`);
for (const [framework, runs] of [...byFramework].sort((a, b) => a[0].localeCompare(b[0])))
  console.log(`| ${framework} | ${runs.length} | ${phases.map((p) => median(runs.map((r) => r[p])).toFixed(1)).join(" | ")} |`);
