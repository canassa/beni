// Tables of a plumbing.mjs result file (research 59).
//
//   node plumbing-report.mjs results/<file>.json [--base=p2]
//
// loop/profile: per subject, the median and IQR over runs, the median of the
// pages' medians, and the difference from `--base`.
// cdp: `performance.now()` is coarsened to 5 µs in the page, so one click's
// time is a multiple of 5 µs; means over many clicks are what resolve below
// that. Per subject: the mean over all clicks, the median of the pages'
// means with their range, and the mean in three bands of click number
// (how warm the code is).

import { readFileSync } from "node:fs";
import { median, quantile } from "./lib/trace.mjs";

const file = process.argv[2];
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const base = arg("base", "p2");
const r = JSON.parse(readFileSync(file, "utf8"));
const subjects = [...new Set(r.samples.map((s) => s.subject))];
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / Math.max(1, xs.length);
const us = (ns) => (ns / 1000).toFixed(2);
console.log(`${file}: ${r.mode}, page ${r.page}, ${r.started} – ${r.finished}, load ${r.loadAtStart?.[0]?.toFixed(2)} → ${r.loadAtEnd?.[0]?.toFixed(2)}, ${r.chrome}`);

if (r.mode === "cdp") {
  const bands = [
    [r.settings.from, 20],
    [21, 60],
    [61, r.settings.clicks],
  ];
  const baseMean = mean(r.samples.filter((s) => s.subject === base).map((s) => s.ns));
  console.log(`\n| subject | µs mean, all clicks | median of page means [range] | − ${base} | ${bands.map(([a, b]) => `clicks ${a}–${b}`).join(" | ")} |`);
  console.log(`|---|--:|--:|--:|${bands.map(() => "--:").join("|")}|`);
  for (const s of subjects) {
    const xs = r.samples.filter((x) => x.subject === s);
    const pages = [...new Set(xs.map((x) => x.page))].map((p) => mean(xs.filter((x) => x.page === p).map((x) => x.ns)));
    const m = mean(xs.map((x) => x.ns));
    console.log(`| ${s} | ${us(m)} | ${us(median(pages))} [${us(Math.min(...pages))}–${us(Math.max(...pages))}] | ${us(m - baseMean)} | ${bands.map(([a, b]) => us(mean(xs.filter((x) => x.click >= a && x.click <= b).map((x) => x.ns)))).join(" | ")} |`);
  }
} else {
  const baseXs = r.samples.filter((s) => s.subject === base).map((s) => s.ns);
  console.log(`\n| subject | ns median [IQR] over runs | median of page medians | − ${base} |`);
  console.log("|---|--:|--:|--:|");
  for (const s of subjects) {
    const xs = r.samples.filter((x) => x.subject === s);
    const pages = [...new Set(xs.map((x) => x.page))].map((p) => median(xs.filter((x) => x.page === p).map((x) => x.ns)));
    const ns = xs.map((x) => x.ns);
    console.log(`| ${s} | ${median(ns).toFixed(0)} [${quantile(ns, 0.25).toFixed(0)}–${quantile(ns, 0.75).toFixed(0)}] | ${median(pages).toFixed(0)} | ${(median(ns) - median(baseXs)).toFixed(0)} |`);
  }
}
