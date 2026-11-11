#!/usr/bin/env node
// The sanitiser corpus under the step 0 prototype (research report 111):
// each `tests/corpus/run` fixture that has a `.sanitize-lists-v2` file is
// built two times and run two times.
//
//   - The oracle: a plain build. No list is edited in place.
//   - The prototype: `--ownership=v3 --ownership-everywhere --sanitize-lists`.
//     Each write that the prototype accepts runs on a copy and poisons the
//     list it wrote, so a read of the old list throws (a trap).
//
// For each fixture the script says one of:
//
//   - `refused`: the prototype refuses the program (the build fails);
//   - `same`: the build passes and the run prints what the oracle prints;
//   - `trap`: the sanitised run throws a stale read, and the oracle does not;
//   - `differs`: the two runs print different text, or end differently.
//
// It also says what v2 does with the fixture: a `.sanitize-lists-v2-refuses`
// file means that v2 refuses it. A fixture that v2 accepts and the prototype
// refuses is a loss, counted by the prototype's cause.
//
//     TMPDIR=<a directory on disk> node bench/ownership-step0-sanitiser.mjs [--beni=zig-out/bin/beni] [--jobs=4] [--only=<text>] [--list] [--json=<file>]

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, ...v] = a.replace(/^--/, "").split("=");
    return [k, v.length ? v.join("=") : true];
  }),
);
const beni = resolve(repo, args.beni ?? "zig-out/bin/beni");
const jobs = Number(args.jobs ?? 4);
const scratch = mkdtempSync(join(tmpdir(), "beni-step0-san-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));

function run(cmd, argv, timeoutMs = 60000) {
  return new Promise((done) => {
    const child = spawn(cmd, argv, { cwd: repo });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      done({ code, signal, out, err });
    });
  });
}

function beniFiles(p) {
  return readdirSync(p, { withFileTypes: true })
    .sort((a, b) => a.name.localeCompare(b.name))
    .flatMap((e) => {
      if (e.isDirectory()) return e.name === "platform" || e.name.startsWith(".") ? [] : beniFiles(join(p, e.name));
      return e.name.endsWith(".beni") ? [join(p, e.name)] : [];
    });
}

// The fixtures: a file `X.beni` with `X.sanitize-lists-v2`, or a directory with `_expected.sanitize-lists-v2`.
const dir = join(repo, "tests/corpus/run");
const fixtures = [];
for (const e of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
  if (e.isDirectory()) {
    const base = join(dir, e.name, "_expected");
    if (!existsSync(`${base}.sanitize-lists-v2`)) continue;
    const platform = existsSync(join(dir, e.name, "platform", "beni.json")) ? join(dir, e.name, "platform") : "node";
    fixtures.push({ name: e.name, src: beniFiles(join(dir, e.name)), root: join(dir, e.name), platform, base });
  } else if (e.name.endsWith(".beni")) {
    const base = join(dir, e.name.slice(0, -5));
    if (!existsSync(`${base}.sanitize-lists-v2`)) continue;
    fixtures.push({ name: e.name.slice(0, -5), src: [join(dir, e.name)], root: null, platform: "node", base });
  }
}
const chosen = fixtures.filter((f) => !args.only || f.name.includes(args.only));

async function build(f, flags, out) {
  const argv = ["build", `--platform=${f.platform}`, ...flags, `--out=${out}`, ...(f.root && f.src.length > 1 ? [`--root=${f.root}`] : []), ...f.src];
  return run(beni, argv);
}

async function one(f, i) {
  const r = { name: f.name, v2: existsSync(`${f.base}.sanitize-lists-v2-refuses`) ? "refuses" : "accepts", v2crash: existsSync(`${f.base}.sanitize-lists-v2-crash`) };
  const o0 = join(scratch, `o-${i}`);
  const o3 = join(scratch, `s-${i}`);
  const plain = await build(f, [], o0);
  if (plain.code !== 0) return { ...r, status: "oracle-build-failed", detail: plain.err.split("\n")[0] };
  const oracle = await run("node", [join(o0, "_main.mjs")]);
  const san = await build(f, ["--ownership=v3", "--ownership-everywhere", "--sanitize-lists"], o3);
  if (san.signal !== null) return { ...r, status: "crash", detail: `the compiler died: ${san.signal}` };
  if (san.code !== 0) {
    const causes = {};
    for (const m of san.err.matchAll(/\bis\s+refused:\s+([a-z-]+)/g)) causes[m[1]] = (causes[m[1]] ?? 0) + 1;
    if (Object.keys(causes).length === 0) return { ...r, status: "crash", detail: san.err.split("\n").slice(0, 3).join(" | ") };
    return { ...r, status: "refused", causes };
  }
  const got = await run("node", [join(o3, "_main.mjs")]);
  rmSync(o0, { recursive: true, force: true });
  rmSync(o3, { recursive: true, force: true });
  if (/a stale read of a list/.test(got.err) && !/a stale read of a list/.test(oracle.err)) return { ...r, status: "trap", detail: (got.err.match(/beni: a stale read[^\n]*/) ?? [""])[0] };
  if (got.out !== oracle.out || got.code !== oracle.code) return { ...r, status: "differs", detail: `exit ${oracle.code} -> ${got.code}; ${got.err.split("\n")[0]}` };
  return { ...r, status: "same" };
}

const results = new Array(chosen.length);
let next = 0;
async function worker() {
  while (next < chosen.length) {
    const i = next++;
    results[i] = await one(chosen[i], i);
    process.stderr.write(`\r${i + 1}/${chosen.length} `);
  }
}
await Promise.all(Array.from({ length: jobs }, worker));
process.stderr.write("\n");

const count = (pred) => results.filter(pred).length;
console.log(`beni: ${beni}`);
console.log(`fixtures: ${results.length}\n`);
console.log("| | v2 accepts | v2 refuses | all |");
console.log("|---|---:|---:|---:|");
for (const s of ["same", "refused", "trap", "differs", "crash", "oracle-build-failed"]) {
  const a = count((r) => r.status === s && r.v2 === "accepts");
  const b = count((r) => r.status === s && r.v2 === "refuses");
  console.log(`| ${s} | ${a} | ${b} | ${a + b} |`);
}
const losses = {};
for (const r of results) if (r.status === "refused" && r.v2 === "accepts") for (const c of Object.keys(r.causes)) losses[c] = (losses[c] ?? 0) + 1;
console.log(`\nLosses against v2 (v2 accepts, the prototype refuses), by cause (a fixture counts once for each cause it has): ${JSON.stringify(losses)}`);
const bad = results.filter((r) => ["trap", "differs", "crash", "oracle-build-failed"].includes(r.status));
console.log(`\nTraps, differences and crashes: ${bad.length}`);
for (const r of bad) console.log(`- ${r.status} ${r.name} (v2 ${r.v2}${r.v2crash ? ", v2 golden says: must trap" : ""}): ${r.detail}`);
if (args.list) {
  console.log("\nEach fixture:");
  for (const r of results) console.log(`- ${r.name}: v2 ${r.v2}, prototype ${r.status}${r.causes ? " " + JSON.stringify(r.causes) : ""}`);
}
if (args.json) writeFileSync(resolve(args.json), JSON.stringify(results, null, 1));
