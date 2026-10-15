// Drive the playground in a headless Chrome (docs/design/playground.md §4,
// §5): `zig build test-playground-page`, not a gate. It needs a Chrome,
// which `nix develop .#browser` puts on PATH, and the network, because the
// editor loads from a CDN (§4.2).
//
//   node tests/browser/playground.mjs <site>
//
// <site> is what `zig build playground` writes. The Chrome is `BENI_CHROME`,
// else the first of chromium, google-chrome-stable and google-chrome on
// PATH; its profile goes under `BENI_CHROME_PROFILE_DIR`, else the system's
// temporary directory. The script serves <site> on 127.0.0.1 and checks:
//   - the first sample builds, its program mounts in the frame, and a click
//     in the frame changes it;
//   - every sample builds, and the printing one prints;
//   - a program with an error marks it in the editor and lists it;
//   - the Types and Ownership tabs show their dumps;
//   - a shared link opens the same source and platform, and a damaged one
//     says so.
// Each failed check prints a line; the exit code is the number of them.
import { spawn } from "node:child_process";
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { delimiter, extname, join, normalize, resolve } from "node:path";
import { encode } from "../../playground/share.js";

const [site] = process.argv.slice(2);
if (!site) {
  process.stderr.write("usage: node tests/browser/playground.mjs <site>\n");
  process.exit(2);
}
const chrome = findChrome();
let failures = 0;
const check = (ok, what) => {
  process.stdout.write(`${ok ? "ok  " : "FAIL"} ${what}\n`);
  if (!ok) failures += 1;
};

function findChrome() {
  if (process.env.BENI_CHROME) return process.env.BENI_CHROME;
  for (const dir of (process.env.PATH ?? "").split(delimiter)) {
    for (const name of ["chromium", "google-chrome-stable", "google-chrome"]) {
      const path = join(dir, name);
      if (!existsSync(path)) continue;
      accessSync(path, constants.X_OK);
      return path;
    }
  }
  process.stderr.write("no Chrome: run under `nix develop .#browser`, or set BENI_CHROME\n");
  process.exit(2);
}

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
// The newest frame of each page: the sandboxed frame runs in a process of
// its own, a target the page's session attaches to automatically.
const frames = new Map();
socket.onmessage = (message) => {
  const m = JSON.parse(message.data);
  if (m.method === "Target.attachedToTarget" && m.params.targetInfo.type === "iframe") {
    frames.set(m.sessionId, m.params.sessionId);
    return;
  }
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

/// A page at `url`, with the means to read it and its frame.
async function open(url) {
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Runtime.enable", {}, sessionId);
  await send("Page.enable", {}, sessionId);
  await send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sessionId);
  await send("Page.navigate", { url }, sessionId);
  const evaluate = async (expression, frameSession = sessionId) => {
    const { result, exceptionDetails } = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, frameSession);
    if (exceptionDetails !== undefined) throw new Error(`${expression}: ${exceptionDetails.exception?.description ?? exceptionDetails.text}`);
    return result.value;
  };
  // Wait until `expression` is truthy, and return it; null after `ms`.
  const until = async (expression, ms = 60_000, frame = false) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const session = frame ? frames.get(sessionId) : sessionId;
      const value = session === undefined ? null : await evaluate(expression, session).catch((e) => {
        // A frame replaced by the next build is gone: wait for its successor.
        if (frame && /context|target|session/i.test(e.message)) return null;
        throw e;
      });
      if (value) return value;
      if (Date.now() > deadline) return null;
      await new Promise((later) => setTimeout(later, 25));
    }
  };
  // Type `text` at the editor's cursor, as a user does.
  const type = async (text) => {
    await evaluate(`document.querySelector(".cm-content").focus()`);
    await send("Input.insertText", { text }, sessionId);
  };
  // Move the editor's cursor to the end of the text, with Ctrl+End.
  const toEnd = async () => {
    await evaluate(`document.querySelector(".cm-content").focus()`);
    for (const type of ["rawKeyDown", "keyUp"]) {
      await send("Input.dispatchKeyEvent", { type, key: "End", code: "End", windowsVirtualKeyCode: 35, modifiers: 2 }, sessionId);
    }
  };
  return { targetId, evaluate, until, type, toEnd };
}

/// A page opened from a link to `source` on `platform`, which the page's own
/// `share.js` makes.
const pageWith = async (platform, source) => open(`${origin}/#${await encode(platform, source)}`);

// Empty while the page is still loading.
const status = `(document.getElementById("status")?.textContent ?? "")`;
const built = `(${status}).startsWith("Built in") && (${status})`;
const loaded = `document.getElementById("frame")?.dataset.loaded === "true"`;
const editorText = `[...document.querySelectorAll(".cm-content .cm-line")].map((l) => l.textContent).join("\\n")`;
const click = (tab) => `document.querySelector('[data-tab="${tab}"]').click()`;

const page = await open(`${origin}/`);
check((await page.until(`/Compiler loaded in \\d+ ms/.test(${status}) || ${built}`)) !== null, "the compiler loads");
check((await page.until(built)) !== null, `the first sample builds (${await page.evaluate(status)})`);
check(await page.evaluate(`document.querySelector(".cm-editor") !== null`), "the editor is CodeMirror");
check((await page.until(loaded)) !== null, "the first sample's program loads in the frame");

