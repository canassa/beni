// ownership-v3-cache.mjs: the module cache under `--ownership=v3` gives what a run with no cache
// gives (`ownership-v3-kernel.md` §7.1), over every root of `bench/ownership-roots.mjs`.
//
// For each root, `beni check --ownership=v3 --ownership-everywhere --diagnostics=json` runs three
// times: with `--no-cache` (the oracle), then two times with a cache directory. Each run with the
// cache must have the oracle's exit code and its diagnostics, byte for byte. The second of them must
// install each module that it can: a root that checks clean has no miss.
//
// **One cache directory serves every root** (`<out>/cache`). The modules of `core/` and of a
// platform are stored by the first root that checks them and read by every other one, in a session
// with other symbols and other types: a block that held an id of a session (a field's text rank, a
// `TypeId`) would give that root another verdict. `--own-cache` gives each root a directory of its
// own instead.
//
//     TMPDIR=<disk> node bench/ownership-v3-cache.mjs <beni> <out> [jobs] [--roots=<text>] [--own-cache]
//
// It writes `<out>/RESULTS` (one line for each root: its name, the three exit codes, and the hits,
// misses and checked modules of the last run) and `<out>/FAULTS` (each root where a run with the
// cache differs from the oracle, with both outputs). It exits 1 when `FAULTS` has a line.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";

const args = process.argv.slice(2);
const flags = args.filter((a) => a.startsWith("--"));
const [beni, out, jobsArg] = args.filter((a) => !a.startsWith("--"));
const only = flags.find((f) => f.startsWith("--roots="))?.slice("--roots=".length);
const ownCache = flags.includes("--own-cache");
const repo = join(dirname(new URL(import.meta.url).pathname), "..");
const { o1Roots } = await import(join(repo, "bench/ownership-roots.mjs"));
mkdirSync(out, { recursive: true });
const scratch = mkdtempSync(join(process.env.TMPDIR, "roots-"));
const roots = o1Roots(repo, scratch).filter((r) => !only || r.name.includes(only));
const jobs = Number(jobsArg ?? 6);
const base = ["check", "--ownership=v3", "--ownership-everywhere", "--diagnostics=json"];

function run(argv) {
  return new Promise((res) => {
    const p = spawn("timeout", ["300", beni, ...argv], { cwd: repo });
    const outChunks = [];
    const errChunks = [];
    p.stdout.on("data", (d) => outChunks.push(d));
    p.stderr.on("data", (d) => errChunks.push(d));
    p.on("close", (code) => res({ code, stdout: Buffer.concat(outChunks).toString(), stderr: Buffer.concat(errChunks).toString() }));
  });
}

/// The cache counters of a `--self-profile` trace.
function counters(trace) {
  const c = { hits: 0, misses: 0, checked: 0 };
  let events;
  try { events = JSON.parse(readFileSync(trace, "utf8")).traceEvents; } catch { return c; }
  for (const e of events) {
    if (e.ph !== "C" || !e.args) continue;
    if (e.args.cache_hits !== undefined) c.hits = e.args.cache_hits;
    if (e.args.cache_misses !== undefined) c.misses = e.args.cache_misses;
    if (e.args.modules_checked !== undefined) c.checked = e.args.modules_checked;
  }
  return c;
}

const results = [];
const faults = [];
let next = 0;
async function one(r, i) {
  const cache = ownCache ? join(out, "caches", String(i)) : join(out, "cache");
  const trace = join(scratch, `trace-${i}.json`);
  const oracle = await run([...base, "--no-cache", ...r.argv]);
  const first = await run([...base, `--cache-dir=${cache}`, ...r.argv]);
  const second = await run([...base, `--cache-dir=${cache}`, `--self-profile=${trace}`, ...r.argv]);
  const c = counters(trace);
  rmSync(trace, { force: true });
  const same = (x) => x.code === oracle.code && x.stderr === oracle.stderr && x.stdout === oracle.stdout;
  let fault = null;
  if (!same(first)) fault = "the first run with the cache differs";
  else if (!same(second)) fault = "the second run with the cache differs";
  else if (oracle.code === 0 && c.misses !== 0) fault = `a root that checks clean has ${c.misses} misses in the second run`;
  results[i] = `${r.name} exit ${oracle.code} ${first.code} ${second.code} hits ${c.hits} misses ${c.misses} checked ${c.checked}`;
  if (fault) faults.push(`== ${r.name}: ${fault}\n-- no cache (exit ${oracle.code})\n${oracle.stderr}\n-- first (exit ${first.code})\n${first.stderr}\n-- second (exit ${second.code})\n${second.stderr}\n`);
}
async function worker() { while (next < roots.length) { const i = next++; await one(roots[i], i); } }
await Promise.all(Array.from({ length: jobs }, worker));
writeFileSync(join(out, "RESULTS"), results.join("\n") + "\n");
writeFileSync(join(out, "FAULTS"), faults.join("\n"));
rmSync(scratch, { recursive: true, force: true });
const warm = results.filter((l) => / misses 0 /.test(l)).length;
console.log(`${roots.length} roots, ${faults.length} faults, ${warm} with no miss in the second run`);
process.exit(faults.length === 0 ? 0 : 1);
