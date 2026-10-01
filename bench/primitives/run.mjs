#!/usr/bin/env node
// Core's small primitives — `String`'s, `Int32`'s, `Char`'s, `Basics`' — built by two
// compilers and timed against each other, in Node.
//
//     node bench/primitives/run.mjs --before-beni=<beni> [--after-beni=./zig-out/bin/beni]
//         [--before-core=<dir>] [--after-core=<dir>] [--dev] [--size=2000] [--rounds=5]
//         [--samples=9] [--sample-ms=10] [--only=compare,sort]
//
// Each compiler builds `bench/primitives/Primitives.beni` with its own
// embedded core, `--release --library` (`--dev` drops `--release`), so a
// change of core, of the compiler or of both is what is measured;
// `--before-core`/`--after-core` build with `--core-root` instead, to time two
// versions of core with one compiler.
//
// **Each build is timed in a process of its own**, the two alternating round
// by round (before first in odd rounds, after first in even ones): two builds
// imported into one process share V8's state, and the one loaded second was
// measured 1.3× slower than the first when both were the SAME build. In a
// round, a process times every workload: it makes its input with the build's
// own `strings`/`ints`, warms, then takes `--samples` samples, each calling
// the workload until `--sample-ms` has passed; its figure is the median
// sample. The table's figure is the median over rounds. Pin it
// (`taskset -c 8`) and quote the load average.

import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir, loadavg } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const options = {
  beforeBeni: null,
  afterBeni: "./zig-out/bin/beni",
  beforeCore: null,
  afterCore: null,
  release: true,
  size: 2000,
  rounds: 5,
  samples: 9,
  sampleMs: 10,
  only: null,
  child: null,
};
for (const arg of process.argv.slice(2)) {
  const [key, value] = arg.replace(/^--/, "").split("=");
  if (key === "before-beni") options.beforeBeni = value;
  else if (key === "after-beni") options.afterBeni = value;
  else if (key === "before-core") options.beforeCore = value;
  else if (key === "after-core") options.afterCore = value;
  else if (key === "dev") options.release = false;
  else if (key === "size") options.size = Number(value);
  else if (key === "rounds") options.rounds = Number(value);
  else if (key === "samples") options.samples = Number(value);
  else if (key === "sample-ms") options.sampleMs = Number(value);
  else if (key === "only") options.only = value;
  else if (key === "child") options.child = value;
  else {
    console.error(`unknown option ${arg}`);
    process.exit(2);
  }
}

const n = options.size;
// Each workload's name, and the input maker it is handed.
const workloads = [
  ["compare", "strings"],
  ["sort", "strings"],
  ["length", "strings"],
  ["slice", "strings"],
  ["indexes", "strings"],
  ["toInt", "numerals"],
  ["fromInt", "ints"],
  ["join", "strings"],
  ["words", "text"],
  ["split", "text"],
  ["fnv", "strings"],
  ["divisions", "ints"],
  ["chars", "strings"],
  ["math", "ints"],
].filter(([name]) => !options.only || options.only.split(",").includes(name));

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};

if (options.child) {
  // A release build exports each root under a short name; its `export`
  // statement lists them in the order the source declares them, as a
  // development build does with `Primitives$strings` and the rest.
  const file = join(options.child, "Primitives.mjs");
  const spelled = [...readFileSync(file, "utf8").matchAll(/export\s*\{([^}]*)\}/g)].at(-1)[1].split(",").map((s) => s.trim());
  const names = [...readFileSync("bench/primitives/Primitives.beni", "utf8").matchAll(/^pub (\w+) :/gm)].map((m) => m[1]);
  if (spelled.length !== names.length) throw new Error(`${spelled.length} exports for ${names.length} declarations`);
  const mod = await import(pathToFileURL(file).href);
  const m = Object.fromEntries(names.map((name, i) => [name, mod[spelled[i]]]));
  let sink = 0;
  const sample = (fn, input) => {
    const budget = options.sampleMs * 1e6;
    let calls = 0;
    const start = process.hrtime.bigint();
    let elapsed = 0n;
    do {
      sink ^= fn(input) === null ? 0 : 1;
      calls += 1;
      elapsed = process.hrtime.bigint() - start;
    } while (elapsed < budget);
    return Number(elapsed) / calls / 1000; // µs per call
  };
  const out = {};
  for (const [name, maker] of workloads) {
    const input = m[maker](n);
    sample(m[name], input);
    const got = [];
    for (let s = 0; s < options.samples; s++) got.push(sample(m[name], input));
    out[name] = median(got);
  }
  if (sink === 42) out.sink = sink;
  console.log(JSON.stringify(out));
  process.exit(0);
}

if (!options.beforeBeni) {
  console.error("give --before-beni=<beni>");
  process.exit(2);
}

const work = mkdtempSync(join(tmpdir(), "beni-primitives-bench-"));
process.on("exit", () => rmSync(work, { recursive: true, force: true }));

function build(name, beni, core) {
  const out = join(work, name);
  mkdirSync(out, { recursive: true });
  const r = spawnSync(resolve(beni), [
    "build", "--no-cache", "--library", "--platform=node", ...(options.release ? ["--release"] : []),
    ...(core ? [`--core-root=${resolve(core)}`] : []), `--out=${out}`, "bench/primitives/Primitives.beni",
  ], { encoding: "utf8" });
  if (r.status !== 0) {
    process.stderr.write(r.stderr ?? "");
    throw new Error(`${beni} build exited ${r.status}`);
  }
  return out;
}

const dirs = { before: build("before", options.beforeBeni, options.beforeCore), after: build("after", options.afterBeni, options.afterCore) };
const passOn = process.argv.slice(2).filter((a) => /^--(size|samples|sample-ms|only)=/.test(a));
const results = { before: [], after: [] };
const load = loadavg()[0];
for (let r = 0; r < options.rounds; r++) {
  for (const side of r % 2 === 0 ? ["before", "after"] : ["after", "before"]) {
    const run = spawnSync(process.execPath, [process.argv[1], `--child=${dirs[side]}`, ...passOn], { encoding: "utf8" });
    if (run.status !== 0) {
      process.stderr.write(run.stderr ?? "");
      throw new Error(`${side} round ${r} exited ${run.status}`);
    }
    results[side].push(JSON.parse(run.stdout.trim().split("\n").at(-1)));
  }
}

console.log(`node ${process.version}, n = ${n}, ${options.release ? "--release" : "development"}, ${options.rounds} rounds, load ${load.toFixed(1)} at start, ${loadavg()[0].toFixed(1)} at end; µs per call, median over rounds [range]\n`);
console.log("| workload | before | after | |\n|---|--:|--:|--:|");
for (const [name] of workloads) {
  const b = results.before.map((x) => x[name]);
  const a = results.after.map((x) => x[name]);
  const range = (xs) => `[${Math.min(...xs).toFixed(1)}–${Math.max(...xs).toFixed(1)}]`;
  console.log(`| \`${name}\` | ${median(b).toFixed(1)} ${range(b)} | ${median(a).toFixed(1)} ${range(a)} | ${(median(a) / median(b)).toFixed(2)}× |`);
}
