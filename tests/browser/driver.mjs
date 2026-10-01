// The browser corpus kind's driver: loads one built program into a page,
// drives it with a script of steps, and prints what the page showed after
// the load and after every step. The corpus walker compares that transcript
// with the fixture's golden (tests/corpus/README.md, `browser/`).
//
//   node driver.mjs --dom=<happy-dom.mjs> <entry.mjs> [<steps>]
//   node driver.mjs --chrome=<ws://…/devtools/browser/…> <entry.mjs> [<steps>]
//
// The first runs the page in Node under happy-dom (the gates); the second in
// a headless Chrome the caller launched, as a fresh target (`zig build
// test-browser`). Both run the same page code below — the prelude, the step
// runner and the serialiser — so a transcript differs between them only
// where the two DOMs do.
//
// Exit 0: the transcript is on stdout. Exit 1: the page threw an uncaught
// exception, or a step could not run; the transcript so far is on stdout and
// the reason on stderr. Exit 2: the driver was called wrongly.
//
// The steps file has one step per line; `#` starts a comment line:
//
//   click <selector>            a bubbling, cancelable `click` MouseEvent
//   click <selector> <n>        `n` of them in one task, then the line
//                               `(the step's task ended)` in the transcript
//   flush <selector>            a click, then the program runtime's `flush`
//                               export in the same task, then the line
//                               `(flushed)`
//   input <selector> "<text>"   set `.value`, then a bubbling `input` InputEvent
//   type <selector> "<text>"    per character, a task of its own: append it to
//                               the live `.value`, then an `input` InputEvent;
//                               the page settles between two characters, as
//                               it does between two keystrokes
//   key <selector> <key> [<modifier>…] [code:<code>]
//                               `keydown` then `keyup` KeyboardEvents with that
//                               `key`, each modifier (`ctrl`, `shift`, `alt`,
//                               `meta`, `repeat`) set and `code` given (default
//                               ""); each one whose default a handler
//                               prevented logs `(keydown's default prevented)`
//                               or `(keyup's …)` when its dispatch returns
//   focus <selector>            `.focus()`
//   advance <ms>                move the page's virtual clock on by `ms`,
//                               firing each timer that comes due, in
//                               order, the page settling after each
//   event <window|document> <name> [<n>]
//                               `n` (default 1) plain `Event`s of that name
//                               on the window or the document, in one task
//   url "<url>"                 `history.replaceState` to the URL, relative to
//                               the page's (`"?q=1#/active"`); nothing fires
//   hash "<#fragment>"          the same, then one `hashchange` on the window
//                               in the step's task — what following a link
//                               to the fragment does, without happy-dom's
//                               second event
//   store <local|session> "<key>" "<value>"
//                               `setItem` on that storage
//   storage <local|session>     log `(localStorage: {…})`, every item by key
//   throws <step>               any step above, which must make the page
//                               throw: each uncaught exception is the line
//                               `(threw: <its first line>)` instead of the
//                               end of the run, and none is a failure
//
// The page's clock is virtual from the start: `Date.now()` is 0 until an
// `advance` step moves it, and a `setTimeout` callback runs only when an
// `advance` step reaches its time.
//
// The two lines are written when the step's own task ends, before any
// microtask it queued, so what the page logged before and after them says
// what ran in that task: a render the program ran at once is logged
// before the line, one it deferred after. The program runtime is the
// module the entry file imports `run` from: `_platform/runtime.foreign.mjs`,
// or a base platform's under `_platform/_<name>/` when the program's
// platform is layered on it.
//
// A selector is one CSS selector without spaces (`#id`, `li:nth-child(2)>a`)
// and must match an element. Events are dispatched with `dispatchEvent`, in
// both DOMs, so none is trusted and `key` types nothing: text goes in with
// `input`.

import { Console } from "node:console";
import { readFileSync, writeFileSync } from "node:fs";
import { basename, resolve } from "node:path";
import process from "node:process";
import { Writable } from "node:stream";
import { pathToFileURL } from "node:url";

// ---------------------------------------------------------------------------
// Page code. Each function is self-contained: Chrome receives its source.
// ---------------------------------------------------------------------------

