// Tables from scaling.mjs's samples: per sweep and operation, one row per
// value of the parameter and one column per subject, each cell the median
// script milliseconds with its interquartile range. Then each subject's
// growth, as the log-log slope of its medians (0 is flat, 1 linear), and
// every value at which a beni build's median is above a Solid's.
//
//   node report-scaling.mjs results/<date>-scaling-full.json [--column=script@4,script@1,total@4,paint@4,gc@4]
//
// Never a geometric mean (rule 8): the medians are the result.

import { readFileSync } from "node:fs";
import { median, quantile } from "./lib/trace.mjs";

const file = process.argv[2];
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const columns = arg("column", "script@4,script@1,total@4").split(",").map((c) => c.split("@")).map(([c, t]) => [c, Number(t ?? 4)]);
const data = JSON.parse(readFileSync(file, "utf8"));
const fmt = (x) => (Number.isNaN(x) ? "—" : x < 1 ? x.toFixed(3) : x < 10 ? x.toFixed(2) : x.toFixed(1));
const order = ["beni", "beni-release", "beni-helper", "beni-helper-release", "solid2", "solid1", "p2", "vanillajs"];

console.log(`${data.chrome}, Node ${data.node}, ${data.beni} at ${data.commit.slice(0, 10)}${data.dirty ? " (dirty tree)" : ""}`);
console.log(`${data.cpu}, taskset ${data.taskset ?? "none"}, ${data.mode} mode: ${data.settings.pages} pages × ${data.settings.samples} samples per point at each of ${(data.settings.throttles ?? [data.throttle]).map((t) => `${t}x`).join(" and ")}, ${data.started} → ${data.finished ?? "?"}`);
const loads = data.batches.map((b) => b.load);
console.log(`1-minute load at batch starts: min ${Math.min(...loads).toFixed(2)}, median ${median(loads).toFixed(2)}, max ${Math.max(...loads).toFixed(2)}; failures: ${data.failures.length}\n`);

const slope = (ps, ms) => {
  const pts = ps.map((p, i) => [p, ms[i]]).filter(([, m]) => m > 0 && !Number.isNaN(m));
  if (pts.length < 2) return NaN;
  const [p0, m0] = pts[0];
  const [p1, m1] = pts.at(-1);
  return Math.log(m1 / m0) / Math.log(p1 / p0);
};
const growth = (s) => (Number.isNaN(s) ? "—" : s < 0.15 ? "flat" : s < 0.7 ? "sublinear" : s < 1.3 ? "linear" : "superlinear");

for (const sweep of data.sweeps) {
  for (const op of sweep.ops) {
    const rows = data.samples.filter((s) => s.sweep === sweep.id && s.op === op);
    if (rows.length === 0) continue;
    const params = sweep.params;
    const subjects = order.filter((s) => rows.some((r) => r.subject === s));
    const cell = (subject, p, col, t = 4) => rows.filter((r) => r.subject === subject && r.param === p && (r.throttle ?? 4) === t).map((r) => r[col]);
    console.log(`### ${sweep.id} / ${op}: ${sweep.what}\n`);
    const cols = (op === "stream" ? [["script", 4], ["gc", 4], ["paint", 4]] : columns).filter(([c, t]) => rows.some((r) => (r.throttle ?? 4) === t));
    for (const [col, t] of cols) {
      const unit = op === "stream" ? "ms per message" : "ms";
      console.log(`**${col}, CPU ${t}x**, median ${unit} [interquartile range] (samples)\n`);
      console.log(`| ${sweep.id === "burst" || sweep.id === "stream" ? "K" : "N"} | ${subjects.join(" | ")} |`);
      console.log(`|--:|${subjects.map(() => "--:").join("|")}|`);
      for (const p of params) {
        const cells = subjects.map((s) => {
          const xs = cell(s, p, col, t);
          return xs.length === 0 ? "—" : `${fmt(median(xs))} [${fmt(quantile(xs, 0.25))}–${fmt(quantile(xs, 0.75))}] (${xs.length})`;
        });
        console.log(`| ${p} | ${cells.join(" | ")} |`);
      }
      console.log("");
    }
    if (op === "stream") {
      console.log("**per 3 s window**: script ms, GC ms, heap growth KB (medians)\n");
      console.log(`| K | ${subjects.join(" | ")} |`);
      console.log(`|--:|${subjects.map(() => "--:").join("|")}|`);
      for (const p of params) {
        const cells = subjects.map((s) => {
          const rs = rows.filter((r) => r.subject === s && r.param === p);
          if (rs.length === 0) return "—";
          return `${fmt(median(rs.map((r) => r.scriptTotal)))} / ${fmt(median(rs.map((r) => r.gcTotal)))} / ${fmt(median(rs.map((r) => (r.heapAfter - r.heapBefore) / 1024)))}`;
        });
        console.log(`| ${p} | ${cells.join(" | ")} |`);
      }
      console.log("");
    }
    // Growth and crossovers, on script medians, at each throttle measured.
    for (const t of [...new Set(rows.map((r) => r.throttle ?? 4))].sort((a, b) => b - a)) {
      const med = (s) => params.map((p) => median(cell(s, p, "script", t)));
      console.log(`Growth of script at ${t}x, log-log slope first → last point (and over the last three): ${subjects
        .map((s) => {
          const m = med(s);
          const all = slope(params, m);
          const top = slope(params.slice(-3), m.slice(-3));
          return `${s} ${Number.isNaN(all) ? "—" : all.toFixed(2)} (${Number.isNaN(top) ? "—" : top.toFixed(2)}) ${growth(top)}`;
        })
        .join("; ")}.\n`);
      for (const b of subjects.filter((s) => s.startsWith("beni"))) {
        for (const sol of ["solid2", "solid1"]) {
          if (!subjects.includes(sol)) continue;
          const mb = med(b);
          const ms = med(sol);
          const slower = params.filter((p, i) => mb[i] > ms[i]);
          console.log(`- ${t}x: ${b} above ${sol} at: ${slower.length === 0 ? "nowhere" : slower.map((p) => `${p} (${fmt(mb[params.indexOf(p)])} vs ${fmt(ms[params.indexOf(p)])})`).join(", ")}`);
        }
      }
      console.log("");
    }
    const gcs = rows.filter((r) => r.gc > 0);
    if (op !== "stream" && gcs.length > 0) {
      console.log(`GC inside the click-to-paint window: ${subjects.map((s) => `${s} ${rows.filter((r) => r.subject === s && r.gc > 0).length}/${rows.filter((r) => r.subject === s).length} samples`).join(", ")}.\n`);
    }
  }
}
