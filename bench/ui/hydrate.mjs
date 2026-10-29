// Hydration measured (docs/design/prerender.md §11, slice P2a): beni's
// hydrating mount of a page `beni build --prerender --release` wrote,
// against Solid 2's `hydrate` of its own hydratable `renderToString` output
// of the same page, in headless Chrome (research 29's harness, `lib/`).
//
//   node hydrate.mjs [--loads=21] [--pages=counter,static,arms]
//                    [--out=results/<date>-hydrate.json] [--taskset=8-15]
//                    [--beni=<path>] [--chrome=<path>]
//
// Each sample is one fresh page load. The page's one module file is the
// subject's whole client — beni's release `_main.mjs`, Solid's Vite and
// terser bundle — with one statement put in front of it, which reads
// `performance.now()`, and one after it, which queues a microtask that reads
// it again: the time from the module's start to the end of the mount, every
// handler attached, and every microtask the mount queued before it run.
// `script` is that; `load` is from the navigation's start to the same
// point, and holds the page's fetch, parse and the module's compile too.
// After the sample, outside it, a real click on the page's button must
// change what the page shows, or the run fails: the page was taken over.
//
// The pages, generated here for both, written as each framework writes
// them (beni's inline markup, Solid's JSX with signals, `<Show>` for an arm):
//
//   counter  a heading, a text hole, two buttons
//   static   research 29's static-heavy page: 50 sections, each a heading
//            with a text hole, a list of 12 items and a paragraph (about
//            2 000 elements), and one button that changes a hole
//   arms     30 panels, each a button and a body behind an arm, every
//            other body hidden by the first model
//
// Run it from `nix develop .#browser`; it needs `apps/solid2/node_modules`
// (`node build.mjs` installs it). Quick: about a minute at the defaults.

import { execSync, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { loadavg } from "node:os";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import { launch } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { median, quantile } from "./lib/trace.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const loads = Number(arg("loads", "21"));
const beniExe = arg("beni", join(root, "../../zig-out/bin/beni"));
const date = new Date().toISOString().slice(0, 10);
const out = join(root, arg("out", `results/${date}-hydrate.json`));
const range = (n) => Array.from({ length: n }, (_, i) => i);
const write = (path, text) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
};

// ---- The pages ------------------------------------------------------------

const SECTIONS = 50;
const ITEMS = 12;
const PANELS = 30;

const beniHead = "import Browser\nimport Html exposing (Html)\nimport Tea\n\n\n";
const beniMain = 'main : Tea.Program\nmain =\n    Browser.mountAt (Tea.sandbox { init = init, update = update, view = view }) "root"\n';

