// Research 56's harness: beni against Solid 1 on the scaling sweeps' pages,
// with hand-edited prototypes of beni's emitted JavaScript and runtime
// beside them. PROTOTYPES, never a build of the compiler: each variant is a
// copy of a scaling build (out/scaling/, made by `node scaling.mjs
// --build-only --full`) with named text edits, written to out/match/.
//
//   node match.mjs --cases=holes:10,rows:30000:change [--subjects=beni,solid1,...]
//                  [--mode=trace|halves|profile] [--pages=2] [--samples=4]
//                  [--taskset=8-15] [--out=results/<file>.json]
//
// Modes:
//   trace    scaling.mjs's sample exactly: a real click on a fresh page's
//            target after five warm-up clicks, script ms from a Chrome trace
//            (lib/trace.mjs), unthrottled. The default.
//   halves   halves.mjs's split, on the same warm-up: performance.now()
//            around a synthetic click (the listener and `update`) and then
//            to a microtask queued after it (beni's render).
//   profile  a V8 CPU profile at a 10 µs interval around each sampled real
//            click, self time summed over every page and sample.
//
// A case is `<sweep>:<param>[:<op>]`; the sweep's own op is the default.

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import { launch, sleep, traced } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { analyse, categories, median, quantile } from "./lib/trace.mjs";
import { variants } from "./match-variants.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const mode = arg("mode", "trace");
const pages = Number(arg("pages", "2"));
const samplesPerPage = Number(arg("samples", "4"));
const warm = Number(arg("warm", "5"));

const byId = (id) => `document.getElementById(${JSON.stringify(id)})`;
const textIs = (finder, text) => `(() => { const n = ${finder}; return n !== null && n.textContent === ${JSON.stringify(String(text))}; })()`;
const row = (i) => `document.querySelector("tbody").children[${i}]`;
const target = (n) => Math.floor(n / 2);
const middle = (w) => Math.floor(w / 2);

// The scaling sweeps' ops (scaling.mjs), and the static page's.
const ops = {
  holes: { tick: { target: "go", done: (k) => textIs(byId("tick"), k) } },
  rows: {
    change: { target: "go", done: (k, n) => textIs(`${row(target(n))}.children[1]`, `changed ${k}`) },
    swap: { target: "swap", done: (k, n) => textIs(`${row(1)}.firstChild`, k % 2 === 1 ? n - 1 : 2) },
  },
  width: { field: { target: "go", done: (k, w) => textIs(byId("changed"), middle(w) + k) } },
  depth: { leaf: { target: "go", done: (k) => textIs(byId("v"), k) } },
  derived: { tick: { target: "go", done: (k) => textIs(byId("tick"), k) } },
  // K synthetic clicks on `#go` from one real click on a driver button,
  // on the 1 000-hole page (scaling.mjs's `burst`).
  burst: { burst: { target: "burst", done: (k, kk) => textIs(byId("tick"), k * kk) } },
  static: { bump: { target: "bump", done: (k) => `document.querySelectorAll("h2 span")[${"(" + k + " - 1) % 50"}].textContent === String(Math.floor((${k} - 1) / 50) + 1)` } },
  table: {},
};

const cases = arg("cases", "holes:10")
  .split(",")
  .map((c) => {
    const [sweep, p, op] = c.split(":");
    const opId = op ?? Object.keys(ops[sweep])[0];
    return { sweep, p: Number(p), op: opId, ...ops[sweep][opId], id: `${sweep}:${p}:${opId}` };
  });

// The subjects of one case: the scaling build's, then every variant that
// applies to its sweep, made from its base directory.
const baseSubjects = (c) => {
  const dir = c.sweep === "static" ? null : c.sweep === "burst" ? "scaling/holes/1000" : `scaling/${c.sweep}/${c.p}`;
  if (c.sweep === "static") {
    return [
      { name: "beni", kind: "beni", dir: "micro-inline-dev" },
      { name: "beni-release", kind: "beni", dir: "micro-inline-rel" },
      { name: "beni-helper", kind: "beni", dir: "micro-helpers-dev" },
      { name: "solid1", kind: "solid", src: "/out/match/static/solid1.js", module: false },
      { name: "p2", kind: "script", src: "/apps/micro/p2/static.js", module: true },
    ];
  }
  return [
    { name: "beni", kind: "beni", dir: `${dir}/beni-dev` },
    { name: "beni-release", kind: "beni", dir: `${dir}/beni-rel` },
    { name: "beni-helper", kind: "beni", dir: `${dir}/beni-helper-dev` },
    { name: "solid1", kind: "solid", src: `/out/${dir}/solid1.js`, module: false },
    { name: "solid2", kind: "solid", src: `/out/${dir}/solid2.js` },
    { name: "p2", kind: "script", src: `/out/${dir}/p2.js` },
    { name: "p3", kind: "script", src: `/out/${dir}/p3.js`, module: true },
    { name: "vanillajs", kind: "script", src: `/out/${dir}/vanilla.js` },
  ].filter((s) => existsSync(join(root, s.dir ? `out/${s.dir}` : s.src)));
};

