// Tables from bench.mjs's samples: per operation and subject, the median
// script milliseconds with its interquartile range and sample count, then
// the same for total and paint. Never a geometric mean: research 29's
// manager re-run moved one by 27 % while every per-operation median held.
//
//   node report.mjs out/cpu.json [--column=script|total|paint] [--vs=solid2,p2]

import { readFileSync } from "node:fs";
import { median, quantile } from "./lib/trace.mjs";

const file = process.argv[2] ?? "out/cpu.json";
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const data = JSON.parse(readFileSync(file, "utf8"));
const columns = arg("column", "script,total,paint").split(",");
const vs = arg("vs", "solid2,p2").split(",");

const benchmarks = [...new Set(data.samples.map((s) => s.benchmark))];
const subjects = [...new Set(data.samples.map((s) => s.subject))];
const cell = (subject, bench, col) => data.samples.filter((s) => s.subject === subject && s.benchmark === bench).map((s) => s[col]);
const fmt = (x) => (x < 10 ? x.toFixed(2) : x.toFixed(1));

console.log(`${data.chrome}, ${data.cpu}, taskset ${data.taskset ?? "none"}, n = ${data.n}, ${data.started} → ${data.finished ?? "?"}`);
console.log(`1-minute load at each batch start: ${data.batches.map((b) => `${b.benchmark.split("_")[0]} ${b.load.toFixed(2)}`).join(", ")}\n`);

for (const col of columns) {
  console.log(`**${col}**, median ms [interquartile range] (samples)\n`);
  console.log(`| subject | ${benchmarks.join(" | ")} |`);
  console.log(`|---|${benchmarks.map(() => "--:").join("|")}|`);
  for (const subject of subjects) {
    const cells = benchmarks.map((b) => {
      const xs = cell(subject, b, col);
      return xs.length === 0 ? "—" : `${fmt(median(xs))} [${fmt(quantile(xs, 0.25))}–${fmt(quantile(xs, 0.75))}] (${xs.length})`;
    });
    console.log(`| ${subject} | ${cells.join(" | ")} |`);
  }
  console.log("");
}

// Ratios of medians, script: each subject against each `vs` subject.
for (const other of vs) {
  if (!subjects.includes(other)) continue;
  console.log(`**script, median ÷ ${other}'s median** (below 1 is faster)\n`);
  console.log(`| subject | ${benchmarks.join(" | ")} |`);
  console.log(`|---|${benchmarks.map(() => "--:").join("|")}|`);
  for (const subject of subjects) {
    if (subject === other) continue;
    const cells = benchmarks.map((b) => {
      const a = median(cell(subject, b, "script"));
      const o = median(cell(other, b, "script"));
      return Number.isNaN(a) || Number.isNaN(o) ? "—" : (a / o).toFixed(2);
    });
    console.log(`| ${subject} | ${cells.join(" | ")} |`);
  }
  console.log("");
}
