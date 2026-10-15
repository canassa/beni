// Measure the playground in a headless Chrome (docs/design/playground.md
// §7.2). Not a gate: it needs a Chrome, which `nix develop .#browser` puts
// on PATH, and it reports times, which move with the machine's load.
//
//   node bench/playground/chrome.mjs <chrome> <site> [--runs=10]
//
// <site> is what `zig build playground` writes (`zig-out/playground`). The
// script serves it on 127.0.0.1, opens the page in a fresh headless Chrome
// over the DevTools protocol, and prints, as JSON:
//   - `load`: the page's "Compiler loaded in … ms" (fetch and compile of
//     `beni.wasm`);
//   - `counter`: the first compile, the counter sample;
//   - `todomvc`: one compile per run of `bench/todomvc/apps/beni/Sandbox.beni`,
//     each with a different trailing comment, as the page's worker timed it;
//   - `print`: the printing sample's compile and what its frame printed;
//   - whether each frame loaded its program;
//   - `depth`: the deepest call `f (f (… 1))` the page compiles before the
//     compiler runs out of the engine's stack (playground.md §8), found by
//     bisection, and the exact depth at which the native compiler stops
//     instead (`nesting_too_deep`, past 4 000 levels of this shape).
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const [chrome, site] = process.argv.slice(2);
const runs = Number(process.argv.find((a) => a.startsWith("--runs="))?.slice("--runs=".length) ?? 10);
if (!chrome || !site) {
  process.stderr.write("usage: node bench/playground/chrome.mjs <chrome> <site> [--runs=10]\n");
  process.exit(2);
}
const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const todomvc = readFileSync(join(repo, "bench/todomvc/apps/beni/Sandbox.beni"), "utf8");

const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".beni": "text/plain; charset=utf-8" };
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

const profile = mkdtempSync(join(process.env.BENI_CHROME_PROFILE_DIR ?? tmpdir(), "beni-playground-"));
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

const { targetId } = await send("Target.createTarget", { url: "about:blank" });
const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
await send("Runtime.enable", {}, sessionId);
await send("Page.enable", {}, sessionId);

// The value of `expression` in the page.
async function evaluate(expression) {
  const { result, exceptionDetails } = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, sessionId);
  if (exceptionDetails !== undefined) throw new Error(`${expression}: ${exceptionDetails.exception?.description ?? exceptionDetails.text}`);
  return result.value;
}

// Wait until `expression` is truthy in the page, and return its value.
async function until(expression, ms = 60_000) {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await evaluate(expression);
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${expression}; status: ${await evaluate("document.getElementById('status').textContent")}`);
    await new Promise((later) => setTimeout(later, 10));
  }
}

const builtMs = `(() => { const m = /^Built in (\\d+) ms/.exec(document.getElementById("status").textContent); return m && Number(m[1]); })()`;
const loadedFrame = `document.getElementById("frame").dataset.loaded === "true"`;
const status = `document.getElementById("status").textContent`;

// Put `text` in the editor as a user's edit, and wait for its build.
async function compile(text) {
  await evaluate(`(() => { const s = document.getElementById("source"); s.value = ${JSON.stringify(text)}; s.dispatchEvent(new Event("input")); document.getElementById("status").textContent = ""; })()`);
  return until(builtMs);
}

await send("Page.navigate", { url: `${origin}/` }, sessionId);
const load = await until(`(() => { const m = /Compiler loaded in (\\d+) ms/.exec(${status}); return m && Number(m[1]); })()`);
const counter = await until(builtMs);
const counterLoaded = await until(loadedFrame);

const todo = [];
for (let i = 0; i < runs; i += 1) todo.push(await compile(`${todomvc}\n-- run ${i}\n`));
const todoLoaded = await until(loadedFrame);

await evaluate(`(() => { const p = document.getElementById("platform"); p.value = "node"; p.dispatchEvent(new Event("change")); document.getElementById("status").textContent = ""; })()`);
const print = await until(builtMs);
const printed = await until(`document.getElementById("console").textContent.includes("fib 10 = 55") && document.getElementById("console").textContent`);

// The page's answer to a call nested `n` levels deep: built, or out of stack.
async function deep(n) {
  const program = `import Node exposing (Program)\n\n\nf : Int → Int\nf x =\n    x + 1\n\n\nbig : Int\nbig =\n    ${"f (".repeat(n)}1${")".repeat(n)}\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt big ]\n`;
  await evaluate(`(() => { const s = document.getElementById("source"); s.value = ${JSON.stringify(program)}; s.dispatchEvent(new Event("input")); document.getElementById("status").textContent = ""; })()`);
  const outcome = await until(`(() => { const t = ${status}; return (t.startsWith("Built in") || t.startsWith("The compiler") || t.startsWith("Errors")) && t; })()`);
  return outcome.startsWith("Built in");
}
let low = 1;
let high = 4000;
if (await deep(high)) low = high;
while (high - low > 1) {
  const mid = Math.floor((low + high) / 2);
  if (await deep(mid)) low = mid;
  else high = mid;
}

const sorted = [...todo].sort((a, b) => a - b);
console.log(
  JSON.stringify(
    {
      chrome: (await send("Browser.getVersion")).product,
      load,
      counter,
      counterLoaded,
      todomvc: { runs: todo, first: todo[0], median: sorted[Math.floor(sorted.length / 2)], min: sorted[0], max: sorted[sorted.length - 1] },
      todoLoaded,
      print,
      printed: printed.split("\n").length - 1,
      depth: low,
    },
    null,
    2,
  ),
);

await send("Target.closeTarget", { targetId });
socket.close();
const exited = new Promise((done) => browser.on("exit", done));
browser.kill();
await exited;
server.close();
rmSync(profile, { recursive: true, force: true });
