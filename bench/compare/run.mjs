// Cold type-check timing across languages: generates N-copy projects with
// gen.mjs, times each tool's check-only path with every cache cleared, and
// fits ms = intercept + slope * N over the medians.
//
//   node run.mjs [--langs=beni,elm,gleam,roc,purescript] [--ns=1,2,4,8,16,32]
//                [--runs=7] [--cpu=2] [--multi] [--work=DIR] [--out=FILE]
//   node run.mjs --verify [--langs=...] [--work=DIR]
//
// Tools come from the environment, else PATH: BENI (default: the repo's
// zig-out/bin/beni), ELM, GLEAM, ROC, PURS, NODE. See README.md.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { performance } from "node:perf_hooks";
import { HERE, LANGS, copySize, generate } from "./gen.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, v] = a.replace(/^--/, "").split("=");
    return [k, v ?? true];
  }),
);
const langs = args.langs ? String(args.langs).split(",") : LANGS;
const ns = (args.ns ? String(args.ns) : "1,2,4,8,16,32").split(",").map(Number);
const runs = Number(args.runs ?? 7);
const cpu = String(args.cpu ?? 2);
const multi = Boolean(args.multi);
const work = path.resolve(String(args.work ?? path.join(os.tmpdir(), "beni-compare")));

const tool = {
  beni: process.env.BENI ?? path.resolve(HERE, "../../zig-out/bin/beni"),
  elm: process.env.ELM ?? "elm",
  gleam: process.env.GLEAM ?? "gleam",
  roc: process.env.ROC ?? "roc",
  purs: process.env.PURS ?? "purs",
  node: process.env.NODE ?? process.execPath,
};

const psDeps = path.join(HERE, "purescript", ".spago", "*", "*", "src", "**", "*.purs");
const rts = multi ? [] : ["+RTS", "-N1", "-RTS"];

function sh(exe, argv, cwd, opts = {}) {
  const r = spawnSync(exe, argv, { cwd, encoding: "utf8", maxBuffer: 1 << 28, ...opts });
  if (r.error) throw r.error;
  return r;
}

function must(r, what) {
  if (r.status !== 0) {
    console.error(`${what} failed (exit ${r.status})\n${r.stdout}\n${r.stderr}`);
    process.exit(1);
  }
  return r;
}

// Per language: what is timed, how the cache is cleared before each run, and
// any untimed one-off setup of a generated project.
const LANG = {
  beni: {
    what: "beni check --no-cache" + (multi ? "" : " --jobs=1") + " --platform=node",
    setup() {},
    reset(dir) {
      fs.rmSync(path.join(dir, ".beni-cache"), { recursive: true, force: true });
    },
    cmd: () => [
      tool.beni,
      ["check", "--no-cache", ...(multi ? [] : ["--jobs=1"]), "--platform=node", "."],
    ],
    version: () => sh(tool.beni, ["version"]).stdout.trim(),
  },
  elm: {
    what: "elm make src/Main.elm --output=/dev/null" + (multi ? "" : " +RTS -N1"),
    setup() {},
    reset(dir) {
      fs.rmSync(path.join(dir, "elm-stuff"), { recursive: true, force: true });
    },
    cmd: () => [tool.elm, ["make", "src/Main.elm", "--output=/dev/null", ...rts]],
    version: () => sh(tool.elm, ["--version"]).stdout.trim(),
  },
  gleam: {
    what: "gleam check (stdlib precompiled, project artefacts deleted)",
    setup(dir) {
      must(sh(tool.gleam, ["check"], dir), "gleam setup");
    },
    reset(dir) {
      fs.rmSync(path.join(dir, "build", "dev", "javascript", "compare"), {
        recursive: true,
        force: true,
      });
    },
    cmd: () => [tool.gleam, ["check"]],
    version: () => sh(tool.gleam, ["--version"]).stdout.trim(),
  },
  roc: {
    what: "roc check Main.roc" + (multi ? "" : " --max-threads 1"),
    setup() {},
    reset() {},
    cmd: () => [tool.roc, ["check", ...(multi ? [] : ["--max-threads", "1"]), "Main.roc"]],
    version: () => {
      const store = fs.realpathSync(which(tool.roc));
      const m = store.match(/roc-([^/]*)\/bin/);
      return `roc ${m ? m[1] : "?"} (${sh(tool.roc, ["version"]).stdout.trim()})`;
    },
  },
  purescript: {
    what:
      "purs compile deps+src" + (multi ? "" : " +RTS -N1") + " (deps' output restored, JS codegen on)",
    setup(dir) {
      must(
        sh(tool.purs, ["compile", psDeps, "-o", "output.deps", ...rts], dir),
        "purs deps setup",
      );
    },
    reset(dir) {
      fs.rmSync(path.join(dir, "output"), { recursive: true, force: true });
      must(sh("cp", ["-a", "output.deps", "output"], dir), "restore purs deps");
    },
    cmd: () => [tool.purs, ["compile", psDeps, "src/**/*.purs", "-o", "output", ...rts]],
    version: () => "purs " + sh(tool.purs, ["--version"]).stdout.trim(),
  },
};

