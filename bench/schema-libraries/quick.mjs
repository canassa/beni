// A short, bounded comparison over this harness's adapters and payloads:
// the rows a decision needs, not `run.mjs`'s full protocol. Each row runs in
// a fresh process of its own, as `run.mjs`'s workers do — in one process the
// rows' shared paths (`JSON.parse`, the sink) go megamorphic and move each
// other's figures by tens of percent. A row's cells are checked for
// correctness first (`correctness.mjs`), then each is calibrated to about
// `--batch-ms`, warmed, and sampled; a figure is the median per operation,
// and `--rounds` runs every row again in rotated order and keeps each cell's
// lowest median, as `analysis.mjs` does. It finishes in well under five
// minutes at the defaults (about half a minute on the recorded machine).
//
//     node bench/schema-libraries/beni/build.mjs
//     node bench/schema-libraries/quick.mjs [--rows=beni,beni-library,effect,…]
//         [--workloads=flat,list,…] [--samples=9] [--batch-ms=2] [--rounds=2] [--json]
//
// Caveats, which the report repeats: one machine, warmed code, registry
// installs are accepted (`run.mjs` refuses them), and the beni rows do not
// run the encode faults — a program value of the wrong type cannot reach a
// beni `print`, which the checker rejects before it runs.
import { spawnSync } from "node:child_process";
import { performance } from "node:perf_hooks";
import { cpus, loadavg } from "node:os";
import { fileURLToPath } from "node:url";
import { measurementCases } from "./fixtures.mjs";
import { auditAdapter } from "./correctness.mjs";
import { adapterPath, consume, rotate } from "./measure-common.mjs";

const options = {
  rows: ["json-floor", "handwritten", "typia", "valibot", "zod", "effect", "beni-library", "beni"],
  workloads: ["flat", "list", "union", "typeahead"],
  samples: 9,
  batchMs: 2,
  rounds: 2,
  json: false,
  child: null,
};
for (const arg of process.argv.slice(2)) {
  const [key, value] = arg.replace(/^--/, "").split("=");
  if (key === "rows") options.rows = value.split(",");
  else if (key === "workloads") options.workloads = value.split(",");
  else if (key === "samples") options.samples = Number(value);
  else if (key === "batch-ms") options.batchMs = Number(value);
  else if (key === "rounds") options.rounds = Number(value);
  else if (key === "json") options.json = true;
  else if (key === "child") options.child = value;
  else {
    console.error(`unknown option ${arg}`);
    process.exit(2);
  }
}

// The parent: each row in a fresh process, every round, then the table.
if (options.child === null) {
  const started = performance.now();
  const best = new Map();
  for (let round = 0; round < options.rounds; round++) {
    for (const row of rotate(options.rows, round)) {
      const args = [fileURLToPath(import.meta.url), `--child=${row}`, `--workloads=${options.workloads.join(",")}`, `--samples=${options.samples}`, `--batch-ms=${options.batchMs}`];
      const r = spawnSync(process.execPath, args, { encoding: "utf8", maxBuffer: 1 << 26 });
      if (r.status !== 0) {
        process.stderr.write(r.stderr);
        continue;
      }
      process.stderr.write(r.stderr);
      for (const line of r.stdout.split("\n").filter(Boolean)) {
        const cell = JSON.parse(line);
        const key = `${cell.workload} ${cell.direction} ${cell.path}\u0000${cell.row}`;
        if (!best.has(key) || cell.median_ns < best.get(key).median_ns) best.set(key, cell);
      }
    }
  }
  const results = [...best.values()];
  const seconds = (performance.now() - started) / 1000;
  const meta = { node: process.version, cpu: cpus()[0].model, load: loadavg().map((x) => x.toFixed(2)).join(" "), seconds: seconds.toFixed(1) };
  if (options.json) {
    console.log(JSON.stringify(meta));
    for (const r of results) console.log(JSON.stringify(r));
  } else {
    console.log(`node ${meta.node}, ${meta.cpu}, load ${meta.load}, ${meta.seconds} s`);
    const rows = options.rows.filter((row) => results.some((r) => r.row === row));
    const fmt = (ns) => (ns === undefined ? "—" : ns >= 100000 ? `${(ns / 1000).toFixed(0)} µs` : `${Math.round(ns)} ns`);
    console.log(["case".padEnd(34), ...rows.map((r) => r.padStart(13))].join(" "));
    const keys = [...new Set(results.map((r) => `${r.workload} ${r.direction} ${r.path}`))];
    for (const key of keys) {
      const line = rows.map((row) => fmt(best.get(`${key}\u0000${row}`)?.median_ns).padStart(13));
      console.log([key.padEnd(34), ...line].join(" "));
    }
  }
  process.exit(0);
}
options.rows = [options.child];

const root = new URL("./", import.meta.url);
const adapters = [];
for (const id of options.rows) {
  try {
    adapters.push(await import(adapterPath(root, id)));
  } catch (error) {
    console.error(`${id}: cannot import (${error.message}); is it installed? (npm ci, or beni/build.mjs)`);
  }
}
const all = (await measurementCases()).filter((c) => options.workloads.includes(c.workload));
const skipped = (adapter, c) =>
  (adapter.meta.workloads && !adapter.meta.workloads.includes(c.workload)) ||
  (adapter.meta.staticEncodeFaults && c.direction === "encode" && c.path !== "valid");

// Correctness first: a row that answers wrongly is reported and not timed.
const failed = new Set();
for (const adapter of adapters) {
  if (adapter.meta.id === "json-floor") continue;
  const cases = all.filter((c) => !skipped(adapter, c));
  const report = await auditAdapter({ adapter, cases, adversarial: [] });
  if (!report.passed) {
    failed.add(adapter.meta.id);
    console.error(`${adapter.meta.id}: ${report.failures.length} correctness failures, not timed`);
    for (const f of report.failures.slice(0, 5)) console.error("  ", JSON.stringify(f));
  }
}

let sink = 0;
function batch(run, input, n) {
  const start = performance.now();
  for (let i = 0; i < n; i++) sink = (sink + consume(run(input))) | 0;
  return ((performance.now() - start) * 1e6) / n;
}
function calibrate(run, input) {
  let n = 1;
  for (;;) {
    const start = performance.now();
    for (let i = 0; i < n; i++) sink = (sink + consume(run(input))) | 0;
    if (performance.now() - start >= options.batchMs || n >= 1 << 20) return n;
    n *= 2;
  }
}
const median = (xs) => [...xs].sort((a, b) => a - b)[xs.length >> 1];

// The child: one row, every case, one JSON line per cell.
for (const c of all) {
  for (const adapter of adapters) {
    if (failed.has(adapter.meta.id) || skipped(adapter, c)) continue;
    const input = adapter.meta.id === "json-floor" ? c.jsonFloorInput : c.input;
    const run = adapter.create(c.workload, c.direction);
    const n = calibrate(run, input);
    for (let i = 0; i < 10; i++) batch(run, input, n);
    const samples = Array.from({ length: options.samples }, () => batch(run, input, n));
    console.log(JSON.stringify({ workload: c.workload, direction: c.direction, path: c.path, row: adapter.meta.id, median_ns: median(samples), sink }));
  }
}
