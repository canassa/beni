// The empty `browser` page, hand-minified: every number in README.md comes
// from this script.
//
//   node measure.mjs build [RT OUT]     build the page (src/Page.beni, bench/size.mjs's
//                                       page, `--platform=browser --release`) with
//                                       ../../../zig-out/bin/beni into built/_main.mjs
//   node measure.mjs size [FILE…]       raw / gzip-9 / brotli-11 of each file
//                                       (default: built/_main.mjs and every steps/*.mjs)
//   node measure.mjs ledger             the ledger: every step against the one before
//   node measure.mjs units [FILE]       the file cut into top-level units: each unit's raw
//                                       bytes and its leave-one-out brotli cost
//   node measure.mjs test [FILE…]       behaviour of the page (see `pageTest`), in happy-dom
//   node measure.mjs corpus [RUNTIME]   every `browser/dom/` and `browser/tea/` fixture,
//                                       `--release`, built against a copy of the browser
//                                       platform whose runtime.js is RUNTIME (default
//                                       src/runtime.final.js), run in happy-dom and compared
//                                       with its golden
//   node measure.mjs terser [FILE]      the reference bound: terser over the file
//
// Run with the repo's Node (`direnv exec . node …`, or the Nix store path).

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import zlib from "node:zlib";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../../..");
const beni = process.env.BENI ?? join(repo, "zig-out/bin/beni");
const steps = join(here, "steps");

export function sizes(buf) {
  return {
    raw: buf.length,
    gz: zlib.gzipSync(buf, { level: 9 }).length,
    br: zlib.brotliCompressSync(buf, {
      params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: buf.length },
    }).length,
  };
}

function stepFiles() {
  return readdirSync(steps).filter((f) => f.endsWith(".mjs")).sort().map((f) => join(steps, f));
}