// Installed before the program runs: console output and uncaught exceptions
// are recorded, in order, for the driver to collect after each phase.
function prelude() {
  const record = { log: [], errors: [] };
  globalThis.__beniHarness = record;
  // Every page starts with empty storage: Chrome keeps a `file:` page's
  // across the pages of one run, happy-dom's window starts empty.
  try {
    localStorage.clear();
    sessionStorage.clear();
  } catch {}
  // The page's clock is virtual: `Date.now()` starts at 0 and moves only
  // when an `advance` step moves it, and a `setTimeout` callback runs only
  // when an `advance` step reaches its time. The driver keeps the real
  // timer for itself.
  const clock = { now: 0, next: 1, timers: [], real: globalThis.setTimeout.bind(globalThis) };
  record.clock = clock;
  globalThis.setTimeout = (fn, ms, ...args) => {
    const id = clock.next++;
    const wait = Number(ms);
    clock.timers.push({ id, due: clock.now + (wait > 0 ? wait : 0), fn, args });
    return id;
  };
  globalThis.clearTimeout = (id) => {
    clock.timers = clock.timers.filter((t) => t.id !== id);
  };
  Date.now = () => clock.now;
  const show = (value) => {
    if (typeof value === "string") return value;
    try {
      return typeof value === "object" && value !== null ? JSON.stringify(value) : String(value);
    } catch {
      return String(value);
    }
  };
  for (const level of ["log", "info", "warn", "error", "debug"]) {
    console[level] = (...args) => record.log.push(`console.${level}: ${args.map(show).join(" ")}`);
  }
  const describe = (error) => {
    if (error !== null && typeof error === "object" && "message" in error) {
      const frame = String(error.stack ?? "")
        .split("\n")
        .find((line) => /^\s+at /.test(line));
      return `${error.name}: ${error.message}${frame ? `\n${frame.trim()}` : ""}`;
    }
    return `a thrown ${typeof error}: ${show(error)}`;
  };
  record.describe = describe;
  globalThis.addEventListener("error", (event) => record.errors.push(describe(event.error ?? event.message)));
  globalThis.addEventListener("unhandledrejection", (event) => record.errors.push(describe(event.reason)));
}

// Import the program's entry file; an exception while its modules evaluate
// is recorded like any other uncaught one.
async function load({ url, runtime }) {
  const record = globalThis.__beniHarness;
  try {
    await import(url);
  } catch (error) {
    record.errors.push(record.describe(error));
    return;
  }
  // The same module instance the program's entry file imported, for the
  // `flush` step; an entry file that imports no `run` has none.
  try {
    record.runtime = runtime === null ? null : await import(new URL(runtime, url).href);
  } catch {
    record.runtime = null;
  }
}

