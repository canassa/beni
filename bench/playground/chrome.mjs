// Measure the playground in a headless Chrome (docs/design/playground.md
// §7.2, §8). Not a gate: it needs a Chrome, which `nix develop .#browser`
// puts on PATH, and it reports times, which move with the machine's load.
//
//   node bench/playground/chrome.mjs <chrome> <site> [--runs=10]
//
// <site> is what `zig build playground` writes (`zig-out/playground`). The
// script serves it on 127.0.0.1, opens pages in a fresh headless Chrome over
// the DevTools protocol, and prints, as JSON:
//   - `load`: the worker's fetch and compile of `beni.wasm`, as the page
//     records it (`data-compiler-loaded-ms`);
//   - `editorReady`: from the start of the navigation to the editor on the
//     page, which the vendored CodeMirror modules make (§4.2);
//   - `counter` and `firstBuildAt`: the first compile, the counter sample,
//     as the worker timed it, and when it was shown, from the start of the
//     navigation;
//   - `todomvc`: one compile per run of `bench/todomvc/apps/beni/Sandbox.beni`,
//     opened from a link and then edited by typing a different trailing
//     comment each run, as the page's worker timed it;
//   - `print`: the printing sample's compile, and how many lines its frame
//     printed;
//   - `depth`: the deepest call `f (f (… 1))` the page compiles before the
//     compiler runs out of the engine's stack (§8), found by bisection.
//
// It drives the editor as a person does, or through a link the page's own
// `share.js` makes, as `tests/browser/playground.mjs` does: it reaches into
// no CodeMirror internals.
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { encode } from "../../playground/share.js";

const [chrome, site] = process.argv.slice(2);
const runs = Number(process.argv.find((a) => a.startsWith("--runs="))?.slice("--runs=".length) ?? 10);
if (!chrome || !site) {
  process.stderr.write("usage: node bench/playground/chrome.mjs <chrome> <site> [--runs=10]\n");
  process.exit(2);
}
const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const todomvc = readFileSync(join(repo, "bench/todomvc/apps/beni/Sandbox.beni"), "utf8");
const printing = readFileSync(join(repo, "playground/samples/node/Print.beni"), "utf8");

const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json", ".beni": "text/plain; charset=utf-8" };
const root = resolve(site);
const server = createServer((req, res) => {
  const path = normalize(join(root, req.url === "/" ? "index.html" : decodeURIComponent(req.url.split("?")[0])));
  if (!path.startsWith(root) || !existsSync(path) || !statSync(path).isFile()) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream" });
  res.end(readFileSync(path));
});
await new Promise((listening) => server.listen(0, "127.0.0.1", listening));
const origin = `http://127.0.0.1:${server.address().port}`;

const profiles = process.env.BENI_CHROME_PROFILE_DIR || tmpdir();
mkdirSync(profiles, { recursive: true });
const profile = mkdtempSync(join(profiles, "beni-playground-"));
const browser = spawn(chrome, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "about:blank"], {
  stdio: ["ignore", "ignore", "pipe"],
});
const endpoint = await new Promise((found, failed) => {
  let text = "";
  browser.stderr.on("data", (chunk) => {
    text += chunk;
    const m = /DevTools listening on (ws:\/\/\S+)/.exec(text);
    if (m) found(m[1]);
  });
  browser.on("exit", () => failed(new Error(`Chrome exited before listening:\n${text}`)));
});

const socket = new WebSocket(endpoint);
await new Promise((opened) => (socket.onopen = opened));
let next = 0;
const waiting = new Map();
socket.onmessage = (message) => {
  const m = JSON.parse(message.data);
  const w = waiting.get(m.id);
  if (w === undefined) return;
  waiting.delete(m.id);
  if (m.error) w.failed(new Error(m.error.message));
  else w.done(m.result);
};
const send = (method, params = {}, sessionId = undefined) =>
  new Promise((done, failed) => {
    next += 1;
    waiting.set(next, { done, failed });
    socket.send(JSON.stringify({ id: next, method, params, sessionId }));
  });

// Empty while the page is still loading.
const status = `(document.getElementById("status")?.textContent ?? "")`;
const builtMs = `(() => { const m = /^Built in (\\d+) ms/.exec(${status}); return m && Number(m[1]); })()`;

