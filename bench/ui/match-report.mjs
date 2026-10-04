// Research 56: tables from match.mjs's samples — per case and subject, the
// median script ms with its interquartile range (or the halves), and each
// median against Solid 1's. Never a geometric mean.
//
//   node match-report.mjs results/<file>.json [--vs=solid1]

import { readFileSync } from "node:fs";
import { median, quantile } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const data = JSON.parse(readFileSync(process.argv[2], "utf8"));
const vs = arg("vs", "solid1");
const subjects = [...new Set(data.samples.map((s) => s.subject))];
const f = (x) => (x < 1 ? x.toFixed(3) : x < 10 ? x.toFixed(2) : x.toFixed(1));
const cell = (xs) => (xs.length === 0 ? "—" : `${f(median(xs))} [${f(quantile(xs, 0.25))}–${f(quantile(xs, 0.75))}]`);

console.log(`${data.chrome}, mode ${data.mode}, ${data.pages} pages × ${data.samplesPerPage} samples, taskset ${data.taskset}, ${data.started} → ${data.finished ?? "?"}\n`);
const col = data.mode === "halves" ? "script" : "script";
console.log(`| case | ${subjects.join(" | ")} |`);
console.log(`|---|${subjects.map(() => "--:").join("|")}|`);
for (const c of data.cases) {
  const xs = (s) => data.samples.filter((r) => r.case === c && r.subject === s).map((r) => r[col]);
  console.log(`| ${c} | ${subjects.map((s) => cell(xs(s))).join(" | ")} |`);
}
if (subjects.includes(vs)) {
  console.log(`\n**median ÷ ${vs}'s median** (below 1 is faster)\n`);
  const others = subjects.filter((s) => s !== vs);
  console.log(`| case | ${others.join(" | ")} |`);
  console.log(`|---|${others.map(() => "--:").join("|")}|`);
  for (const c of data.cases) {
    const m = (s) => median(data.samples.filter((r) => r.case === c && r.subject === s).map((r) => r[col]));
    console.log(`| ${c} | ${others.map((s) => (Number.isNaN(m(s)) ? "—" : (m(s) / m(vs)).toFixed(2))).join(" | ")} |`);
  }
}