export function build(out, runtime = null) {
  const work = mkdtempSync(join(tmpdir(), "empty-page-"));
  cpSync(join(here, "src/Page.beni"), join(work, "Page.beni"));
  const root = runtime && patchedPlatforms(runtime);
  const r = spawnSync(beni, ["build", `--platform=${root ? join(root, "browser") : "browser"}`, "--diagnostics=json", "--out=out", "--root=.", "--release", "--allow-debug", "Page.beni"], { cwd: work, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`build failed\n${r.stdout}${r.stderr}`);
  mkdirSync(dirname(out), { recursive: true });
  cpSync(join(work, "out/_main.mjs"), out);
  rmSync(work, { recursive: true, force: true });
  if (root) rmSync(root, { recursive: true, force: true });
}

// Top-level units, by the same cut `Minify.zig` makes: a declaration to its `;`
// at depth 0 (or its newline, for the emitted half), an expression statement, the
// export list. Good enough for the files this study writes.
export function units(text) {
  const out = [];
  let depth = 0, start = 0, str = null;
  const tpl = [];
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (str) {
      if (c === "\\") { i++; continue; }
      if (str === "`" && c === "$" && text[i + 1] === "{") { depth++; i++; str = null; tpl.push(depth); continue; }
      if (c === str) str = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { str = c; continue; }
    if (c === "{" || c === "(" || c === "[") depth++;
    else if (c === "}" || c === ")" || c === "]") {
      if (c === "}" && tpl.length && tpl[tpl.length - 1] === depth) { tpl.pop(); depth--; str = "`"; continue; }
      depth--;
    } else if (depth === 0 && (c === ";" || c === "\n")) {
      const u = text.slice(start, i + 1);
      out.push(u);
      start = i + 1;
    }
  }
  if (start < text.length) out.push(text.slice(start));
  return out;
}

function table(rows, cols) {
  const w = cols.map((c) => Math.max(c.length, ...rows.map((r) => String(r[c]).length)));
  const line = (vals) => vals.map((v, j) => (typeof v === "number" ? String(v).padStart(w[j]) : String(v).padEnd(w[j]))).join("  ");
  console.log(line(cols));
  for (const r of rows) console.log(line(cols.map((c) => r[c])));
}

// ---- behaviour ------------------------------------------------------------

// The empty page's behaviour, in happy-dom, for one file: what the page shows
// after load (the driver's transcript, compared with the baseline build's);
// that `flush` is exported and callable; that a message sent through the
// body's `$$root` renders on one microtask and leaves the page as it was; and
// the two mount faults — no element with the id, and a node that holds a
// program already — each thrown with its exact message. The second and third
// are driven by reusing the file with its `run` call rewritten, so a step that
// changed `run`'s messages or checks is caught.
async function pageTest(file) {
  const { GlobalWindow: Window } = await import(pathToFileURL(join(repo, "tests/browser/happy-dom.mjs")).href);
  const text = readFileSync(file, "utf8");
  const results = [];
  const load = async (source, setup) => {
    const window = new Window({ url: "http://localhost/" });
    const saved = {};
    for (const k of ["document", "window", "queueMicrotask"]) saved[k] = globalThis[k];
    globalThis.document = window.document;
    globalThis.window = window;
    setup?.(window.document);
    const dir = mkdtempSync(join(tmpdir(), "empty-page-test-"));
    const path = join(dir, "page.mjs");
    writeFileSync(path, source);
    let mod, error = null;
    try {
      mod = await import(pathToFileURL(path).href);
    } catch (e) {
      error = e;
    }
    return { window, mod, error, restore: () => { Object.assign(globalThis, saved); rmSync(dir, { recursive: true, force: true }); } };
  };
  // 1. load: the body holds exactly one comment node, the fragment's marker.
  {
    const { window, mod, error, restore } = await load(text);
    const body = window.document.body;
    results.push(["load", error === null && body.childNodes.length === 1 && body.firstChild.nodeType === 8 && body.firstChild.data === "" ? "ok" : `FAIL ${error ?? body.innerHTML}`]);
    results.push(["$$root set", typeof body.$$root === "function" ? "ok" : "FAIL"]);
    results.push(["flush export", typeof mod?.flush === "function" ? "ok" : "FAIL"]);
    const marker = body.firstChild;
    body.$$root(1);
    body.$$root(2);
    await new Promise((r) => setTimeout(r, 0));
    results.push(["send renders, same node", body.childNodes.length === 1 && body.firstChild === marker ? "ok" : `FAIL ${body.innerHTML}`]);
    mod?.flush?.();
    results.push(["flush with nothing queued", body.firstChild === marker ? "ok" : "FAIL"]);
    restore();
  }
  // 2. a second mount at the body: the page's body already holds a program.
  {
    const { error, restore } = await load(text, (d) => { d.body.$$root = () => {}; });
    results.push(["body already holds", error?.message === "the page's body already holds a program" ? "ok" : `FAIL ${error?.message}`]);
    restore();
  }
  // 3. the mount record's `n` pointed at a missing and at a taken id: the run
  //    call is rewritten to mount at "app" (the emitted `{a:…,n:null}`).
  {
    const at = text.replace(/n:null\}/, 'n:"app"}');
    // From step 09 on the record's `n` is folded away (the program mounts at
    // the body, and nothing else can reach the id path); cases 4 and 5 cover
    // what is left of it.
    if (at === text) results.push(["mount at an id", /n:null/.test(text) || /getElementById/.test(text) ? "FAIL (n:null not found but the id path is still there)" : "ok"]);
    else {
      let r = await load(at);
      results.push(["no element has the id", r.error?.message === 'no element has the id "app" to mount a program at' ? "ok" : `FAIL ${r.error?.message}`]);
      r.restore();
      r = await load(at, (d) => { const e = d.createElement("div"); e.id = "app"; e.$$root = () => {}; d.body.append(e); });
      results.push(["the element already holds", r.error?.message === 'the element "app" already holds a program' ? "ok" : `FAIL ${r.error?.message}`]);
      r.restore();
      r = await load(at, (d) => { const e = d.createElement("div"); e.id = "app"; e.append(d.createElement("p")); d.body.append(e); });
      const app = r.window.document.getElementById("app");
      results.push(["mount after children", r.error === null && app.childNodes.length === 2 && app.lastChild.nodeType === 8 ? "ok" : `FAIL ${r.error} ${app.innerHTML}`]);
      r.restore();
    }
  }
  // 4. no body yet (a script run from the head): the id message with `null`,
  //    exactly as `${m.n}` printed it.
  {
    const { error, restore } = await load(text, (d) => { d.documentElement.removeChild(d.body); });
    results.push(["no body", error?.message === 'no element has the id "null" to mount a program at' ? "ok" : `FAIL ${error?.message}`]);
    restore();
  }
  // 5. a body with children: the program's node goes after them, and the
  //    children are untouched.
  {
    const { window, error, restore } = await load(text, (d) => { d.body.append(d.createElement("p"), d.createTextNode("x")); });
    const b = window.document.body;
    results.push(["mount after the body's children", error === null && b.childNodes.length === 3 && b.childNodes[0].nodeName === "P" && b.childNodes[1].data === "x" && b.lastChild.nodeType === 8 && b.lastChild.data === "" ? "ok" : `FAIL ${error} ${b.innerHTML}`]);
    restore();
  }
  return results;
}

