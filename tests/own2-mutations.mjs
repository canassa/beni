#!/usr/bin/env node
// The mutation harness of the ownership checker v2 (`docs/design/ownership-v2.md`
// §2.14, §7 item 7): each member of `src/own2/Mutate.zig`'s `Name` is one rule
// broken on purpose. A green suite says little until a rule's mutant fails it.
//
//     zig build test-own2-mutations
//     zig build test-own2-mutations -- --only=payload_prefix_off,once_off --jobs=2
//
// Each mutant is a child `zig build` of the compiler with
// `-Downership-v2-mutation=<name>`, self-hosted and into a prefix of its own, and
// runs the selection, in this order: the `run/Sanitiser` fixtures, the `ownership/`
// fixtures, and the `own2` unit tests. All three run for every mutant, so a line of
// the table says which of them pins the rule. They run without the v1/v2 parity net
// (`-Dno-v2-parity`): a fixture's own golden or sanitised run is a pin, and v1 goes at
// S10. A mutant nothing killed is a candidate, and a candidate must still pass the
// corpus as the gates run it: unfiltered, with the parity net, the stale check of
// `ownership-v2-known.txt` and core's parity (`staleKnown`, `coreParity`, which any
// `-Dcorpus` or `-Dno-v2-parity` turns off). It costs minutes, so only candidates
// pay. Any non-zero exit there is a pin, classified below.
// A plain build of the selection and of that net runs first as the control. A fixture
// that fails on the plain compiler (#2053's two on this machine) is left out of the
// net by `-Dcorpus-except`, since a failed fixture stops its kind before the stale
// check; with it out, the net must be green.
//
// A result is one of:
//     killed    a fixture or a unit test failed
//     blanket   more than half the selection failed: the mutant broke core or the
//               compiler, which says nothing of the rule (look at it, narrow it)
//     elsewhere the net failed a fixture's own golden or run outside the selection
//     v1 only   the net failed only by parity with v1, or core's parity
//     stale     the net failed only on a STALE line: a difference the known list
//               excuses is gone. A real pin and a weak one: it says a verdict moved,
//               not that any program went wrong
//     SURVIVED  the net exited 0: nothing pins this rule
//     timeout   the mutant used up --per; it hangs something (not a kill)
//     crash     the checker panicked on core while the checked core was made: a
//               safety check of its own fired, so no fixture was run
//     unbuilt   the child build failed: a hook that does not compile
//
// Budget: `--budget` seconds in all, 150 minutes by default, `--per` seconds a mutant, 2400 by
// default; what the budget leaves out is `not run` in the table. At five jobs a
// mutant takes about a minute of the wall clock, a candidate some minutes more, so all
// of them about two hours.
//
// The step fails on a survivor not in `tests/own2-mutations-survivors.txt`, which
// names each known survivor, its class (dead, redundant, equivalent, open) and why, on an entry there that no longer
// survives, on `unbuilt`, and on a red control. A filtered run (`--only`) checks
// only the names it ran. It writes `results.md` and `results.jsonl` under `--out`.

import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const zig = process.argv[2] ?? "zig";
const opts = { resume: false, jobs: 5, netJobs: 2, budget: 9000, per: 2400, out: "zig-out/own2-mutations", only: null, control: true };
for (const a of process.argv.slice(3)) {
  const [k, v] = a.replace(/^--/, "").split("=");
  if (k === "help") {
    console.log("--only=a,b  --jobs=N (5)  --net-jobs=N (2)  --budget=SECONDS (9000)  --per=SECONDS (2400)  --out=DIR  --no-control  --resume (keep results.jsonl's lines, run the rest)");
    process.exit(0);
  } else if (k === "only") opts.only = v.split(",");
  else if (k === "resume") opts.resume = true;
  else if (k === "net-jobs") opts.netJobs = Number(v);
  else if (k === "no-control") opts.control = false;
  else if (k === "out") opts.out = v;
  else if (k === "jobs" || k === "budget" || k === "per") opts[k] = Number(v);
  else {
    console.error(`unknown option ${a}`);
    process.exit(2);
  }
}

// The table: every member, with what it stands for and what it breaks.
const source = fs.readFileSync("src/own2/Mutate.zig", "utf8");
const body = source.slice(source.indexOf("pub const Name = enum {"), source.indexOf("/// The mutation of this build"));
const table = [...body.matchAll(/\/\/\/ ([^:]+): (.*)\.\n\s+(\w+),/g)].map(([, tags, doc, name]) => ({ name, tags, doc }));
const names = new Set(table.map((t) => t.name));
for (const n of opts.only ?? []) {
  if (!names.has(n)) {
    console.error(`no mutation ${n}`);
    process.exit(2);
  }
}
const chosen = opts.only ? table.filter((t) => opts.only.includes(t.name)) : table;

