// Check a development build's source maps in Chrome, the way DevTools reads
// them (docs/design/backend.md §11.1). Not a gate: it needs a Chrome, which
// `nix develop .#browser` puts on PATH.
//
//   node tests/browser/sourcemap-chrome.mjs <chrome> <out-dir>
//
// It serves <out-dir> (a `beni build --platform=browser` tree, page shell
// included) on 127.0.0.1, opens its `index.html` in a headless Chrome over
// the DevTools protocol, waits for the page's first uncaught exception, and
// prints each frame of its stack twice: where Chrome says it is in the
// emitted JavaScript, and where that script's `sourceMappingURL` — as
// Chrome reported it in `Debugger.scriptParsed` — maps it. A frame Chrome
// gives no map for prints `unmapped`.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";

const [chrome, outDir] = process.argv.slice(2);
if (!chrome || !outDir) {
  process.stderr.write("usage: node sourcemap-chrome.mjs <chrome> <out-dir>\n");
  process.exit(2);
}

const types = { ".html": "text/html", ".mjs": "text/javascript", ".map": "application/json" };
const server = createServer((req, res) => {
  const path = normalize(join(outDir, req.url === "/" ? "index.html" : decodeURIComponent(req.url.split("?")[0])));
  try {
    const bytes = readFileSync(path);
    res.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream" });
    res.end(bytes);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((listening) => server.listen(0, "127.0.0.1", listening));
const origin = `http://127.0.0.1:${server.address().port}`;

const profile = mkdtempSync(join(process.env.BENI_CHROME_PROFILE_DIR ?? tmpdir(), "beni-sourcemap-"));
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
const listeners = [];
socket.onmessage = (message) => {
  const m = JSON.parse(message.data);
  const w = waiting.get(m.id);
  if (w === undefined) return void listeners.forEach((listen) => listen(m));
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
const scripts = new Map();
const thrown = new Promise((caught) => {
  listeners.push((m) => {
    if (m.sessionId !== sessionId) return;
    if (m.method === "Debugger.scriptParsed") scripts.set(m.params.scriptId, m.params);
    if (m.method === "Runtime.exceptionThrown") caught(m.params.exceptionDetails);
  });
});
await send("Runtime.enable", {}, sessionId);
await send("Debugger.enable", {}, sessionId);
await send("Page.enable", {}, sessionId);
await send("Page.navigate", { url: `${origin}/` }, sessionId);
const details = await Promise.race([thrown, new Promise((_, late) => setTimeout(() => late(new Error("no exception in 10 s")), 10_000))]);

console.log(`exception: ${details.exception?.description?.split("\n")[0] ?? details.text}`);
for (const frame of details.stackTrace?.callFrames ?? []) {
  const script = scripts.get(frame.scriptId);
  const at = `${frame.url.slice(origin.length)}:${frame.lineNumber + 1}:${frame.columnNumber + 1}`;
  if (!script?.sourceMapURL) {
    console.log(`  ${frame.functionName || "<anonymous>"} ${at} unmapped`);
    continue;
  }
  const mapUrl = new URL(script.sourceMapURL, script.url);
  const map = await (await fetch(mapUrl)).json();
  const hit = locate(map, frame.lineNumber, frame.columnNumber);
  const where = hit ? `${new URL(map.sources[hit.source], mapUrl).href.replace(origin, "")}:${hit.line + 1}:${hit.column + 1}${hit.name ? ` (${hit.name})` : ""}` : "no segment";
  console.log(`  ${frame.functionName || "<anonymous>"} ${at} -> ${where}`);
}

await send("Target.closeTarget", { targetId });
socket.close();
const exited = new Promise((done) => browser.on("exit", done));
browser.kill();
await exited;
server.close();
rmSync(profile, { recursive: true, force: true });

// The segment covering a generated position: the last on its line at or
// before its column. Base64 VLQ, decoded from the format alone.
function locate(map, line, column) {
  const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const state = [0, 0, 0, 0, 0];
  let best = null;
  map.mappings.split(";").forEach((text, l) => {
    state[0] = 0;
    for (const segment of text ? text.split(",") : []) {
      const fields = [];
      let value = 0, shift = 0;
      for (const ch of segment) {
        const d = digits.indexOf(ch);
        value += (d & 31) << shift;
        if (d & 32) { shift += 5; continue; }
        fields.push(value & 1 ? -(value >>> 1) : value >>> 1);
        value = 0; shift = 0;
      }
      fields.forEach((delta, i) => (state[i] += delta));
      if (l === line && state[0] <= column) {
        best = { source: state[1], line: state[2], column: state[3], name: fields.length === 5 ? map.names[state[4]] : null };
      }
    }
  });
  return best;
}