// ---- the corpus against a patched runtime ---------------------------------

function corpusFixtures() {
  const out = [];
  for (const [sub, platform] of [["dom", "browser"], ["tea", "browser-tea"]]) {
    const dir = join(repo, "tests/corpus/browser", sub);
    for (const e of readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      if (e.isDirectory()) {
        const p = join(dir, e.name);
        out.push({ name: `${sub}/${e.name}`, platform, dir: p, sources: readdirSync(p).filter((f) => f.endsWith(".beni")).sort(), golden: join(p, "_expected"), });
      } else if (e.name.endsWith(".beni")) {
        const stem = e.name.slice(0, -5);
        out.push({ name: `${sub}/${stem}`, platform, dir, sources: [e.name], golden: join(dir, stem) });
      }
    }
  }
  return out;
}

export function patchedPlatforms(runtime) {
  const root = mkdtempSync(join(tmpdir(), "empty-page-platform-"));
  cpSync(join(repo, "platforms/browser"), join(root, "browser"), { recursive: true });
  rmSync(join(root, "browser/zig"), { recursive: true, force: true });
  const bj = JSON.parse(readFileSync(join(root, "browser/beni.json"), "utf8"));
  delete bj.zig; // the `dom` lowering is registered in the binary by name
  writeFileSync(join(root, "browser/beni.json"), JSON.stringify(bj));
  cpSync(runtime, join(root, "browser/runtime.js"));
  cpSync(join(repo, "platforms/browser-tea"), join(root, "browser-tea"), { recursive: true });
  const tj = JSON.parse(readFileSync(join(root, "browser-tea/beni.json"), "utf8"));
  tj.platforms = ["../browser"];
  writeFileSync(join(root, "browser-tea/beni.json"), JSON.stringify(tj));
  return root;
}