const known = new Map();
for (const line of fs.readFileSync("tests/own2-mutations-survivors.txt", "utf8").split("\n")) {
  if (!line.trim() || line.startsWith("#")) continue;
  const [name, cls] = line.split(" ");
  known.set(name, cls);
}

const selection = [
  { key: "sanitiser", args: ["test-blackbox-corpus", "-Dcorpus=run/Sanitiser", "-Dno-v2-parity"] },
  { key: "ownership", args: ["test-blackbox-corpus", "-Dcorpus=ownership/", "-Dno-v2-parity"] },
  { key: "unit", args: ["test", "-Dtest-filter=own2."] },
];

// At most `--net-jobs` candidates run the whole corpus at once: past that its slowest
// cases go over the hang guard.
const netWaiting = [];
let netFreeSlots = opts.netJobs;
const netSlot = () => (netFreeSlots > 0 ? (netFreeSlots--, Promise.resolve()) : new Promise((r) => netWaiting.push(r)));
const netFree = () => {
  const next = netWaiting.shift();
  if (next) next();
  else netFreeSlots++;
};

/// The corpus as the gates run it, less what fails on the plain compiler.
const net = () => ["test-blackbox-corpus", ...(except.length ? [`-Dcorpus-except=${except.join(",")}`] : [])];
let except = [];
const out = path.resolve(opts.out);
fs.mkdirSync(out, { recursive: true });
const started = Date.now();
const secs = () => Math.round((Date.now() - started) / 1000);

/// One child build, in a process group of its own so a deadline stops its tests.
function build(args, prefix, deadline) {
  return new Promise((resolve) => {
    const c = spawn(zig, ["build", ...args, "--prefix", prefix, `-Dharness-prefix=${prefix}`], { detached: true, stdio: ["ignore", "pipe", "pipe"] });
    let text = "";
    const take = (d) => {
      text += d;
      if (text.length > 1 << 24) text = text.slice(-(1 << 23));
    };
    c.stdout.on("data", take);
    c.stderr.on("data", take);
    let timedOut = false;
    const t = setTimeout(() => {
      timedOut = true;
      process.kill(-c.pid, "SIGKILL");
    }, Math.max(1000, deadline - Date.now()));
    c.on("close", (code) => {
      clearTimeout(t);
      resolve({ code, text, timedOut });
    });
  });
}

/// What a finished phase says: the fixtures or tests it names as failed.
function failures(key, r) {
  const fails = new Set();
  for (const m of r.text.matchAll(/^.*?FAIL (tests\/.+?): (\w+)$/gm)) fails.add(`${m[1]} (${m[2]})`);
  if (key === "unit") for (const m of r.text.matchAll(/^error: '(.+)' failed/gm)) fails.add(m[1]);
  return [...fails].sort();
}

/// What the gates' corpus said, whatever made it exit: a fixture's own failure,
/// parity with v1, core's dump or parity, a STALE line, a worker that died.
function netOf(b) {
  const fails = failures("net", b);
  const parity = fails.filter((f) => /\((OwnershipV2Differs|OwnershipV2Limit)\)$/.test(f)).length;
  const stale = [...b.text.matchAll(/^.*STALE ownership-v2-known\.txt: (.*)$/gm)].map((m) => m[1]);
  const core = /CoreDumpFailed|^\s*core: /m.test(b.text) ? 1 : 0;
  const worker = /CorpusWorkerFailed/.test(b.text) ? 1 : 0;
  const n = { fails: [...fails.slice(0, 100), ...stale.slice(0, 20).map((k) => `STALE ${k}`)], own: fails.length - parity, parity, stale: stale.length, core, worker, exit: b.code };
  n.count = fails.length + stale.length + core + worker || (b.code ? 1 : 0);
  return n;
}

function panicOf(text) {
  const m = text.match(/(?:thread \d+ )?panic: .*|reached unreachable code|integer overflow|index out of bounds.*/);
  return m ? m[0].slice(0, 120) : "";
}

const compileError = (text) => /\.zig:\d+:\d+: error: /.test(text);

