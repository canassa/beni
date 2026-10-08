// Research 59's harness: where a beni message's fixed cost goes, measured
// without a trace. Every subject is a scaling page already built by
// `node scaling.mjs --build-only --full --sweeps=<s> --params=<p>
// --subjects=beni,beni-release,solid1,p2,vanillajs` (out/scaling/<s>/<p>/);
// the ablations are copies of its development build with named text edits
// to the emitted runtime and program (out/plumbing/), as research 56's
// match-variants.mjs makes them. They are instruments, never a build of the
// compiler, and nothing a user runs.
//
//   node plumbing.mjs [--page=holes/10] [--mode=loop|cdp|profile]
//                     [--subjects=beni,beni-release,solid1,p2,vanillajs,...]
//                     [--pages=4] [--reps=30] [--n=1000] [--warm=2000]
//                     [--clicks=200] [--taskset=8-15] [--out=results/<file>.json]
//
// Modes:
//   loop     in the page, hot: `warm` clicks, then `reps` timed runs of `n`
//            `el.click()` each, `performance.now()` around the run, ns per
//            message. A synthetic click is not trusted, and beni renders a
//            trusted event's message at the end of its dispatch but an
//            untrusted one's in a microtask (backend.md §15.11); so every
//            beni subject here passes `true` where its listener reads
//            `event.isTrusted`, and takes the path a real click takes.
//   cdp      real, trusted clicks (CDP `Input.dispatchMouseEvent`), each
//            timed in the page from a capturing `click` listener on
//            `window` (the first listener of the dispatch) to a bubbling
//            one (the last), so the browser's hit test and input handling
//            are outside and every framework listener is inside. No shim;
//            the code is as warm as `clicks` makes it, which is how a
//            benchmark meets it. `--from=6` keeps clicks from the sixth.
//   profile  loop mode under a V8 CPU profile (`--interval` µs, default
//            25): self time per function and per source line.
//   spread   spread-micro.mjs's loop in the page (Q2), `--widths=…`; one
//            subject is enough, its page is only a host.
//
// The pages' `#go` is the target; `--done=<id>` names the element whose
// text must equal the number of clicks after each run (`tick`, or `v` on
// the depth page).

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import { execSync } from "node:child_process";
import { launch, sleep } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { median, quantile } from "./lib/trace.mjs";
import { microSource } from "./spread-micro.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const mode = arg("mode", "loop");
const pageDir = arg("page", "holes/10");
const pages = Number(arg("pages", "4"));
const reps = Number(arg("reps", "30"));
const n = Number(arg("n", "1000"));
const warm = Number(arg("warm", "2000"));
const clicks = Number(arg("clicks", "200"));
const from = Number(arg("from", "6"));
const doneId = arg("done", pageDir.startsWith("depth") ? "v" : "tick");
// How the done element's text follows from the number of clicks: the width
// page's `#changed` starts at its middle field's value.
const doneOffset = Number(arg("done-offset", "0"));

// ---- Ablations -----------------------------------------------------------------
//
// Each is a list of edits `[file, find, replace]` to the development build;
// `find` must occur (a string, replaced once, or a RegExp). They are written
// against the runtime's output (`_platform/_browser/Rt.mjs`) as the compiler
// emits it at this commit.

const RT = "_platform/_browser/Rt.mjs";