// The counter, in its frame: a click on `+` shows 1.
const counted = await page.until(`document.querySelector("span")?.textContent === "0" && (document.querySelectorAll("button")[1].click(), true)`, 10_000, true);
check(counted !== null && (await page.until(`document.querySelector("span")?.textContent === "1"`, 10_000, true)) !== null, "a click in the frame increments the counter");

// Every sample.
const samples = JSON.parse(await page.evaluate(`JSON.stringify([...document.getElementById("sample").options].map((o) => [o.value, o.text]))`));
for (const [value, name] of samples.filter(([v]) => v !== "shared")) {
  await page.evaluate(`(() => { document.getElementById("status").textContent = ""; const s = document.getElementById("sample"); s.value = ${JSON.stringify(value)}; s.dispatchEvent(new Event("change")); })()`);
  check((await page.until(built)) !== null, `sample ${name} builds (${await page.evaluate(status)})`);
  if ((await page.evaluate(`document.getElementById("platform").value`)) === "node") {
    check((await page.until(`document.getElementById("console").textContent.includes("fib 10 = 55")`, 10_000)) !== null, `sample ${name} prints`);
  } else {
    check((await page.until(loaded, 10_000)) !== null, `sample ${name} loads in the frame`);
    // Mounted, not only imported: the page's markup is in the frame.
    const mounted = name === "TodoMVC" ? `document.querySelector("input") !== null` : `document.querySelectorAll("button").length === 2`;
    check((await page.until(mounted, 10_000, true)) !== null, `sample ${name} mounts its markup`);
  }
}

// An error, marked in the editor and listed.
const wrong = await pageWith("node", "import Node exposing (Program)\n\n\nmain : Program\nmain = Node.printLines [ missing ]\n");
check((await wrong.until(`/^1 error/.test(${status}) && (${status})`)) !== null, `an error is reported (${await wrong.evaluate(status)})`);
check((await wrong.until(`document.querySelector(".cm-lintRange-error")?.textContent === "missing"`, 10_000)) !== null, "the error is marked on `missing` in the editor");
check((await wrong.evaluate(`document.querySelector(".diagnostic")?.textContent ?? ""`)).startsWith("NAMING ERROR — Main.beni:5:"), "the error is listed with its place");

// The dumps and the emitted JavaScript.
const program = "import Node exposing (Program)\n\n\ndouble : Int → Int\ndouble n = n * 2\n\n\nmain : Program\nmain = Node.printLines [ String.fromInt (double 21) ]\n";
const tabs = await pageWith("node", program);
check((await tabs.until(built)) !== null, `a linked program builds (${await tabs.evaluate(status)})`);
check((await tabs.until(`document.getElementById("console").textContent.includes("42")`, 10_000)) !== null, "the linked program runs");
await tabs.evaluate(click("types"));
check((await tabs.until(`document.getElementById("types-text").textContent.includes("double : Int → Int")`, 20_000)) !== null, "the Types tab shows the types");
await tabs.evaluate(click("ownership"));
check((await tabs.until(`document.getElementById("ownership-text").textContent.includes("summary double:")`, 20_000)) !== null, "the Ownership tab shows the report");
await tabs.evaluate(click("javascript"));
check((await tabs.evaluate(`document.getElementById("code").textContent`)).includes("double"), "the JavaScript tab shows the emitted module");

// A dump refreshes after an edit while its tab is open.
await tabs.evaluate(click("types"));
check(await tabs.evaluate(`location.hash.includes("code=")`), "a link stays in the address until an edit");
await tabs.toEnd();
await tabs.type("\ntriple : Int → Int\ntriple n = n * 3\n");
check((await tabs.until(`location.hash === ""`, 5_000)) !== null, "an edit clears the link from the address");
check((await tabs.until(`document.getElementById("types-text").textContent.includes("triple : Int → Int") && !document.getElementById("types-text").classList.contains("stale")`, 20_000)) !== null, "the open Types tab shows the edited program's types");
await tabs.evaluate(click("result"));

// The Share button, after an edit: the link holds the edited source.
await tabs.evaluate(`document.getElementById("status").textContent = ""`);
await tabs.type("-- edited → 😀\n");
check((await tabs.until(built)) !== null, `the edited program builds (${await tabs.evaluate(status)})`);
const edited = await tabs.evaluate(editorText);
check(edited.includes("-- edited → 😀") && edited.includes("triple"), "the edits are in the editor");
await tabs.evaluate(`document.getElementById("share").click()`);
const link = await tabs.until(`location.hash.includes("code=") && document.getElementById("sample").value === "shared" && location.href`, 10_000);
check(link !== null, "Share puts the source in the address");
const second = await open(link);
check((await second.until(built)) !== null, `the shared link builds (${await second.evaluate(status)})`);
check((await second.evaluate(editorText)) === edited, "the shared link opens the edited source");
check((await second.evaluate(`document.getElementById("platform").value`)) === "node", "the shared link opens the same platform");
const damaged = await open(`${origin}/#platform=node&code=@@@@`);
check((await damaged.until(`(${built}) && (${status}).includes("the link held no program")`, 30_000)) !== null, `a damaged link builds the first sample and says so (${await damaged.evaluate(status)})`);
check(
  (await damaged.evaluate(`document.getElementById("sample").value`)) === "0" && (await damaged.evaluate(editorText)).startsWith("-- A counter"),
  "a damaged link opens the first sample",
);

socket.close();
const exited = new Promise((done) => browser.on("exit", done));
browser.kill();
await exited;
server.close();
rmSync(profile, { recursive: true, force: true });
process.stdout.write(`${failures} failed\n`);
process.exitCode = failures === 0 ? 0 : 1;