async function runMutant(t) {
  const prefix = path.join(out, "p", t.name);
  const deadline = Date.now() + opts.per * 1000;
  const flag = t.name === "none" ? [] : [`-Downership-v2-mutation=${t.name}`];
  const r = { name: t.name, tags: t.tags, doc: t.doc, phases: {}, panic: "", result: "SURVIVED" };
  const began = Date.now();
  let log = "";
  for (const s of selection) {
    const b = await build([...s.args, ...flag], prefix, deadline);
    log += `---- ${s.key} exit ${b.code}\n${b.text.slice(-(1 << 20))}\n`;
    if (b.timedOut) {
      r.result = "timeout";
      r.phases[s.key] = { fails: [], timeout: true };
      break;
    }
    const fails = failures(s.key, b);
    r.phases[s.key] = { fails: fails.slice(0, 200), count: fails.length };
    r.panic ||= panicOf(b.text);
    if (b.code !== 0 && fails.length === 0) {
      // A failed build, or a test binary that died before it could name a test.
      r.phases[s.key].exit = b.code;
      if (compileError(b.text) || s.key !== "unit" || !panicOf(b.text)) {
        r.result = !compileError(b.text) && panicOf(b.text) ? "crash" : "unbuilt";
        r.why = (b.text.match(/.*\.zig:\d+:\d+: error: .*/) ?? [panicOf(b.text) || b.text.slice(-300)])[0].slice(0, 200);
        break;
      }
      r.phases[s.key].fails = ["(the unit tests died)"];
      r.phases[s.key].count = 1;
    }
  }
  const failed = () => Object.values(r.phases).reduce((a, p) => a + (p.count ?? 0), 0);
  if (r.result === "SURVIVED") {
    if (failed() > 0) r.result = controlSize && failed() > controlSize / 2 ? "blanket" : "killed";
    else if (t.name !== "none") {
      // A case over the hang guard on a loaded machine stops its whole part, the
      // stale check with it: it says nothing, so it runs again, and alone it is `timeout`.
      let b;
      for (let tries = 0; tries < 2; tries++) {
        await netSlot();
        b = await build([...net(), ...flag], prefix, deadline);
        netFree();
        log += `---- net exit ${b.code}\n${b.text.slice(-(1 << 21))}\n`;
        if (!b.text.includes("FAIL: test timed out")) break;
      }
      const n = netOf(b);
      r.phases.net = n;
      if (b.timedOut || b.text.includes("FAIL: test timed out")) r.result = "timeout";
      else if (b.code !== 0) r.result = n.own ? "elsewhere" : n.parity || n.core ? "v1 only" : n.stale ? "stale" : "elsewhere";
    }
  }
  fs.writeFileSync(path.join(out, `${t.name}.log`), log);
  fs.rmSync(prefix, { recursive: true, force: true });
  r.seconds = Math.round((Date.now() - began) / 1000);
  return r;
}

/// How many cases the selection has, to tell a blanket failure from a kill.
let controlSize = 0;
if (opts.control) {
  console.log("control: the selection on the plain compiler");
  const c = await runMutant({ name: "none", tags: "", doc: "control" });
  if (c.result !== "SURVIVED") {
    console.error(`the control is not green: ${c.result} ${JSON.stringify(c.phases).slice(0, 600)}`);
    process.exit(1);
  }
  const prefix = path.join(out, "p", "none");
  const whole = await build(net(), prefix, Date.now() + 3600000);
  except = failures("net", whole).map((f) => f.split(" ")[0]);
  if (whole.code !== 0) {
    const again = await build(net(), prefix, Date.now() + 3600000);
    if (again.code !== 0) {
      console.error(`the gates' corpus fails on the plain compiler, less ${except}: ${again.text.slice(-1500)}`);
      process.exit(1);
    }
  }
  fs.rmSync(prefix, { recursive: true, force: true });
  console.log(`control green in ${c.seconds} s; the net leaves out ${except.join(", ") || "nothing"}`);
}
const counted = fs.readdirSync("tests/corpus/ownership").filter((f) => f.endsWith(".beni")).length;
controlSize = counted + fs.readdirSync("tests/corpus/run").filter((f) => f.startsWith("Sanitiser") && f.endsWith(".beni")).length;

// Each mutant leaves about 0.7 GB in the local cache. Past 8 GB of it, once
// no build is running, what the mutants left is removed, and what the control
// built stays, so that no mutant builds the test binaries again.
const cache_limit = cacheBytes() + 8 * 2 ** 30;
const since = Date.now();
const cache_gone = [".zig-cache/o", ".zig-cache/h", ".zig-cache/z", ".zig-cache/tmp"];
function cacheBytes() {
  const r = spawnSync("du", ["-sb", ".zig-cache"], { encoding: "utf8" });
  return Number.parseInt(r.stdout, 10) || 0;
}
function pruneCache() {
  for (const d of cache_gone) {
    if (!fs.existsSync(d)) continue;
    for (const e of fs.readdirSync(d)) {
      const p = path.join(d, e);
      if (fs.lstatSync(p).mtimeMs > since) fs.rmSync(p, { recursive: true, force: true });
    }
  }
  console.log(`[${secs()} s] pruned the mutants' builds from .zig-cache`);
}