// Every beni subject in loop and profile mode: the trusted path (see above).
const shimDev = [[RT, "return Rt$turn(event$1.isTrusted, () =>", "return Rt$turn(true, () =>"]];
const shimRel = [["_main.mjs", /([\w$]+)\(([\w$]+)\.isTrusted,/, "$1(true,"]];

const ablations = {
  // The three `try … finally` guards of a message: around the handler
  // (`fire`), around the turn and around the flush.
  nofinally: [
    [RT, /let ok\$5 = false;\n    try \{\n([\s\S]*?)      ok\$5 = true;\n    \} finally \{\n      if \(!ok\$5\) \{\n        Rt\$stop\(\);\n      \}\n    \}\n/, "$1"],
    [RT, /let ok\$3 = false;\n    Rt\$turning = true;\n    try \{\n      f\$2\(null\);\n      ok\$3 = true;\n    \} finally \{\n      Rt\$turning = false;\n      if \(!ok\$3\) \{\n        Rt\$stop\(\);\n      \}\n    \}\n/, "Rt$turning = true;\n    f$2(null);\n    Rt$turning = false;\n"],
    [RT, /let ok\$1 = false;\n    try \{\n([\s\S]*?)      ok\$1 = true;\n      return null;\n    \} finally \{\n      Rt\$flushing = false;\n      if \(!ok\$1\) \{\n        Rt\$stop\(\);\n      \}\n    \}\n/, "$1      Rt$flushing = false;\n      return null;\n"],
  ],
  // The property names built per event and per node (`$$${type}`,
  // `${key}F`, `${key}X`) written as constants.
  constkeys: [
    [RT, "node$3[`${key$2}F`]", "node$3.$$clickF"],
    [RT, "node$1[`${key$3}X`]", "node$1.$$clickX"],
    [RT, "`$$${type_$2}`", '"$$click"'],
  ],
  // The walk stops at the first handler, as if the runtime knew no ancestor
  // holds one; today it goes on to the document.
  stopwalk: [[RT, /(Rt\$fire\(node\$3, event\$1, key\$2, flags\$4\);\n)/, "$1      return null;\n"]],
  // The `.disabled` read on every node the walk passes.
  nodisabled: [[RT, " && !node$3.disabled", ""]],
  // The mount found without walking up from the handler's node.
  knownroot: [[RT, "Rt$mountAbove(node$1.parentNode)", "globalThis.document.body"]],
  // `Html.map`'s chain (`$$cx`, `through`) and the `X` (payload decoder)
  // lookups skipped: the button has neither.
  nocx: [[RT, /Rt\$through\(node\$1\.\$\$cx, (x\$6 === undefined \? node\$1\[key\$3\] : node\$1\[key\$3\]\(x\$6\(event\$2\)\))\)/, "($1)"]],
  nox: [[RT, /const x\$6 = node\$1(?:\[[^\]]+\]|\.\$\$clickX);/, "const x$6 = undefined;"]],
  // A message sent during a turn rendered at once, instead of queued for
  // the flush at the turn's end (the queue, `waiting`, `scheduled`, the
  // flush's array swap and loop).
  noqueue: [[RT, "      if (!waiting$5) {\n        waiting$5 = true;", "      if (Rt$turning) {\n        model$4 = program$1.update(msg$7, model$4);\n        render$6();\n        return null;\n      }\n      if (!waiting$5) {\n        waiting$5 = true;"]],
  // `turn`'s closure and call: the delegated listener does the turn inline.
  noturn: [[RT, /return Rt\$turn\((?:true|event\$1\.isTrusted), \(\) => (Rt\$bubble\([^\n]*\))\);/, "Rt$turning = true;\n  $1;\n  Rt$turning = false;\n  return Rt$scheduled ? Rt$flush() : null;"]],
  // `view`'s two objects and the generic patch (`childHtml`, `patch`,
  // `held`): the render calls the template's patch on the instance.
  noview: [[RT, "return Rt$childHtml(s$3, program$1.view(model$4));\n  };", "const i = s$3.i;\n    i.t.p(i, [model$4]);\n    return null;\n  };"]],
  // The `$$root` closure's `dead` check.
  nodead: [[RT, "  root$2.$$root = (msg$7) => {\n    if (Rt$dead) {\n      return null;\n    } else {", "  root$2.$$root = (msg$7) => {\n    {"]],
};
// The ladder: `lad-k` removes the first k pieces in this order, so each
// step's difference is that piece's cost with the ones before it gone, and
// the steps sum to the whole (`lad-11` is `all`).
const ladder = ["constkeys", "stopwalk", "nodisabled", "knownroot", "nocx", "nox", "nofinally", "noturn", "noqueue", "noview", "nodead"];
ablations.all = ladder.flatMap((k) => ablations[k]);
for (let k = 1; k <= ladder.length; k++) ablations[`lad${k}`] = ladder.slice(0, k).flatMap((n) => ablations[n]);

