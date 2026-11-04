// Load the examples' site in a headless Chrome, as GitHub Pages serves it
// (issue #244): `zig build test-pages`, not a gate. It needs a Chrome,
// which `nix develop .#browser` puts on PATH, and no network.
//
//   node tests/browser/pages.mjs <site> <base>
//
// <site> is what `examples/build-pages.mjs` wrote for <base>. The script
// serves it on 127.0.0.1 under <base> with GitHub Pages' rules: a directory
// answers its index.html, a directory without a final "/" is redirected,
// and a path that names no file answers 404.html with status 404. No host
// other than 127.0.0.1 resolves in the Chrome, so the fonts and the API
// that the programs ask for fail. The script checks:
//   - each routed program's own page and two deep paths: the 404 page
//     stands in for the program's shell, which renders the program at that
//     path, with its styles, the title of the route, and no page error;
//   - the routed programs in 404.html are the ones this script checks;
//   - a path that no program routes shows the page's own "Not found".
// Each check prints a line; the exit code is 1 when one failed. The Chrome
// is `BENI_CHROME`, else the first of chromium, google-chrome-stable and
// google-chrome on PATH; its profile goes under `BENI_CHROME_PROFILE_DIR`,
// else the system's temporary directory. The run stops after 120 s.
import { spawn } from "node:child_process";
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { delimiter, extname, join, normalize, resolve, sep } from "node:path";

const [site, base] = process.argv.slice(2);
if (!site || !base || !/^\/([A-Za-z0-9._~-]+\/)*$/.test(base)) {
  process.stderr.write("usage: node tests/browser/pages.mjs <site> <base, from / to a final />\n");
  process.exit(2);
}

// What a routed program's page must show at each path: its root element,
// the document's title, and a style that only the program's shell gives.
// `examples/build-pages.mjs` names the programs that route by path.
const routed = [
  {
    name: "conduit",
    root: "div.app",
    paths: [
      { path: "", title: "Home — Conduit" },
      { path: "login", title: "Login — Conduit" },
      { path: "article/x", title: "Article — Conduit" },
    ],
    // The theme sets the brand's size, and the shell's own style makes
    // div.app a column.
    styled: `getComputedStyle(document.querySelector(".navbar-brand")).fontSize === "24px" && getComputedStyle(document.querySelector("div.app")).display === "flex"`,
  },
];
// Paths that no program routes. The second starts with a program's name
// and no "/" after it.
const missing = ["no/such/page", "conduitlogin"];

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

const root = resolve(site);
const page404 = join(root, "404.html");
if (!existsSync(page404)) {
  process.stderr.write(`${site} has no 404.html: build it with examples/build-pages.mjs\n`);
  process.exit(2);
}

// The routed programs that 404.html holds: the JSON array in its script,
// which starts after `const app = `. Each "]" is a place where the array
// can end; the first prefix that is JSON is the array, because a shorter
// one stops in a string or in an inner array.
function routedIn(page) {
  const start = page.indexOf("[", page.indexOf("const app = "));
  if (page.indexOf("const app = ") < 0 || start < 0) return null;
  for (let end = page.indexOf("]", start); end >= 0; end = page.indexOf("]", end + 1)) {
    let value;
    try {
      value = JSON.parse(page.slice(start, end + 1));
    } catch (e) {
      if (e instanceof SyntaxError) continue;
      throw e;
    }
    return Array.isArray(value) ? value.map((app) => app.base).sort() : null;
  }
  return null;
}
const inPage = routedIn(readFileSync(page404, "utf8"));
const checked = routed.map(({ name }) => `${base}${name}/`).sort();
check(
  inPage !== null && JSON.stringify(inPage) === JSON.stringify(checked),
  `404.html stands in for the programs this script checks (404.html: ${JSON.stringify(inPage)}, checked: ${JSON.stringify(checked)})`,
);

const types = {
  ".html": "text/html; charset=utf-8",
  ".mjs": "text/javascript",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".map": "application/json",
  ".txt": "text/plain; charset=utf-8",
  ".svg": "image/svg+xml",
  ".wasm": "application/wasm",
};
// GitHub Pages' rules, under <base>. A name that starts with "." is not in
// the site: upload-pages-artifact leaves such files out.
const server = createServer((req, res) => {
  const { pathname } = new URL(req.url, "http://127.0.0.1");
  const path = decodeURIComponent(pathname);
  if (!path.startsWith(base)) {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not under the base\n");
    return;
  }
  const rel = path.slice(base.length);
  let file = normalize(join(root, rel));
  const inside = (file === root || file.startsWith(root + sep)) && !rel.split("/").some((part) => part.startsWith("."));
  if (inside && existsSync(file) && statSync(file).isDirectory()) {
    if (!path.endsWith("/")) {
      res.writeHead(301, { location: `${path}/` });
      res.end();
      return;
    }
    file = join(file, "index.html");
  }
  if (inside && existsSync(file) && statSync(file).isFile()) {
    res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
    res.end(readFileSync(file));
    return;
  }
  res.writeHead(404, { "content-type": types[".html"] });
  res.end(readFileSync(page404));
});
await new Promise((listening) => server.listen(0, "127.0.0.1", listening));
const origin = `http://127.0.0.1:${server.address().port}`;