// Run one step. Returns null, or why the step could not run — or, for
// `advance`, a promise of one.
function step(s) {
  if (s.command === "advance") {
    // Fire every timer due by the target time, earliest first (by when it
    // was set, among timers due at once), with the clock at its time, and
    // let the page settle after each, so the work a timer resumed runs —
    // and may set the next timer — before the next one fires.
    const clock = globalThis.__beniHarness.clock;
    const target = clock.now + s.ms;
    return (async () => {
      for (;;) {
        let t = null;
        for (const c of clock.timers) {
          if (c.due <= target && (t === null || c.due < t.due || (c.due === t.due && c.id < t.id))) t = c;
        }
        if (t === null) break;
        clock.timers = clock.timers.filter((c) => c !== t);
        clock.now = t.due;
        t.fn(...t.args);
        await new Promise((done) => clock.real(done, 0));
      }
      clock.now = target;
      return null;
    })();
  }
  if (s.command === "url") {
    history.replaceState(null, "", s.text);
    return null;
  }
  if (s.command === "hash") {
    const oldURL = location.href;
    history.replaceState(null, "", s.text);
    dispatchEvent(new HashChangeEvent("hashchange", { oldURL, newURL: location.href }));
    return null;
  }
  if (s.command === "store") {
    (s.selector === "local" ? localStorage : sessionStorage).setItem(s.key, s.value);
    return null;
  }
  if (s.command === "storage") {
    const area = s.selector === "local" ? localStorage : sessionStorage;
    const entries = {};
    const keys = [];
    for (let i = 0; i < area.length; i++) keys.push(area.key(i));
    for (const k of keys.sort()) entries[k] = area.getItem(k);
    globalThis.__beniHarness.log.push(`(${s.selector}Storage: ${JSON.stringify(entries)})`);
    return null;
  }
  if (s.command === "event") {
    const on = s.selector === "window" ? globalThis : document;
    for (let n = 0; n < s.count; n++) on.dispatchEvent(new Event(s.name));
    return null;
  }
  const target = document.querySelector(s.selector);
  if (target === null) return `no element matches \`${s.selector}\``;
  const init = { bubbles: true, cancelable: true, composed: true };
  switch (s.command) {
    case "click":
      for (let n = 0; n < (s.count ?? 1); n++) target.dispatchEvent(new MouseEvent("click", { ...init, button: 0, detail: 1 }));
      if (s.count !== undefined) globalThis.__beniHarness.log.push("(the step's task ended)");
      return null;
    case "flush": {
      const runtime = globalThis.__beniHarness.runtime;
      if (typeof runtime?.flush !== "function") return "the program runtime exports no `flush`";
      target.dispatchEvent(new MouseEvent("click", { ...init, button: 0, detail: 1 }));
      runtime.flush();
      globalThis.__beniHarness.log.push("(flushed)");
      return null;
    }
    case "input":
      if (!("value" in target)) return `\`${s.selector}\` has no \`value\``;
      target.value = s.text;
      target.dispatchEvent(new InputEvent("input", { ...init, cancelable: false, inputType: "insertText", data: s.text }));
      return null;
    // One character of a `type` step: what the control shows now, plus it.
    case "type":
      if (!("value" in target)) return `\`${s.selector}\` has no \`value\``;
      target.value += s.text;
      target.dispatchEvent(new InputEvent("input", { ...init, cancelable: false, inputType: "insertText", data: s.text }));
      return null;
    case "key": {
      const key = { ...init, key: s.key, code: s.code, ...s.modifiers };
      if (!target.dispatchEvent(new KeyboardEvent("keydown", key))) globalThis.__beniHarness.log.push("(keydown's default prevented)");
      if (!target.dispatchEvent(new KeyboardEvent("keyup", key))) globalThis.__beniHarness.log.push("(keyup's default prevented)");
      return null;
    }
    case "focus":
      target.focus();
      return null;
  }
  return `unknown command \`${s.command}\``;
}

// Let everything the last phase queued run: its microtasks, then one turn
// of the event loop.
function settle() {
  return new Promise((done) => globalThis.__beniHarness.clock.real(done, 0));
}

// What the phase logged and threw, taken out of the record.
function drain() {
  const record = globalThis.__beniHarness;
  const taken = { log: record.log, errors: record.errors };
  record.log = [];
  record.errors = [];
  return taken;
}