export function corpus(runtime, { rewrite = null, dev = false, chrome = null } = {}) {
  const root = patchedPlatforms(runtime);
  const work = mkdtempSync(join(tmpdir(), "empty-page-corpus-"));
  let failed = 0;
  const rows = [];
  for (const f of corpusFixtures()) {
    const w = join(work, f.name.replace("/", "_"));
    mkdirSync(w, { recursive: true });
    for (const s of f.sources) cpSync(join(f.dir, s), join(w, s));
    const args = ["build", `--platform=${join(root, f.platform)}`, "--out=out", ...(dev ? [] : ["--release", "--allow-debug"]), ...f.sources];
    const b = spawnSync(beni, args, { cwd: w, encoding: "utf8" });
    if (b.status !== 0) { failed++; rows.push({ fixture: f.name, result: `BUILD FAILED ${b.stderr.slice(0, 300)}` }); continue; }
    const entry = join(w, "out/_main.mjs");
    if (rewrite) writeFileSync(entry, rewrite(readFileSync(entry, "utf8")));
    const stepsFile = `${f.golden}.steps`;
    const driverArgs = [join(repo, "tests/browser/driver.mjs"), chrome ? `--chrome=${chrome}` : `--dom=${join(repo, "tests/browser/happy-dom.mjs")}`, entry, ...(existsSync(stepsFile) ? [stepsFile] : [])];
    const r = spawnSync(process.execPath, driverArgs, { encoding: "utf8" });
    const want = [chrome && `${f.golden}.chrome-expected`, !dev && `${f.golden}.release-expected`, `${f.golden}.expected`].find((p) => p && existsSync(p));
    const ok = r.status === 0 && r.stdout === readFileSync(want, "utf8");
    if (!ok) failed++;
    rows.push({ fixture: f.name, result: ok ? "ok" : `FAIL (exit ${r.status}) ${r.stderr.slice(0, 300)}` });
  }
  rmSync(work, { recursive: true, force: true });
  rmSync(root, { recursive: true, force: true });
  return { rows, failed };
}

// ---- main -----------------------------------------------------------------