const profiles = process.env.BENI_CHROME_PROFILE_DIR || tmpdir();
mkdirSync(profiles, { recursive: true });
const profile = mkdtempSync(join(profiles, "beni-pages-"));
// No host resolves except 127.0.0.1, so nothing leaves the machine: not the
// fonts and the API that Conduit asks for, and not Chrome's own requests.
const browser = spawn(
  chrome,
  ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1", "about:blank"],
  { stdio: ["ignore", "ignore", "pipe"] },
);
// The hang guard: every test stops after 120 s. Chrome's profile stays in
// the profile directory then.
setTimeout(() => {
  process.stdout.write("FAIL the check did not end in 120 s\n");
  browser.kill("SIGKILL");
  process.exit(1);
}, 120_000).unref();

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
// What each page's session saw, by session id.
const seen = new Map();
socket.onmessage = (message) => {
  const m = JSON.parse(message.data);
  const w = waiting.get(m.id);
  if (w !== undefined) {
    waiting.delete(m.id);
    if (m.error) w.failed(new Error(m.error.message));
    else w.done(m.result);
    return;
  }
  const page = seen.get(m.sessionId);
  if (page === undefined) return;
  const p = m.params;
  switch (m.method) {
    case "Runtime.exceptionThrown":
      page.errors.push(p.exceptionDetails.exception?.description ?? p.exceptionDetails.text);
      break;
    case "Runtime.consoleAPICalled":
      if (p.type === "error" || p.type === "assert") page.errors.push(`console.${p.type}: ${p.args.map((a) => a.value ?? a.description).join(" ")}`);
      break;
    case "Network.requestWillBeSent":
      page.requests.set(p.requestId, { url: p.request.url, document: p.type === "Document" });
      page.pending.add(p.requestId);
      page.changed = Date.now();
      break;
    case "Network.responseReceived": {
      const request = page.requests.get(p.requestId) ?? { url: p.response.url, document: p.type === "Document" };
      request.status = p.response.status;
      page.requests.set(p.requestId, request);
      break;
    }
    case "Network.loadingFinished":
      page.pending.delete(p.requestId);
      page.changed = Date.now();
      break;
    case "Network.loadingFailed": {
      const request = page.requests.get(p.requestId);
      if (request !== undefined) request.failed = p.errorText;
      page.pending.delete(p.requestId);
      page.changed = Date.now();
      break;
    }
  }
};
const send = (method, params = {}, sessionId = undefined) =>
  new Promise((done, failed) => {
    next += 1;
    waiting.set(next, { done, failed });
    socket.send(JSON.stringify({ id: next, method, params, sessionId }));
  });

/// The page at `path` under the base, loaded, with what it saw.
async function open(path) {
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  const page = { errors: [], requests: new Map(), pending: new Set(), changed: Date.now() };
  seen.set(sessionId, page);
  await send("Runtime.enable", {}, sessionId);
  await send("Page.enable", {}, sessionId);
  await send("Network.enable", {}, sessionId);
  await send("Page.navigate", { url: `${origin}${base}${path}` }, sessionId);
  const evaluate = async (expression) => {
    const { result, exceptionDetails } = await send("Runtime.evaluate", { expression, returnByValue: true }, sessionId);
    if (exceptionDetails !== undefined) throw new Error(`${expression}: ${exceptionDetails.exception?.description ?? exceptionDetails.text}`);
    return result.value;
  };
  // Wait until `expression` is truthy, and return it; null after `ms`.
  const until = async (expression, ms = 10_000) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const value = await evaluate(expression);
      if (value) return value;
      if (Date.now() > deadline) return null;
      await new Promise((later) => setTimeout(later, 25));
    }
  };
  // Wait until no request is open and none started for 300 ms, so that the
  // program has seen every answer, the failed ones too.
  const settled = async (ms = 10_000) => {
    const deadline = Date.now() + ms;
    while (page.pending.size > 0 || Date.now() - page.changed < 300) {
      if (Date.now() > deadline) return false;
      await new Promise((later) => setTimeout(later, 25));
    }
    return true;
  };
  return { page, evaluate, until, settled };
}