// `document.body` as text, one node per line, indented by depth. Text and
// attribute values are JSON strings, so whitespace is visible. A form
// control's live `value` (and a checkbox's or radio's `checked`) follows
// its attributes as `.value=…`, since it is not an attribute; the focused
// element is marked `:focus`. An element in the SVG or MathML namespace is
// written `svg:` or `math:` before its name. An element whose only child is
// text is written on one line, and an empty void element has no end tag.
function serialise() {
  const quote = (s) => JSON.stringify(s);
  const prefixes = { "http://www.w3.org/2000/svg": "svg:", "http://www.w3.org/1998/Math/MathML": "math:" };
  const voids = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"];
  const lines = [];
  const walk = (node, depth) => {
    const pad = "  ".repeat(depth);
    if (node.nodeType === 3) return void lines.push(pad + quote(node.data));
    if (node.nodeType === 8) return void lines.push(`${pad}<!--${node.data}-->`);
    if (node.nodeType !== 1) return void lines.push(`${pad}<?node type ${node.nodeType}?>`);
    const name = (prefixes[node.namespaceURI] ?? "") + node.localName;
    let open = `<${name}`;
    for (const a of node.attributes) open += ` ${a.name}=${quote(a.value)}`;
    if (node.localName === "input" || node.localName === "textarea" || node.localName === "select") {
      open += ` .value=${quote(node.value)}`;
      if (node.type === "checkbox" || node.type === "radio") open += ` .checked=${node.checked}`;
    }
    if (node === document.activeElement && node !== document.body) open += " :focus";
    open += ">";
    const children = [...(node.localName === "template" ? node.content.childNodes : node.childNodes)];
    const close = `</${name}>`;
    if (children.length === 0) return void lines.push(pad + open + (voids.includes(name) ? "" : close));
    if (children.length === 1 && children[0].nodeType === 3) return void lines.push(pad + open + quote(children[0].data) + close);
    lines.push(pad + open);
    for (const child of children) walk(child, depth + 1);
    lines.push(pad + close);
  };
  walk(document.body, 0);
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// The driver.
// ---------------------------------------------------------------------------

const usage = (why) => {
  process.stderr.write(`driver: ${why}\nusage: node driver.mjs (--dom=<happy-dom.mjs> | --chrome=<ws url>) <entry.mjs> [<steps>]\n`);
  process.exit(2);
};

const options = {};
const positional = [];
for (const arg of process.argv.slice(2)) {
  const m = arg.match(/^--(dom|chrome)=(.+)$/);
  if (m) options[m[1]] = m[2];
  else if (arg.startsWith("--")) usage(`unknown option ${arg}`);
  else positional.push(arg);
}
if (positional.length < 1 || positional.length > 2) usage("expected an entry file and at most one steps file");
if ((options.dom === undefined) === (options.chrome === undefined)) usage("give exactly one of --dom and --chrome");
const [entry, stepsPath] = positional;

// Parse the whole script before the page loads, so a malformed step is
// reported without running anything.
const steps = [];
if (stepsPath !== undefined) {
  const text = readFileSync(stepsPath, "utf8");
  text.split("\n").forEach((raw, i) => {
    const written = raw.trim();
    if (written === "" || written.startsWith("#")) return;
    const where = `${stepsPath}:${i + 1}`;
    const throws = written.startsWith("throws ");
    const line = throws ? written.slice("throws ".length).trim() : written;
    const m = line.match(/^(\S+)\s+(\S+)(?:\s+(.*))?$/);
    if (!m) usage(`${where}: \`${line}\` is not \`<command> <selector> [<argument>]\``);
    const [, command, selector, argument] = m;
    const s = { line: written, where, command, selector, throws };
    if (command === "advance") {
      if (argument !== undefined || !/^[0-9]+$/.test(selector)) usage(`${where}: \`advance\` takes a number of milliseconds`);
      s.ms = Number(selector);
    } else if (command === "url" || command === "hash") {
      try {
        s.text = JSON.parse(argument === undefined ? selector : "");
      } catch {
        s.text = undefined;
      }
      if (typeof s.text !== "string" || (command === "hash" && !s.text.startsWith("#"))) {
        usage(`${where}: \`${command}\` takes one JSON string${command === "hash" ? " that starts with `#`" : ""}`);
      }
    } else if (command === "store") {
      const kv = (argument ?? "").match(/^("(?:[^"\\]|\\.)*")\s+("(?:[^"\\]|\\.)*")$/);
      if ((selector !== "local" && selector !== "session") || kv === null) usage(`${where}: \`store\` takes \`local\` or \`session\` and two JSON strings`);
      s.key = JSON.parse(kv[1]);
      s.value = JSON.parse(kv[2]);
    } else if (command === "storage") {
      if ((selector !== "local" && selector !== "session") || argument !== undefined) usage(`${where}: \`storage\` takes \`local\` or \`session\``);
    } else if (command === "event") {
      const e = (argument ?? "").match(/^([a-z]+)(?:\s+([1-9][0-9]*))?$/);
      if ((selector !== "window" && selector !== "document") || e === null) {
        usage(`${where}: \`event\` takes \`window\` or \`document\`, an event name and at most a count`);
      }
      s.name = e[1];
      s.count = e[2] === undefined ? 1 : Number(e[2]);
    } else if (command === "click" && argument !== undefined) {
      if (!/^[1-9][0-9]*$/.test(argument)) usage(`${where}: \`click\` takes a selector and at most a count`);
      s.count = Number(argument);
    } else if (command === "click" || command === "focus" || command === "flush") {
      if (argument !== undefined) usage(`${where}: \`${command}\` takes a selector only`);
    } else if (command === "input" || command === "type") {
      try {
        s.text = JSON.parse(argument ?? "");
      } catch {
        s.text = undefined;
      }
      if (typeof s.text !== "string") usage(`${where}: \`${command}\` takes a selector and a JSON string`);
      if (command === "type" && s.text === "") usage(`${where}: \`type\` takes at least one character`);
    } else if (command === "key") {
      const words = (argument ?? "").split(/\s+/).filter((w) => w !== "");
      if (words.length === 0) usage(`${where}: \`key\` takes a selector, one key name and at most its modifiers and \`code:<code>\``);
      s.key = words[0];
      s.code = "";
      s.modifiers = {};
      for (const w of words.slice(1)) {
        if (["ctrl", "shift", "alt", "meta", "repeat"].includes(w)) s.modifiers[w === "repeat" ? "repeat" : `${w}Key`] = true;
        else if (/^code:\S+$/.test(w)) s.code = w.slice("code:".length);
        else usage(`${where}: \`key\` takes \`ctrl\`, \`shift\`, \`alt\`, \`meta\`, \`repeat\` or \`code:<code>\` after the key, not \`${w}\``);
      }
    } else usage(`${where}: unknown command \`${command}\``);
    steps.push(s);
  });
}

// The page the program runs in: an empty document at this URL, in the
// directory the driver runs in (the test's project). Chrome loads it from
// the file, which the driver writes.
const pageFile = resolve("_page.html");
const pageUrl = pathToFileURL(pageFile).href;
const entryUrl = pathToFileURL(resolve(entry)).href;
const blank = "<!DOCTYPE html><html><head></head><body></body></html>";

// A page: `run(fn, arg)` calls one page function with a JSON argument and
// resolves to its JSON result.
async function happyDomPage(domPath) {
  const { GlobalWindow } = await import(pathToFileURL(resolve(domPath)).href);
  // happy-dom reports a listener's exception on the console as well as to
  // the page's `error` listeners, which Chrome does not: its console is one
  // that writes nothing, and the page keeps Node's.
  const silent = new Console({ stdout: new Writable({ write: (_chunk, _encoding, done) => done() }) });
  // A new window's document is the empty page. It loads nothing from
  // anywhere: the driver imports the program, and no fixture has anything
  // else to fetch.
  const window = new GlobalWindow({
    url: pageUrl,
    console: silent,
    settings: {
      disableJavaScriptFileLoading: true,
      disableCSSFileLoading: true,
      disableIframePageLoading: true,
      navigation: { disableMainFrameNavigation: true, disableChildFrameNavigation: true, disableChildPageNavigation: true },
    },
  });
  // Node's global object becomes the page's: every property the window
  // has and Node lacks or holds differently is defined on it, the window's
  // references to itself become references to it, and its event methods
  // are the window's, so an `error` listener the page adds is on the window
  // happy-dom reports a listener's exception to. What Node has and the
  // window lacks — `MessageChannel`, `process` — stays.
  for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(window))) {
    if (["constructor", "undefined", "NaN", "global", "globalThis", "console"].includes(key)) continue;
    const own = Object.getOwnPropertyDescriptor(globalThis, key);
    if (own !== undefined && own.value !== undefined && own.value === descriptor.value) continue;
    if (descriptor.value === window) descriptor.value = globalThis;
    Object.defineProperty(globalThis, key, { ...descriptor, configurable: true });
  }
  for (const method of ["addEventListener", "removeEventListener", "dispatchEvent"]) {
    globalThis[method] = window[method].bind(window);
  }
  prelude();
  // What escapes to Node rather than to the page's `error` event — a
  // microtask that threw — is an uncaught exception of the page all the
  // same.
  const record = globalThis.__beniHarness;
  process.on("uncaughtException", (error) => record.errors.push(record.describe(error)));
  process.on("unhandledRejection", (error) => record.errors.push(record.describe(error)));
  return {
    run: async (fn, arg) => fn(arg),
    close: async () => {},
  };
}

