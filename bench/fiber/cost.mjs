// Runtime cost ratchets. Public Beni programs, pinned Node, no runtime probes.
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { brotliCompressSync, constants } from "node:zlib";

const here = path.dirname(fileURLToPath(import.meta.url));
export const cases = [
  { name: "Parked", key: "parked", metric: "retained", counts: [2048, 4096], answer: () => "done" },
  { name: "ParkedDeferred", key: "parked-deferred", metric: "retained", counts: [2048, 4096], answer: () => "done" },
  { name: "Completed", key: "completed", metric: "retained", counts: [2048, 4096], answer: n => String(n * (n + 1) / 2) },
  { name: "SpawnJoin", key: "spawn-join", metric: "allocated", counts: [2048, 4096], answer: n => String(n * (n + 1) / 2) },
  { name: "FastPath", key: "fast-path", metric: "allocated", counts: [500000, 1000000], answer: String },
  { name: "Yield", key: "yield", metric: "allocated", counts: [2048, 4096], answer: String },
];
export const sizePrograms = ["S0Plain", "S1Start", "S2SpawnJoin", "S3ScopeFinalizer", "S4Cancel", "S5Queue"];
const flags = ["--jitless", "--predictable", "--trace-gc", "--expose-gc", "--max-semi-space-size=512", "--min-semi-space-size=512"];

function command(exe, args) {
  const p = spawnSync(exe, args, { encoding: "utf8", timeout: 120000, maxBuffer: 16 * 1024 * 1024 });
  if (p.error || p.status !== 0) throw new Error(`${exe} ${args.join(" ")}: ${p.error ?? p.status}\n${p.stdout}\n${p.stderr}`);
  return p.stdout;
}

export function buildCosts(beni, out) {
  fs.mkdirSync(out, { recursive: true });
  for (const c of cases) command(beni, ["build", "--release", "--no-source-maps", `--platform=${path.join(here, "cost/platform")}`, `--out=${path.join(out, c.name)}`, path.join(here, `cost/${c.name}.beni`)]);
}

