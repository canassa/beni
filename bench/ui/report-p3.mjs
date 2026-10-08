// Research 60's tables: per sweep point, each subject's traced and untraced
// script ms (median [interquartile range]) beside its bytes, and the ratio of
// each median to vanilla's. Reads the batches research 60 names.
//
//   node report-p3.mjs [--prefix=results/2026-10-08-p3]

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { root } from "./lib/serve.mjs";
import { median, quantile } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const prefix = arg("prefix", "results/2026-10-08-p3");
const load = (name) => {
  const f = join(root, `${prefix}-${name}.json`);
  return existsSync(f) ? JSON.parse(readFileSync(f, "utf8")) : { samples: [] };
};
const traced = ["flat", "lists", "burst-a", "burst-b"].flatMap((b) => load(`traced-${b}`).samples);
const untraced = ["flat", "lists", "burst-a", "burst-b"].flatMap((b) => load(`untraced-${b}`).samples);
const sizes = existsSync(join(root, `${prefix}-sizes.json`)) ? JSON.parse(readFileSync(join(root, `${prefix}-sizes.json`), "utf8")) : {};
const subjects = ["p3", "beni", "p2", "vanillajs", "solid1"];
const fmt = (x) => (x < 1 ? x.toFixed(3) : x < 10 ? x.toFixed(2) : x.toFixed(1));
const stat = (xs) => (xs.length === 0 ? null : { m: median(xs), lo: quantile(xs, 0.25), hi: quantile(xs, 0.75), n: xs.length });
const cell = (s) => (s === null ? "—" : `${fmt(s.m)} [${fmt(s.lo)}–${fmt(s.hi)}]`);

const points = [
  ["holes", "tick", 10, "holes", 10],
  ["holes", "tick", 10000, "holes", 10000],
  ["rows", "change", 30000, "rows", 30000],
  ["rows", "swap", 30000, "rows", 30000],
  ["live", "tick", 10000, "live", 10000],
  ["depth", "leaf", 128, "depth", 128],
  ...[1, 3, 10, 30, 100, 300, 1000].map((k) => ["burst", "burst", k, "holes", 1000]),
];
for (const [sweep, op, p, sizeSweep, sizePoint] of points) {
  const pick = (rows, s) => rows.filter((r) => r.sweep === sweep && r.op === op && r.param === p && r.subject === s).map((r) => r.script);
  const vt = stat(pick(traced, "vanillajs"));
  const vu = stat(pick(untraced, "vanillajs"));
  console.log(`\n### ${sweep} ${op} ${p}\n`);
  console.log("| subject | traced ms | ÷ vanilla | untraced ms | ÷ vanilla | bytes |");
  console.log("|---|--:|--:|--:|--:|--:|");
  for (const s of subjects) {
    const t = stat(pick(traced, s));
    const u = stat(pick(untraced, s));
    const bytes = sizes[sizeSweep]?.[sizePoint]?.[s === "beni" ? "beni" : s]?.brotli;
    const ratio = (a, b) => (a === null || b === null ? "—" : (a.m / b.m).toFixed(2));
    console.log(`| ${s} | ${cell(t)} | ${ratio(t, vt)} | ${cell(u)} | ${ratio(u, vu)} | ${bytes?.toLocaleString("en").replace(/,/g, " ") ?? "—"} |`);
  }
}
