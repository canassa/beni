// Drive the playground in a headless Chrome (docs/design/playground.md §4,
// §5): `zig build test-playground-page`, not a gate. It needs a Chrome,
// which `nix develop .#browser` puts on PATH, and no network: the editor's
// modules are files of the site (§4.2).
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
//   - each styled sample's CSS reaches the frame, in the light and the dark
//     scheme, with the contrast §4.6 gives, and no sideways scroll in a
//     320 px wide frame;
//   - a program with an error marks it in the editor and lists it;
//   - the Types and Ownership tabs show their dumps;
//   - an empty CSS pane gives the frame no style sheet, an edit in the CSS
//     pane reaches the frame, the pane highlights CSS, and an `@import` from
//     another origin applies in the frame;
//   - a shared link opens the same source, CSS and platform, and a damaged
//     one says so.
// Each failed check prints a line; the exit code is the number of them.
// With `BENI_PLAYGROUND_SCREENSHOTS=<dir>`, it also saves a screenshot of
// each styled sample's frame in each scheme, at a desktop and a phone
// width, and of the page with the CSS pane open, into <dir>.
import { spawn } from "node:child_process";
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
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
// Another origin, with one style sheet: what an `@import` in the CSS pane
// loads (playground.md §4.6).
const elsewhereServer = createServer((req, res) => {
  res.writeHead(req.url === "/imported.css" ? 200 : 404, { "content-type": "text/css" });
  res.end(req.url === "/imported.css" ? "html { background-color: rgb(4, 5, 6); }\n" : "");
});
await new Promise((listening) => elsewhereServer.listen(0, "127.0.0.1", listening));
const elsewhereOrigin = `http://127.0.0.1:${elsewhereServer.address().port}`;
const screenshots = process.env.BENI_PLAYGROUND_SCREENSHOTS;
if (screenshots) mkdirSync(screenshots, { recursive: true });

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
// Every URL a page asked for (`Network.requestWillBeSent`).
const requests = [];
socket.onmessage = (message) => {
  const m = JSON.parse(message.data);
  if (m.method === "Network.requestWillBeSent") {
    requests.push(m.params.request.url);
    return;
  }
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
  await send("Network.enable", {}, sessionId);
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
  // Type `text` at the cursor of the editor `editor` (`#editor`, the
  // source, or `#css-editor`), as a user does.
  const type = async (text, editor = "#editor") => {
    await evaluate(`document.querySelector("${editor} .cm-content").focus()`);
    await send("Input.insertText", { text }, sessionId);
  };
  // Move the editor's cursor to the end of the text, with Ctrl+End.
  const toEnd = async (editor = "#editor") => {
    await evaluate(`document.querySelector("${editor} .cm-content").focus()`);
    for (const type of ["rawKeyDown", "keyUp"]) {
      await send("Input.dispatchKeyEvent", { type, key: "End", code: "End", windowsVirtualKeyCode: 35, modifiers: 2 }, sessionId);
    }
  };
  // The value of `expression` in the page's newest frame.
  const inFrame = (expression) => evaluate(expression, frames.get(sessionId));
  // The colour scheme the page and its frame prefer: `light` or `dark`.
  const scheme = async (value) => {
    const features = [{ name: "prefers-color-scheme", value }];
    await send("Emulation.setEmulatedMedia", { features }, sessionId);
    await send("Emulation.setEmulatedMedia", { features }, frames.get(sessionId));
  };
  // The page's size, or its own size again with no arguments.
  const size = async (width, height, deviceScaleFactor = 1) => {
    if (width === undefined) await send("Emulation.clearDeviceMetricsOverride", {}, sessionId);
    else await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor, mobile: false }, sessionId);
  };
  // A PNG of the page, or of the part of it that `selector` covers, into
  // `screenshots`.
  const screenshot = async (file, selector = null) => {
    const clip = selector === null ? undefined : { ...(await evaluate(`JSON.parse(JSON.stringify(document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect()))`)), scale: 1 };
    const { data } = await send("Page.captureScreenshot", { format: "png", clip }, sessionId);
    writeFileSync(join(screenshots, file), Buffer.from(data, "base64"));
  };
  return { targetId, evaluate, until, type, toEnd, inFrame, scheme, size, screenshot };
}

