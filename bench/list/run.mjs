#!/usr/bin/env node
// `core/List`'s list-building functions, two versions of core against each
// other, in Node.
//
//     node bench/list/run.mjs --before-rev=<git rev> [--after=core]
//         [--beni=./zig-out/bin/beni] [--sizes=1000,10000,100000]
//         [--rounds=3] [--samples=9] [--sample-ms=10] [--only=map,filter]
//
// Builds `bench/list/ListBench.beni` twice with the same compiler and
// `--core-root`: once with core as it was at `--before-rev` (or the
// directory `--before=<dir>`), once with `--after` (default: this tree's
// `core/`). Then, for every workload and size, both builds are timed
// against the same input list, interleaved sample by sample so that load
// moves both alike. A sample calls the function until `--sample-ms` has
// passed and reports time per call; a round is `--samples` samples of each
// build, and the figure is the median over rounds of each round's median.
// One JSON line per (workload, size), then a table.
//
// `--before-beni=<beni>` builds the "before" side with another compiler:
// across a change of the list's REPRESENTATION (the array-backed `List`),
// the core and the emitter that agree on it have to be used together.
//
// Pin it (`taskset -c 8`) and quote the load average: this is a
// microbenchmark, and a busy machine moves it by tens of percent.

import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, cpSync } from "node:fs";
import { tmpdir, loadavg } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const options = {
  beni: "./zig-out/bin/beni",
  beforeBeni: null,
  before: null,
  beforeRev: null,
  after: "core",
  sizes: [1000, 10000, 100000],
  rounds: 3,
  samples: 9,
  sampleMs: 10,
  only: null,
};
for (const arg of process.argv.slice(2)) {
  const [key, value] = arg.replace(/^--/, "").split("=");
  if (key === "beni") options.beni = value;
  else if (key === "before-beni") options.beforeBeni = value;
  else if (key === "before") options.before = value;
  else if (key === "before-rev") options.beforeRev = value;
  else if (key === "after") options.after = value;
  else if (key === "sizes") options.sizes = value.split(",").map(Number);
  else if (key === "rounds") options.rounds = Number(value);
  else if (key === "samples") options.samples = Number(value);
  else if (key === "sample-ms") options.sampleMs = Number(value);
  else if (key === "only") options.only = new Set(value.split(","));
  else {
    console.error(`unknown option ${arg}`);
    process.exit(2);
  }
}
if (!options.before && !options.beforeRev) {
  console.error("give --before-rev=<git rev> or --before=<core dir>");
  process.exit(2);
}

const work = mkdtempSync(join(tmpdir(), "beni-list-bench-"));
process.on("exit", () => rmSync(work, { recursive: true, force: true }));

function run(cmd, args, input) {
  const r = spawnSync(cmd, args, { input, encoding: "buffer", maxBuffer: 1 << 28 });
  if (r.status !== 0) {
    process.stderr.write(r.stderr ?? "");
    throw new Error(`${cmd} ${args.join(" ")} exited ${r.status}`);
  }
  return r.stdout;
}

let beforeCore = options.before;
if (!beforeCore) {
  const tar = run("git", ["archive", options.beforeRev, "core"]);
  run("tar", ["-x", "-C", work], tar);
  beforeCore = join(work, "core");
}

async function build(name, core, beni = options.beni) {
  const out = join(work, name);
  mkdirSync(out, { recursive: true });
  run(beni, [
    "build", "--no-cache", "--library", "--platform=node",
    `--core-root=${resolve(core)}`, `--out=${out}`, "bench/list/ListBench.beni",
  ]);
  return import(pathToFileURL(join(out, "ListBench.mjs")).href);
}

const before = await build("before", beforeCore, options.beforeBeni ?? options.beni);
const after = await build("after", options.after);

