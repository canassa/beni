// The scaling sweeps: how each subject's cost per update grows as one
// parameter of the page grows — the number of holes, rows, model fields,
// levels of nesting, items behind a derived view, live rows a render skips,
// calls of a helper tree, messages in one task.
// The table benchmark (bench.mjs) measures one size; this measures curves.
// A separate investigation, run by hand; no gate runs it.
//
//   node scaling.mjs [--full] [--sweeps=holes,rows,...] [--subjects=beni,solid1,...]
//                    [--taskset=4-7] [--out=results/<date>-scaling-<mode>.json]
//                    [--build-only] [--no-build] [--beni=<path>] [--chrome=<path>]
//                    [--variants=<name>=<path to beni>,...]
//
// Quick by default (two or three points a sweep, one page of three samples
// per point and subject); `--full` takes every point and two pages of four
// samples. By default only beni (its development build, and the view-helper
// variant of `derived`) and Solid 1 are measured, unthrottled; `--subjects=`
// adds any of beni-release, beni-helper-release, solid2, p2 and vanillajs, and
// `--throttle=4` measures under the table benchmark's CPU throttling instead. Run it from `nix develop .#browser`, after `node build.mjs` has
// fetched the stylesheet and installed both Solids.
//
// Each sample is research 29's: one real click on a fresh page's `#go`,
// click to paint from a Chrome trace (lib/trace.mjs, js-framework-
// benchmark's method). Unthrottled by default: under 4x Chrome pauses the
// main thread in slices, which adds about half a millisecond, at random, to
// an update shorter than that.
// Several samples are taken on one page, after warm-up clicks, each in a
// trace of its own. The `stream` sweep is the one
// exception: a 60 Hz stream of messages for three seconds in one trace,
// reported per message.
//
// Every program is generated for each value of its parameter by
// apps/scaling/*.mjs, into out/scaling/ and apps/solid{1,2}/gen/ (both
// git-ignored), and built: beni development and `--release`, Solid 1 as
// rollup.config.js builds it, Solid 2 as vite.config.mjs does.
//
// `--variants=A=../../a/beni,B=…` adds one subject per other beni binary,
// `beni-<name>`: each program's development build by that binary, made
// again on every run, measured in the same batch as the rest — how two
// builds of the compiler are compared under the same noise.

import { execSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import * as depth from "./apps/scaling/depth.mjs";
import * as derived from "./apps/scaling/derived.mjs";
import * as holes from "./apps/scaling/holes.mjs";
import * as live from "./apps/scaling/live.mjs";
import * as liveHelper from "./apps/scaling/live-helper.mjs";
import * as tree from "./apps/scaling/tree.mjs";
import * as rows from "./apps/scaling/rows.mjs";
import * as width from "./apps/scaling/width.mjs";
import { launch, sleep, traced } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { analyse, categories } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const flag = (name) => process.argv.includes(`--${name}`);
const full = flag("full");
const mode = full ? "full" : "quick";
const repo = join(root, "../..");
const beniExe = arg("beni", join(repo, "zig-out/bin/beni"));
// The compiler a page was built by: a page built by another beni is built
// again, even when its source did not change.
const beniId = existsSync(beniExe) ? createHash("sha256").update(readFileSync(beniExe)).digest("hex") : "";
// CPU throttling: none by default; `--throttle=4` is the table benchmark's.
const THROTTLE = Number(arg("throttle", "1"));
const settings = full ? { pages: 2, samples: 4, warm: 5, throttles: [THROTTLE] } : { pages: 1, samples: 3, warm: 3, throttles: [THROTTLE] };

// ---- The sweeps --------------------------------------------------------------

const byId = (id) => `document.getElementById(${JSON.stringify(id)})`;
const textIs = (finder, text) => `(() => { const n = ${finder}; return n !== null && n.textContent === ${JSON.stringify(String(text))}; })()`;
const row = (i) => `document.querySelector("tbody").children[${i}]`;

// `params` full and quick; `program` the generator module and its
// parameter; `done(k, p)` the expression that holds after the k-th `#go`.
const sweeps = [
  {
    id: "holes",
    what: "view size: N holes, one changes",
    program: holes,
    params: { full: [10, 30, 100, 300, 1000, 3000, 10000], quick: [10, 1000, 10000] },
    ops: [{ id: "tick", target: "go", done: (k) => textIs(byId("tick"), k) }],
  },
  {
    id: "rows",
    what: "list length: N keyed rows",
    program: rows,
    params: { full: [10, 30, 100, 300, 1000, 3000, 10000, 30000], quick: [10, 1000, 30000] },
    ops: [
      { id: "change", target: "go", done: (k, n) => textIs(`${row(rows.target(n))}.children[1]`, `changed ${k}`) },
      { id: "swap", target: "swap", done: (k, n) => textIs(`${row(1)}.firstChild`, k % 2 === 1 ? n - 1 : 2) },
    ],
  },
  {
    id: "width",
    what: "model width: W fields, one changes",
    program: width,
    params: { full: [4, 8, 16, 17, 20, 32, 64, 128, 256, 1024], quick: [8, 20, 256] },
    ops: [{ id: "field", target: "go", done: (k, w) => textIs(byId("changed"), width.middle(w) + k) }],
  },
  {
    id: "depth",
    what: "model depth: the value D records deep",
    program: depth,
    params: { full: [1, 2, 4, 8, 16, 32, 64, 128], quick: [1, 16, 128] },
    ops: [{ id: "leaf", target: "go", done: (k) => textIs(byId("v"), k) }],
  },
  {
    id: "derived",
    what: `derived view: top ${derived.SHOWN} of N items filtered and sorted, an unrelated field changes`,
    program: derived,
    helper: true,
    params: { full: [100, 300, 1000, 3000, 10000, 30000, 100000], quick: [100, 3000, 100000] },
    ops: [{ id: "tick", target: "go", done: (k) => textIs(byId("tick"), k) }],
  },
  {
    id: "live",
    what: "live rows: N keyed rows, each a controlled input and a helper's markup, an unrelated field changes",
    program: live,
    params: { full: [100, 300, 1000, 3000, 10000], quick: [100, 1000, 10000] },
    ops: [{ id: "tick", target: "go", done: (k) => textIs(byId("tick"), k) }],
  },
  {
    id: "helperRows",
    what: "rows holding a helper: N keyed rows, each a helper's markup and no input, an unrelated field changes",
    program: liveHelper,
    params: { full: [100, 300, 1000, 3000, 10000], quick: [100, 1000, 10000] },
    ops: [{ id: "tick", target: "go", done: (k) => textIs(byId("tick"), k) }],
  },
  {
    id: "tree",
    what: "helper tree: a recursive helper D levels deep, an unrelated field changes",
    program: tree,
    params: { full: [4, 6, 8, 10, 12], quick: [4, 8, 12] },
    ops: [{ id: "tick", target: "go", done: (k) => textIs(byId("tick"), k) }],
  },
  {
    id: "burst",
    what: "K messages in one task, on the 1 000-hole page of `holes`",
    program: holes,
    programParam: () => 1000,
    params: { full: [1, 3, 10, 30, 100, 300, 1000], quick: [1, 30, 1000] },
    ops: [{ id: "burst", target: "burst", done: (k, kk) => textIs(byId("tick"), k * kk) }],
  },
  {
    id: "stream",
    what: "K messages per 60 Hz tick for 3 s, on the 1 000-hole page of `holes`",
    program: holes,
    programParam: () => 1000,
    params: { full: [1, 10, 100], quick: [1, 100] },
    ops: [{ id: "stream", stream: true }],
  },
];

const wantedSweeps = arg("sweeps", null)?.split(",") ?? sweeps.map((s) => s.id);
for (const w of wantedSweeps) if (!sweeps.some((s) => s.id === w)) throw new Error(`unknown sweep ${w}`);
const variants = (arg("variants", null)?.split(",") ?? []).map((v) => {
  const [name, path] = v.split("=");
  return { name, path };
});
const defaultSubjects = ["beni", "beni-helper", "solid1"];
const wantedSubjects = [...(arg("subjects", null)?.split(",") ?? defaultSubjects), ...variants.map((v) => `beni-${v.name}`)];
const wants = (name) => wantedSubjects.includes(name);
const chosen = sweeps.filter((s) => wantedSweeps.includes(s.id));

// ---- Generating and building -------------------------------------------------

const progDir = (sweep, p) => `out/scaling/${sweep.program === holes ? "holes" : sweep.id}/${p}`;
const programs = new Map();
for (const s of chosen) for (const p of s.params[mode]) {
  const pp = s.programParam ? s.programParam(p) : p;
  programs.set(progDir(s, pp), { sweep: s, p: pp });
}

// Writes `text` to `path` and says whether it changed.
const put = (path, text) => {
  const file = join(root, path);
  if (existsSync(file) && readFileSync(file, "utf8") === text) return false;
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, text);
  return true;
};

