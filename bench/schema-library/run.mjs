#!/usr/bin/env node
// `core/Schema`'s library engine (`schema.md` §16, S3), measured: the size
// of a program that uses a small schema, and decode and encode timings of
// report 34's `flat` and `list` workloads — the numbers S4's specialised
// `parse` and `print` are to be compared with.
//
//     node bench/schema-library/run.mjs [--beni=./zig-out/bin/beni]
//         [--samples=15] [--sample-ms=20] [--json]
//
// **Size.** `SchemaSize.beni` is built with `--release` and the empty
// program beside it; each line is the whole output tree's raw, gzip-9 and
// brotli-11 bytes (`backend.md` §13: brotli primary).
//
// **Speed.** `SchemaBench.beni` is built with `--release --library`, and
// each workload is one exported function, called until `--sample-ms` has
// passed; a figure is the median over `--samples` samples of the time per
// call, with the interquartile range. `JSON.parse` and `JSON.stringify` of
// the same text are the floor every JSON schema pays. The payloads are
// report 34's (`bench/schema-libraries/payloads/`). Pin it (`taskset -c 8`)
// and quote the load average: this is a microbenchmark.

import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir, loadavg, cpus } from "node:os";
import { join, resolve, dirname } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { brotliCompressSync, gzipSync, constants } from "node:zlib";

const here = dirname(fileURLToPath(import.meta.url));
const options = { beni: "./zig-out/bin/beni", samples: 15, sampleMs: 20, json: false };
for (const arg of process.argv.slice(2)) {
  const [key, value] = arg.replace(/^--/, "").split("=");
  if (key === "beni") options.beni = value;
  else if (key === "samples") options.samples = Number(value);
  else if (key === "sample-ms") options.sampleMs = Number(value);
  else if (key === "json") options.json = true;
  else {
    console.error(`unknown option ${arg}`);
    process.exit(2);
  }
}

const work = mkdtempSync(join(tmpdir(), "beni-schema-library-"));
process.on("exit", () => rmSync(work, { recursive: true, force: true }));

function build(name, source, flags) {
  const dir = join(work, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Main.beni"), source);
  const r = spawnSync(resolve(options.beni), ["build", "--platform=node", ...flags, "."], { cwd: dir, encoding: "utf8" });
  if (r.status !== 0) {
    process.stderr.write(r.stdout + r.stderr);
    throw new Error(`building ${name} failed`);
  }
  return join(dir, "out");
}

// Every emitted file of a tree, in path order, as one buffer.
function bundle(out) {
  const files = [];
  const walk = (d) => {
    for (const e of readdirSync(d).sort()) {
      const p = join(d, e);
      if (statSync(p).isDirectory()) walk(p);
      else if (e.endsWith(".mjs")) files.push(readFileSync(p));
    }
  };
  walk(out);
  return { files: files.length, bytes: Buffer.concat(files) };
}

function sizes(name, out) {
  const { files, bytes } = bundle(out);
  return {
    program: name,
    files,
    raw_bytes: bytes.length,
    gzip_bytes: gzipSync(bytes, { level: 9 }).length,
    brotli_bytes: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length,
  };
}

const lines = [];
const sizeSource = readFileSync(join(here, "SchemaSize.beni"), "utf8");
const emptySource = 'import Node\n\n\nmain : Node.Program\nmain =\n    Node.print "{}"\n';
for (const [name, source] of [["empty", emptySource], ["SchemaSize", sizeSource]]) {
  for (const release of [false, true]) {
    const out = build(`${name}-${release ? "release" : "dev"}`, source, release ? ["--release", "--no-source-maps"] : ["--no-source-maps"]);
    lines.push({ size: true, release, ...sizes(name, out) });
  }
}

// The workloads.
const benchSource = readFileSync(join(here, "SchemaBench.beni"), "utf8");
const devOut = build("bench-dev", benchSource, ["--library", "--no-source-maps"]);
const relOut = build("bench-release", benchSource, ["--library", "--release", "--no-source-maps"]);
const order = readFileSync(join(devOut, "Main.mjs"), "utf8").match(/export\s*\{([^}]*)\}/)[1].split(",").map((s) => s.trim().replace(/^Main\$/, ""));
const relNames = readFileSync(join(relOut, "Main.mjs"), "utf8").match(/export\s*\{([^}]*)\}/)[1].split(",").map((s) => s.trim());
const m = await import(pathToFileURL(join(relOut, "Main.mjs")));
const fn = (name) => m[relNames[order.indexOf(name)]];