function which(exe) {
  if (exe.includes("/")) return exe;
  for (const d of (process.env.PATH ?? "").split(":")) {
    const p = path.join(d, exe);
    if (fs.existsSync(p)) return p;
  }
  return exe;
}

// Every run is offline when `unshare -rn` works (an empty network namespace):
// without it `elm make` with no elm-stuff/ asks package.elm-lang.org for
// registry updates, several hundred milliseconds that are not checking.
const offline = !args.online && sh("unshare", ["-rn", "true"]).status === 0;

function timeOnce(lang, dir) {
  LANG[lang].reset(dir);
  let [exe, argv] = LANG[lang].cmd();
  if (!multi) [exe, argv] = ["taskset", ["-c", cpu, exe, ...argv]];
  if (offline) [exe, argv] = ["unshare", ["-rn", exe, ...argv]];
  const t0 = performance.now();
  const r = sh(exe, argv, dir);
  const ms = performance.now() - t0;
  must(r, `${lang} check in ${dir}`);
  return ms;
}

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

function fit(points) {
  const n = points.length;
  const mx = points.reduce((s, [x]) => s + x, 0) / n;
  const my = points.reduce((s, [, y]) => s + y, 0) / n;
  let sxy = 0;
  let sxx = 0;
  let syy = 0;
  for (const [x, y] of points) {
    sxy += (x - mx) * (y - my);
    sxx += (x - mx) ** 2;
    syy += (y - my) ** 2;
  }
  const slope = sxy / sxx;
  return { slope, intercept: my - slope * mx, r2: (sxy * sxy) / (sxx * syy) };
}

const loadavg = () => os.loadavg().map((l) => +l.toFixed(2));

function bench() {
  const results = {
    date: new Date().toISOString(),
    machine: { cpu: os.cpus()[0].model, nproc: os.cpus().length, kernel: os.release() },
    mode: multi ? "all cores, tools' default parallelism" : `pinned to CPU ${cpu} with taskset`,
    offline,
    runs,
    ns,
    loadavg: { start: loadavg() },
    langs: {},
  };
  // Generate and set up every project first, and warm the page cache.
  const points = [];
  for (const lang of langs) {
    results.langs[lang] = {
      what: LANG[lang].what,
      version: LANG[lang].version(),
      size: copySize(lang),
      medians: {},
      samples: {},
    };
    for (const n of ns) {
      const dir = path.join(work, `${lang}-${n}`);
      generate(lang, n, dir);
      LANG[lang].setup(dir);
      timeOnce(lang, dir); // discarded
      results.langs[lang].samples[n] = [];
      points.push([lang, n, dir]);
    }
  }
  // Round-robin: sample i of every point is taken before sample i + 1 of any,
  // so a burst of background load lands on every language alike.
  for (let i = 0; i < runs; i++) {
    for (const [lang, n, dir] of points) {
      results.langs[lang].samples[n].push(+timeOnce(lang, dir).toFixed(1));
    }
    console.error(`round ${i + 1}/${runs} done, load ${loadavg().join(" ")}`);
  }
  results.loadavg.end = loadavg();
  for (const lang of langs) {
    const entry = results.langs[lang];
    for (const n of ns) entry.medians[n] = +median(entry.samples[n]).toFixed(1);
    const f = fit(ns.map((n) => [n, entry.medians[n]]));
    entry.slope = +f.slope.toFixed(2);
    entry.intercept = +f.intercept.toFixed(1);
    entry.r2 = +f.r2.toFixed(4);
    entry.msPer1kTokens = +((f.slope / entry.size.tokens) * 1000).toFixed(2);
    entry.msPer1kLines = +((f.slope / entry.size.lines) * 1000).toFixed(2);
    // The same fit over each point's fastest run: less sensitive to a burst of
    // background load, which only ever adds time.
    const fMin = fit(ns.map((n) => [n, Math.min(...entry.samples[n])]));
    entry.slopeMin = +fMin.slope.toFixed(2);
    entry.interceptMin = +fMin.intercept.toFixed(1);
  }
  return results;
}