/// A page opened from a link to `source` and `css` on `platform`, which the
/// page's own `share.js` makes.
const pageWith = async (platform, source, css = "") => open(`${origin}/#${await encode(platform, source, css)}`);

// Empty while the page is still loading.
const status = `(document.getElementById("status")?.textContent ?? "")`;
const built = `(${status}).startsWith("Built in") && (${status})`;
const loaded = `document.getElementById("frame")?.dataset.loaded === "true"`;
const textOf = (editor) => `[...document.querySelectorAll("${editor} .cm-content .cm-line")].map((l) => l.textContent).join("\\n")`;
const editorText = textOf("#editor");
const cssText = textOf("#css-editor");
const showCss = `document.querySelector('[data-file="css-editor"]').click()`;
// The frame's style sheets: none for a program with an empty CSS pane.
const unstyled = `document.styleSheets.length === 0 && document.querySelector("style") === null`;
const later = (ms) => new Promise((done) => setTimeout(done, ms));

// The text of the elements `checks` names whose contrast on their
// background is under what WCAG 2.2 AA asks (playground.md §4.6): 4.5:1,
// and 3:1 for large text (24 px, or 18.66 px and bold) and for a control's
// glyph (`ui`). Run in the frame. The background is every background from
// the root down to `on` (the element itself unless given), each laid over
// the one under it; an element with none is skipped as not shown.
const lowContrast = `((checks) => {
  const rgba = (text) => {
    const [r, g, b, a = 1] = /rgba?\\(([^)]*)\\)/.exec(text)[1].split(/[\\s,\\/]+/).filter(Boolean).map(Number);
    return [r, g, b, a];
  };
  const over = ([r, g, b, a], under) => [r * a + under[0] * (1 - a), g * a + under[1] * (1 - a), b * a + under[2] * (1 - a)];
  const channel = (c) => ((c /= 255) <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  const luminance = ([r, g, b]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
  const low = [];
  for (const { text, pseudo = null, on = null, ui = false } of checks) {
    const element = document.querySelector(text);
    if (element === null) {
      low.push({ text, missing: true });
      continue;
    }
    const layers = [];
    for (let e = on === null ? element : document.querySelector(on); e !== null; e = e.parentElement) layers.unshift(getComputedStyle(e).backgroundColor);
    const background = layers.reduce((under, layer) => over(rgba(layer), under), [255, 255, 255]);
    const style = getComputedStyle(element, pseudo);
    const [lighter, darker] = [luminance(over(rgba(style.color), background)), luminance(background)].sort((a, b) => b - a);
    const ratio = (lighter + 0.05) / (darker + 0.05);
    const size = parseFloat(style.fontSize);
    const large = size >= 24 || (size >= 18.66 && Number(style.fontWeight) >= 700);
    const least = ui || large ? 3 : 4.5;
    if (ratio < least) low.push({ text, pseudo, ratio: Number(ratio.toFixed(2)), least });
  }
  return low;
})`;