const pages = {
  counter: {
    beni: `${beniHead}type alias Model =\n    count : Int\n\n\ntype Msg\n    = Inc\n    | Dec\n\n\ninit : ⊤ → Model\ninit ⊤ = { count = 0 }\n\n\nupdate : Msg, Model → Model\nupdate msg model =\n    case msg of\n        Inc →\n            { model | count = model.count + 1 }\n\n        Dec →\n            { model | count = model.count - 1 }\n\n\nview : Model → Html Msg\nview model =\n    <div>\n        <h1>Counter</h1>\n        <output>{model.count}</output>\n        <button id="go" onClick={Inc}>+</button>\n        <button onClick={Dec}>-</button>\n    </div>\n\n\n${beniMain}`,
    solid: `import { createSignal } from "solid-js";\nexport const App = () => {\n  const [count, setCount] = createSignal(0);\n  return (\n    <div>\n      <h1>Counter</h1>\n      <output>{count()}</output>\n      <button id="go" onClick={() => setCount((c) => c + 1)}>+</button>\n      <button onClick={() => setCount((c) => c - 1)}>-</button>\n    </div>\n  );\n};\n`,
    shown: `document.querySelector("output").textContent`,
  },
  static: {
    beni: (() => {
      const fields = range(SECTIONS).map((i) => `    v${i} : Int\n`).join("");
      const zeros = range(SECTIONS).map((i) => `v${i} = 0`).join(", ");
      const section = (i) =>
        `        <section data-k="s">\n            <h2>Section ${i} <span>{model.v${i}}</span></h2>\n            <ul>\n${range(ITEMS).map((j) => `                <li><a href="#">item ${j}</a> <em>note</em></li>\n`).join("")}            </ul>\n            <p>The static text of section ${i}, which no message changes.</p>\n        </section>\n`;
      return `${beniHead}type alias Model =\n${fields}\n\ntype Msg\n    = Bump\n\n\ninit : ⊤ → Model\ninit ⊤ = { ${zeros} }\n\n\nupdate : Msg, Model → Model\nupdate msg model =\n    case msg of\n        Bump →\n            { model | v0 = model.v0 + 1 }\n\n\nview : Model → Html Msg\nview model =\n    <main>\n        <button id="go" onClick={Bump}>bump</button>\n${range(SECTIONS).map(section).join("")}    </main>\n\n\n${beniMain}`;
    })(),
    solid: (() => {
      const section = (i) =>
        `      <section data-k="s">\n        <h2>Section ${i} <span>{values[${i}][0]()}</span></h2>\n        <ul>\n${range(ITEMS).map((j) => `          <li><a href="#">item ${j}</a> <em>note</em></li>\n`).join("")}        </ul>\n        <p>The static text of section ${i}, which no message changes.</p>\n      </section>\n`;
      return `import { createSignal } from "solid-js";\nexport const App = () => {\n  const values = Array.from({ length: ${SECTIONS} }, () => createSignal(0));\n  return (\n    <main>\n      <button id="go" onClick={() => values[0][1]((v) => v + 1)}>bump</button>\n${range(SECTIONS).map(section).join("")}    </main>\n  );\n};\n`;
    })(),
    shown: `document.querySelector("h2 span").textContent`,
  },
  arms: {
    beni: (() => {
      const fields = range(PANELS).map((i) => `    o${i} : Bool\n`).join("");
      const init = range(PANELS).map((i) => `o${i} = ${i % 2 === 0 ? "True" : "False"}`).join(", ");
      const msgs = range(PANELS).map((i) => `${i === 0 ? "    = " : "    | "}T${i}\n`).join("");
      const arms = range(PANELS).map((i) => `        T${i} →\n            { model | o${i} = not model.o${i} }\n`).join("\n");
      const panel = (i) =>
        `        <section>\n            <button${i === 1 ? ' id="go"' : ""} onClick={T${i}}>Panel ${i}</button>\n            {if model.o${i} then\n                <div>\n                    <p>The body of panel ${i}</p>\n                    <ul><li>one</li><li>two</li></ul>\n                    <button onClick={T${i}}>Close</button>\n                </div>\n             else\n                <></>\n            }\n        </section>\n`;
      return `${beniHead}type alias Model =\n${fields}\n\ntype Msg\n${msgs}\n\ninit : ⊤ → Model\ninit ⊤ = { ${init} }\n\n\nupdate : Msg, Model → Model\nupdate msg model =\n    case msg of\n${arms}\n\nview : Model → Html Msg\nview model =\n    <main>\n${range(PANELS).map(panel).join("")}    </main>\n\n\n${beniMain}`;
    })(),
    solid: (() => {
      const panel = (i) =>
        `      <section>\n        <button${i === 1 ? ' id="go"' : ""} onClick={() => flip(${i})}>Panel ${i}</button>\n        <Show when={open[${i}][0]()}>\n          <div>\n            <p>The body of panel ${i}</p>\n            <ul><li>one</li><li>two</li></ul>\n            <button onClick={() => flip(${i})}>Close</button>\n          </div>\n        </Show>\n      </section>\n`;
      return `import { createSignal, Show } from "solid-js";\nexport const App = () => {\n  const open = Array.from({ length: ${PANELS} }, (_, i) => createSignal(i % 2 === 0));\n  const flip = (i) => open[i][1]((o) => !o);\n  return (\n    <main>\n${range(PANELS).map(panel).join("")}    </main>\n  );\n};\n`;
    })(),
    // Panel 1's body opens: the page shows one more paragraph.
    shown: `document.querySelectorAll("p").length`,
  },
};
const wanted = arg("pages", Object.keys(pages).join(",")).split(",");

