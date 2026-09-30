// The fiber runtime benchmark in headless Chrome (`nix develop .#browser`):
// `node chrome.mjs <beni build dir> [<budget>=<beni build dir> …]`, the same
// arguments as node.mjs. Effect v4 is bundled for the browser with esbuild,
// everything is served from one local origin, and the page runs
// workloads.mjs — the same code node.mjs runs — and hands back the tables.

import { createServer } from "node:http";
import { readFileSync, existsSync, statSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { launch } from "../ui/lib/cdp.mjs";

const here = fileURLToPath(new URL(".", import.meta.url));
const [main, ...rest] = process.argv.slice(2);
const builds = new Map([["main", resolve(main ?? "out")]]);
const labels = [];
for (const arg of rest) {
  const [label, dir] = arg.split("=");
  builds.set(label, resolve(dir));
  labels.push(label);
}

const bundleDir = mkdtempSync(join(tmpdir(), "beni-fiber-"));
await build({ entryPoints: [join(here, "effect.mjs")], bundle: true, format: "esm", platform: "browser", outfile: join(bundleDir, "effect.mjs"), logLevel: "error" });

const sizes = process.env.FIBER_SIZES ?? "{}";
const page = `<!DOCTYPE html><html><head><meta charset="utf-8"><title>fibers</title></head><body><script type="module">
import * as effect from "/bundle/effect.mjs";
import { all, sweep } from "/fiber/workloads.mjs";
try {
  const beni = await import("/b/main/Bench.mjs");
  const budgets = [];
  for (const label of ${JSON.stringify(labels)}) budgets.push([label, await import("/b/" + label + "/Bench.mjs")]);
  window.__progress = [];
  const SIZES = { effectYields: 1000, ...${sizes} };
  const result = await all(beni, effect, SIZES, (label) => window.__progress.push(label));
  const latency = budgets.length === 0 ? [] : await sweep(budgets, effect, 200000, SIZES.effectYields ?? 2000);
  window.__result = { host: navigator.userAgent, result, latency };
} catch (e) {
  window.__result = { error: String(e && e.stack || e) };
}
</script></body></html>`;

const types = { ".mjs": "text/javascript", ".js": "text/javascript", ".html": "text/html" };
const file = (path) => {
  const [, top, name, ...tail] = path.split("/");
  if (top === "fiber") return join(here, [name, ...tail].join("/"));
  if (top === "bundle") return join(bundleDir, [name, ...tail].join("/"));
  if (top === "b" && builds.has(name)) return join(builds.get(name), tail.join("/"));
  return null;
};
const server = createServer((req, res) => {
  const path = new URL(req.url, "http://x").pathname;
  // Cross-origin isolated, so `performance.now()` has its fine resolution.
  const headers = { "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp" };
  if (path === "/" || path === "/index.html") {
    res.writeHead(200, { ...headers, "Content-Type": "text/html" });
    res.end(page);
    return;
  }
  const f = file(path);
  if (f === null || !existsSync(f) || !statSync(f).isFile()) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { ...headers, "Content-Type": types[extname(f)] ?? "application/octet-stream" });
  res.end(readFileSync(f));
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const port = server.address().port;

const browser = await launch();
try {
  // The page's module runs the whole benchmark under a top-level `await`,
  // so nothing here waits for its load event: it navigates and polls.
  const { targetId } = await browser.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await browser.send("Target.attachToTarget", { targetId, flatten: true });
  const send = (method, params = {}) => browser.send(method, params, sessionId);
  await send("Runtime.enable");
  browser.on((msg) => {
    if (msg.sessionId !== sessionId) return;
    if (msg.method === "Runtime.exceptionThrown") console.error("page:", msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text);
    if (msg.method === "Runtime.consoleAPICalled") console.error("page:", msg.params.args.map((a) => a.value ?? a.description).join(" "));
  });
  await send("Page.navigate", { url: `http://127.0.0.1:${port}/` });
  const read = async (expression) => (await send("Runtime.evaluate", { expression, returnByValue: true })).result.value;
  const start = Date.now();
  let result;
  for (;;) {
    result = await read("window.__result");
    if (result !== undefined) break;
    if (Date.now() - start > 900000) throw new Error(`timed out; done: ${JSON.stringify(await read("window.__progress"))}`);
    await new Promise((done) => setTimeout(done, 200));
  }
  console.log(JSON.stringify({ browser: browser.version, ...result }, null, 1));
} finally {
  await browser.close();
  server.close();
}
