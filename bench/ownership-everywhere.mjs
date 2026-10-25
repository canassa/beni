#!/usr/bin/env node
// Ownership everywhere — the measurement of `ownership-checker.md` §30.2, as a
// script instead of an uncommitted patch (§30.7, slice O0).
//
// Every program of the corpus, the examples and the bench apps is checked
// under the hidden, test-only `--ownership-everywhere` flag: every platform
// enforces as `"lists": "in-place"` does, and every program constructor has
// the direct entry row. The first table counts programs, not demands, per
// row of §30.2; the second gives each rejected program's causes, read from
// `dump --stage=ownership` under the same flag; the third is the pass's
// cost, whole process, `--jobs=1 --no-cache`, best of 7.
//
//     zig build -Doptimize=ReleaseFast
//     node bench/ownership-everywhere.mjs [--beni=zig-out/bin/beni] [--jobs=N] [--runs=7] [--no-cost | --cost-only]
//
// Each `check` writes cache entries into a fresh directory of its own, as a
// default run would: the summary-block crash of §30.2 only showed when a
// run wrote them. A crash is a program whose `check` dies by a signal or
// exits with neither 0 nor 1; it is counted apart from the rejections.
//
// About a minute on a quiet 16-core machine, most of it the cost table.
//
// `--diff=<a>,<b>` (`ownership-v2.md` §7.2) is the whole-corpus verdict diff
// instead: every root above, core and every platform surface is dumped under
// `--ownership=<a>` and `--ownership=<b>` (`v1` or `v2`, hidden flags), with
// the same rows as the tables, and the verdict lines are compared per
// `(root, module, line:col)`. It prints three lists: the lines with the same
// verdict, those `<b>` accepts where `<a>` refused, and those `<b>` refuses
// where `<a>` accepted. A position one side reports and the other does not is
// an acceptance on the silent side, since a dump reports no line where it
// demands nothing. `--diff=v1,v1` is the diff's own control: every line the
// same. A side whose checker is not built stops the diff with exit 2.
//
//     node bench/ownership-everywhere.mjs --diff=v1,v2 [--beni=…] [--jobs=N] [--same]
//
// `--same` lists the lines of the first list as well; by default it is
// counted.

import { spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { availableParallelism } from "node:os";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, v] = a.replace(/^--/, "").split("=");
    return [k, v ?? true];
  }),
);
const beni = resolve(repo, args.beni ?? "zig-out/bin/beni");
const jobs = Number(args.jobs ?? Math.max(1, availableParallelism() - 2));
const runs = Number(args.runs ?? 7);
if (!existsSync(beni)) {
  console.error(`no beni at ${beni}: zig build -Doptimize=ReleaseFast`);
  process.exit(2);
}
const scratch = mkdtempSync(join(tmpdir(), "beni-own-everywhere-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));

// ---- the programs -----------------------------------------------------------

const corpus = join(repo, "tests/corpus");
const isDir = (p) => statSync(p).isDirectory();

/// The `.beni` files of a project, its own platform (`platform/`) left out.
function sources(dir, top = true) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      if (!(top && e.name.startsWith("platform"))) out.push(...sources(p, false));
    } else if (e.name.endsWith(".beni")) out.push(p);
  }
  return out.sort();
}

/// One program: a file, or a project directory checked from its root. A
/// project with a platform of its own is checked on it, as the corpus
/// builds it: `platform/` when present, otherwise `fallback`.
function program(row, path, fallback) {
  const name = relative(repo, path);
  if (!isDir(path)) return { row, name, platform: fallback, paths: [path], root: [] };
  const own = existsSync(join(path, "platform")) ? join(path, "platform") : null;
  // A page that drives a program kept outside the corpus names its sources
  // (`_expected.sources`, `tests/corpus/README.md`): that program is checked.
  // A file of several directories is one program whose files are copied
  // together, each at its path below its directory, as the corpus does.
  const named = join(path, "_expected.sources");
  const listed = existsSync(named) ? readFileSync(named, "utf8").split("\n").map((l) => l.trim()).filter(Boolean) : [];
  let dir = path;
  if (listed.length === 1) dir = join(repo, listed[0]);
  else if (listed.length > 1) {
    dir = mkdtempSync(join(scratch, "sources-"));
    for (const l of listed) cpSync(join(repo, l), dir, { recursive: true });
  }
  return { row, name, platform: own ?? fallback, paths: sources(dir), root: [`--root=${dir}`], dir };
}

/// Every file and project directly under `dir`, but the subdirectories in `skip`.
function programs(row, dir, platform, skip = []) {
  return readdirSync(dir)
    .filter((n) => !skip.includes(n) && (n.endsWith(".beni") || isDir(join(dir, n))))
    .sort()
    .map((n) => program(row, join(dir, n), platform));
}