const payload = (w) => JSON.parse(readFileSync(join(here, "../schema-libraries/payloads", `${w}.json`), "utf8"));
const flat = Object.fromEntries(payload("flat").map((e) => [e.path, e.wire]));
const list = Object.fromEntries(payload("list").map((e) => [e.path, e.wire]));
const text = (v) => JSON.stringify(v);
const T = { flat: text(flat.valid), wrong: text(flat.wrong_type), missing: text(flat.missing_key), unknown: text(flat.unknown_key), list: text(list.valid) };
const user = fn("prepare")(T.flat);
const users = fn("prepareList")(T.list);

const workloads = [
  ["JSON.parse flat (floor)", () => JSON.parse(T.flat), null],
  ["parse flat valid", () => fn("parseUser")(T.flat), 0],
  ["read flat valid (no JSON.parse)", () => fn("readUser")(flat.valid), 0],
  ["parse flat wrong_type", () => fn("parseUser")(T.wrong), 1],
  ["parse flat missing_key", () => fn("parseUser")(T.missing), 1],
  ["parse flat unknown_key (Reject, AllErrors)", () => fn("parseUserAll")(T.unknown), 1],
  ["JSON.parse list (floor)", () => JSON.parse(T.list), null],
  ["parse list valid", () => fn("parseUsers")(T.list), 0],
  ["decode flat (typed to typed)", () => fn("decodeUser")(user), 0],
  ["JSON.stringify flat (floor)", () => JSON.stringify(flat.valid), null],
  ["print flat valid", () => fn("printUser")(user), 0],
  ["JSON.stringify list (floor)", () => JSON.stringify(list.valid), null],
  ["print list valid", () => fn("printUsers")(users), 0],
];

// Each workload's answer is checked before it is timed: issues counted.
for (const [name, f, expected] of workloads) {
  if (expected !== null && f() !== expected) throw new Error(`${name}: expected ${expected} issues, got ${f()}`);
}

function sample(f) {
  let calls = 0;
  const start = process.hrtime.bigint();
  const budget = BigInt(options.sampleMs) * 1000000n;
  let now = start;
  while (now - start < budget) {
    for (let i = 0; i < 64; i++) f();
    calls += 64;
    now = process.hrtime.bigint();
  }
  return Number(now - start) / calls;
}

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[s.length >> 1];
};
const quartile = (xs, q) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor((s.length - 1) * q)];
};

// Warm every workload, then interleave samples so load moves them alike.
for (const [, f] of workloads) sample(f);
const results = workloads.map(() => []);
for (let s = 0; s < options.samples; s++) workloads.forEach(([, f], i) => results[i].push(sample(f)));
workloads.forEach(([name], i) => {
  lines.push({ workload: name, median_ns: Math.round(median(results[i])), q1_ns: Math.round(quartile(results[i], 0.25)), q3_ns: Math.round(quartile(results[i], 0.75)) });
});

const meta = { node: process.version, cpu: cpus()[0].model, load: loadavg().map((x) => x.toFixed(2)).join(" ") };
if (options.json) {
  console.log(JSON.stringify(meta));
  for (const l of lines) console.log(JSON.stringify(l));
} else {
  console.log(`node ${meta.node}, ${meta.cpu}, load ${meta.load}`);
  for (const l of lines.filter((l) => l.size)) {
    console.log(`${(l.program + (l.release ? " --release" : "")).padEnd(24)} ${String(l.files).padStart(3)} files ${String(l.raw_bytes).padStart(7)} raw ${String(l.gzip_bytes).padStart(6)} gzip ${String(l.brotli_bytes).padStart(6)} brotli`);
  }
  for (const l of lines.filter((l) => l.workload)) {
    console.log(`${l.workload.padEnd(44)} ${String(l.median_ns).padStart(7)} ns  [${l.q1_ns}–${l.q3_ns}]`);
  }
}