// A delegated listener replaced by one on the button, calling `update` and
// the template's patch: P2's shape, through beni's own `update` and patch.
// Only for the holes page (it names the template's patch). The document
// listener is not registered.
ablations.direct = [
  [
    RT,
    "  return Rt$childHtml(s$3, program$1.view(model$4));\n};\nconst Rt$setPhase",
    "  const out = Rt$childHtml(s$3, program$1.view(model$4));\n  const go = root$2.querySelector(\"#go\");\n  go.addEventListener(\"click\", () => { model$4 = program$1.update(\"Go\", model$4); const i = s$3.i; i.t.p(i, [model$4]); });\n  return out;\n};\nconst Rt$setPhase",
  ],
  [RT, "globalThis.document.addEventListener(name$2, Rt$delegated);", ""],
];

// ---- Subjects ------------------------------------------------------------------

const base = `scaling/${pageDir}`;
const all = {
  beni: { kind: "beni", dir: `${base}/beni-dev`, edits: mode === "cdp" ? [] : shimDev },
  "beni-release": { kind: "beni", dir: `${base}/beni-rel`, edits: mode === "cdp" ? [] : shimRel },
  // The development build with no shim, in loop mode: untrusted clicks,
  // whose renders all wait for one microtask after the run.
  "beni-untrusted": { kind: "beni", dir: `${base}/beni-dev`, edits: [] },
  // The development build again, as a second subject: the batch's noise.
  "beni-again": { kind: "beni", dir: `${base}/beni-dev`, edits: mode === "cdp" ? [] : shimDev },
  solid1: { kind: "solid", src: `/out/${base}/solid1.js`, module: false },
  p2: { kind: "script", src: `/out/${base}/p2.js` },
  vanillajs: { kind: "script", src: `/out/${base}/vanilla.js` },
};
for (const [name, edits] of Object.entries(ablations)) all[`abl-${name}`] = { kind: "beni", dir: `${base}/beni-dev`, edits: [...(mode === "cdp" ? [] : shimDev), ...edits] };

const wanted = arg("subjects", "beni,beni-release,solid1,p2,vanillajs").split(",");
const subjects = wanted.map((name) => {
  const s = all[name];
  if (s === undefined) throw new Error(`unknown subject ${name}`);
  if (s.kind !== "beni") return { ...s, subject: name, name: `${pageDir.replace("/", "-")}.${name}` };
  if (s.edits.length === 0) return { ...s, subject: name, name: `${pageDir.replace("/", "-")}.${name}` };
  const rel = `plumbing/${pageDir.replace("/", "-")}/${name}`;
  const dir = join(root, "out", rel);
  rmSync(dir, { recursive: true, force: true });
  cpSync(join(root, "out", s.dir), dir, { recursive: true });
  for (const [file, find, replace] of s.edits) {
    const f = join(dir, file);
    const text = readFileSync(f, "utf8");
    const hit = find instanceof RegExp ? find.test(text) : text.includes(find);
    if (!hit) throw new Error(`${name}: ${file} has no ${String(find).slice(0, 100)}`);
    writeFileSync(f, find instanceof RegExp ? text.replace(find, replace) : text.replace(find, () => replace));
  }
  return { kind: "beni", dir: rel, subject: name, name: `${pageDir.replace("/", "-")}.${name}` };
});
for (const s of subjects) if (!existsSync(join(root, s.dir ? `out/${s.dir}` : s.src))) throw new Error(`${s.subject}: not built (${s.dir ?? s.src})`);
if (process.argv.includes("--build-only")) process.exit(0);

// ---- Measuring -----------------------------------------------------------------

const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(subjects);
const result = {
  mode,
  page: pageDir,
  chrome: browser.version,
  node: process.version,
  commit: execSync("git rev-parse HEAD", { cwd: root }).toString().trim(),
  cpu: (await import("node:os")).cpus()[0].model,
  taskset: arg("taskset", null),
  settings: { pages, reps, n, warm, clicks, from },
  started: new Date().toISOString(),
  loadAtStart: loadavg(),
  samples: [],
  profiles: {},
};
const out = arg("out", null);
const save = () => {
  if (out === null) return;
  mkdirSync(dirname(join(root, out)), { recursive: true });
  writeFileSync(join(root, out), `${JSON.stringify(result)}\n`);
};