const results = [];
const already = new Set();
if (opts.resume && fs.existsSync(path.join(out, "results.jsonl"))) {
  for (const l of fs.readFileSync(path.join(out, "results.jsonl"), "utf8").split("\n")) {
    if (!l) continue;
    const r = JSON.parse(l);
    if (r.result === "unbuilt" || r.result === "timeout" || !chosen.some((t) => t.name === r.name)) continue;
    results.push(r);
    already.add(r.name);
  }
}
const queue = chosen.filter((t) => !already.has(t.name));
let running = 0;
let draining = null;
function afterMutant() {
  running--;
  if (!draining && cacheBytes() > cache_limit) {
    let open;
    draining = new Promise((r) => (open = r));
    draining.open = open;
  }
  if (draining && running === 0) {
    pruneCache();
    const d = draining;
    draining = null;
    d.open();
  }
}
const jsonl = fs.createWriteStream(path.join(out, "results.jsonl"), { flags: "a" });

function shortKill(r) {
  const parts = [];
  for (const [k, p] of Object.entries(r.phases)) if (p.count) parts.push(`${k} ${p.count}: ${p.fails.slice(0, 2).map((f) => f.split("/").pop()).join(", ")}`);
  return parts.join("; ");
}

async function worker() {
  while (queue.length) {
    if (draining) {
      await draining;
      continue;
    }
    const t = queue.shift();
    if (secs() >= opts.budget) {
      results.push({ ...t, result: "not run", phases: {} });
      continue;
    }
    running++;
    const r = await runMutant(t);
    results.push(r);
    afterMutant();
    jsonl.write(`${JSON.stringify(r)}\n`);
    console.log(`[${secs()} s, ${results.length}/${chosen.length}] ${t.name}: ${r.result} ${r.why ?? shortKill(r)}${r.panic ? ` (panic: ${r.panic})` : ""}`);
  }
}
await Promise.all(Array.from({ length: opts.jobs }, worker));
jsonl.end();

results.sort((a, b) => table.findIndex((t) => t.name === a.name) - table.findIndex((t) => t.name === b.name));
const cell = (r, k) => {
  const p = r.phases[k];
  if (!p) return "";
  if (p.timeout) return "timeout";
  if (k === "net") return p.exit ? [p.own && `${p.own} own`, p.parity && `${p.parity} parity`, p.stale && `${p.stale} STALE`, p.core && "core", p.worker && "worker"].filter(Boolean).join(", ") || `exit ${p.exit}` : "0";
  if (!p.count) return p.exit ? `exit ${p.exit}` : "0";
  const first = p.fails[0].split("/").pop().replace(/\.beni\b/, "");
  return p.count === 1 ? first : `${p.count}: ${first}, …`;
};
let md = `| Mutation | For | Breaks | Result | Class | run/Sanitiser | ownership/ | unit | the net |\n|---|---|---|---|---|---|---|---|---|\n`;
for (const r of results) md += `| \`${r.name}\` | ${r.tags} | ${r.doc.replaceAll("|", "\\|")} | ${r.result}${r.panic ? " (panics)" : ""} | ${r.result === "SURVIVED" ? known.get(r.name) ?? "" : ""} | ${cell(r, "sanitiser")} | ${cell(r, "ownership")} | ${cell(r, "unit")} | ${cell(r, "net")} |\n`;
fs.writeFileSync(path.join(out, "results.md"), md);

const tally = {};
for (const r of results) tally[r.result] = (tally[r.result] ?? 0) + 1;
console.log(`${results.length} mutations in ${secs()} s: ${JSON.stringify(tally)}; ${path.join(opts.out, "results.md")}`);

let bad = 0;
for (const r of results) {
  if (r.result === "SURVIVED" && !known.has(r.name)) {
    console.error(`${r.name}: ${r.result}, and tests/own2-mutations-survivors.txt does not name it`);
    bad++;
  }
  if (r.result !== "SURVIVED" && r.result !== "not run" && known.has(r.name)) {
    console.error(`${r.name} no longer survives (${r.result}): drop it from tests/own2-mutations-survivors.txt`);
    bad++;
  }
  if (r.result === "unbuilt") bad++;
}
process.exit(bad ? 1 : 0);