// Each styled sample's look (playground.md §4.6): a computed style its CSS
// sets, in each scheme; the text whose contrast is checked; and, for
// TodoMVC, the todos that show every kind of text.
const looks = {
  Counter: {
    known: `getComputedStyle(document.querySelector("span")).color + " on " + getComputedStyle(document.documentElement).backgroundColor`,
    light: "rgb(184, 63, 69) on rgb(245, 245, 245)",
    dark: "rgb(232, 118, 124) on rgb(22, 22, 24)",
    texts: [{ text: "span" }, { text: "button", pseudo: "::before" }],
  },
  TodoMVC: {
    known: `getComputedStyle(document.querySelector(".todoapp h1")).color + " on " + getComputedStyle(document.body).backgroundColor`,
    light: "rgb(184, 63, 69) on rgb(245, 245, 245)",
    dark: "rgb(232, 118, 124) on rgb(22, 22, 24)",
    // Two todos, the first completed, typed and clicked as a person does.
    prepare: [
      `(() => { const input = document.querySelector(".new-todo"); input.value = "Write the spec"; input.dispatchEvent(new Event("input", { bubbles: true })); input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); return true; })()`,
      `document.querySelectorAll(".todo-list li").length === 1 && (() => { const input = document.querySelector(".new-todo"); input.value = "Style the samples"; input.dispatchEvent(new Event("input", { bubbles: true })); input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); return true; })()`,
      `document.querySelectorAll(".todo-list li").length === 2 && (document.querySelector(".todo-list .toggle").click(), true)`,
      `document.querySelector(".todo-list li.completed") !== null && document.querySelector(".clear-completed:not([hidden])") !== null`,
    ],
    texts: [
      // The heading sits above the card, on the page.
      { text: ".todoapp h1", on: "body" },
      { text: ".new-todo", pseudo: "::placeholder" },
      { text: ".todo-list li:not(.completed) label" },
      { text: ".todo-list li.completed label" },
      { text: ".todo-count" },
      { text: ".filters a" },
      { text: ".clear-completed" },
      { text: ".toggle-all + label", pseudo: "::before", ui: true },
    ],
  },
};

/// The checks of §4.6 on the sample `name` that `page` shows, and its
/// screenshots when they are asked for.
async function checkLook(page, name, look) {
  for (const step of look.prepare ?? []) {
    check((await page.until(step, 10_000, true)) !== null, `${name}: ${step.slice(0, 80)}…`);
  }
  for (const value of ["light", "dark"]) {
    await page.scheme(value);
    check((await page.until(`${look.known} === ${JSON.stringify(look[value])}`, 10_000, true)) !== null, `${name}'s CSS reaches the frame, ${value} (${await page.inFrame(look.known)})`);
    // Past the samples' colour transitions (0.4 s at most).
    await later(600);
    const low = await page.inFrame(`${lowContrast}(${JSON.stringify(look.texts)})`);
    check(low.length === 0, `${name}: every text has the contrast WCAG 2.2 AA asks, ${value} ${JSON.stringify(low)}`);
    if (screenshots) {
      await page.size(1280, 800);
      await later(300);
      await page.screenshot(`${name}-${value}-desktop.png`, "#frame");
      await page.size(390, 1400, 2);
      await later(300);
      await page.screenshot(`${name}-${value}-phone.png`, "#frame");
      await page.size();
    }
  }
  await page.scheme("light");
  await page.size(320, 900);
  const scroll = `innerWidth + " " + document.documentElement.scrollWidth`;
  check((await page.until(`innerWidth <= 320 && document.documentElement.scrollWidth <= innerWidth`, 5_000, true)) !== null, `${name}: no sideways scroll in a 320 px wide frame (width and scroll width ${await page.inFrame(scroll)})`);
  await page.size();
}
const click = (tab) => `document.querySelector('[data-tab="${tab}"]').click()`;