const page = join(repo, "tests/platforms/page");
const browser = join(corpus, "browser");
const all = [
  ...programs("run/ (files and projects)", join(corpus, "run"), "node"),
  ...programs("browser/ top level and OwnPlatform", browser, page, ["dom", "tea", "inline"]),
  ...programs("browser/dom/", join(browser, "dom"), "browser"),
  ...programs("browser/tea/", join(browser, "tea"), "browser-tea"),
  // `browser-inline`'s pages and its application goldens; `build/bad/inline/`
  // is left out, since its projects are refused on purpose.
  ...programs("browser/inline/", join(browser, "inline"), "browser-inline"),
  ...programs("emit/inline/", join(corpus, "emit/inline"), "browser-inline"),
  ...programs("emit/release/inline/", join(corpus, "emit/release/inline"), "browser-inline"),
  ...["bike-wars", "conduit", "sternhalma"].map((n) => program("examples/", join(repo, "examples", n, "src"), "browser-tea")),
  ...["NoEditing", "NoRouting", "NoStorage", "Sandbox"].map((n) =>
    program("bench/ apps", join(repo, "bench/todomvc/apps/beni", `${n}.beni`), "browser-tea"),
  ),
  ...["beni/Main.beni", "micro/beni/Components", "micro/beni/Helpers", "micro/beni/Inline"].map((n) =>
    program("bench/ apps", join(repo, "bench/ui/apps", n), "browser-tea"),
  ),
  program("bench/ apps", join(repo, "bench/jfb/frameworks/keyed/beni-tea/src"), "browser-tea"),
  program("bench/corpus", join(repo, "bench/corpus"), "node"),
];

// ---- running them -----------------------------------------------------------

function run(argv) {
  return new Promise((done) => {
    const child = spawn(beni, argv, { cwd: repo });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code, signal) => done({ code, signal, out, err }));
  });
}

const ownershipCodes = new Set([
  "list_still_used",
  "top_level_list_changed",
  "list_may_be_shared",
  "view_changes_model",
  "record_still_used",
  "top_level_record_changed",
  "record_may_be_shared",
]);
let next = 0;

async function measure(p, i) {
  const platform = `--platform=${p.platform}`;
  const cache = `--cache-dir=${join(scratch, String(i))}`;
  const c = await run(["check", "--ownership-everywhere", "--diagnostics=json", platform, cache, ...p.root, ...p.paths]);
  p.crashed = c.signal !== null || (c.code !== 0 && c.code !== 1);
  if (p.crashed) {
    p.why = c.signal ?? `exit ${c.code}: ${c.err.split("\n")[0]}`;
    return;
  }
  let diags = [];
  try {
    diags = c.err.trim() ? JSON.parse(c.err) : [];
  } catch {
    p.why = `unreadable diagnostics: ${c.err.slice(0, 200)}`;
  }
  const errors = diags.filter((d) => d.severity === "error");
  p.codes = errors.filter((d) => ownershipCodes.has(d.code)).map((d) => d.code);
  p.other = errors.filter((d) => !ownershipCodes.has(d.code)).map((d) => d.code);
  p.rejected = p.codes.length > 0;
  if (!p.rejected) return;
  // The causes, under the same rows (§9's report, one line per demand).
  const d = await run(["dump", "--stage=ownership", "--ownership-everywhere", platform, ...p.root, p.dir ?? p.paths[0]]);
  p.lines = d.out
    .split("\n")
    .map((l) => l.match(/^\s+(\d+:\d+) (.*): (rejected ([\w-]+)|pending)(.*)$/))
    .filter(Boolean)
    .map((m) => ({ at: m[1], op: m[2], cause: m[4] ?? "pending", approx: /\(approx\)$/.test(m[5]) }));
}

async function worker() {
  while (next < all.length) {
    const i = next++;
    await measure(all[i], i);
  }
}
// ---- the whole-corpus verdict diff (`ownership-v2.md` §7.2) -----------------

/// One dump's verdict lines, by `module\tline:col`: whether any line at the
/// position refused (rejected or pending), and the lines themselves.
function verdicts(out) {
  const at = new Map();
  let module = "";
  for (const line of out.split("\n")) {
    const header = line.match(/^module (\S+)/);
    if (header) {
      module = header[1];
      continue;
    }
    const m = line.match(/^\s+(\d+:\d+) (.*?): (accepted|rejected|pending)\b(.*)$/);
    if (!m) continue;
    const key = `${module}\t${m[1]}`;
    const v = at.get(key) ?? { refused: false, lines: [] };
    v.refused ||= m[3] !== "accepted";
    v.lines.push(line.trim());
    at.set(key, v);
  }
  return at;
}