// Each workload: how to make its input from a size, and how to call it.
const workloads = [
  ["map", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$map(xs)],
  ["filter", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$filter(xs)],
  ["filterMap", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$filterMap(xs)],
  ["indexedMap", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$indexedMap(xs)],
  ["take", (m, n) => m.ListBench$make(n), (m, xs, n) => m.ListBench$take(xs, n / 2)],
  ["append", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$append(xs)],
  ["concat", (m, n) => m.ListBench$chunks(n), (m, xs) => m.ListBench$concat(xs)],
  ["concatMap", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$concatMap(xs)],
  ["map2", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$map2(xs)],
  ["map3", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$map3(xs)],
  ["map5", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$map5(xs)],
  ["partition", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$partition(xs)],
  ["unzip", (m, n) => m.ListBench$pairs(n), (m, xs) => m.ListBench$unzip(xs)],
  ["intersperse", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$intersperse(xs)],
  ["sortWith", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$sortWith(xs)],
  ["foldl", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$foldl(xs)],
  ["foldr", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$foldr(xs)],
  ["sum", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$sum(xs)],
  ["reverse", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$reverse(xs)],
  ["length", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$length(xs)],
  ["member (absent)", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$member(xs)],
  ["== itself", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$equal(xs)],
  ["range", (m, n) => m.ListBench$make(n), (m, xs, n) => m.ListBench$range(n)],
  ["get (near end)", (m, n) => m.ListBench$make(n), (m, xs, n) => m.ListBench$get(xs, n)],
  ["last", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$last(xs)],
  ["set (middle)", (m, n) => m.ListBench$make(n), (m, xs, n) => m.ListBench$set(xs, n)],
  ["push", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$push(xs)],
  ["pop", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$pop(xs)],
  ["slice (a quarter)", (m, n) => m.ListBench$make(n), (m, xs, n) => m.ListBench$slice(xs, n)],
  ["drop (half)", (m, n) => m.ListBench$make(n), (m, xs, n) => m.ListBench$drop(xs, n)],
  ["[ x, ...xs ]", (m, n) => m.ListBench$make(n), (m, xs) => m.ListBench$cons(xs)],
];

let sink = 0;
function sample(call, m, xs, n) {
  const budget = options.sampleMs * 1e6;
  let calls = 0;
  const start = process.hrtime.bigint();
  let elapsed = 0n;
  do {
    const r = call(m, xs, n);
    sink ^= r === null ? 0 : 1;
    calls += 1;
    elapsed = process.hrtime.bigint() - start;
  } while (elapsed < budget);
  return Number(elapsed) / calls / 1000; // µs per call
}

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};

const rows = [];
const load = loadavg()[0];
for (const [name, make, call] of workloads) {
  if (options.only && !options.only.has(name)) continue;
  for (const n of options.sizes) {
    const inputs = { before: make(before, n), after: make(after, n) };
    // Warm both before any sample counts.
    sample(call, before, inputs.before, n);
    sample(call, after, inputs.after, n);
    const rounds = { before: [], after: [] };
    for (let r = 0; r < options.rounds; r++) {
      const got = { before: [], after: [] };
      for (let s = 0; s < options.samples; s++) {
        got.before.push(sample(call, before, inputs.before, n));
        got.after.push(sample(call, after, inputs.after, n));
      }
      rounds.before.push(median(got.before));
      rounds.after.push(median(got.after));
    }
    const row = {
      workload: name,
      n,
      before_us: +median(rounds.before).toFixed(2),
      after_us: +median(rounds.after).toFixed(2),
      before_rounds: rounds.before.map((x) => +x.toFixed(2)),
      after_rounds: rounds.after.map((x) => +x.toFixed(2)),
    };
    row.ratio = +(row.after_us / row.before_us).toFixed(2);
    rows.push(row);
    console.log(JSON.stringify(row));
  }
}

console.log(`\nnode ${process.version}, load ${load.toFixed(1)} at start, ${loadavg()[0].toFixed(1)} at end; µs per call, before → after (after ÷ before)\n`);
const sizes = options.sizes;
console.log(`| workload | ${sizes.map((n) => `n = ${n.toLocaleString("en")}`).join(" | ")} |`);
console.log(`|---|${sizes.map(() => "--:").join("|")}|`);
const byName = new Map();
for (const r of rows) {
  if (!byName.has(r.workload)) byName.set(r.workload, new Map());
  byName.get(r.workload).set(r.n, r);
}
for (const [name, cells] of byName) {
  const fmt = (r) => (r ? `${r.before_us} → ${r.after_us} (${r.ratio.toFixed(2)}×)` : "");
  console.log(`| \`${name}\` | ${sizes.map((n) => fmt(cells.get(n))).join(" | ")} |`);
}
if (sink === 42) console.log("");