const page = await open(`${origin}/`);
check((await page.until(`/Compiler loaded in \\d+ ms/.test(${status}) || ${built}`)) !== null, "the compiler loads");
check((await page.until(built)) !== null, `the first sample builds (${await page.evaluate(status)})`);
check(await page.evaluate(`document.querySelector(".cm-editor") !== null`), "the editor is CodeMirror");
check((await page.until(loaded)) !== null, "the first sample's program loads in the frame");
// The editor's modules are files of the site (§4.2): the page asks no other
// origin for anything.
const elsewhere = requests.filter((url) => !url.startsWith(`${origin}/`) && !url.startsWith("blob:") && !url.startsWith("data:"));
check(requests.some((url) => url.endsWith("/vendor/codemirror-view.js")) && elsewhere.length === 0, `every request stays on the site (${JSON.stringify(elsewhere)})`);

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
    check(looks[name] !== undefined, `sample ${name} has a look to check`);
    if (looks[name] !== undefined) await checkLook(page, name, looks[name]);
  }
}
if (screenshots) {
  // The page with the CSS pane open, on TodoMVC.
  await page.evaluate(`(() => { document.getElementById("status").textContent = ""; const s = document.getElementById("sample"); s.value = "1"; s.dispatchEvent(new Event("change")); })()`);
  await page.until(built);
  await page.until(loaded, 10_000);
  await page.evaluate(showCss);
  for (const value of ["light", "dark"]) {
    await page.scheme(value);
    await page.size(1440, 900);
    await later(600);
    await page.screenshot(`page-css-pane-${value}.png`);
    await page.size();
  }
  await page.scheme("light");
}

// An error, marked in the editor and listed.
const wrong = await pageWith("node", "import Node exposing (Program)\n\n\nmain : Program\nmain = Node.printLines [ missing ]\n");
check((await wrong.until(`/^1 error/.test(${status}) && (${status})`)) !== null, `an error is reported (${await wrong.evaluate(status)})`);
check((await wrong.until(`document.querySelector(".cm-lintRange-error")?.textContent === "missing"`, 10_000)) !== null, "the error is marked on `missing` in the editor");
check((await wrong.evaluate(`document.querySelector(".diagnostic")?.textContent ?? ""`)).startsWith("NAMING ERROR — Main.beni:5:"), "the error is listed with its place");
// From the CSS pane, a click on the error shows the source (§4.6).
await wrong.evaluate(showCss);
await wrong.evaluate(`document.querySelector(".diagnostic").click()`);
check(await wrong.evaluate(`!document.getElementById("editor").hidden && document.getElementById("css-editor").hidden`), "a click on a diagnostic shows the source's tab");

// beni's grammar in the editor: the Elm mode with beni's tokens (§4.2).
const notation = "-- every token of beni's own\nimport Html exposing (Html)\n\n\npub schema Person =\n    name : String\n\n\nf : Int, Int → Int × Int\nf a b = ( a, b )\n\n\nview : ⊤ → Html msg\nview _ = <p class=\"x\">{\"a ≠ b ≤ c ≥ d ▷ e ◁ f … g ← h λ ⊥\"}</p>\n";
const highlighted = await pageWith("browser-direct", notation);
await highlighted.until(`document.querySelector(".cm-editor") !== null && document.querySelector(".cm-content")?.textContent.includes("schema")`, 20_000);
for (const piece of ["→", "×", "⊤", "pub", "schema", "<p", "class"]) {
  check(await highlighted.evaluate(`[...document.querySelectorAll("#editor .cm-line span")].some((s) => s.textContent === ${JSON.stringify(piece)} && s.className !== "")`), `the editor highlights ${piece}`);
}