/// Every root the diff dumps: the programs of the tables, then core and every
/// platform surface, each with the arguments of its dump.
function diffRoots() {
  const roots = all.map((p) => ({ name: p.name, argv: [`--platform=${p.platform}`, ...p.root, p.dir ?? p.paths[0]] }));
  roots.push({ name: "core", argv: ["core"] });
  for (const p of ["node", "html", "browser", "browser-tea", "browser-inline"]) roots.push({ name: `platforms/${p}`, argv: [`--platform=${p}`, `platforms/${p}`] });
  return roots;
}

async function diff(sides) {
  const roots = diffRoots();
  const dumped = sides.map(() => new Array(roots.length));
  let at = 0;
  const work = async () => {
    while (at < roots.length) {
      const i = at++;
      for (const [s, side] of sides.entries()) {
        dumped[s][i] = await run(["dump", "--stage=ownership", "--ownership-everywhere", `--ownership=${side}`, ...roots[i].argv]);
      }
    }
  };
  await Promise.all(Array.from({ length: jobs }, work));

  // A side whose checker is not built has nothing to compare.
  for (const [s, side] of sides.entries()) {
    const unbuilt = dumped[s].find((r) => r.code === 2 && /is not built yet/.test(r.err));
    if (unbuilt) {
      console.error(`--ownership=${side}: ${unbuilt.err.trim()}`);
      process.exit(2);
    }
  }
  const failed = [];
  const same = [];
  const accepts = [];
  const refuses = [];
  for (const [i, root] of roots.entries()) {
    const [a, b] = dumped.map((d) => d[i]);
    const bad = [a, b].map((r, s) => (r.code === 0 ? null : `${sides[s]}: ${r.signal ?? `exit ${r.code}`} ${r.err.split("\n")[0]}`)).filter(Boolean);
    if (bad.length) {
      failed.push(`${root.name}: ${bad.join("; ")}`);
      continue;
    }
    const va = verdicts(a.out);
    const vb = verdicts(b.out);
    for (const key of [...new Set([...va.keys(), ...vb.keys()])].sort()) {
      const x = va.get(key) ?? { refused: false, lines: [] };
      const y = vb.get(key) ?? { refused: false, lines: [] };
      const [module, pos] = key.split("\t");
      const row = { where: `${root.name} ${module} ${pos}`, a: x.lines, b: y.lines };
      if (x.refused === y.refused) same.push(row);
      else if (x.refused) accepts.push(row);
      else refuses.push(row);
    }
  }
  const [a, b] = sides;
  const show = (rows, title, lines) => {
    console.log(`\n## ${title}: ${rows.length}\n`);
    if (!lines) return;
    for (const r of rows) {
      console.log(`- ${r.where}`);
      for (const l of r.a) console.log(`    ${a}: ${l}`);
      for (const l of r.b) console.log(`    ${b}: ${l}`);
      if (r.a.length === 0) console.log(`    ${a}: (no demand)`);
      if (r.b.length === 0) console.log(`    ${b}: (no demand)`);
    }
  };
  console.log(`# Ownership verdicts, --ownership=${a} against --ownership=${b}: ${roots.length} roots`);
  show(same, "The same verdict", !!args.same);
  show(accepts, `${b} accepts where ${a} refused`, true);
  show(refuses, `${b} refuses where ${a} accepted`, true);
  if (failed.length) {
    console.log(`\n## Roots not dumped: ${failed.length}\n`);
    for (const f of failed) console.log(`- ${f}`);
  }
  return failed.length ? 1 : 0;
}

if (args.diff) {
  const sides = String(args.diff).split(",");
  if (sides.length !== 2 || !sides.every((s) => s === "v1" || s === "v2")) {
    console.error("--diff takes two checkers, each v1 or v2: --diff=v1,v2");
    process.exit(2);
  }
  process.exit(await diff(sides));
}