/// A page at `url`, with the means to read it and to type in its editor.
async function open(url) {
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Runtime.enable", {}, sessionId);
  await send("Page.enable", {}, sessionId);
  await send("Page.navigate", { url }, sessionId);
  const evaluate = async (expression) => {
    const { result, exceptionDetails } = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, sessionId);
    if (exceptionDetails !== undefined) throw new Error(`${expression}: ${exceptionDetails.exception?.description ?? exceptionDetails.text}`);
    return result.value;
  };
  // Wait until `expression` is truthy in the page, and return its value.
  const until = async (expression, ms = 60_000) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const value = await evaluate(expression);
      if (value) return value;
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${expression}; status: ${await evaluate(status)}`);
      await new Promise((later) => setTimeout(later, 5));
    }
  };
  // Type `text` at the end of the editor's text, as a person does.
  const typeAtEnd = async (text) => {
    await evaluate(`document.querySelector(".cm-content").focus()`);
    for (const type of ["rawKeyDown", "keyUp"]) {
      await send("Input.dispatchKeyEvent", { type, key: "End", code: "End", windowsVirtualKeyCode: 35, modifiers: 2 }, sessionId);
    }
    await send("Input.insertText", { text }, sessionId);
  };
  const close = () => send("Target.closeTarget", { targetId });
  return { evaluate, until, typeAtEnd, close };
}

const linkTo = async (platform, source) => `${origin}/#${await encode(platform, source)}`;

// The first sample, its compiler and its editor.
const first = await open(`${origin}/`);
const editorReady = await first.until(`document.querySelector(".cm-editor") !== null && Math.round(performance.now())`);
const load = Number(await first.until(`document.documentElement.dataset.compilerLoadedMs`));
const counter = await first.until(builtMs);
const firstBuildAt = Math.round(await first.evaluate("performance.now()"));
await first.close();

// TodoMVC: opened from a link, then edited `runs` times.
const todo = await open(await linkTo("browser-direct", todomvc));
const todomvcRuns = [await todo.until(builtMs)];
for (let i = 1; i < runs; i += 1) {
  await todo.evaluate(`document.getElementById("status").textContent = ""`);
  await todo.typeAtEnd(`\n-- run ${i}\n`);
  todomvcRuns.push(await todo.until(builtMs));
}
await todo.close();

// The printing sample.
const printPage = await open(await linkTo("node", printing));
const print = await printPage.until(builtMs);
const printed = (await printPage.until(`document.getElementById("console").textContent.includes("fib 10 = 55") && document.getElementById("console").textContent`)).split("\n").length - 1;
await printPage.close();

// The deepest call the page compiles.
async function compiles(n) {
  const program = `import Node exposing (Program)\n\n\nf : Int → Int\nf x =\n    x + 1\n\n\nbig : Int\nbig =\n    ${"f (".repeat(n)}1${")".repeat(n)}\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt big ]\n`;
  const page = await open(await linkTo("node", program));
  const outcome = await page.until(`(() => { const t = ${status}; return (t.startsWith("Built in") || t.startsWith("The compiler") || t.startsWith("The playground failed") || /error/.test(t)) && t; })()`);
  await page.close();
  return outcome.startsWith("Built in");
}
let low = 1;
let high = 4000;
if (await compiles(high)) low = high;
while (high - low > 1) {
  const mid = Math.floor((low + high) / 2);
  if (await compiles(mid)) low = mid;
  else high = mid;
}

const sorted = [...todomvcRuns].sort((a, b) => a - b);
console.log(
  JSON.stringify(
    {
      chrome: (await send("Browser.getVersion")).product,
      load,
      editorReady,
      counter,
      firstBuildAt,
      todomvc: { runs: todomvcRuns, first: todomvcRuns[0], median: sorted[Math.floor(sorted.length / 2)], min: sorted[0], max: sorted[sorted.length - 1] },
      print,
      printed,
      depth: low,
    },
    null,
    2,
  ),
);

socket.close();
const exited = new Promise((done) => browser.on("exit", done));
browser.kill();
await exited;
server.close();
rmSync(profile, { recursive: true, force: true });