// ---- Building -------------------------------------------------------------

const shell = (title, view, script) =>
  `<!doctype html>\n<html lang="en">\n  <head>\n    <meta charset="utf-8">\n    <title>${title}</title>\n    <script type="module" src="${script}"></script>\n  </head>\n  <body><div id="root">${view}</div></body>\n</html>\n`;
// The module, timed: its start, and a microtask queued at its end.
const timed = (js) => `window.__t0=performance.now();\n${js}\nqueueMicrotask(()=>{window.__t1=performance.now()});\n`;
const sizes = (bytes) => ({
  raw: bytes.length,
  gzip: gzipSync(bytes, { level: 9 }).length,
  brotli: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length,
});

const solidDir = join(root, "apps/solid2");
const subjects = [];
const bytes = {};
for (const page of wanted) {
  const spec = pages[page];
  if (spec === undefined) throw new Error(`unknown page ${page}`);
  const dir = join(root, "out/hydrate", page);
  rmSync(dir, { recursive: true, force: true });

  // beni: the client of `--prerender --release`, and the page it wrote.
  write(join(dir, "beni/src/Main.beni"), spec.beni);
  write(join(dir, "beni/src/shell.html"), shell(page, "{{view}}", "{{entry}}"));
  write(join(dir, "beni/src/beni.json"), '{ "html": "shell.html" }\n');
  const b = spawnSync(beniExe, ["build", "--platform=browser-inline", "--prerender", "--release", "--no-cache", "--out=../out", "Main.beni"], { cwd: join(dir, "beni/src"), encoding: "utf8" });
  if (b.status !== 0) throw new Error(`beni ${page}: ${b.stderr}`);
  const beniJs = readFileSync(join(dir, "beni/out/_main.mjs"));
  // The same program built without `--prerender`, mounted fresh: what the
  // hydrating mount adds is the difference.
  const f = spawnSync(beniExe, ["build", "--platform=browser-inline", "--release", "--no-cache", "--out=../fresh", "Main.beni"], { cwd: join(dir, "beni/src"), encoding: "utf8" });
  if (f.status !== 0) throw new Error(`beni ${page} fresh: ${f.stderr}`);
  const freshJs = readFileSync(join(dir, "beni/fresh/_main.mjs"));
  write(join(dir, "beni/out/timed.mjs"), timed(beniJs.toString()));
  const beniHtml = readFileSync(join(dir, "beni/out/index.html"), "utf8").replace('src="/_main.mjs"', `src="/out/hydrate/${page}/beni/out/timed.mjs"`);

  // Solid 2: the hydratable client bundle and the server build that renders
  // the page, both from one `App`, Vite with `solid({ ssr: true })`.
  const src = join(solidDir, "src/hydrate", page);
  write(join(src, "App.jsx"), spec.solid);
  write(join(src, "client.jsx"), `import { hydrate } from "@solidjs/web";\nimport { App } from "./App.jsx";\nhydrate(() => <App />, document.getElementById("root"));\n`);
  write(join(src, "server.jsx"), `import { generateHydrationScript, renderToString } from "@solidjs/web";\nimport { App } from "./App.jsx";\nexport const html = () => renderToString(() => <App />);\nexport const script = () => generateHydrationScript();\n`);
  const vite = (extra, env) => {
    const r = spawnSync("npx", ["vite", "build", "--logLevel", "warn", "--config", "vite.hydrate.config.mjs", ...extra], { cwd: solidDir, stdio: "inherit", env: { ...process.env, ...env } });
    if (r.status !== 0) throw new Error(`vite ${page} ${extra.join(" ")}: exit ${r.status}`);
  };
  vite([], { PAGE: page, OUT: join(dir, "solid") });
  // In the app's directory, where Node finds the packages it leaves out.
  vite(["--ssr", `src/hydrate/${page}/server.jsx`], { PAGE: page, OUT: join(src, "server") });
  const { html, script } = await import(join(src, "server/server.js"));
  const solidJs = readFileSync(join(dir, "solid/client.js"));
  write(join(dir, "solid/timed.js"), timed(solidJs.toString()));
  // Solid's page holds its hydration script in its head, which `hydrate`
  // needs (`generateHydrationScript`): its bytes are the page's.
  const solidHtml = shell(page, html(), `/out/hydrate/${page}/solid/timed.js`).replace("</head>", `${script()}</head>`);

  bytes[page] = {
    beni: { js: sizes(beniJs), fresh: sizes(freshJs), html: sizes(Buffer.from(beniHtml)) },
    solid: { js: sizes(solidJs), html: sizes(Buffer.from(solidHtml)) },
  };
  subjects.push({ name: `${page}.beni`, page, subject: "beni", kind: "html", html: beniHtml });
  subjects.push({ name: `${page}.solid`, page, subject: "solid", kind: "html", html: solidHtml });
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
  loads,
  bytes,
  rows: [],
};