const main = process.argv[1] !== undefined && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
const [cmd = "size", ...rest] = main ? process.argv.slice(2) : ["none"];
if (cmd === "build") {
  // `build`: the embedded platform; `build RUNTIME OUT`: a copy of it whose runtime.js is RUNTIME.
  const out = rest[1] ? resolve(rest[1]) : join(here, "built/_main.mjs");
  build(out, rest[0] ? resolve(rest[0]) : null);
  console.log(out.startsWith(here) ? out.slice(here.length + 1) : out, sizes(readFileSync(out)));
} else if (cmd === "size") {
  const files = rest.length ? rest : [join(here, "built/_main.mjs"), ...stepFiles()];
  table(files.map((f) => ({ file: f.startsWith(here) ? f.slice(here.length + 1) : f, ...sizes(readFileSync(f)) })), ["file", "raw", "gz", "br"]);
} else if (cmd === "ledger") {
  let prev = null;
  const rows = [];
  for (const f of stepFiles()) {
    const s = sizes(readFileSync(f));
    rows.push({ step: basename(f, ".mjs"), raw: s.raw, gz: s.gz, br: s.br, "Δraw": prev ? s.raw - prev.raw : "", "Δgz": prev ? s.gz - prev.gz : "", "Δbr": prev ? s.br - prev.br : "" });
    prev = s;
  }
  table(rows, ["step", "raw", "gz", "br", "Δraw", "Δgz", "Δbr"]);
} else if (cmd === "units") {
  const file = rest[0] ?? join(here, "built/_main.mjs");
  const text = readFileSync(file, "utf8");
  const us = units(text);
  const whole = sizes(Buffer.from(text)).br;
  table(us.map((u) => ({ unit: u.slice(0, 48).replace(/\n/g, "⏎"), raw: u.length, "br if removed": whole - sizes(Buffer.from(us.filter((x) => x !== u).join(""))).br, "br alone": sizes(Buffer.from(u)).br })), ["unit", "raw", "br if removed", "br alone"]);
  console.log(`whole: ${JSON.stringify(sizes(Buffer.from(text)))}; units ${us.length}, rejoined equal: ${us.join("") === text}`);
} else if (cmd === "test") {
  const files = rest.length ? rest : [join(here, "built/_main.mjs"), ...stepFiles()];
  let bad = 0;
  for (const f of files) {
    const res = await pageTest(f);
    const fails = res.filter(([, r]) => r !== "ok");
    bad += fails.length;
    console.log(`${basename(f)}: ${fails.length ? fails.map(([n, r]) => `${n}: ${r}`).join("; ") : `ok (${res.length} checks)`}`);
  }
  process.exit(bad ? 1 : 0);
} else if (cmd === "corpus") {
  const runtime = resolve(rest.find((a) => !a.startsWith("--")) ?? join(here, "src/runtime.final.js"));
  const chrome = rest.find((a) => a.startsWith("--chrome="))?.slice(9) ?? null;
  const { rows, failed } = corpus(runtime, { dev: rest.includes("--dev"), chrome });
  table(rows, ["fixture", "result"]);
  console.log(`${rows.length - failed}/${rows.length} ok`);
  process.exit(failed ? 1 : 0);
} else if (cmd === "terser") {
  const file = rest[0] ?? join(here, "built/_main.mjs");
  const { minify } = await import(pathToFileURL(process.env.TERSER ?? join(repo, "bench/arrays/node_modules/terser/main.js")).href);
  const r = await minify(readFileSync(file, "utf8"), { module: true, compress: { passes: 3, toplevel: true, unsafe_arrows: true, pure_getters: true }, mangle: { toplevel: true } });
  console.log(r.code);
  console.log(sizes(Buffer.from(r.code)));
} else if (cmd === "steps") {
  // Regenerate steps/ and src/runtime.final.js from steps.mjs.
  const { STEPS } = await import("./steps.mjs");
  rmSync(steps, { recursive: true, force: true });
  mkdirSync(steps, { recursive: true });
  const work = mkdtempSync(join(tmpdir(), "empty-page-steps-"));
  let runtime = readFileSync(join(here, "src/runtime.js"), "utf8");
  let shipped = null;
  let built = false;
  for (const s of STEPS) {
    if (s.kind === "source") {
      if (built) throw new Error(`step ${s.id}: a source step after an output step`);
      runtime = s.edit(runtime);
      writeFileSync(join(work, "runtime.js"), runtime);
      build(join(work, "out.mjs"), join(work, "runtime.js"));
      shipped = readFileSync(join(work, "out.mjs"), "utf8");
    } else {
      built = true;
      shipped = s.edit(shipped);
    }
    writeFileSync(join(steps, `${s.id}-${s.name}.mjs`), shipped);
  }
  writeFileSync(join(here, "src/runtime.final.js"), runtime);
  rmSync(work, { recursive: true, force: true });
  console.log(`${STEPS.length} steps written`);
} else if (cmd === "verify") {
  // Every step: the page test; every source step: the corpus against its
  // cumulative runtime; every generic output step: the corpus against the
  // final runtime with the generic rewrites so far applied to each page.
  const { STEPS } = await import("./steps.mjs");
  const work = mkdtempSync(join(tmpdir(), "empty-page-verify-"));
  let runtime = readFileSync(join(here, "src/runtime.js"), "utf8");
  const rewrites = [];
  let bad = 0;
  const skipCorpus = rest.includes("--page-only");
  for (const s of STEPS) {
    const file = join(steps, `${s.id}-${s.name}.mjs`);
    const res = await pageTest(file);
    const fails = res.filter(([, r]) => r !== "ok");
    let line = `${s.id}-${s.name}: page ${fails.length ? fails.map(([n, r]) => `${n}: ${r}`).join("; ") : `ok (${res.length})`}`;
    bad += fails.length;
    let corpusRun = null;
    if (s.kind === "source") {
      runtime = s.edit(runtime);
      corpusRun = { rewrite: null };
    } else if (s.generic) {
      rewrites.push(s.generic);
      corpusRun = { rewrite: (t) => rewrites.reduce((x, f) => f(x), t) };
    }
    if (corpusRun && !skipCorpus && s.id !== "00") {
      writeFileSync(join(work, "runtime.js"), runtime);
      const { rows, failed } = corpus(join(work, "runtime.js"), corpusRun);
      bad += failed;
      line += `; corpus ${rows.length - failed}/${rows.length}${failed ? ` FAILED: ${rows.filter((r) => r.result !== "ok").map((r) => `${r.fixture} ${r.result}`).join("; ")}` : ""}`;
    }
    console.log(line);
  }
  rmSync(work, { recursive: true, force: true });
  process.exit(bad ? 1 : 0);
} else if (cmd === "chrome") {
  // The headless-Chrome check (`nix develop .#browser`, or CHROME=<binary>):
  // the corpus against the final runtime with every generic rewrite, the load
  // transcript of the first and the last step (which must be equal), and
  // tools/timing.mjs in a page.
  const { STEPS } = await import("./steps.mjs");
  const profile = mkdtempSync(join(tmpdir(), "empty-page-chrome-"));
  const { spawn } = await import("node:child_process");
  const chrome = spawn(process.env.CHROME ?? "chromium", ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--disable-gpu", "--allow-file-access-from-files", "--disable-extensions", "--disable-background-networking", "--disable-component-update", "--disable-sync", "--mute-audio", "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows", "about:blank"], { stdio: "ignore" });
  let ws = null;
  for (let t = 0; t < 300 && ws === null; t++) {
    await new Promise((r) => setTimeout(r, 100));
    const p = join(profile, "DevToolsActivePort");
    if (existsSync(p)) { const [port, path] = readFileSync(p, "utf8").split("\n"); if (path) ws = `ws://127.0.0.1:${port}${path}`; }
  }
  if (ws === null) throw new Error("Chrome did not start");
  try {
    const work = mkdtempSync(join(tmpdir(), "empty-page-chrome-rt-"));
    writeFileSync(join(work, "runtime.js"), readFileSync(join(here, "src/runtime.final.js")));
    const generic = STEPS.filter((s) => s.generic).map((s) => s.generic);
    const { rows, failed } = corpus(join(work, "runtime.js"), { chrome: ws, rewrite: (t) => generic.reduce((x, f) => f(x), t) });
    console.log(`corpus in Chrome, final runtime and every generic rewrite: ${rows.length - failed}/${rows.length}${failed ? ` FAILED: ${rows.filter((r) => r.result !== "ok").map((r) => `${r.fixture} ${r.result}`).join("; ")}` : ""}`);
    const files = stepFiles();
    const transcript = (f) => {
      const dir = mkdtempSync(join(tmpdir(), "empty-page-chrome-page-"));
      cpSync(f, join(dir, "_main.mjs"));
      const r = spawnSync(process.execPath, [join(repo, "tests/browser/driver.mjs"), `--chrome=${ws}`, join(dir, "_main.mjs")], { encoding: "utf8" });
      return `${r.status}\n${r.stdout}${r.stderr}`;
    };
    const first = transcript(files[0]);
    const last = transcript(files[files.length - 1]);
    console.log(`load transcript in Chrome, ${basename(files[0])} vs ${basename(files[files.length - 1])}: ${first === last ? "equal" : "DIFFERENT"}\n${first}`);
    if (rest.includes("--timing")) {
      // tools/timing.mjs in a fresh target, read back from the page's body.
      const sock = new WebSocket(ws);
      await new Promise((r) => (sock.onopen = r));
      let id = 0;
      const pending = new Map();
      sock.onmessage = (m) => { const d = JSON.parse(m.data); pending.get(d.id)?.(d.result); };
      const send = (method, params = {}, sessionId) => new Promise((r) => { pending.set(++id, r); sock.send(JSON.stringify({ id, method, params, sessionId })); });
      const { targetId } = await send("Target.createTarget", { url: "about:blank" });
      const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
      const code = readFileSync(join(here, "tools/timing.mjs"), "utf8");
      const r = await send("Runtime.evaluate", { expression: `(()=>{${code}\nreturn document.body.textContent})()`, returnByValue: true }, sessionId);
      console.log(`tools/timing.mjs in Chrome:\n${r?.result?.value ?? JSON.stringify(r)}`);
      sock.close();
    }
    rmSync(work, { recursive: true, force: true });
    if (failed || first !== last) process.exitCode = 1;
  } finally {
    chrome.kill();
    await new Promise((r) => setTimeout(r, 300));
    rmSync(profile, { recursive: true, force: true });
  }
} else if (cmd !== "none") {
  console.error(`unknown command ${cmd}`);
  process.exit(2);
}