const run = (cmd, args, cwd = root, env = process.env) => {
  const r = spawnSync(cmd, args, { cwd, stdio: "inherit", env });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")}: exit ${r.status}`);
};

function buildAll() {
  const rebuild = flag("rebuild");
  const solid1 = [];
  const solid2 = [];
  for (const [dir, { sweep, p }] of programs) {
    const m = sweep.program;
    const tag = dir.replace(/^out\/scaling\//, "").replace("/", "-");
    const beniPrograms = [["src", "beni", m.beni(p)]];
    if (sweep.helper) beniPrograms.push(["src-helper", "beni-helper", m.beniHelper(p)]);
    for (const [src, out, text] of beniPrograms) {
      const changed = put(`${dir}/${src}/Main.beni`, text);
      const builds = [["dev", []], ["rel", ["--release"]]].filter(([suffix]) => suffix === "dev" || wants(`${out}-release`));
      for (const [suffix, flags] of builds) {
        const outDir = `${dir}/${out}-${suffix}`;
        const stamp = join(root, outDir, ".built-by");
        const same = existsSync(stamp) && readFileSync(stamp, "utf8") === beniId;
        if (!changed && !rebuild && same && existsSync(join(root, outDir, "_main.mjs"))) continue;
        rmSync(join(root, outDir), { recursive: true, force: true });
        run(beniExe, ["build", "--platform=browser-tea", ...flags, "--no-cache", `--out=${outDir}`, `${dir}/${src}/Main.beni`]);
        writeFileSync(stamp, beniId);
      }
    }
    for (const v of variants) {
      const outDir = `${dir}/beni-${v.name}-dev`;
      rmSync(join(root, outDir), { recursive: true, force: true });
      run(v.path, ["build", "--platform=browser-tea", "--no-cache", `--out=${outDir}`, `${dir}/src/Main.beni`]);
    }
    for (const v of [1, 2].filter((v) => wants(`solid${v}`))) {
      const src = `apps/solid${v}/gen/${tag}.jsx`;
      const changed = put(src, m.solid(v, p));
      if (changed || rebuild || !existsSync(join(root, dir, `solid${v}.js`))) (v === 1 ? solid1 : solid2).push([join(root, src), join(root, dir), `solid${v}`]);
    }
    put(`${dir}/p2.js`, m.p2(p));
    put(`${dir}/vanilla.js`, m.vanilla(p));
  }
  if (solid1.length > 0) {
    const list = join(root, "out/scaling/solid1-entries.json");
    writeFileSync(list, JSON.stringify(solid1.map(([input, dir]) => [input, join(dir, "solid1.js")])));
    run("npx", ["rollup", "-c", "rollup.scaling.config.js", "--silent"], join(root, "apps/solid1"), { ...process.env, SCALING_ENTRIES: list });
  }
  if (solid2.length > 0) {
    const list = join(root, "out/scaling/solid2-entries.json");
    writeFileSync(list, JSON.stringify(solid2));
    run("node", ["build-scaling.mjs", list], join(root, "apps/solid2"));
  }
}

// The subjects of one program directory, as lib/serve.mjs serves them.
const subjectsOf = (sweep, dir) => {
  const key = dir.replace(/^out\/scaling\//, "").replace("/", ".");
  const list = [
    { name: "beni", kind: "beni", dir: `scaling/${dir.slice(12)}/beni-dev` },
    { name: "beni-release", kind: "beni", dir: `scaling/${dir.slice(12)}/beni-rel` },
    ...(sweep.helper
      ? [
          { name: "beni-helper", kind: "beni", dir: `scaling/${dir.slice(12)}/beni-helper-dev` },
          { name: "beni-helper-release", kind: "beni", dir: `scaling/${dir.slice(12)}/beni-helper-rel` },
        ]
      : []),
    ...variants.map((v) => ({ name: `beni-${v.name}`, kind: "beni", dir: `scaling/${dir.slice(12)}/beni-${v.name}-dev` })),
    { name: "solid2", kind: "solid", src: `/${dir}/solid2.js` },
    { name: "solid1", kind: "solid", src: `/${dir}/solid1.js`, module: false },
    { name: "p2", kind: "script", src: `/${dir}/p2.js` },
    { name: "vanillajs", kind: "script", src: `/${dir}/vanilla.js` },
  ];
  return list
    .filter((s) => wants(s.name))
    .map((s) => ({ ...s, subject: s.name, name: `${key}.${s.name}` }));
};

if (!flag("no-build")) buildAll();
if (flag("build-only")) process.exit(0);

// ---- Measuring ----------------------------------------------------------------

// GC pauses on the main thread: `devtools.timeline` carries them, so the
// trace is the table benchmark's, with no category added.
const gcNames = new Set(["MinorGC", "MajorGC"]);
const traceCategories = categories;

// The union of `pred` events' intervals within [from, to], in ms.
const unionMs = (entries, pred, from, to) => {
  const xs = entries
    .filter((e) => e.ph === "X" && pred(e) && +e.ts >= from && +e.ts <= to)
    .map((e) => [+e.ts, +e.ts + +e.dur])
    .sort((a, b) => a[0] - b[0]);
  let sum = 0;
  let cur = null;
  for (const [s, e] of xs) {
    if (cur === null || s > cur[1]) {
      if (cur !== null) sum += cur[1] - cur[0];
      cur = [s, e];
    } else cur[1] = Math.max(cur[1], e);
  }
  if (cur !== null) sum += cur[1] - cur[0];
  return sum / 1000;
};

// lib/trace.mjs's analysis, for a trace that may hold synthetic clicks
// inside the real one (the `burst` sweep): only the outermost click
// starts the measurement; the inner ones are inside its interval.
const analyseOne = (events) => {
  const clicks = events.filter((e) => e.name === "EventDispatch" && e.args?.data?.type === "click").sort((a, b) => a.ts - b.ts);
  const outer = clicks[0];
  const kept = events.filter((e) => !(e.name === "EventDispatch" && e.args?.data?.type === "click") || e === outer);
  const r = analyse(kept);
  // lib/trace.mjs falls back to the last commit when none follows the
  // last event it starts from: the trace ended before the work did, and
  // the settle was too short.
  const outerEnd = +outer.ts + +outer.dur;
  const starts = kept.filter((e) => e.ph === "X" && e.pid === outer.pid && +e.ts > outerEnd && ["FunctionCall", "TimerFire", "FireAnimationFrame", "Layout"].includes(e.name));
  const lastStart = Math.max(outerEnd, ...starts.map((e) => +e.ts + +e.dur));
  if (r.tsEnd < lastStart) throw new Error("the trace ended before the work did");
  const isGc = (e) => gcNames.has(e.name);
  return { ...r, gc: unionMs(events, isGc, r.tsStart, r.tsEnd), gcEvents: events.filter((e) => isGc(e) && e.ph === "X" && +e.ts >= r.tsStart && +e.ts <= r.tsEnd).length };
};

const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const allSubjects = [...programs.entries()].flatMap(([dir, { sweep }]) => subjectsOf(sweep, dir));
const { server, origin } = await serve(allSubjects);
const git = (args) => execSync(`git ${args}`, { cwd: repo }).toString().trim();
const result = {
  mode,
  chrome: browser.version,
  node: process.version,
  beni: spawnSync(beniExe, ["version"], { encoding: "utf8" }).stdout.trim(),
  commit: git("rev-parse HEAD"),
  dirty: git("status --porcelain") !== "",
  cpu: execSync("grep -m1 'model name' /proc/cpuinfo").toString().split(":")[1].trim(),
  taskset: arg("taskset", null),
  throttle: THROTTLE,
  settings,
  started: new Date().toISOString(),
  sweeps: chosen.map((s) => ({ id: s.id, what: s.what, params: s.params[mode], ops: s.ops.map((o) => o.id) })),
  batches: [],
  samples: [],
  failures: [],
};
const out = join(root, arg("out", `results/${result.started.slice(0, 10)}-scaling-${mode}.json`));
const save = () => {
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(result, null, 1));
};

const heap = (page) => page.eval("performance.memory.usedJSHeapSize");

// A driver button outside the program: one real click on it sends
// `#go` K synthetic clicks in the same task.
const burstButton = (k) => `(() => {
  const b = document.createElement("button");
  b.id = "burst";
  b.textContent = "burst";
  b.style.cssText = "position:fixed;left:0;top:0;z-index:9";
  b.addEventListener("click", () => { const go = document.getElementById("go"); for (let i = 0; i < ${k}; i++) go.click(); });
  document.documentElement.appendChild(b);
  return true;
})()`;

async function measurePage(sweep, op, p, subject, pageIndex) {
  const page = await browser.newPage(`${origin}/s/${subject.name}/`);
  const rows = [];
  try {
    await page.waitFor(`${byId("go")} !== null`);
    if (op.stream) return await measureStream(page, sweep, op, p, subject, pageIndex);
    if (sweep.id === "burst") await page.eval(burstButton(p));
    let k = 0;
    for (let i = 0; i < settings.warm; i++) {
      await page.click(byId(op.target));
      k++;
      await page.waitFor(op.done(k, p), 60000);
    }
    let settle = 300;
    for (let j = 0; j < settings.samples * settings.throttles.length; j++) {
      const throttle = settings.throttles[j % settings.throttles.length];
      await sleep(50);
      await page.eval("window.gc && window.gc()");
      const before = await heap(page);
      const box = await page.locate(byId(op.target));
      await sleep(50);
      const events = await traced(page, traceCategories, async () => {
        if (throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: throttle });
        await page.press(box);
        await sleep(settle);
        if (throttle > 1) await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });
      });
      k++;
      await page.waitFor(op.done(k, p), 60000);
      let r;
      try {
        r = analyseOne(events);
      } catch (e) {
        settle *= 3;
        result.failures.push({ sweep: sweep.id, op: op.id, param: p, subject: subject.subject, page: pageIndex, sample: j, error: e.message });
        console.error(`${sweep.id}/${op.id} ${p} ${subject.subject} #${pageIndex}.${j}: ${e.message}; settle now ${settle} ms`);
        continue;
      }
      if (r.total * 1.5 + 150 > settle) settle = Math.ceil(r.total * 1.5 + 150);
      const after = await heap(page);
      rows.push({ sweep: sweep.id, op: op.id, param: p, subject: subject.subject, page: pageIndex, sample: j, throttle, load: loadavg()[0], ...r, heapBefore: before, heapAfter: after });
    }
    return rows;
  } finally {
    await page.close();
  }
}