if (!args["cost-only"]) {
  await Promise.all(Array.from({ length: jobs }, worker));

  // ---- the platforms' own modules and core (§28.7) ------------------------------

  const modules = [];
  for (const [what, argv] of [
    ["core", ["core"]],
    ...["node", "html", "browser", "browser-tea", "browser-inline"].map((p) => [p, [`--platform=${p}`, `platforms/${p}`]]),
  ]) {
    const r = await run(["dump", "--stage=ownership", "--ownership-totals", "--ownership-everywhere", ...argv]);
    const total = r.out.match(/^total (\d+): .* pending (\d+), rejected (\d+)$/m);
    modules.push({ what, demands: total ? +total[1] : null, pending: total ? +total[2] : null, rejected: total ? +total[3] : null, crashed: r.signal !== null || r.code !== 0 });
  }

  // ---- the tables ---------------------------------------------------------------

  const rows = [...new Set(all.map((p) => p.row))];
  console.log("## Programs rejected under `--ownership-everywhere`\n");
  console.log("| What | Platform | Programs | Rejected | Crashed | Other errors |");
  console.log("|---|---|---:|---:|---:|---:|");
  for (const row of rows) {
    const ps = all.filter((p) => p.row === row);
    const platforms = [...new Set(ps.map((p) => (p.platform.startsWith("/") ? (p.platform === page ? "tests/platforms/page" : "own") : p.platform)))].join(", ");
    const n = (f) => ps.filter(f).length;
    console.log(`| \`${row}\` | ${platforms} | ${ps.length} | **${n((p) => p.rejected)}** | ${n((p) => p.crashed)} | ${n((p) => p.other?.length)} |`);
  }
  const rejected = all.filter((p) => p.rejected);
  const n = (f) => all.filter(f).length;
  console.log(`\n**${n((p) => p.rejected)} of ${all.length} programs rejected; ${n((p) => p.crashed)} crashed.**\n`);

  console.log("| Module set | Demands | Pending | Rejected |");
  console.log("|---|---:|---:|---:|");
  for (const m of modules) console.log(`| ${m.what} | ${m.crashed ? "crash" : m.demands} | ${m.pending ?? "—"} | ${m.rejected ?? "—"} |`);

  console.log("\n## Rejected programs, by cause\n");
  console.log("A line's cause is its report's (`later-use`, `top-level`, `escaped`, `need`, …), `~` when approximate.\n");
  console.log("| Program | Platform | Lines | Causes |");
  console.log("|---|---|---:|---|");
  const byCause = new Map();
  for (const p of rejected) {
    const causes = new Map();
    for (const l of p.lines ?? []) {
      const key = (l.approx ? "~" : "") + l.cause;
      causes.set(key, (causes.get(key) ?? 0) + 1);
    }
    for (const k of causes.keys()) byCause.set(k, (byCause.get(k) ?? 0) + 1);
    const shown = [...causes].map(([k, v]) => `${k} ${v}`).join(", ");
    console.log(`| \`${p.name}\` | ${p.platform.startsWith("/") ? "own" : p.platform} | ${p.lines?.length ?? "?"} | ${shown} |`);
  }
  console.log("\n| Cause | Programs |");
  console.log("|---|---:|");
  for (const [k, v] of [...byCause].sort()) console.log(`| ${k} | ${v} |`);

  for (const p of all.filter((p) => p.crashed || p.other?.length)) {
    console.log(`\n- \`${p.name}\` on ${p.platform}: ${p.crashed ? `crashed (${p.why})` : `other errors: ${[...new Set(p.other)].join(", ")}`}`);
  }
}

// ---- the cost (§30.2, *Cost*) -------------------------------------------------

if (!args["no-cost"]) {
  const best = (argv) => {
    let min = Infinity;
    for (let i = 0; i < runs; i++) {
      const t = process.hrtime.bigint();
      const r = spawnSync(beni, argv, { cwd: repo });
      const ms = Number(process.hrtime.bigint() - t) / 1e6;
      if (r.status !== 0 && r.status !== 1) return NaN;
      min = Math.min(min, ms);
    }
    return min;
  };
  const cases = [
    ["Conduit", "browser-tea", "examples/conduit/src", true],
    ["Bike Wars", "browser-tea", "examples/bike-wars/src", true],
    ["`bench/corpus`", "node", "bench/corpus", true],
  ];
  console.log(`\n## Cost: whole process, \`--jobs=1 --no-cache\`, best of ${runs}\n`);
  console.log("| Program | Platform | Without | With the pass | Change |");
  console.log("|---|---|---:|---:|---:|");
  for (const [name, platform, path, both] of cases) {
    const base = ["check", "--jobs=1", "--no-cache", `--platform=${platform}`, path];
    const without = both ? best(base) : NaN;
    // On an in-place platform the pass already runs: "as today", no flag.
    const withPass = best(both ? [...base.slice(0, 1), "--ownership-everywhere", ...base.slice(1)] : base);
    const change = both ? `+${Math.round((withPass / without - 1) * 100)} %` : "—";
    console.log(`| ${name} | ${platform}${both ? "" : ", as today"} | ${both ? `${without.toFixed(0)} ms` : "—"} | ${withPass.toFixed(0)} ms | ${change} |`);
  }
}
