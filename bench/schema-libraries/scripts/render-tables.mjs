import { readFile, writeFile } from "node:fs/promises";
import { ROWS, stats } from "../measure-common.mjs";
import { WORKLOADS } from "../spec.mjs";

// Descriptive report tables use the preselected first group, not whichever
// group later looks best. An unconverged fallback is printed, never hidden.
const capture = JSON.parse(await readFile(new URL("../results.json", import.meta.url), "utf8"));
if (!capture.complete) throw new Error("capture is incomplete");
const processes = capture.timing.processes.filter((item) => item.group === 0);
const f = (value) => value === null ? "—" : value.toFixed(value < 1000 && value > -1000 ? 1 : 0);
const choose = (row, workload, direction, path) => {
  const matches = processes.flatMap((process) => process.cells.filter((cell) => cell.row === row && cell.workload === workload && cell.direction === direction && cell.path === path && cell.summary));
  const converged = matches.filter((cell) => cell.warmup.converged);
  return (converged.length ? converged : matches).sort((a, b) => a.summary.median_ns_per_op - b.summary.median_ns_per_op)[0];
};

const output = [
  "Descriptive tables: **group 0**, lowest converged repetition median from its",
  "three fresh processes; p10/p90 are that same repetition's 35 batch samples.",
  "`†` means none of the group's repetitions met the bounded warm-up criterion;",
  "the lowest raw median is shown but excluded from stable-order conclusions.",
  "All groups, raw samples and flips are in `results.json`. Units: **ns/op**.",
  "Net columns subtract the corresponding JSON floor median, not quantiles.",
  "FJS has no decode row. Failure stringify nets are counterfactual, not work performed.",
  "",
];
for (const [direction, valid] of [["decode", true], ["decode", false], ["encode", true], ["encode", false]]) {
  output.push(`### ${direction === "decode" ? "Decode" : "Encode"} — ${valid ? "success" : "failure"}`, "");
  output.push(`| Workload | ${valid ? "" : "Fault | "}Row | Median | p10 | p90 | Net ${direction === "decode" ? "parse" : "stringify"} |`);
  output.push(`|---|${valid ? "" : "---|"}---|---:|---:|---:|---:|`);
  for (const workload of WORKLOADS) for (const path of valid ? ["valid"] : ["wrong_type", "missing_key", "unknown_key"]) {
    const floor = choose("json-floor", workload, direction, path);
    for (const row of ROWS) {
      const cell = choose(row, workload, direction, path);
      if (!cell) continue;
      const summary = stats(cell.samples_ns_per_op);
      const net = floor ? summary.median_ns_per_op - floor.summary.median_ns_per_op : null;
      output.push(`| ${workload} | ${valid ? "" : `${path} | `}${row}${cell.warmup.converged ? "" : "†"} | ${f(summary.median_ns_per_op)} | ${f(summary.p10_ns_per_op)} | ${f(summary.p90_ns_per_op)} | ${f(net)} |`);
    }
  }
  output.push("");
}
const rendered = output.join("\n");
if (process.argv.includes("--write-report")) {
  const reportUrl = new URL("../../../docs/design/research/34-compiled-schemas-in-javascript.md", import.meta.url);
  const report = await readFile(reportUrl, "utf8");
  const section = `## 3. Results\n\n${rendered}\n\n`;
  const updated = report.replace(/## 3\. Results\n[\s\S]*?(?=## 4\. Startup, browser size, and CSP)/, section);
  if (updated === report) throw new Error("report section 3 marker not found");
  await writeFile(reportUrl, updated);
} else {
  process.stdout.write(rendered);
}