// The CSS pane (§4.6). A program with an empty pane: its frame has no style
// sheet. An edit in the pane reaches the frame, `</style>` and all.
const counter = await (await fetch(`${origin}/samples/browser-direct/Counter.beni`)).text();
const bare = await pageWith("browser-direct", counter);
check((await bare.until(built)) !== null && (await bare.until(loaded, 10_000)) !== null, `a counter with no CSS builds and loads (${await bare.evaluate(status)})`);
check((await bare.until(`document.querySelectorAll("button").length === 2 && ${unstyled}`, 10_000, true)) !== null, "an empty CSS pane gives the frame no style sheet");
check((await bare.evaluate(cssText)) === "", "a link with no CSS opens an empty CSS pane");
await bare.evaluate(showCss);
check(await bare.evaluate(`!document.getElementById("css-editor").hidden && document.getElementById("editor").hidden`), "the style.css tab shows the CSS editor");
await bare.evaluate(`document.getElementById("status").textContent = ""`);
const edge = "/* </style></script> */\nmain {\n  outline: 3px solid rgb(1, 2, 3);\n}\n";
await bare.type(edge, "#css-editor");
check((await bare.until(`location.hash === ""`, 5_000)) !== null, "an edit of the CSS clears the link from the address");
check((await bare.until(built)) !== null, `an edit of the CSS builds the program (${await bare.evaluate(status)})`);
check((await bare.until(`document.querySelector("main") !== null && getComputedStyle(document.querySelector("main")).outlineColor === "rgb(1, 2, 3)"`, 10_000, true)) !== null, "an edit of the CSS reaches the frame, past a </style> in it");
check(await bare.evaluate(`[...document.querySelectorAll("#css-editor .cm-line span")].some((s) => s.textContent === "outline" && s.className !== "")`), "the CSS pane highlights CSS");
// Share: the link holds the source and the CSS.
await bare.evaluate(`document.getElementById("share").click()`);
const styledLink = await bare.until(`location.hash.includes("css=") && location.href`, 10_000);
check(styledLink !== null, "Share puts the CSS in the address");
const styled = await open(styledLink);
check((await styled.until(built)) !== null, `a link with CSS builds (${await styled.evaluate(status)})`);
check((await styled.evaluate(editorText)) === (await bare.evaluate(editorText)), "the link opens the source");
check((await styled.evaluate(cssText)) === edge, `the link opens the CSS (${JSON.stringify(await styled.evaluate(cssText))})`);
check((await styled.evaluate(`document.getElementById("platform").value`)) === "browser-direct", "the link opens the platform");
check((await styled.until(`document.querySelector("main") !== null && getComputedStyle(document.querySelector("main")).outlineColor === "rgb(1, 2, 3)"`, 10_000, true)) !== null, "the link's CSS reaches the frame");
// No list of allowed style sheets (§4.6): the frame loads an `@import` from
// another origin as it is.
const imported = await pageWith("browser-direct", counter, `@import url("${elsewhereOrigin}/imported.css");\n`);
check((await imported.until(built)) !== null, `a CSS with an @import builds (${await imported.evaluate(status)})`);
check((await imported.until(`getComputedStyle(document.documentElement).backgroundColor === "rgb(4, 5, 6)"`, 10_000, true)) !== null, "an @import from another origin applies in the frame");

// The dumps and the emitted JavaScript.
const program = "import Node exposing (Program)\n\n\ndouble : Int → Int\ndouble n = n * 2\n\n\nmain : Program\nmain = Node.printLines [ String.fromInt (double 21) ]\n";
const tabs = await pageWith("node", program);
check((await tabs.until(built)) !== null, `a linked program builds (${await tabs.evaluate(status)})`);
check((await tabs.until(`document.getElementById("console").textContent.includes("42")`, 10_000)) !== null, "the linked program runs");
check((await tabs.until(unstyled, 10_000, true)) !== null, "a printing program with an empty CSS pane has no style sheet in its frame");
await tabs.evaluate(click("types"));
check((await tabs.until(`document.getElementById("types-text").textContent.includes("double : Int → Int")`, 20_000)) !== null, "the Types tab shows the types");
await tabs.evaluate(click("ownership"));
check((await tabs.until(`document.getElementById("ownership-text").textContent.includes("summary double:")`, 20_000)) !== null, "the Ownership tab shows the report");
await tabs.evaluate(click("javascript"));
check((await tabs.until(`document.querySelector("#code .cm-content")?.textContent.includes("double")`, 10_000)) !== null, "the JavaScript tab shows the emitted module");
// Highlighted by the JavaScript grammar: a keyword of the module is in an
// element of its own with a highlight class.
check(await tabs.evaluate(`[...document.querySelectorAll("#code .cm-line span")].some((s) => s.textContent === "import" && s.className !== "")`), "the JavaScript tab highlights the emitted module");

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
elsewhereServer.close();
rmSync(profile, { recursive: true, force: true });
process.stdout.write(`${failures} failed\n`);
process.exitCode = failures === 0 ? 0 : 1;