const doneText = (k) => String(k + doneOffset);
const loopScript = (count, runs, warmup) => `(async () => {
  const el = document.getElementById("go");
  const done = document.getElementById(${JSON.stringify(doneId)});
  const tick = () => new Promise((r) => setTimeout(r, 0));
  let k = 0;
  for (let i = 0; i < ${warmup}; i++) { el.click(); k++; }
  await tick();
  if (done.textContent !== String(k + ${doneOffset})) return { error: "after warm-up: " + done.textContent + " for " + k };
  const ns = [];
  for (let r = 0; r < ${runs}; r++) {
    const t0 = performance.now();
    for (let i = 0; i < ${count}; i++) el.click();
    const t1 = performance.now();
    k += ${count};
    ns.push(((t1 - t0) * 1e6) / ${count});
    await tick();
    if (done.textContent !== String(k + ${doneOffset})) return { error: "run " + r + ": " + done.textContent + " for " + k };
  }
  return { ns };
})()`;

// Self time per function and per line of a profile, in µs, added to `into`.
const addProfile = (profile, into) => {
  const byId = new Map(profile.nodes.map((x) => [x.id, x]));
  const dt = new Map();
  for (let i = 0; i < profile.samples.length; i++) dt.set(profile.samples[i], (dt.get(profile.samples[i]) ?? 0) + profile.timeDeltas[i]);
  for (const node of profile.nodes) {
    const f = node.callFrame;
    if (f.functionName === "(idle)") continue;
    const key = `${f.functionName || "(anonymous)"} ${f.url.replace(origin, "").replace(/^\/out\//, "")}:${f.lineNumber + 1}`;
    const self = dt.get(node.id) ?? 0;
    const e = (into[key] ??= { self: 0, lines: {} });
    e.self += self;
    const hits = node.hitCount || 0;
    for (const { line, ticks } of node.positionTicks ?? []) e.lines[line] = (e.lines[line] ?? 0) + (hits === 0 ? 0 : (self * ticks) / hits);
  }
  void byId;
};

async function measurePage(subject, pageIndex) {
  const page = await browser.newPage(`${origin}/s/${subject.name}/`);
  try {
    if (mode === "spread") {
      const widths = arg("widths", "64,128,256,512,1000,1016,1020,1021,1024,1030").split(",").map(Number);
      const rows = await page.eval(`(() => { ${microSource}; return micro(${JSON.stringify(widths)}, ${Number(arg("budget", "5"))}, null, null); })()`);
      return rows.map((r) => ({ subject: `spread ${r.w}`, page: pageIndex, ns: r.ns, q1: r.q1, q3: r.q3, n: r.n }));
    }
    await page.waitFor(`document.getElementById("go") !== null`);
    if (mode === "loop" || mode === "profile") {
      if (mode === "profile") {
        await page.send("Profiler.enable");
        await page.send("Profiler.setSamplingInterval", { interval: Number(arg("interval", "25")) });
        // Warm outside the profile; then the timed runs inside it.
        const w = await page.eval(loopScript(1, 1, warm));
        if (w.error) throw new Error(w.error);
        await page.send("Profiler.start");
      }
      const r = await page.eval(loopScript(n, reps, mode === "profile" ? 0 : warm));
      if (r.error) throw new Error(r.error);
      if (mode === "profile") {
        const { profile } = await page.send("Profiler.stop");
        const into = (result.profiles[subject.subject] ??= { messages: 0, fns: {} });
        into.messages += n * reps;
        addProfile(profile, into.fns);
      }
      return r.ns.map((ns, rep) => ({ subject: subject.subject, page: pageIndex, rep, ns }));
    }
    // cdp
    await page.eval(`(() => {
      window.__t = [];
      let t0 = 0;
      window.addEventListener("click", () => { t0 = performance.now(); }, true);
      window.addEventListener("click", () => { window.__t.push(performance.now() - t0); }, false);
      return true;
    })()`);
    const box = await page.locate(`document.getElementById("go")`);
    // `--profile`: a CPU profile over the clicks from `from` on.
    const profiling = process.argv.includes("--profile");
    if (profiling) {
      await page.send("Profiler.enable");
      await page.send("Profiler.setSamplingInterval", { interval: Number(arg("interval", "10")) });
    }
    for (let i = 0; i < clicks; i++) {
      if (profiling && i === from - 1) await page.send("Profiler.start");
      await page.press(box);
    }
    await sleep(20);
    if (profiling) {
      const { profile } = await page.send("Profiler.stop");
      const into = (result.profiles[subject.subject] ??= { messages: 0, fns: {} });
      into.messages += clicks - from + 1;
      addProfile(profile, into.fns);
    }
    await page.waitFor(`document.getElementById(${JSON.stringify(doneId)}).textContent === ${JSON.stringify(doneText(clicks))}`);
    const ts = await page.eval("window.__t");
    if (ts.length !== clicks) throw new Error(`${ts.length} clicks timed of ${clicks}`);
    return ts.map((ms, i) => ({ subject: subject.subject, page: pageIndex, click: i + 1, ns: ms * 1e6 })).filter((x) => x.click >= from);
  } finally {
    await page.close();
  }
}

