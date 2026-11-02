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

export function checkCosts(rows, budgets) {
  const expected = [...Object.keys(budgets.retained), ...Object.keys(budgets.allocated)].sort();
  if (JSON.stringify(Object.keys(rows).sort()) !== JSON.stringify(expected)) throw new Error("cost cases and budget keys differ");
  if (process.version !== budgets.node) throw new Error(`cost budgets require ${budgets.node}, got ${process.version}`);
  for (const [key, row] of Object.entries(rows)) {
    if (!Number.isSafeInteger(row.small) || !Number.isSafeInteger(row.large)) throw new Error(`${key}: invalid numeric sample`);
    const cap = budgets[row.metric][key];
    if (!cap || !Number.isSafeInteger(cap.deltaBytes) || cap.deltaBytes < 0 || JSON.stringify(cap.counts) !== JSON.stringify(row.counts) || row.large - row.small > cap.deltaBytes) throw new Error(`${key}: ${JSON.stringify(row)}, budget ${JSON.stringify(cap)}`);
  }
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

export function checkSizes(rows, budgets) {
  if (JSON.stringify(rows.map(row => row.fiber).sort()) !== JSON.stringify(Object.keys(budgets.brotli).sort())) throw new Error("size cases and budget keys differ");
  for (const row of rows) {
    const cap = budgets.brotli[row.fiber];
    if (!Number.isSafeInteger(row.brotli) || !Number.isFinite(cap) || row.brotli > cap) throw new Error(`${row.fiber}: ${row.brotli} brotli bytes, budget ${cap}; raw ${row.raw}`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [beni, out] = process.argv.slice(2);
  if (!beni || !out) throw new Error("usage: node bench/fiber/cost.mjs <beni> <output directory>");
  const budgets = JSON.parse(fs.readFileSync(path.join(here, "budgets.json")));
  buildCosts(path.resolve(beni), path.resolve(out));
  const costs = measureCosts(path.resolve(out));
  const sizes = measureFiberSizes(path.resolve(beni), path.resolve(out, "sizes"));
  console.log(JSON.stringify({ node: process.version, flags, costs, sizes }, null, 2));
  checkCosts(costs, budgets);
  checkSizes(sizes, budgets);
}