// Copies `from` (under out/) to out/match/<case>/<name>/ and applies the
// edits: `[file, find, replace]`, each `find` required to occur.
const makeVariant = (c, v, base) => {
  const from = base.find((s) => s.name === v.from);
  if (from === undefined) return null;
  const rel = `match/${c.sweep}-${c.p}/${v.name}`;
  const dir = join(root, "out", rel);
  rmSync(dir, { recursive: true, force: true });
  if (from.kind === "beni") cpSync(join(root, "out", from.dir), dir, { recursive: true });
  else {
    mkdirSync(dir, { recursive: true });
    cpSync(join(root, from.src), join(dir, "main.js"));
  }
  for (const [file, find, replace] of v.edits(c)) {
    const f = join(dir, from.kind === "beni" ? file : "main.js");
    let s = readFileSync(f, "utf8");
    const finds = find instanceof RegExp ? find : null;
    if (finds ? !finds.test(s) : !s.includes(find)) throw new Error(`${v.name} on ${c.id}: ${file} has no ${String(find).slice(0, 120)}`);
    s = finds ? s.replace(finds, replace) : s.replace(find, () => (typeof replace === "function" ? replace(s) : replace));
    writeFileSync(f, s);
  }
  return from.kind === "beni" ? { name: v.name, kind: "beni", dir: rel } : { ...from, name: v.name, src: `/out/${rel}/main.js` };
};

const wanted = arg("subjects", "beni,solid1").split(",");
const plan = cases.map((c) => {
  const base = baseSubjects(c);
  const made = variants.filter((v) => wanted.includes(v.name) && v.sweeps.includes(c.sweep === "burst" ? "holes" : c.sweep)).map((v) => makeVariant(c, v, base)).filter((s) => s !== null);
  const all = [...base, ...made].filter((s) => wanted.includes(s.name));
  return { c, subjects: all.map((s) => ({ ...s, subject: s.name, name: `${c.sweep}-${c.p}.${s.name}` })) };
});
if (process.argv.includes("--build-only")) process.exit(0);

const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(plan.flatMap((p) => p.subjects));
const result = {
  mode,
  chrome: browser.version,
  node: process.version,
  cpu: (await import("node:os")).cpus()[0].model,
  commit: (await import("node:child_process")).execSync("git rev-parse HEAD", { cwd: root }).toString().trim(),
  started: new Date().toISOString(),
  taskset: arg("taskset", null),
  pages,
  samplesPerPage,
  warm,
  cases: cases.map((c) => c.id),
  samples: [],
  profiles: {},
};
const out = arg("out", null);
const save = () => {
  if (out === null) return;
  mkdirSync(dirname(join(root, out)), { recursive: true });
  writeFileSync(join(root, out), JSON.stringify(result, null, 1));
};

// Self time per function of a profile's samples taken between `from` and
// `to` (µs, the profile's clock), added to `into`.
const selfTime = (profile, into) => {
  const byNode = new Map(profile.nodes.map((n) => [n.id, n]));
  let t = profile.startTime;
  let busy = 0;
  for (let i = 0; i < profile.samples.length; i++) {
    t += profile.timeDeltas[i];
    const f = byNode.get(profile.samples[i]).callFrame;
    if (f.functionName === "(idle)") continue;
    const key = `${f.functionName || "(anonymous)"} ${f.url.replace(origin, "").replace(/^\/out\//, "")}:${f.lineNumber + 1}`;
    into.set(key, (into.get(key) ?? 0) + 1);
    busy++;
  }
  return busy;
};