const fmt = (xs) => (xs.length === 0 ? "—" : `${median(xs).toFixed(0).padStart(6)} [${quantile(xs, 0.25).toFixed(0)}–${quantile(xs, 0.75).toFixed(0)}]`);
const t0 = Date.now();
for (let i = 0; i < pages; i++) {
  for (let s = 0; s < subjects.length; s++) {
    const subject = subjects[(i + s) % subjects.length];
    try {
      result.samples.push(...(await measurePage(subject, i)));
    } catch (e) {
      console.error(`${subject.subject} #${i}: ${e.message}`);
    }
  }
  save();
}
result.finished = new Date().toISOString();
result.loadAtEnd = loadavg();
save();
console.log(`\n${pageDir} (${mode}, ${pages} pages; ${mode === "cdp" ? `${clicks} real clicks, from #${from}` : `${reps} runs of ${n} after ${warm}`}), ns per message, median [IQR] over ${mode === "cdp" ? "clicks" : "runs"}  [${((Date.now() - t0) / 1000).toFixed(0)} s, load ${result.loadAtStart[0].toFixed(2)}]`);
if (mode === "spread") for (const name of [...new Set(result.samples.map((r) => r.subject))]) console.log(`  ${name.padEnd(18)} ${fmt(result.samples.filter((r) => r.subject === name).map((r) => r.ns))} ns per spread (median over pages of each page's median)`);
for (const s of mode === "spread" ? [] : subjects) {
  const xs = result.samples.filter((r) => r.subject === s.subject).map((r) => r.ns);
  const perPage = [...new Set(result.samples.filter((r) => r.subject === s.subject).map((r) => r.page))].map((p) => median(result.samples.filter((r) => r.subject === s.subject && r.page === p).map((r) => r.ns)));
  const mean = xs.reduce((a, b) => a + b, 0) / Math.max(1, xs.length);
  console.log(`  ${s.subject.padEnd(18)} ${fmt(xs)}  mean ${mean.toFixed(0)}  page medians ${perPage.map((x) => x.toFixed(0)).join(" ")}`);
}
if (Object.keys(result.profiles).length > 0) {
  for (const [name, p] of Object.entries(result.profiles)) {
    const total = Object.values(p.fns).reduce((a, e) => a + e.self, 0);
    console.log(`\n  ${name}: ${((total * 1000) / p.messages).toFixed(0)} ns a message sampled`);
    for (const [key, e] of Object.entries(p.fns).sort((a, b) => b[1].self - a[1].self).slice(0, 16)) {
      const lines = Object.entries(e.lines).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([l, us]) => `L${l} ${((us * 1000) / p.messages).toFixed(0)}`).join(", ");
      console.log(`    ${((e.self * 1000) / p.messages).toFixed(0).padStart(6)} ns  ${key}${lines ? `   (${lines})` : ""}`);
    }
  }
}
server.close();
await browser.close();