for (const page of wanted) {
  const of = subjects.filter((s) => s.page === page);
  for (let i = 0; i < loads; i++) {
    for (let k = 0; k < of.length; k++) {
      const s = of[(i + k) % of.length];
      const p = await browser.newPage(`${origin}/s/${s.name}/`);
      await p.waitFor("window.__t1 !== undefined");
      const script = await p.eval("window.__t1 - window.__t0");
      const load = await p.eval("window.__t1");
      // Taken over: no `data-beni` and no `data-hk` left to claim, and a real
      // click changes what the page shows.
      const before = await p.eval(pages[page].shown);
      await p.click(`document.getElementById("go")`);
      await p.waitFor(`String(${pages[page].shown}) !== ${JSON.stringify(String(before))}`, 5000);
      await p.close();
      result.rows.push({ page, subject: s.subject, load: loadavg()[0], script, navigation: load });
      console.log(`${page.padEnd(8)} ${s.subject.padEnd(6)} #${i} script ${script.toFixed(3)} ms  load ${load.toFixed(1)} ms`);
    }
  }
}
result.finished = new Date().toISOString();
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(result, null, 1));

console.log(`\n| page | subject | module start → handlers, ms, median [q1–q3] | navigation → handlers, ms, median | JS bytes, brotli (raw) | page HTML bytes, brotli |`);
console.log(`|---|---|--:|--:|--:|--:|`);
for (const page of wanted) {
  for (const subject of ["beni", "solid"]) {
    const rows = result.rows.filter((r) => r.page === page && r.subject === subject);
    const xs = rows.map((r) => r.script);
    const ys = rows.map((r) => r.navigation);
    const b = bytes[page][subject];
    console.log(`| ${page} | ${subject} | ${median(xs).toFixed(3)} [${quantile(xs, 0.25).toFixed(3)}–${quantile(xs, 0.75).toFixed(3)}] | ${median(ys).toFixed(1)} | ${b.js.brotli} (${b.js.raw}) | ${b.html.brotli} |`);
  }
}
console.log(`\nbeni's hydrating client against the same program mounted fresh, brotli:`);
for (const page of wanted) {
  const b = bytes[page].beni;
  console.log(`  ${page}: ${b.js.brotli} B against ${b.fresh.brotli} B, +${b.js.brotli - b.fresh.brotli} B`);
}
server.close();
await browser.close();
