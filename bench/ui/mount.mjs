// The mount of a static page, timed from a real click, untraced
// (docs/design/browser-direct.md §12.2, §14 slice S0): `browser-tea` and
// `browser-direct`, development and `--release`, against the vanilla page
// that writes the same HTML through a `template` and appends it. One
// source per page, generated here; nothing on it changes after the mount.
//
//   node mount.mjs [--pages=15] [--sizes=hello,list1000] [--subjects=a,b]
//                  [--out=results/<date>-mount.json] [--taskset=8-15]
//                  [--beni=<path>] [--chrome=<path>]
//
// Each sample is one fresh page: the program's modules are loaded first,
// and a real click on `#go` (`Input.dispatchMouseEvent`) runs `run(main)`
// — the runtime's own entry, which mounts every program inside its guard —
// or the vanilla page's two statements. The time is the page's own, from a
// capture-phase click listener on `window`, which runs before any other,
// to a microtask a bubble-phase one queues, which runs after the click's
// listeners and every microtask they queued (scaling.mjs's `--untraced`).
// Style, layout and paint are not in it. A development build is started
// through its modules' exports; a release build is one scope-hoisted file
// that starts itself, so its last statement — `run(main)` — is made a
// function the click calls, and nothing else of it changes.
//
// Run it from `nix develop .#browser`. Quick: about a minute at the
// defaults.

import { execSync, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import { launch } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { median, quantile } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const pages = Number(arg("pages", "15"));
const beniExe = arg("beni", join(root, "../../zig-out/bin/beni"));
const date = new Date().toISOString().slice(0, 10);
const out = join(root, arg("out", `results/${date}-mount.json`));

// ---- The pages ------------------------------------------------------------

const hello = '<main><h1 class="title">Hello</h1><p>A static page, &amp; nothing to change.</p><hr /></main>';
const list = (n) => `<ul>${Array.from({ length: n }, (_, i) => `<li class="item">Item ${i}</li>`).join("")}</ul>`;
const sizes = {
  hello: { markup: hello, html: '<main><h1 class="title">Hello</h1><p>A static page, &amp; nothing to change.</p><hr></main>', done: `document.querySelector("h1.title") !== null` },
  list1000: { markup: list(1000), html: list(1000), done: `document.querySelectorAll("li.item").length === 1000` },
};
const wantedSizes = arg("sizes", Object.keys(sizes).join(",")).split(",");

const source = (markup) =>
  `import Html exposing (Html)\nimport Tea\n\n\nview : {} → Html {}\nview _ =\n    ${markup}\n\n\nmain : Tea.Program\nmain =\n    Tea.sandbox { init = {}, update = λ_ m → m, view = view }\n`;

const builds = [
  { name: "beni", platform: "browser-tea", release: false, runtime: "_platform/_browser/Rt.mjs", run: "Rt$run" },
  { name: "beni-release", platform: "browser-tea", release: true },
  { name: "beni-direct", platform: "browser-direct", release: false, runtime: "_platform/Direct.mjs", run: "Direct$run" },
  { name: "beni-direct-release", platform: "browser-direct", release: true },
];
const wantedSubjects = arg("subjects", [...builds.map((b) => b.name), "vanillajs"].join(",")).split(",");

// The click-to-microtask timer, and `#go`, which `start` is bound to.
const timer = `
window.__clickTimes = [];
let depth = 0, t0 = 0;
addEventListener("click", () => { if (depth++ === 0) t0 = performance.now(); }, true);
addEventListener("click", () => { if (--depth === 0) queueMicrotask(() => window.__clickTimes.push(performance.now() - t0)); });
const go = document.createElement("button");
go.id = "go";
go.textContent = "mount";
document.body.append(go);
`;

const subjects = [];
for (const size of wantedSizes) {
  const spec = sizes[size];
  if (spec === undefined) throw new Error(`unknown size ${size}`);
  const dir = `out/mount/${size}`;
  mkdirSync(join(root, dir), { recursive: true });
  writeFileSync(join(root, dir, "Main.beni"), source(spec.markup));
  for (const b of builds.filter((b) => wantedSubjects.includes(b.name))) {
    const outDir = `${dir}/${b.name}`;
    rmSync(join(root, outDir), { recursive: true, force: true });
    const r = spawnSync(beniExe, ["build", `--platform=${b.platform}`, ...(b.release ? ["--release"] : []), "--no-cache", `--out=${outDir}`, `${dir}/Main.beni`], { cwd: root, encoding: "utf8" });
    if (r.status !== 0) throw new Error(`${b.name} ${size}: ${r.stderr}`);
    let loader;
    if (!b.release) {
      loader = `import { Main$main as main } from "/${outDir}/Main.mjs";\nimport { ${b.run} as run } from "/${outDir}/${b.runtime}";\n${timer}go.addEventListener("click", () => run(main), { once: true });\nwindow.__ready = true;\n`;
    } else {
      // The release file's last statement is `run(main);`, before its
      // exports when it has any.
      const text = readFileSync(join(root, outDir, "_main.mjs"), "utf8");
      const m = /(\w+)\((\w+)\);(export\{[^}]*\};)?\s*$/.exec(text);
      if (m === null) throw new Error(`${b.name} ${size}: no run(main) at the end of the release file`);
      const held = `${text.slice(0, m.index)}window.__start=()=>${m[1]}(${m[2]});${m[3] ?? ""}`;
      writeFileSync(join(root, outDir, "held.mjs"), held);
      loader = `import "/${outDir}/held.mjs";\n${timer}go.addEventListener("click", () => window.__start(), { once: true });\nwindow.__ready = true;\n`;
    }
    writeFileSync(join(root, outDir, "loader.mjs"), loader);
    subjects.push({ name: `${size}.${b.name}`, subject: b.name, size, kind: "script", module: true, src: `/${outDir}/loader.mjs` });
  }
  if (wantedSubjects.includes("vanillajs")) {
    const vanilla = `${timer}const html = ${JSON.stringify(spec.html)};\ngo.addEventListener("click", () => { const t = document.createElement("template"); t.innerHTML = html; document.body.append(t.content); }, { once: true });\nwindow.__ready = true;\n`;
    writeFileSync(join(root, dir, "vanilla.mjs"), vanilla);
    subjects.push({ name: `${size}.vanillajs`, subject: "vanillajs", size, kind: "script", module: true, src: `/${dir}/vanilla.mjs` });
  }
}

