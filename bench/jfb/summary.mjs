// Markdown tables from one results directory of run.mjs (research 83):
// per-operation medians with their quartiles, total and script, and the
// table's own summary numbers — js-framework-benchmark's weighted geometric
// mean of each framework's factor over the fastest, with the weights and
// rules of webdriver-ts-results/src/Common.ts (`computeFactors`,
// `computeGeometricMean`) at the pinned commit: medians, factor = value /
// the smallest value of any framework in the table, CPU weights per
// benchmark, memory and size unweighted.
//
//   node bench/jfb/summary.mjs bench/jfb/results/<date>/<pass>
//   node bench/jfb/summary.mjs references/js-framework-benchmark/webdriver-ts/results.json \
//       --only=vanillajs-keyed,solid-v1.9.3-keyed,...   (the published run, those frameworks)

import { readFileSync } from "node:fs";
import { join } from "node:path";

const path = process.argv[2];
const only = process.argv.find((a) => a.startsWith("--only="))?.slice(7).split(",") ?? null;
const rows = JSON.parse(readFileSync(path.endsWith(".json") ? path : join(path, "results.json"), "utf8")).filter((r) => only === null || only.includes(r.framework));

const cpu = ["01_run1k", "02_replace1k", "03_update10th1k_x16", "04_select1k", "05_swap1k", "06_remove-one-1k", "07_create10k", "08_create1k-after1k_x2", "09_clear1k_x8"];
const cpuWeights = [0.64280248137063, 0.5607178150466176, 0.5643800750716564, 0.1925635870170522, 0.13200612879341714, 0.5277091212292658, 0.5644449600965534, 0.5508359820582848, 0.4225836631419211];
const mem = ["21_ready-memory", "22_run-memory", "25_run-clear-memory"];
const size = ["41_size-uncompressed", "42_size-compressed", "43_first-paint"];

const quantile = (sorted, q) => {
  const pos = (sorted.length - 1) * q;
  const lo = Math.floor(pos);
  return sorted[lo] + (sorted[Math.min(lo + 1, sorted.length - 1)] - sorted[lo]) * (pos - lo);
};
const stat = (values) => {
  const s = [...values].sort((a, b) => a - b);
  return { median: quantile(s, 0.5), q1: quantile(s, 0.25), q3: quantile(s, 0.75), n: s.length };
};
const short = (f) => f.replace(/-keyed$/, "");

const frameworks = [...new Set(rows.map((r) => r.framework))];
const lookup = (f, b, key) => rows.find((r) => r.framework === f && r.benchmark === b)?.values[key] ?? null;

const geomean = (benchmarks, key, weights) => {
  const medians = benchmarks.map((b) => frameworks.map((f) => (lookup(f, b, key) === null ? null : stat(lookup(f, b, key)).median)));
  const mins = medians.map((ms) => Math.min(...ms.filter((m) => m !== null)));
  return frameworks.map((_, fi) => {
    let sum = 0;
    benchmarks.forEach((_, bi) => {
      if (medians[bi][fi] !== null) sum += weights[bi] * Math.log(medians[bi][fi] / mins[bi]);
    });
    return Math.exp(sum / weights.reduce((a, b) => a + b, 0));
  });
};

const fmt = (x, d = 1) => x.toFixed(d);
const table = (title, benchmarks, key, digits, weights) => {
  const g = geomean(benchmarks, key, weights);
  const order = frameworks.map((f, i) => [f, g[i]]).sort((a, b) => a[1] - b[1]);
  console.log(`\n### ${title}\n`);
  console.log(`| framework | ${benchmarks.join(" | ")} | weighted geomean |`);
  console.log(`|---|${benchmarks.map(() => "--:").join("|")}|--:|`);
  for (const [f, gm] of order) {
    const cells = benchmarks.map((b) => {
      const v = lookup(f, b, key);
      if (v === null) return "—";
      const s = stat(v);
      return s.n > 1 ? `${fmt(s.median, digits)} [${fmt(s.q1, digits)}–${fmt(s.q3, digits)}]` : fmt(s.median, digits);
    });
    console.log(`| ${short(f)} | ${cells.join(" | ")} | ${gm.toFixed(2)} |`);
  }
};

table("CPU, total ms (click to paint), median [IQR]", cpu, "total", 1, cpuWeights);
table("CPU, script ms, median [IQR]", cpu, "script", 2, cpuWeights);
table("Memory, MB", mem, "DEFAULT", 2, mem.map(() => 1));
table("Size and first paint (kB, kB, ms)", size, "DEFAULT", 1, size.map(() => 1));