function sample(root, c, n) {
  const text = command(process.execPath, [...flags, path.join(root, c.name, "_main.mjs"), String(n)]);
  const begin = text.indexOf("FIBER_COST_BEGIN\n");
  const end = text.indexOf("FIBER_COST_END ");
  if (begin < 0 || end < begin) throw new Error(`${c.key}: missing measurement markers\n${text}`);
  if (!text.slice(0, begin).includes("Mark-Compact") || !text.slice(end).includes("Mark-Compact")) throw new Error(`${c.key}: forced GC trace missing\n${text}`);
  const inside = text.slice(begin, end);
  if (c.metric === "allocated" && /Scavenge|Mark-Compact|Mark-sweep/.test(inside)) throw new Error(`${c.key}: GC inside allocation interval\n${inside}`);
  const read = prefix => {
    const lines = text.split("\n").filter(x => x.startsWith(prefix));
    if (lines.length !== 1) throw new Error(`${c.key}: expected one ${prefix} row\n${text}`);
    const row = JSON.parse(lines[0].slice(prefix.length));
    if (row.label !== c.key || row.count !== n) throw new Error(`${c.key}: wrong measurement ${JSON.stringify(row)}`);
    return row;
  };
  const allocated = read("FIBER_COST_END "), retained = read("FIBER_COST_RETAINED ");
  const plain = text.split("\n").filter(x => x && !x.startsWith("FIBER_COST_") && !/^\[\d+:/.test(x));
  if (plain.join("\n") !== c.answer(n)) throw new Error(`${c.key}: result ${plain}, expected ${c.answer(n)}`);
  return c.metric === "retained" ? retained.retained : allocated.allocated;
}

export function measureCosts(out) {
  const rows = {};
  for (const c of cases) {
    const [a, b] = c.counts;
    const small = sample(out, c, a), large = sample(out, c, b);
    rows[c.key] = { metric: c.metric, bytes: Math.round((large - small) / (b - a)), small, large, counts: c.counts };
  }
  return rows;
}

export const budgetAdvice = "Review bench/fiber/budgets.json; do not raise caps to hide a regression.\nMeasure: node bench/fiber/cost.mjs ./zig-out/bin/beni zig-out/fiber-cost\nRe-record verified hashes: zig build test-run-hashes -Dtest-filter='fiber '";

function costFailures(rows, budgets) {
  const failures = [];
  const expected = [...Object.keys(budgets.retained), ...Object.keys(budgets.allocated)].sort();
  if (JSON.stringify(Object.keys(rows).sort()) !== JSON.stringify(expected)) failures.push("cost cases and budget keys differ");
  if (process.version !== budgets.node) failures.push(`cost budgets require ${budgets.node}, got ${process.version}`);
  for (const [key, row] of Object.entries(rows)) {
    if (!Number.isSafeInteger(row.small) || !Number.isSafeInteger(row.large)) {
      failures.push(`${key}: invalid numeric sample`);
      continue;
    }
    const cap = budgets[row.metric]?.[key];
    if (!cap || !Number.isSafeInteger(cap.deltaBytes) || cap.deltaBytes < 0 || JSON.stringify(cap.counts) !== JSON.stringify(row.counts)) {
      failures.push(`${key}: invalid or mismatched budget ${JSON.stringify(cap)}`);
      continue;
    }
    const delta = row.large - row.small;
    if (delta > cap.deltaBytes) failures.push(`${key}: delta ${delta} bytes, budget ${cap.deltaBytes} (${delta - cap.deltaBytes} over)`);
  }
  return failures;
}

function rejectFailures(failures) {
  if (failures.length) throw new Error(`Fiber budget failures:\n${failures.join("\n")}\n${budgetAdvice}`);
}

export function checkCosts(rows, budgets) {
  rejectFailures(costFailures(rows, budgets));
}

export function costSlack(rows, budgets) {
  return Object.entries(rows).map(([key, row]) => {
    const count = row.counts[1] - row.counts[0];
    const delta = row.large - row.small;
    const cap = budgets[row.metric][key].deltaBytes;
    const actual = delta / count;
    const target = budgets.targets[key];
    return {
      case: key,
      bytesPerUnit: actual,
      slackDeltaBytes: cap - delta,
      slackBytesPerUnit: (cap - delta) / count,
      ...(target === undefined ? {} : { targetBytesPerUnit: target, distanceToTargetBytesPerUnit: Math.max(0, actual - target) }),
    };
  });
}

export function sizeSlack(rows, budgets) {
  return rows.map(row => ({ case: row.fiber, brotliBytes: row.brotli, slackBytes: budgets.brotli[row.fiber] - row.brotli }));
}

export function formatSlack(costs, sizes, budgets) {
  const lines = costSlack(costs, budgets).map(row =>
    `${row.case}: slack ${row.slackDeltaBytes} bytes (${row.slackBytesPerUnit.toFixed(3)} bytes/unit)` +
    (row.slackDeltaBytes > 0 ? "; review tightening budgets.json" : "") +
    (row.targetBytesPerUnit === undefined ? "" : `; target ${row.targetBytesPerUnit} bytes/unit, distance ${row.distanceToTargetBytesPerUnit.toFixed(3)} bytes/unit`));
  for (const row of sizeSlack(sizes, budgets)) lines.push(`${row.case}: slack ${row.slackBytes} brotli bytes${row.slackBytes > 0 ? "; review tightening budgets.json" : ""}`);
  return lines.join("\n") + "\n";
}

export function measureFiberSizes(beni, out, repo = path.resolve(here, "../..")) {
  for (const name of sizePrograms) {
    const dest = path.resolve(out, name);
    fs.rmSync(dest, { recursive: true, force: true });
    command(beni, ["build", "--release", "--no-source-maps", "--platform=node", `--out=${dest}`, path.join(repo, `tests/corpus/emit/release/app/Fiber${name}.beni`)]);
  }
  return measureBuiltSizes(out);
}

export function measureBuiltSizes(out) {
  const rows = [];
  for (const name of sizePrograms) {
    const dir = path.join(out, name);
    const files = fs.readdirSync(dir, { recursive: true }).filter(file => file.endsWith(".mjs")).sort();
    const bytes = Buffer.concat(files.map(file => fs.readFileSync(path.join(dir, file))));
    const brotli = brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: bytes.length } }).length;
    rows.push({ fiber: name, raw: bytes.length, brotli });
  }
  return rows;
}

function sizeFailures(rows, budgets) {
  const failures = [];
  if (JSON.stringify(rows.map(row => row.fiber).sort()) !== JSON.stringify(Object.keys(budgets.brotli).sort())) failures.push("size cases and budget keys differ");
  for (const row of rows) {
    const cap = budgets.brotli[row.fiber];
    if (!Number.isSafeInteger(row.brotli) || !Number.isFinite(cap)) failures.push(`${row.fiber}: invalid size sample or budget`);
    else if (row.brotli > cap) failures.push(`${row.fiber}: ${row.brotli} brotli bytes, budget ${cap} (${row.brotli - cap} over); raw ${row.raw}`);
  }
  return failures;
}

export function checkSizes(rows, budgets) {
  rejectFailures(sizeFailures(rows, budgets));
}

export function checkBudgets(costs, sizes, budgets) {
  rejectFailures([...costFailures(costs, budgets), ...sizeFailures(sizes, budgets)]);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [beni, out] = process.argv.slice(2);
  if (!beni || !out) throw new Error("usage: node bench/fiber/cost.mjs <beni> <output directory>");
  const budgets = JSON.parse(fs.readFileSync(path.join(here, "budgets.json")));
  buildCosts(path.resolve(beni), path.resolve(out));
  const costs = measureCosts(path.resolve(out));
  const sizes = measureFiberSizes(path.resolve(beni), path.resolve(out, "sizes"));
  console.log(JSON.stringify({ node: process.version, flags, costs, sizes, slack: { costs: costSlack(costs, budgets), sizes: sizeSlack(sizes, budgets) } }, null, 2));
  process.stderr.write(formatSlack(costs, sizes, budgets));
  checkBudgets(costs, sizes, budgets);
}