// Three seconds of a 60 Hz stream, `p` messages per tick, in one trace:
// the script and GC time inside it, per message sent.
async function measureStream(page, sweep, op, p, subject, pageIndex) {
  const start = `(() => { const go = document.getElementById("go"); window.__sent = 0; window.__timer = setInterval(() => { for (let i = 0; i < ${p}; i++) go.click(); window.__sent += ${p}; }, 1000 / 60); return true; })()`;
  const stop = "(() => { clearInterval(window.__timer); return window.__sent; })()";
  // Warm: one second of the same stream, unthrottled.
  await page.eval(start);
  await sleep(1000);
  await page.eval(stop);
  await sleep(200);
  await page.eval("window.gc && window.gc()");
  const before = await heap(page);
  let sent = 0;
  const events = await traced(page, traceCategories, async () => {
    await page.send("Emulation.setCPUThrottlingRate", { rate: THROTTLE });
    await page.eval(start);
    await sleep(3000);
    sent = await page.eval(stop);
    await sleep(300);
    await page.send("Emulation.setCPUThrottlingRate", { rate: 1 });
  });
  const after = await heap(page);
  const timers = events.filter((e) => e.ph === "X" && e.name === "TimerFire").sort((a, b) => a.ts - b.ts);
  if (timers.length === 0) throw new Error("no timer fired");
  const from = +timers[0].ts;
  const last = timers.at(-1);
  const to = +last.ts + +last.dur + 100000;
  const jsNames = new Set(["EventDispatch", "EvaluateScript", "v8.evaluateModule", "FunctionCall", "TimerFire", "FireIdleCallback", "FireAnimationFrame", "RunMicrotasks", "V8.Execute"]);
  const paintNames = new Set(["UpdateLayoutTree", "Layout", "Commit", "Paint", "Layerize", "PrePaint"]);
  const pid = timers[0].pid;
  const script = unionMs(events, (e) => e.pid === pid && jsNames.has(e.name), from, to);
  const paint = unionMs(events, (e) => e.pid === pid && paintNames.has(e.name), from, to);
  const gc = unionMs(events, (e) => e.pid === pid && gcNames.has(e.name), from, to);
  const ticks = timers.length;
  return [
    {
      sweep: sweep.id, op: op.id, param: p, subject: subject.subject, page: pageIndex, sample: 0, throttle: THROTTLE, load: loadavg()[0],
      sent, ticks, windowMs: (to - from) / 1000, scriptTotal: script, paintTotal: paint, gcTotal: gc,
      script: script / sent, paint: paint / sent, gc: gc / sent, total: (script + paint) / sent,
      heapBefore: before, heapAfter: after,
    },
  ];
}