function table(results) {
  const head = [
    "language",
    ...results.ns.map((n) => `N=${n}`),
    "slope ms/copy",
    "slope (min) ms/copy",
    "intercept ms",
    "R²",
    "tokens/copy",
    "ms/1k tokens",
    "lines/copy",
    "ms/1k lines",
  ];
  const rows = Object.entries(results.langs).map(([lang, e]) => [
    lang,
    ...results.ns.map((n) => e.medians[n].toFixed(1)),
    e.slope.toFixed(2),
    e.slopeMin.toFixed(2),
    e.intercept.toFixed(1),
    e.r2.toFixed(4),
    String(e.size.tokens),
    e.msPer1kTokens.toFixed(2),
    String(e.size.lines),
    e.msPer1kLines.toFixed(2),
  ]);
  const line = (cells) => `| ${cells.join(" | ")} |`;
  return [line(head), line(head.map(() => "---")), ...rows.map(line)].join("\n");
}

// ---- verification: every port compiles, runs, and prints the same lines ---

function runProject(lang, dir) {
  const out = path.join(dir, "_out");
  switch (lang) {
    case "beni":
      must(sh(tool.beni, ["build", "--no-cache", "--platform=node", `--out=${out}`, "."], dir), "beni build");
      return must(sh(tool.node, [path.join(out, "_main.mjs")], dir), "beni run").stdout;
    case "elm":
      must(sh(tool.elm, ["make", "src/Main.elm", `--output=${out}.js`], dir), "elm make");
      return must(sh(tool.node, [path.join(HERE, "elm", "run.js"), `${out}.js`], dir), "elm run").stdout;
    case "gleam": {
      const env = { ...process.env, PATH: `${path.dirname(tool.node)}:${process.env.PATH}` };
      return must(sh(tool.gleam, ["run", "--no-print-progress"], dir, { env }), "gleam run").stdout;
    }
    case "roc":
      must(sh(tool.roc, ["build", "--output", out, "app.roc"], dir), "roc build");
      return must(sh(out, [], dir), "roc run").stdout;
    case "purescript":
      must(sh(tool.purs, ["compile", psDeps, "src/**/*.purs", "-o", "output"], dir), "purs compile");
      return must(
        sh(tool.node, ["--input-type=module", "-e", 'import("./output/Main/index.js").then(m => m.main())'], dir),
        "purescript run",
      ).stdout;
  }
}

function verify() {
  let reference = null;
  let ok = true;
  for (const lang of langs) {
    const one = runProject(lang, generate(lang, 1, path.join(work, `verify-${lang}-1`)));
    const two = runProject(lang, generate(lang, 2, path.join(work, `verify-${lang}-2`)));
    reference ??= one;
    const same = one === reference;
    const doubled = two === one + one || two.trimEnd() === `${one.trimEnd()}\n${one.trimEnd()}`;
    console.log(
      `${lang.padEnd(10)} ${one.trimEnd().split("\n").length} lines, ` +
        `${same ? "same as " + langs[0] : "DIFFERS from " + langs[0]}, ` +
        `N=2 ${doubled ? "prints it twice" : "DIFFERS"}`,
    );
    if (!same || !doubled) ok = false;
  }
  process.exit(ok ? 0 : 1);
}

fs.mkdirSync(work, { recursive: true });
if (args.verify) {
  verify();
} else {
  const results = bench();
  const out = args.out ? path.resolve(String(args.out)) : path.join(work, "results.json");
  fs.writeFileSync(out, JSON.stringify(results, null, 2));
  console.log(table(results));
  console.error(`\nraw samples: ${out}`);
}
