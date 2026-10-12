// js-framework-benchmark's own runner over beni and the frameworks we compare
// it with, and its own results table (research 83).
//
// The benchmark is the submodule references/js-framework-benchmark, pinned
// and sparse. Nothing is written into it: the run works in a copy,
// bench/jfb/work/ (git-ignored), where the official frameworks we run, the
// beni entries of bench/jfb/frameworks/ and every npm install, build, trace
// and result live. Steps, each skippable:
//
//   1. the submodule is initialised if it is not (shallow, sparse);
//   2. its files are copied into work/, with the official entries named by
//      --frameworks and the beni entries (their `src/Main.beni` is
//      bench/ui/apps/beni/Main.beni, the program bench/ui measures);
//   3. `npm ci` for the benchmark's server, webdriver-ts and
//      webdriver-ts-results, then `npm ci && npm run build-prod` for every
//      framework (the beni entries run $BENI, by default zig-out/bin/beni);
//   4. their server is started, and `isKeyed` and `isCSPCompliant` check
//      the beni entries;
//   5. `benchmarkRunner` runs the CPU, memory and size benchmarks for the
//      frameworks, in one batch, under `taskset` when --taskset is given;
//   6. `createResultJS` and the results app's `vite build` make the table;
//   7. results/<date>/ receives the raw result files, results.json, the
//      built table (report/) and meta.json (versions, load, wall time).
//
//   node bench/jfb/run.mjs [--frameworks=vanillajs,solid,...] [--count=N]
//       [--benchmarks=01_,02_] [--chrome=<path>] [--taskset=16-31]
//       [--port=8080] [--out=bench/jfb/results/<date>]
//       [--skip-install] [--skip-build] [--skip-run] [--headed] [--resume] [--checks-only]
//   node bench/jfb/run.mjs --report-only --out=bench/jfb/results/<date>
//
// --count replaces the runner's iteration counts (15 CPU runs, select 25, 1
// for memory and size) with its own `--count`, as `npm run bench -- --count`
// does. --report-only rebuilds report/ from a results directory's raw files.
// --resume keeps the work copy's results and only runs the missing pairs.
// --checks-only stops after the keyed and strict-CSP checks of the beni entries.

import { spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { cpus } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../..");
const submodule = join(repo, "references/js-framework-benchmark");
const work = join(here, "work");

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const flag = (name) => process.argv.includes(`--${name}`);

const official = ["vanillajs", "solid", "svelte", "react-hooks", "vue", "elm"];
const ours = readdirSync(join(here, "frameworks/keyed"));
const frameworks = arg("frameworks", [...official, ...ours].join(",")).split(",");
const count = arg("count", null);
const benchmarks = arg("benchmarks", null);
// Puppeteer and Playwright take a path, not a command name.
const chrome = arg("chrome", null) ?? spawnSync("sh", ["-c", "command -v google-chrome"], { encoding: "utf8" }).stdout.trim();
const taskset = arg("taskset", null);
const port = arg("port", "8080");
const date = new Date().toISOString().slice(0, 10);
const out = join(repo, arg("out", `bench/jfb/results/${date}`));
const beni = process.env.BENI ?? join(repo, "zig-out/bin/beni");
// The elm entry's `build-prod` starts with `elm-tooling install`, a tool its
// package.json does not list: the maintainers have it installed globally. A
// shim on PATH runs the published package instead; `elm-tooling install`
// then puts elm 0.19.1 (elm-tooling.json) in node_modules/.bin, which also
// stands in for the `elm` npm package's install script, which npm 11 does
// not run without an allowScripts policy.
const shims = join(work, ".bin");
const env = { ...process.env, PATH: `${shims}:${process.env.PATH}`, PORT: port, BENI: beni, LANG: "en_US.UTF-8", CHROMEDRIVER_SKIP_DOWNLOAD: "true", PUPPETEER_SKIP_DOWNLOAD: "true" };
const writeShims = () => {
  mkdirSync(shims, { recursive: true });
  writeFileSync(join(shims, "elm-tooling"), '#!/bin/sh\nexec npx --yes elm-tooling@1.21.0 "$@"\n', { mode: 0o755 });
};

const run = (cmd, args, cwd, extra = {}) => {
  console.log(`$ (${relative(repo, cwd) || "."}) ${cmd} ${args.join(" ")}`);
  const r = spawnSync(cmd, args, { cwd, stdio: "inherit", env: { ...env, ...extra } });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")}: exit ${r.status}`);
};
const text = (cmd, args) => spawnSync(cmd, args, { encoding: "utf8" }).stdout.trim();
const uptime = () => text("uptime", []);

// 1. The submodule, shallow and sparse: the benchmark and the entries we run.
const sparse = ["/*", "!/frameworks/", "!/broken-frameworks/", ...official.map((f) => `/frameworks/keyed/${f}/`)];
if (!existsSync(join(submodule, "webdriver-ts"))) {
  run("git", ["submodule", "update", "--init", "--depth", "1", "--filter=blob:none", "references/js-framework-benchmark"], repo);
  run("git", ["-C", submodule, "sparse-checkout", "set", "--no-cone", ...sparse], repo);
}
const commit = text("git", ["-C", submodule, "rev-parse", "HEAD"]);

// The results app reads its version line from App.tsx; ours names the
// Chrome that ran, and says the table is not an official release.
const chromeVersion = text(chrome, ["--version"]).replace(/^\D*/, "");
const setVersion = () => {
  const app = join(work, "webdriver-ts-results/src/App.tsx");
  writeFileSync(app, readFileSync(app, "utf8").replace(/const version = "[^"]*";/, `const version = "Chrome ${chromeVersion} (beni's run, not an official release)";`));
};

const startServer = async () => {
  const server = spawn("npm", ["start"], { cwd: join(work, "server"), env, stdio: ["ignore", "ignore", "inherit"], detached: true });
  for (let i = 0; i < 100; i++) {
    try {
      const res = await fetch(`http://localhost:${port}/ls`);
      if (res.ok) return server;
    } catch {}
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error("the benchmark's server did not start");
};
const stopServer = (server) => process.kill(-server.pid, "SIGTERM");

const report = () => {
  setVersion();
  run("node", ["dist/createResultJS.js"], join(work, "webdriver-ts"));
  run("npm", ["run", "build"], join(work, "webdriver-ts-results"));
  rmSync(join(out, "report"), { recursive: true, force: true });
  cpSync(join(work, "webdriver-ts-results/dist"), join(out, "report"), { recursive: true });
  cpSync(join(work, "webdriver-ts/results.json"), join(out, "results.json"));
};

if (flag("report-only")) {
  // The raw files of `out` are the only results the table sees.
  rmSync(join(work, "webdriver-ts/results"), { recursive: true, force: true });
  cpSync(join(out, "raw"), join(work, "webdriver-ts/results"), { recursive: true });
  const server = await startServer();
  try {
    report();
  } finally {
    stopServer(server);
  }
  process.exit(0);
}

// 2. The work copy. node_modules and builds survive from run to run;
// an entry built by an earlier run stays, and the runner and the table see
// only the frameworks named here (the table drops entries without results).
mkdirSync(work, { recursive: true });
cpSync(submodule, work, {
  recursive: true,
  filter: (src) => {
    const rel = relative(submodule, src);
    return rel !== ".git" && !rel.startsWith("frameworks") && !rel.startsWith("broken-frameworks") && !rel.split("/").includes("node_modules");
  },
});
mkdirSync(join(work, "frameworks/keyed"), { recursive: true });
mkdirSync(join(work, "frameworks/non-keyed"), { recursive: true });
writeShims();
const beniVersion = existsSync(beni) || beni === "beni" ? text(beni, ["version"]) : "";
for (const name of frameworks) {
  const dest = join(work, "frameworks/keyed", name);
  if (ours.includes(name)) {
    cpSync(join(here, "frameworks/keyed", name), dest, { recursive: true, dereference: true });
    // The version the table shows is the compiler's.
    const pkg = JSON.parse(readFileSync(join(dest, "package.json"), "utf8"));
    pkg["js-framework-benchmark"].frameworkVersion = beniVersion.replace(/^beni\s*/, "").split(/\s/)[0];
    writeFileSync(join(dest, "package.json"), JSON.stringify(pkg, null, 2) + "\n");
  } else {
    if (!existsSync(join(submodule, "frameworks/keyed", name))) throw new Error(`${name} is not in the sparse checkout; add it to the sparse paths`);
    cpSync(join(submodule, "frameworks/keyed", name), dest, { recursive: true, filter: (src) => !src.includes("/node_modules") && !src.endsWith("/dist") });
  }
}

// 3. Installs and builds.
if (!flag("skip-install")) {
  // The root package is only the maintainers' tooling (cli.js, eslint),
  // and its lock does not install under npm 11; the server is started
  // from server/, as the root's `npm start` does.
  for (const dir of ["server", "webdriver-ts", "webdriver-ts-results"])
    if (!existsSync(join(work, dir, "node_modules"))) run("npm", ["ci", "--no-audit", "--no-fund"], join(work, dir));
  run("npm", ["run", "compile"], join(work, "webdriver-ts"));
}
if (!flag("skip-build")) {
  for (const name of frameworks) {
    const dir = join(work, "frameworks/keyed", name);
    if (!existsSync(join(dir, "node_modules"))) run("npm", ["ci", "--no-audit", "--no-fund"], dir);
    run("npm", ["run", "build-prod"], dir);
  }
}
if (flag("skip-run")) process.exit(0);

// 4–6. The server, the keyed check, the benchmark and the table.
const server = await startServer();
const meta = {
  benchmarkCommit: commit,
  chrome: chromeVersion,
  node: process.version,
  beni: beniVersion,
  cpu: cpus()[0].model,
  cores: cpus().length,
  taskset,
  count: count === null ? "runner default (CPU 15, select 25, memory 1, size 1)" : Number(count),
  headless: !flag("headed"),
  frameworks,
  started: new Date().toISOString(),
  uptimeBefore: uptime(),
  load: [],
};
const t0 = Date.now();
try {
  const headless = flag("headed") ? [] : ["--headless"];
  // isKeyed prints ERROR and exits 0 when a check throws; either is a failure.
  const keyed = spawnSync("node", ["dist/isKeyed.js", ...headless, "--chromeBinary", chrome, "--framework", ...ours.filter((f) => frameworks.includes(f)).map((f) => `keyed/${f}`)], { cwd: join(work, "webdriver-ts"), env, encoding: "utf8" });
  const said = keyed.stdout + keyed.stderr;
  console.log(said.split("\n").filter((l) => / is (non-)?keyed for |ERROR/.test(l)).join("\n"));
  if (keyed.status !== 0 || /ERROR|Error in isKeyed/.test(said)) throw new Error(`isKeyed failed:\n${said}`);
  meta.isKeyed = said.split("\n").filter((l) => / is (non-)?keyed for /.test(l));
  // The strict-CSP check behind note 1139: an entry that fails it without
  // declaring the note, or declares it and passes, is an ERROR.
  const csp = spawnSync("node", ["dist/isCSPCompliant.js", ...headless, "--chromeBinary", chrome, "--framework", ...ours.filter((f) => frameworks.includes(f)).map((f) => `keyed/${f}`)], { cwd: join(work, "webdriver-ts"), env, encoding: "utf8" });
  const cspSaid = csp.stdout + csp.stderr;
  meta.csp = cspSaid.split("\n").filter((l) => /CSP|ERROR/.test(l) && !/^\s*args/.test(l));
  console.log(meta.csp.join("\n"));
  if (csp.status !== 0 || /ERROR/.test(cspSaid)) throw new Error(`isCSPCompliant failed:\n${cspSaid}`);
  if (flag("checks-only")) {
    stopServer(server);
    process.exit(0);
  }
  if (!flag("resume")) {
    rmSync(join(work, "webdriver-ts/results"), { recursive: true, force: true });
    rmSync(join(work, "webdriver-ts/traces"), { recursive: true, force: true });
  }
  // The runner exits 1 when any (framework, benchmark) failed, and its
  // README's remedy is to run that pair again; a pass leaves no result file
  // for it. Each missing pair is run again, at most twice.
  const runner = (fws, bms) => {
    const args = ["dist/benchmarkRunner.js", ...headless, "--chromeBinary", chrome, ...(count === null ? [] : ["--count", count]), ...(bms === null ? [] : ["--benchmark", ...bms]), "--framework", ...fws.map((f) => `keyed/${f}`)];
    const [cmd, all] = taskset === null ? ["node", args] : ["taskset", ["-c", taskset, "node", ...args]];
    console.log(`$ ${cmd} ${all.join(" ")}`);
    return spawnSync(cmd, all, { cwd: join(work, "webdriver-ts"), stdio: "inherit", env }).status;
  };
  const expected = ["01_run1k", "02_replace1k", "03_update10th1k_x16", "04_select1k", "05_swap1k", "06_remove-one-1k", "07_create10k", "08_create1k-after1k_x2", "09_clear1k_x8", "21_ready-memory", "22_run-memory", "25_run-clear-memory", "41_size-uncompressed"].filter(
    (id) => benchmarks === null || benchmarks.split(",").some((b) => id.startsWith(b) || (b.startsWith("40") && id.startsWith("41"))),
  );
  const missing = () => {
    const files = existsSync(join(work, "webdriver-ts/results")) ? readdirSync(join(work, "webdriver-ts/results")) : [];
    return frameworks.flatMap((f) =>
      expected.filter((id) => !files.some((file) => new RegExp(`^${f}(-v[^_]*)?-keyed_${id}\\.json$`).test(file))).map((id) => [f, id.startsWith("41") ? "40_" : id]),
    );
  };
  // The runner is a spawnSync, which blocks this process: the load is
  // sampled by a shell beside it, once a minute, into a file.
  const loadFile = join(work, "load.txt");
  writeFileSync(loadFile, "");
  const loadSampler = spawn("sh", ["-c", `while true; do echo "$(date +%H:%M) $(cut -d" " -f1 /proc/loadavg)" >> ${loadFile}; sleep 60; done`], { stdio: "ignore", detached: true });
  meta.retried = [];
  try {
    if (!flag("resume")) runner(frameworks, benchmarks === null ? null : benchmarks.split(","));
    for (let attempt = 0; attempt < 2 && missing().length > 0; attempt++)
      for (const [f, id] of missing()) {
        meta.retried.push(`${f} ${id}`);
        runner([f], [id]);
      }
  } finally {
    process.kill(-loadSampler.pid, "SIGTERM");
    meta.load = readFileSync(loadFile, "utf8").trim().split("\n");
    // More runnable threads than the cores outside --taskset: the pinned
    // cores were shared too, and the pass is not a quiet-machine measurement.
    meta.maxLoad = Math.max(...meta.load.map((l) => Number(l.split(" ")[1])));
    if (meta.maxLoad > 24) console.log(`WARNING: the 1-minute load reached ${meta.maxLoad} during the pass`);
  }
  if (missing().length > 0) throw new Error(`no result after two retries: ${missing().map((m) => m.join(" ")).join(", ")}`);
  meta.benchSeconds = Math.round((Date.now() - t0) / 1000);
  meta.uptimeAfter = uptime();
  mkdirSync(out, { recursive: true });
  rmSync(join(out, "raw"), { recursive: true, force: true });
  cpSync(join(work, "webdriver-ts/results"), join(out, "raw"), { recursive: true });
  report();
  meta.finished = new Date().toISOString();
  writeFileSync(join(out, "meta.json"), JSON.stringify(meta, null, 2) + "\n");
  console.log(`results in ${relative(repo, out)}; the table is ${relative(repo, join(out, "report/index.html"))}`);
} finally {
  stopServer(server);
}