const t0 = Date.now();
for (const sweep of chosen) {
  for (const op of sweep.ops) {
    for (const p of sweep.params[mode]) {
      const dir = progDir(sweep, sweep.programParam ? sweep.programParam(p) : p);
      const subjects = subjectsOf(sweep, dir);
      result.batches.push({ sweep: sweep.id, op: op.id, param: p, load: loadavg()[0], at: new Date().toISOString() });
      const pages = settings.pages;
      for (let i = 0; i < pages; i++) {
        for (let s = 0; s < subjects.length; s++) {
          const subject = subjects[(i + s) % subjects.length];
          let got = null;
          for (let attempt = 0; attempt < 2 && got === null; attempt++) {
            try {
              got = await measurePage(sweep, op, p, subject, i);
            } catch (e) {
              result.failures.push({ sweep: sweep.id, op: op.id, param: p, subject: subject.subject, page: i, error: e.message });
              console.error(`${sweep.id}/${op.id} ${p} ${subject.subject} #${i}: ${e.message}`);
            }
          }
          if (got === null) continue;
          result.samples.push(...got);
          const at = got.filter((r) => r.throttle === THROTTLE).map((r) => r.script).sort((a, b) => a - b);
          const med = at[Math.floor(at.length / 2)];
          console.log(`${sweep.id}/${op.id} ${String(p).padStart(6)} ${subject.subject.padEnd(20)} #${i} script ${med?.toFixed(3) ?? "—"} ms (${got.length})  [${((Date.now() - t0) / 1000).toFixed(0)} s]`);
        }
      }
      save();
    }
  }
}
result.finished = new Date().toISOString();
result.seconds = (Date.now() - t0) / 1000;
save();
console.log(`wrote ${out} in ${result.seconds.toFixed(0)} s`);
server.close();
await browser.close();