// ---- Measuring ------------------------------------------------------------

const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(subjects);
const git = (cmd) => execSync(`git ${cmd}`, { cwd: root }).toString().trim();
const result = {
  chrome: browser.version,
  node: process.version,
  beni: spawnSync(beniExe, ["version"], { encoding: "utf8" }).stdout.trim(),
  commit: git("rev-parse HEAD"),
  dirty: git("status --porcelain") !== "",
  taskset: arg("taskset", null),
  started: new Date().toISOString(),
  pages,
  rows: [],
};

for (const size of wantedSizes) {
  const ofSize = subjects.filter((s) => s.size === size);
  for (let p = 0; p < pages; p++) {
    for (let k = 0; k < ofSize.length; k++) {
      const s = ofSize[(p + k) % ofSize.length];
      const page = await browser.newPage(`${origin}/s/${s.name}/`);
      await page.waitFor("window.__ready === true");
      await page.eval("window.gc && window.gc()");
      await page.click(`document.getElementById("go")`);
      await page.waitFor("window.__clickTimes.length === 1");
      if (!(await page.eval(sizes[size].done))) throw new Error(`${s.name}: the page does not show what it should`);
      const ms = await page.eval("window.__clickTimes[0]");
      await page.close();
      result.rows.push({ size, subject: s.subject, page: p, load: loadavg()[0], ms });
      console.log(`${size.padEnd(9)} ${s.subject.padEnd(20)} #${p} ${ms.toFixed(3)} ms`);
    }
  }
}
result.finished = new Date().toISOString();
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(result, null, 1));

// The table: the median and the quartiles over the pages, and the ratio of
// the medians to vanilla's.
console.log(`\n| page | subject | mount ms, median [q1–q3] | × vanilla |`);
console.log(`|---|---|--:|--:|`);
for (const size of wantedSizes) {
  const of = (subject) => result.rows.filter((r) => r.size === size && r.subject === subject).map((r) => r.ms);
  const vanilla = of("vanillajs");
  for (const subject of [...builds.map((b) => b.name), "vanillajs"]) {
    const xs = of(subject);
    if (xs.length === 0) continue;
    const ratio = vanilla.length === 0 ? "—" : (median(xs) / median(vanilla)).toFixed(2);
    console.log(`| ${size} | ${subject} | ${median(xs).toFixed(3)} [${quantile(xs, 0.25).toFixed(3)}–${quantile(xs, 0.75).toFixed(3)}] | ${ratio} |`);
  }
}
server.close();
await browser.close();