async function chromePage(endpoint) {
  writeFileSync(pageFile, blank);
  const socket = new WebSocket(endpoint);
  await new Promise((opened, failed) => {
    socket.onopen = opened;
    socket.onerror = () => failed(new Error(`cannot connect to Chrome at ${endpoint}`));
  });
  let next = 0;
  const waiting = new Map();
  const events = [];
  socket.onmessage = (message) => {
    const m = JSON.parse(message.data);
    const w = waiting.get(m.id);
    if (w === undefined) return void events.forEach((listen) => listen(m));
    waiting.delete(m.id);
    if (m.error) w.failed(new Error(`${w.method}: ${m.error.message}`));
    else w.done(m.result);
  };
  const send = (method, params = {}, sessionId = undefined) =>
    new Promise((done, failed) => {
      next += 1;
      waiting.set(next, { method, done, failed });
      socket.send(JSON.stringify({ id: next, method, params, sessionId }));
    });
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Page.enable", {}, sessionId);
  // A headless target is never the focused window, so `focus()` would move
  // `document.activeElement` without firing `focus` and `blur`; emulated
  // focus makes it fire them, as happy-dom and a focused browser do.
  await send("Emulation.setFocusEmulationEnabled", { enabled: true }, sessionId);
  await send("Page.addScriptToEvaluateOnNewDocument", { source: `(${prelude})();` }, sessionId);
  const loaded = new Promise((done) => {
    events.push((m) => {
      if (m.sessionId === sessionId && m.method === "Page.loadEventFired") done();
    });
  });
  await send("Page.navigate", { url: pageUrl }, sessionId);
  await loaded;
  const helpers = `const step = ${step}; const settle = ${settle}; const drain = ${drain}; const serialise = ${serialise}; const load = ${load};`;
  return {
    run: async (fn, arg) => {
      const expression = `(() => { ${helpers} return (${fn.name})(${JSON.stringify(arg) ?? ""}); })()`;
      const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, sessionId);
      if (r.exceptionDetails) throw new Error(`${fn.name} failed in Chrome: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      return r.result.value;
    },
    close: async () => {
      await send("Target.closeTarget", { targetId });
      socket.close();
    },
  };
}

const page = options.dom !== undefined ? await happyDomPage(options.dom) : await chromePage(options.chrome);

const transcript = [];
let shown = null;
const finish = async (code, why) => {
  await page.close();
  process.stdout.write(transcript.length === 0 ? "" : `${transcript.join("\n")}\n`, () => {
    if (why !== undefined) process.stderr.write(`${why}\n`, () => process.exit(code));
    else process.exit(code);
  });
};

// One phase: act, let the page settle, then record what it logged and what
// it now shows.
const phase = async (title, act, throws = false) => {
  transcript.push(`-- ${title}`);
  const fault = await act();
  await page.run(settle);
  const { log, errors } = await page.run(drain);
  transcript.push(...log);
  if (throws) {
    if (errors.length === 0) {
      await finish(1, `${title}: the step was to make the page throw, and it did not`);
      return false;
    }
    transcript.push(...errors.map((e) => `(threw: ${e.split("\n")[0]})`));
  } else if (errors.length !== 0) {
    await finish(1, `${title}: the page threw an uncaught exception:\n${errors.join("\n")}`);
    return false;
  }
  if (fault !== null && fault !== undefined) {
    await finish(1, fault);
    return false;
  }
  const dom = await page.run(serialise);
  transcript.push(dom === shown ? "(the DOM did not change)" : dom);
  shown = dom;
  return true;
};

// The program runtime, as the entry file names it: `import { run } from …`,
// or under `--release`, when `start` comes from the same file,
// `import{run,start}from…`. A `--release` application is one scope-hoisted
// file that imports no runtime (backend.md §9): the runtime is inside it, and
// the file itself exports the runtime's `flush`.
const runtimeImport = readFileSync(resolve(entry), "utf8").match(/^import ?\{ ?run ?(?:, ?start ?)?\} ?from ?"([^"]+)";$/m);
const runtime = runtimeImport === null ? `./${basename(entry)}` : runtimeImport[1];

// The steps before the first that is not `url` or `store` set the page up:
// they run before the program loads, each a heading with nothing under it.
const setup = [];
while (steps.length !== 0 && (steps[0].command === "url" || steps[0].command === "store") && !steps[0].throws) setup.push(steps.shift());
let setupFault = null;
for (const s of setup) {
  transcript.push(`-- ${s.line}`);
  const why = await page.run(step, s);
  if (why !== null) {
    setupFault = `${s.where}: ${s.line}: ${why}`;
    break;
  }
}

if (setupFault !== null) await finish(1, setupFault);
else if (await phase("load", () => page.run(load, { url: entryUrl, runtime }))) {
  let ok = true;
  for (const s of steps) {
    ok = await phase(s.line, async () => {
      // A `type` step is one task per character, the page settling after
      // each but the last, which the phase settles.
      const tasks = s.command === "type" ? [...s.text].map((ch) => ({ ...s, text: ch })) : [s];
      for (const [i, t] of tasks.entries()) {
        if (i !== 0) await page.run(settle);
        const why = await page.run(step, t);
        if (why !== null) return `${s.where}: ${s.line}: ${why}`;
      }
      return null;
    }, s.throws);
    if (!ok) break;
  }
  if (ok) await finish(0);
}
