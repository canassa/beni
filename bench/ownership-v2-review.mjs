#!/usr/bin/env node
// The measurements of research report 110 (the design review of ownership
// checker v2): what each checker costs and what it decides on the real code
// of the repository.
//
// For each root, `beni dump --stage=ownership --ownership-everywhere` runs
// under `--ownership=v1` and `--ownership=v2` with `--self-profile`, `--runs`
// times each. The table gives, per root:
//
//   - the lines of the modules that the ownership pass walked;
//   - the best time of the type check (`check` events), of v1's pass
//     (`ownership` events) and of v2's pass (`ownership2_module` events),
//     and the lines per second each one gives;
//   - with `--mode=check`, what the pass adds to the rest of the run: its
//     time against the wall time of the trace without it;
//   - v2's accounts: the declarations, the records they used, the records
//     per source unit, and the declarations stopped at the summary-size limit;
//   - each checker's verdicts: demands, accepted, rejected, pending.
//
// The roots are those of `bench/ownership-roots.mjs` that are not test
// fixtures: core, the platforms, the examples and the benchmark programs.
// `--roots=all` takes every root (slow), `--roots=<text>` those whose name
// contains the text.
//
//     zig build test-perf "-Dtest-filter=generated module of §7.6"   # installs zig-out/perf/bin/beni
//     TMPDIR=<a directory on disk> node bench/ownership-v2-review.mjs [--beni=zig-out/perf/bin/beni] [--runs=5] [--jobs=2] [--roots=real] [--json=<file>]
//
// Timing runs are sequential per root (`--jobs` only spreads roots), so use
// `--jobs=1` for numbers that go into a report.

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { o1Roots } from "./ownership-roots.mjs";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, ...v] = a.replace(/^--/, "").split("=");
    return [k, v.length ? v.join("=") : true];
  }),
);
const beni = resolve(repo, args.beni ?? "zig-out/perf/bin/beni");
const runs = Number(args.runs ?? 5);
const jobs = Number(args.jobs ?? 1);
const which = args.roots ?? "real";
const timeoutMs = Number(args.timeout ?? 120) * 1000;
// `--mode=check` times `beni check --no-cache` in place of the dump: the
// times of a build's own run of the pass. It prints no accounts and no
// verdicts, and it leaves out the roots that only a dump can read (core and
// the platforms).
const mode = args.mode ?? "dump";
if (!existsSync(beni)) {
  console.error(`no beni at ${beni}`);
  process.exit(2);
}
const scratch = mkdtempSync(join(tmpdir(), "beni-own2-review-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));

const isReal = (name) => name === "core" || /^(platforms|examples|bench)\//.test(name);
const dumpOnly = (name) => name === "core" || /^(platforms|tests\/platforms|bench\/schema-prototype)\//.test(name);
const roots = o1Roots(repo, scratch)
  .filter((r) => (which === "all" ? true : which === "real" ? isReal(r.name) : r.name.includes(which)))
  .filter((r) => mode === "dump" || !dumpOnly(r.name));
const command = mode === "check" ? ["check", "--no-cache"] : ["dump", "--stage=ownership"];

function run(argv) {
  return new Promise((done) => {
    const child = spawn(beni, argv, { cwd: repo });
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

const lineCount = new Map();
function linesOf(file) {
  if (!lineCount.has(file)) {
    let n = 0;
    try {
      n = readFileSync(resolve(repo, file), "utf8").split("\n").length - 1;
    } catch {
      n = 0;
    }
    lineCount.set(file, n);
  }
  return lineCount.get(file);
}

/// One trace: the summed duration (ms) of each phase, and the files of the
/// ownership pass's module events.
function readTrace(path, moduleEvent) {
  const events = JSON.parse(readFileSync(path, "utf8")).traceEvents;
  const ms = {};
  const files = new Set();
  let first = Infinity;
  let last = 0;
  for (const e of events) {
    if (e.ph !== "X") continue;
    ms[e.name] = (ms[e.name] ?? 0) + e.dur / 1000;
    first = Math.min(first, e.ts);
    last = Math.max(last, e.ts + e.dur);
    if (e.name === moduleEvent && e.args?.file) files.add(e.args.file);
  }
  return { ms, files: [...files], wall_ms: (last - first) / 1000 };
}

/// A dump's verdict totals and, for v2, its accounts.
function readDump(text) {
  const d = { demands: 0, accepted: 0, rejected: 0, pending: 0, kinds: {}, causes: {}, limits: [], accounts: [] };
  for (const line of text.split("\n")) {
    let m = line.match(/^total (\d+): accepted (\d+) \(([^)]*)\), pending (\d+), rejected (\d+)/);
    if (m) {
      d.demands += +m[1];
      d.accepted += +m[2];
      d.pending += +m[4];
      d.rejected += +m[5];
      for (const part of m[3].split(/[,;] /)) {
        const k = part.match(/^(\S+) (\d+)$/);
        if (k) d.kinds[k[1]] = (d.kinds[k[1]] ?? 0) + +k[2];
      }
      continue;
    }
    m = line.match(/^cause (\S+) (\d+)/);
    if (m) {
      d.causes[m[1]] = (d.causes[m[1]] ?? 0) + +m[2];
      continue;
    }
    m = line.match(/^\s+limit (\S+): /);
    if (m) {
      d.limits.push(m[1]);
      continue;
    }
    m = line.match(/^\s+account (\S+): source (\d+), baseline (\d+), growth (\d+) of (\d+), total (\d+), continuation (\d+) of (\d+), demands (\d+), walks (\d+), rounds (\d+)/);
    if (m) d.accounts.push({ decl: m[1], source: +m[2], baseline: +m[3], growth: +m[4], total: +m[6], continuation: +m[7], lane: +m[8], demands: +m[9], walks: +m[10], rounds: +m[11] });
  }
  return d;
}

async function measure(root, i) {
  const r = { name: root.name };
  for (const own of ["v1", "v2"]) {
    const moduleEvent = own === "v1" ? "ownership_module" : "ownership2_module";
    let best = null;
    let dump = null;
    for (let k = 0; k < runs; k += 1) {
      const trace = join(scratch, `t-${i}-${own}-${k}.json`);
      const c = await run([...command, "--ownership-everywhere", `--ownership=${own}`, "--jobs=1", `--self-profile=${trace}`, ...root.argv]);
      if (c.signal !== null || !existsSync(trace)) {
        r[own] = { failed: c.signal ?? `exit ${c.code}: ${c.err.split("\n")[0]}` };
        break;
      }
      const t = readTrace(trace, moduleEvent);
      rmSync(trace, { force: true });
      const own_ms = own === "v1" ? (t.ms.ownership ?? t.ms.ownership_module ?? 0) : (t.ms.ownership2_module ?? 0);
      const front_ms = (t.ms.lex ?? 0) + (t.ms.parse ?? 0) + (t.ms.lower ?? 0);
      // The rest of the run: the trace's wall time without the pass (one thread).
      const row = { own_ms, check_ms: t.ms.check ?? 0, front_ms, rest_ms: t.wall_ms - own_ms, files: t.files };
      if (best === null) best = row;
      else {
        if (row.own_ms < best.own_ms) {
          best.own_ms = row.own_ms;
          best.files = row.files;
        }
        best.check_ms = Math.min(best.check_ms, row.check_ms);
        best.front_ms = Math.min(best.front_ms, row.front_ms);
        best.rest_ms = Math.min(best.rest_ms, row.rest_ms);
      }
      dump = c.out;
    }
    if (best === null) continue;
    const lines = best.files.reduce((n, f) => n + linesOf(f), 0);
    r[own] = { ...best, files: best.files.length, lines, ...readDump(dump) };
  }
  return r;
}

const results = new Array(roots.length);
let next = 0;
async function worker() {
  while (next < roots.length) {
    const i = next++;
    results[i] = await measure(roots[i], i);
    process.stderr.write(`\r${i + 1}/${roots.length} `);
  }
}
await Promise.all(Array.from({ length: jobs }, worker));
process.stderr.write("\n");

const f1 = (x) => x.toFixed(1);
const kls = (lines, ms) => (ms > 0 ? `${Math.round(lines / ms)}k` : "-");
console.log(`beni: ${beni}`);
console.log(`mode: ${mode}; runs per checker: ${runs} (best time of each phase); roots: ${roots.length} (${which})\n`);
console.log("| root | lines | type check ms | v1 ms | v2 ms | check lines/s | v1 lines/s | v2 lines/s | v2 decls | v2 at limit | v2 records | records per source unit |");
console.log("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|");
const sum = { lines: 0, check: 0, v1: 0, v2: 0, decls: 0, limits: 0, records: 0, source: 0 };
for (const r of results) {
  if (r.v2?.failed || r.v1?.failed || !r.v1 || !r.v2) {
    console.log(`| ${r.name} | failed: v1 ${r.v1?.failed ?? "ok"}; v2 ${r.v2?.failed ?? "ok"} |`);
    continue;
  }
  const lines = r.v2.lines;
  const records = r.v2.accounts.reduce((n, a) => n + a.total, 0);
  const source = r.v2.accounts.reduce((n, a) => n + a.source, 0);
  const check = Math.min(r.v1.check_ms, r.v2.check_ms);
  console.log(
    `| ${r.name} | ${lines} | ${f1(check)} | ${f1(r.v1.own_ms)} | ${f1(r.v2.own_ms)} | ${kls(lines, check)} | ${kls(lines, r.v1.own_ms)} | ${kls(lines, r.v2.own_ms)} | ${r.v2.accounts.length + r.v2.limits.length} | ${r.v2.limits.length} | ${records} | ${source ? f1(records / source) : "-"} |`,
  );
  sum.lines += lines;
  sum.check += check;
  sum.v1 += r.v1.own_ms;
  sum.v2 += r.v2.own_ms;
  sum.decls += r.v2.accounts.length + r.v2.limits.length;
  sum.limits += r.v2.limits.length;
  sum.records += records;
  sum.source += source;
}
console.log(
  `| **all** | ${sum.lines} | ${f1(sum.check)} | ${f1(sum.v1)} | ${f1(sum.v2)} | ${kls(sum.lines, sum.check)} | ${kls(sum.lines, sum.v1)} | ${kls(sum.lines, sum.v2)} | ${sum.decls} | ${sum.limits} | ${sum.records} | ${sum.source ? f1(sum.records / sum.source) : "-"} |`,
);

if (mode === "check") {
  const adds = (d) => `+${Math.round((100 * d.own_ms) / d.rest_ms)} %`;
  console.log("\nWhat the pass adds to the rest of the run (the trace's wall time without the pass):\n");
  console.log("| root | rest of the run ms | v1 adds | v2 adds |");
  console.log("|---|---:|---:|---:|");
  for (const r of results) {
    if (!r.v1 || !r.v2 || r.v1.failed || r.v2.failed) continue;
    console.log(`| ${r.name} | ${f1(Math.min(r.v1.rest_ms, r.v2.rest_ms))} | ${adds(r.v1)} | ${adds(r.v2)} |`);
  }
}

// The verdicts and the accounts come from the dump.
if (mode === "dump") {
  console.log("\n| root | v1 demands | v1 accepted | v1 rejected | v1 pending | v2 demands | v2 accepted | v2 rejected | v2 pending | v2 causes |");
  console.log("|---|---:|---:|---:|---:|---:|---:|---:|---:|---|");
  const tot = { v1: [0, 0, 0, 0], v2: [0, 0, 0, 0] };
  for (const r of results) {
    if (!r.v1 || !r.v2 || r.v1.failed || r.v2.failed) continue;
    const row = (d) => [d.demands, d.accepted, d.rejected, d.pending];
    const causes = Object.entries(r.v2.causes).map(([k, v]) => `${k} ${v}`).join(", ");
    console.log(`| ${r.name} | ${row(r.v1).join(" | ")} | ${row(r.v2).join(" | ")} | ${causes} |`);
    row(r.v1).forEach((v, k) => (tot.v1[k] += v));
    row(r.v2).forEach((v, k) => (tot.v2[k] += v));
  }
  console.log(`| **all** | ${tot.v1.join(" | ")} | ${tot.v2.join(" | ")} | |`);

  // The declarations that cost the most records, and the distribution.
  const accounts = results.flatMap((r) => (r.v2?.accounts ?? []).map((a) => ({ root: r.name, ...a })));
  accounts.sort((a, b) => b.total - a.total);
  const totals = accounts.map((a) => a.total).sort((a, b) => a - b);
  const pct = (p) => totals[Math.min(totals.length - 1, Math.floor((p / 100) * totals.length))] ?? 0;
  console.log(`\nv2 declarations with an account: ${accounts.length}; records per declaration: median ${pct(50)}, p90 ${pct(90)}, p99 ${pct(99)}, max ${totals.at(-1) ?? 0}`);
  console.log(`declarations with no demand: ${accounts.filter((a) => a.demands === 0).length}; their share of all records: ${f1((100 * accounts.filter((a) => a.demands === 0).reduce((n, a) => n + a.total, 0)) / Math.max(1, sum.records))}%`);
  console.log("\nThe 15 declarations that cost the most records:\n");
  console.log("| root | declaration | source units | records | records per unit | demands | walks | rounds |");
  console.log("|---|---|---:|---:|---:|---:|---:|---:|");
  for (const a of accounts.slice(0, 15)) console.log(`| ${a.root} | ${a.decl} | ${a.source} | ${a.total} | ${f1(a.total / Math.max(1, a.source))} | ${a.demands} | ${a.walks} | ${a.rounds} |`);
  const limited = results.flatMap((r) => (r.v2?.limits ?? []).map((d) => `${r.name}: ${d}`));
  console.log(`\nDeclarations stopped at the summary-size limit: ${limited.length}`);
  for (const l of limited) console.log(`- ${l}`);
}

if (args.json) writeFileSync(resolve(args.json), JSON.stringify(results, null, 1));
