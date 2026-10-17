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

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
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

/// The `.beni` files of a project, its own platforms (`platform/`,
/// `platform-tea/`) left out.
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
/// builds it: `platform-tea/` when the row is `browser-tea` and the project
/// has one, else `platform/`; `fallback` when it has neither.
function program(row, path, fallback) {
  const name = relative(repo, path);
  if (!isDir(path)) return { row, name, platform: fallback, paths: [path], root: [] };
  const tea = fallback === "browser-tea" && existsSync(join(path, "platform-tea"));
  const own = tea ? join(path, "platform-tea") : existsSync(join(path, "platform")) ? join(path, "platform") : null;
  // A page that drives a program kept outside the corpus names its sources
  // (`_expected.sources`, `tests/corpus/README.md`): that program is checked.
  const named = join(path, "_expected.sources");
  const dir = existsSync(named) ? join(repo, readFileSync(named, "utf8").trim()) : path;
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
  ...programs("browser/ top level and OwnPlatform", browser, page, ["dom", "tea", "direct", "inline"]),
  ...programs("browser/dom/", join(browser, "dom"), "browser"),
  ...programs("browser/tea/", join(browser, "tea"), "browser-tea"),
  ...programs("browser/direct/", join(browser, "direct"), "browser-direct"),
  ...programs("browser/direct/ on browser-tea", join(browser, "direct"), "browser-tea"),
  // `browser-inline`'s pages and its application goldens; `build/bad/inline/`
  // is left out, since its projects are refused on purpose.
  ...programs("browser/inline/", join(browser, "inline"), "browser-inline"),
  ...programs("emit/inline/, emit/release/inline/", join(corpus, "emit/inline"), "browser-inline"),
  ...programs("emit/inline/, emit/release/inline/", join(corpus, "emit/release/inline"), "browser-inline"),
  ...["bike-wars", "conduit", "sternhalma"].map((n) => program("examples/", join(repo, "examples", n, "src"), "browser-tea")),
  ...["NoEditing", "NoRouting", "NoStorage", "Sandbox"].map((n) =>
    program("bench/ apps", join(repo, "bench/todomvc/apps/beni", `${n}.beni`), "browser-tea"),
  ),
  ...["beni/Main.beni", "micro/beni/Components", "micro/beni/Helpers", "micro/beni/Inline"].map((n) =>
    program("bench/ apps", join(repo, "bench/ui/apps", n), "browser-tea"),
  ),
  program("bench/ apps", join(repo, "bench/jfb/frameworks/keyed/beni-tea/src"), "browser-tea"),
  program("bench/ apps", join(repo, "bench/jfb/frameworks/keyed/beni-direct/src"), "browser-direct"),
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

const ownershipCodes = new Set(["list_still_used", "top_level_list_changed", "list_may_be_shared", "view_changes_model"]);
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
if (!args["cost-only"]) {
  await Promise.all(Array.from({ length: jobs }, worker));

  // ---- the platforms' own modules and core (§28.7) ------------------------------

  const modules = [];
  for (const [what, argv] of [
    ["core", ["core"]],
    ...["node", "html", "browser", "browser-direct", "browser-tea", "browser-inline"].map((p) => [p, [`--platform=${p}`, `platforms/${p}`]]),
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
  // §30.2 counts `browser/direct/`'s sources once: their second platform is
  // a row of the table, not more programs.
  const once = all.filter((p) => !p.row.endsWith(" on browser-tea"));
  const n = (f) => once.filter(f).length;
  console.log(`\n**${n((p) => p.rejected)} of ${once.length} programs rejected; ${n((p) => p.crashed)} crashed.**\n`);

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
    ["Conduit", "browser-direct", "examples/conduit/src", false],
    ["Bike Wars", "browser-tea", "examples/bike-wars/src", true],
    ["`bench/corpus`", "node", "bench/corpus", true],
  ];
  console.log(`\n## Cost: whole process, \`--jobs=1 --no-cache\`, best of ${runs}\n`);
  console.log("| Program | Platform | Without | With the pass | Change |");
  console.log("|---|---|---:|---:|---:|");
  for (const [name, platform, path, both] of cases) {
    const base = ["check", "--jobs=1", "--no-cache", `--platform=${platform}`, path];
    const without = both ? best(base) : NaN;
    // On `browser-direct` the pass already runs: "as today", no flag.
    const withPass = best(both ? [...base.slice(0, 1), "--ownership-everywhere", ...base.slice(1)] : base);
    const change = both ? `+${Math.round((withPass / without - 1) * 100)} %` : "—";
    console.log(`| ${name} | ${platform}${both ? "" : ", as today"} | ${both ? `${without.toFixed(0)} ms` : "—"} | ${withPass.toFixed(0)} ms | ${change} |`);
  }
}