async function measurePage(c, subject, pageIndex) {
  const page = await browser.newPage(`${origin}/s/${subject.name}/`);
  const rows = [];
  try {
    if (c.sweep === "burst") {
      await page.waitFor(`${byId("go")} !== null`);
      await page.eval(`(() => {
        const b = document.createElement("button");
        b.id = "burst";
        b.textContent = "burst";
        b.style.cssText = "position:fixed;left:0;top:0;z-index:9";
        b.addEventListener("click", () => { const go = document.getElementById("go"); for (let i = 0; i < ${c.p}; i++) go.click(); });
        document.documentElement.appendChild(b);
        return true;
      })()`);
    }
    await page.waitFor(`${byId(c.target)} !== null`);
    let k = 0;
    for (let i = 0; i < warm; i++) {
      await page.click(byId(c.target));
      k++;
      await page.waitFor(c.done(k, c.p), 60000);
    }
    let settle = 300;
    for (let j = 0; j < samplesPerPage; j++) {
      await sleep(50);
      await page.eval("window.gc && window.gc()");
      const box = await page.locate(byId(c.target));
      await sleep(50);
      if (mode === "halves") {
        const r = await page.eval(`new Promise((done) => {
          const el = ${byId(c.target)};
          const t0 = performance.now();
          el.click();
          const t1 = performance.now();
          queueMicrotask(() => { const t2 = performance.now(); setTimeout(() => done([t1 - t0, t2 - t1]), 0); });
        })`);
        k++;
        await page.waitFor(c.done(k, c.p), 60000);
        rows.push({ case: c.id, subject: subject.subject, page: pageIndex, sample: j, click: r[0], micro: r[1], script: r[0] + r[1] });
        continue;
      }
      if (mode === "profile") {
        await page.send("Profiler.enable");
        await page.send("Profiler.setSamplingInterval", { interval: 10 });
        await page.send("Profiler.start");
        await page.press(box);
        k++;
        await page.waitFor(c.done(k, c.p), 60000);
        const { profile } = await page.send("Profiler.stop");
        const into = (result.profiles[`${c.id} ${subject.subject}`] ??= { busy: 0, clicks: 0, self: {} });
        const m = new Map(Object.entries(into.self));
        into.busy += selfTime(profile, m);
        into.clicks++;
        into.self = Object.fromEntries(m);
        continue;
      }
      const events = await traced(page, arg("categories", null)?.split(";") ?? categories, async () => {
        await page.press(box);
        await sleep(settle);
      });
      k++;
      await page.waitFor(c.done(k, c.p), 60000);
      let r;
      try {
        // As scaling.mjs's `analyseOne`: synthetic clicks inside the real
        // one (the burst) are not the measured click.
        const clicks = events.filter((e) => e.name === "EventDispatch" && e.args?.data?.type === "click").sort((a, b) => a.ts - b.ts);
        r = analyse(events.filter((e) => !(e.name === "EventDispatch" && e.args?.data?.type === "click") || e === clicks[0]));
      } catch (e) {
        settle *= 3;
        console.error(`${c.id} ${subject.subject}: ${e.message}`);
        continue;
      }
      if (r.total * 1.5 + 150 > settle) settle = Math.ceil(r.total * 1.5 + 150);
      // `--dump`: the main thread's events inside the measured window, for
      // the last sample of each page.
      if (process.argv.includes("--dump") && j === samplesPerPage - 1) {
        const click = events.find((e) => e.name === "EventDispatch" && e.args?.data?.type === "click");
        const from = +click.ts;
        const inWin = events.filter((e) => e.pid === click.pid && e.tid === click.tid && +e.ts >= from && +e.ts <= +click.ts + +click.dur + 200).sort((a, b) => a.ts - b.ts);
        console.log(`--- ${subject.subject} page ${pageIndex}: script ${r.script.toFixed(3)} total ${r.total.toFixed(3)}`);
        for (const e of inWin) console.log(`  ${((+e.ts - +click.ts) / 1000).toFixed(3).padStart(8)} ${e.ph} +${(+(e.dur ?? 0) / 1000).toFixed(3)}  ${e.cat} ${e.name} ${e.args?.data?.type ?? e.args?.data?.functionName ?? ""}${e.args?.data?.stackTrace ? ` [stack ${e.args.data.stackTrace.length}]` : ""}`);
      }
      rows.push({ case: c.id, subject: subject.subject, page: pageIndex, sample: j, load: loadavg()[0], ...r });
    }
    return rows;
  } finally {
    await page.close();
  }
}

const fmt = (xs) => (xs.length === 0 ? "—" : `${median(xs).toFixed(3)} [${quantile(xs, 0.25).toFixed(3)}–${quantile(xs, 0.75).toFixed(3)}]`);
const t0 = Date.now();
for (const { c, subjects } of plan) {
  for (let i = 0; i < pages; i++) {
    for (let s = 0; s < subjects.length; s++) {
      const subject = subjects[(i + s) % subjects.length];
      try {
        const got = await measurePage(c, subject, i);
        result.samples.push(...got);
      } catch (e) {
        console.error(`${c.id} ${subject.subject} #${i}: ${e.message}`);
      }
    }
  }
  console.log(`\n${c.id} (${mode}, ${pages} pages × ${samplesPerPage}), script ms median [IQR]  [${((Date.now() - t0) / 1000).toFixed(0)} s]`);
  for (const s of subjects) {
    const xs = result.samples.filter((r) => r.case === c.id && r.subject === s.subject);
    if (mode === "halves") console.log(`  ${s.subject.padEnd(28)} click ${fmt(xs.map((x) => x.click))}  micro ${fmt(xs.map((x) => x.micro))}  both ${fmt(xs.map((x) => x.script))}`);
    else if (mode === "trace") console.log(`  ${s.subject.padEnd(28)} ${fmt(xs.map((x) => x.script))}  total ${median(xs.map((x) => x.total)).toFixed(2)}  (${xs.length})`);
    else {
      const p = result.profiles[`${c.id} ${s.subject}`];
      if (p === undefined) continue;
      console.log(`  ${s.subject}: ${p.busy} busy samples of 10 µs over ${p.clicks} clicks (${((p.busy * 0.01) / p.clicks).toFixed(3)} ms a click)`);
      for (const [key, n] of Object.entries(p.self).sort((a, b) => b[1] - a[1]).slice(0, 18)) console.log(`    ${((100 * n) / p.busy).toFixed(1).padStart(5)}%  ${(((n * 0.01) / p.clicks) * 1000).toFixed(1).padStart(6)} µs  ${key}`);
    }
  }
  save();
}
result.finished = new Date().toISOString();
save();
server.close();
await browser.close();