// The requests of a page that went wrong: a request to the server that
// failed or answered an error, except the document's own 404, which
// `notFound` says to expect; and a request to another host that got an
// answer, which no request may get. The favicon at the root of the origin
// is Chrome's own request, outside the base: on GitHub Pages, another
// site's file.
function wrongRequests(page, notFound) {
  const wrong = [];
  for (const { url, document, status, failed } of page.requests.values()) {
    if (!/^(https?|wss?):/.test(url) || url === `${origin}/favicon.ico`) continue;
    if (new URL(url).origin === origin) {
      const expected = document && notFound ? 404 : 200;
      if (failed !== undefined || (status !== undefined && status !== expected && !(status >= 300 && status < 400))) {
        wrong.push(`${url}: ${failed ?? status}`);
      }
    } else if (status !== undefined) {
      wrong.push(`${url} left the machine: ${status}`);
    }
  }
  return wrong;
}

// The other hosts that a page asked for, which no host resolves for.
const blocked = (page) => [...new Set([...page.requests.values()].map(({ url }) => (/^(https?|wss?):/.test(url) ? new URL(url) : null)).filter((url) => url !== null && url.origin !== origin).map((url) => url.host))].sort();
const note = (at, page) => process.stdout.write(`     ${at}: blocked hosts: ${blocked(page).join(", ") || "none"}\n`);

for (const program of routed) {
  for (const { path, title } of program.paths) {
    const at = `${base}${program.name}/${path}`;
    const deep = path !== "";
    const { page, evaluate, until, settled } = await open(`${program.name}/${path}`);
    const shown = await until(`document.querySelector(${JSON.stringify(program.root)}) !== null && document.title === ${JSON.stringify(title)}`);
    check(shown !== null, `${at}: ${program.root} with the title "${title}" (title "${await evaluate("document.title")}")`);
    check(await settled(), `${at}: every request ends`);
    check((await evaluate(`document.querySelectorAll(${JSON.stringify(program.root)}).length`)) === 1, `${at}: one ${program.root}`);
    check((await evaluate(`location.pathname`)) === at, `${at}: the address stays (${await evaluate("location.pathname")})`);
    check((await evaluate(`document.getElementById("not-found") === null`)) === true, `${at}: no #not-found`);
    check(shown !== null && (await evaluate(program.styled)) === true, `${at}: the shell's styles apply`);
    const documents = [...page.requests.values()].filter((r) => r.document).map((r) => r.status);
    check(JSON.stringify(documents) === JSON.stringify([deep ? 404 : 200]), `${at}: the document answers ${deep ? "404, from 404.html" : "200"} (${JSON.stringify(documents)})`);
    const wrong = wrongRequests(page, deep);
    check(wrong.length === 0, `${at}: no request to the server fails, and none leaves the machine${wrong.map((w) => `\n       ${w}`).join("")}`);
    check(page.errors.length === 0, `${at}: no page error${page.errors.map((e) => `\n       ${e}`).join("")}`);
    note(at, page);
  }
}

for (const path of missing) {
  const at = `${base}${path}`;
  const { page, evaluate, until, settled } = await open(path);
  const shown = await until(`document.getElementById("not-found")?.hidden === false`);
  check(shown !== null, `${at}: #not-found shows`);
  check(await settled(), `${at}: every request ends`);
  check((await evaluate(`document.title`)) === "Not found · beni examples", `${at}: the title of the page (${await evaluate("document.title")})`);
  check((await evaluate(`document.querySelector("#not-found a")?.getAttribute("href")`)) === base, `${at}: the link goes to ${base}`);
  const wrong = wrongRequests(page, true);
  check(wrong.length === 0, `${at}: no request to the server fails, and none leaves the machine${wrong.map((w) => `\n       ${w}`).join("")}`);
  check(page.errors.length === 0, `${at}: no page error${page.errors.map((e) => `\n       ${e}`).join("")}`);
  note(at, page);
}

socket.close();
// Chrome writes into its profile until it exits.
const exited = browser.exitCode !== null || browser.signalCode !== null ? Promise.resolve() : new Promise((done) => browser.on("exit", done));
browser.kill();
await exited;
server.close();
rmSync(profile, { recursive: true, force: true });
process.stdout.write(`${failures} failed\n`);
process.exitCode = failures === 0 ? 0 : 1;
