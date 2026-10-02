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
//   node driver.mjs --dom=<happy-dom.mjs> [--steps=<steps>] --page=<entry.mjs>@<report.json>…
//
// runs each page in turn in this one process, each in a page of its own,
// and writes what a run of it alone would have given — its exit code,
// stdout and stderr — to its report, as `{"code":…,"stdout":…,"stderr":…}`.
// The corpus walker runs a fixture's development and release builds so:
// Node starts, and compiles the DOM, once for both.
//
// The steps file has one step per line; `#` starts a comment line:
//
//   click <selector> [ctrl|shift|alt|meta]… [button:<n>]
//                               a bubbling, cancelable `click` MouseEvent with
//                               those modifiers held and that `button`
//                               (default 0); one whose default a handler or a
//                               listener prevented logs `(click's default
//                               prevented)` when its dispatch returns; one on a
//                               link nothing prevented is stopped by the
//                               driver after every listener of the page and
//                               logs `(the host follows the link to "<href>")`
//   click <selector> <n>       `n` of them in one task, then the line
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
//   hash "<#fragment>"          the same, then one `popstate` and one
//                               `hashchange` on the window
//                               in the step's task — what following a link
//                               to the fragment does, without happy-dom's
//                               second event
//   back / forward              `history.back()` / `history.forward()`, then
//                               wait for the `popstate` the traversal fires
//   location                    log `(location: <path><?query><#fragment>)`
//   store <local|session> "<key>" "<value>"
//                               `setItem` on that storage
//   storage <local|session>     log `(localStorage: {…})`, every item by key
//   timers                      log `(timers: <n>)`, the timers the virtual
//                               clock holds that have not fired or been cleared
//   listeners <window|document> [<name>]
//                               log `(listeners: <n>)`, the listeners the page
//                               added to that target (for that event) and has
//                               not removed
//   respond <n> <status> "<body>" [<name>: "<value>"]…
//                               answer the `n`-th request the page made with a
//                               `Response` of that status, body and headers,
//                               its `url` the request's
//   respond <n> <status> chunks "<a>" "<b>"…
//                               the same, its body a stream that yields each
//                               chunk in a task of its own, the page settling
//                               between two
//   fail <n>                    reject the `n`-th request with `new
//                               TypeError("Failed to fetch")`, the Fetch
//                               standard's network error
//   throws <step>               any step above, which must make the page
//                               throw: each uncaught exception is the line
//                               `(threw: <its first line>)` instead of the
//                               end of the run, and none is a failure
//
// The page's clock is virtual from the start: `Date.now()` is 0 until an
// `advance` step moves it, and a `setTimeout` callback runs only when an
// `advance` step reaches its time.
//
// The page's `fetch` is scripted from the start: each call is logged as it
// is made, `(fetch <n>: <METHOD> <path> <headers> [<body>]
// [credentials:<mode>])` — the headers as JSON, by lower-cased name, a
// multipart boundary written `…`, a `FormData` body as its entries — and
// stays pending until a `respond` or `fail` step answers it. Aborting it
// rejects it with the signal's reason, as the host's `fetch` does, and logs
// `(fetch <n> aborted: <the reason's name>)`. A `data:` URL is the host's
// own `fetch`, not numbered or logged. A request still pending when the
// script ends fails the run, as an uncaught exception does.
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
import { enableCompileCache } from "node:module";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import process from "node:process";
import { Writable } from "node:stream";
import { pathToFileURL } from "node:url";

// happy-dom is one 890 kB file that every run compiles. V8's code cache for
// it (and this file), kept between runs, makes a run about 100 million
// instructions cheaper — the test budget counts Node's. It changes nothing a
// page does: a stale or missing cache is compiled again.
enableCompileCache(join(tmpdir(), "beni-browser-driver"));

// ---------------------------------------------------------------------------
// Page code. Each function is self-contained: Chrome receives its source.
// ---------------------------------------------------------------------------

// Installed before the program runs: console output and uncaught exceptions
// are recorded, in order, for the driver to collect after each phase.
function prelude() {
  const record = { log: [], errors: [] };
  globalThis.__beniHarness = record;
  // Every page starts with empty storage: Chrome keeps an origin's
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
  // The page's `fetch` is scripted: each request is numbered and logged as
  // it is made, and stays pending until a `respond` or `fail` step answers
  // it. The request and the answer are the DOM's own `Request` and
  // `Response`, so header normalisation, `ok`, `text()` and the body's
  // reader are the DOM's. A `data:` URL is the host's, as before.
  const hostFetch = globalThis.fetch;
  const requests = [];
  record.requests = requests;
  globalThis.fetch = (input, init = undefined) => {
    let request;
    try {
      request = new Request(input, init);
    } catch (error) {
      // The host's `fetch` rejects what `new Request` throws.
      return Promise.reject(error);
    }
    if (request.url.startsWith("data:")) return hostFetch.call(globalThis, input, init);
    const entry = { n: requests.length + 1, request, signal: init?.signal ?? null, settled: false, resolve: null, reject: null };
    requests.push(entry);
    const headers = {};
    for (const [name, value] of request.headers) headers[name.toLowerCase()] = value.replace(/boundary=\S+/, "boundary=…");
    const sorted = {};
    for (const name of Object.keys(headers).sort()) sorted[name] = headers[name];
    const body = init?.body;
    const shown = body === undefined || body === null ? "" : ` ${JSON.stringify(body instanceof FormData ? [...body.entries()] : String(body))}`;
    const where = new URL(request.url);
    const path = where.origin === location.origin ? where.pathname + where.search + where.hash : where.href;
    const credentials = request.credentials === "same-origin" ? "" : ` credentials:${request.credentials}`;
    record.log.push(`(fetch ${entry.n}: ${request.method} ${path} ${JSON.stringify(sorted)}${shown}${credentials})`);
    return new Promise((resolve, reject) => {
      entry.resolve = (response) => {
        entry.settled = true;
        resolve(response);
      };
      entry.reject = (error) => {
        entry.settled = true;
        reject(error);
      };
      const signal = entry.signal;
      if (signal === null) return;
      const aborted = () => {
        if (entry.settled) return;
        record.log.push(`(fetch ${entry.n} aborted: ${signal.reason?.name})`);
        entry.reject(signal.reason);
      };
      if (signal.aborted) aborted();
      else signal.addEventListener("abort", aborted, { once: true });
    });
  };
  // The page's entropy is a fixed sequence (an LCG from 1), so a program
  // that seeds `Random` from `crypto.getRandomValues` is deterministic.
  let entropy = 1;
  Object.defineProperty(globalThis.crypto, "getRandomValues", {
    configurable: true,
    value: (array) => {
      for (let i = 0; i < array.length; i++) {
        entropy = (Math.imul(entropy, 1664525) + 1013904223) >>> 0;
        array[i] = entropy;
      }
      return array;
    },
  });
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
  // Every listener the page adds to the window or the document from here
  // on, and has not removed, by target: a registration is its type, its
  // listener and its capture flag, as the DOM's own, so adding one twice
  // is one and removing it ends it; a `once` listener ends when it fires,
  // and one with a `signal` when the signal aborts. Only counted: each
  // call goes on to the DOM's own method unchanged.
  const listening = { window: new Map(), document: new Map() };
  record.listening = listening;
  const capture = (options) => (typeof options === "boolean" ? options : Boolean(options?.capture));
  for (const [name, target] of [["window", globalThis], ["document", document]]) {
    const live = listening[name];
    const add = target.addEventListener.bind(target);
    const remove = target.removeEventListener.bind(target);
    const keyOf = (type, listener, options) => `${type}\u0000${capture(options)}`;
    const ends = (type, listener, options) => {
      const ofKey = live.get(keyOf(type, listener, options));
      if (ofKey !== undefined) ofKey.delete(listener);
    };
    target.addEventListener = (type, listener, options) => {
      add(type, listener, options);
      if (listener === null || listener === undefined || options?.signal?.aborted) return;
      const key = keyOf(type, listener, options);
      if (!live.has(key)) live.set(key, new Set());
      if (live.get(key).has(listener)) return;
      live.get(key).add(listener);
      const end = () => ends(type, listener, options);
      if (typeof options === "object" && options?.once) add(type, end, { once: true, capture: capture(options) });
      if (typeof options === "object" && options?.signal) options.signal.addEventListener("abort", end, { once: true });
    };
    target.removeEventListener = (type, listener, options) => {
      remove(type, listener, options);
      ends(type, listener, options);
    };
  }
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
  if (s.command === "location") {
    globalThis.__beniHarness.log.push(`(location: ${location.pathname}${location.search}${location.hash})`);
    return null;
  }
  if (s.command === "back" || s.command === "forward") {
    // A traversal fires its `popstate` later in Chrome and at once in
    // happy-dom: wait for it either way, a few real turns at most.
    const clock = globalThis.__beniHarness.clock;
    let heard = false;
    const hear = () => {
      heard = true;
    };
    addEventListener("popstate", hear, { once: true });
    if (s.command === "back") history.back();
    else history.forward();
    return new Promise((done) => {
      let turns = 0;
      const wait = () => {
        if (heard) return void done(null);
        if (++turns > 100) {
          removeEventListener("popstate", hear);
          return void done(`\`${s.command}\` fired no \`popstate\`: there is no entry to go to`);
        }
        clock.real(wait, 1);
      };
      wait();
    });
  }
  if (s.command === "respond" || s.command === "fail") {
    const entry = globalThis.__beniHarness.requests[s.n - 1];
    if (entry === undefined) return `the page made no request ${s.n}`;
    if (entry.settled) return `request ${s.n} was already answered or aborted`;
    if (s.command === "fail") {
      entry.reject(new TypeError("Failed to fetch"));
      return null;
    }
    // A status that carries no body is given none, as a server sends none.
    const bodyless = [101, 103, 204, 205, 304].includes(s.status);
    const answer = (body) => {
      const response = new Response(bodyless ? null : body, { status: s.status, headers: s.headers });
      Object.defineProperty(response, "url", { value: entry.request.url });
      entry.resolve(response);
    };
    if (s.chunks === undefined) {
      // As bytes, which add no `Content-Type` of their own: the answer
      // carries the headers the step names and no others, as a server's.
      answer(new TextEncoder().encode(s.body));
      return null;
    }
    // Each chunk in a task of its own, the page settling between two; an
    // abort while the body streams errors it with the signal's reason, as
    // the host's does.
    let controller = null;
    let ended = false;
    const stream = new ReadableStream({
      start(c) {
        controller = c;
      },
      cancel() {
        ended = true;
      },
    });
    entry.signal?.addEventListener(
      "abort",
      () => {
        if (ended) return;
        ended = true;
        globalThis.__beniHarness.log.push(`(fetch ${entry.n} aborted: ${entry.signal.reason?.name})`);
        controller.error(entry.signal.reason);
      },
      { once: true },
    );
    answer(stream);
    const clock = globalThis.__beniHarness.clock;
    const turn = () => new Promise((done) => clock.real(done, 0));
    return (async () => {
      const encoder = new TextEncoder();
      for (const chunk of s.chunks) {
        await turn();
        if (ended) return null;
        controller.enqueue(encoder.encode(chunk));
      }
      await turn();
      if (!ended) {
        ended = true;
        controller.close();
      }
      return null;
    })();
  }
  if (s.command === "hash") {
    const oldURL = location.href;
    history.replaceState(null, "", s.text);
    dispatchEvent(new PopStateEvent("popstate", { state: null }));
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
  if (s.command === "timers") {
    globalThis.__beniHarness.log.push(`(timers: ${globalThis.__beniHarness.clock.timers.length})`);
    return null;
  }
  if (s.command === "listeners") {
    let n = 0;
    for (const [key, set] of globalThis.__beniHarness.listening[s.selector]) {
      if (s.name === undefined || key.split("\u0000")[0] === s.name) n += set.size;
    }
    globalThis.__beniHarness.log.push(`(listeners: ${n})`);
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
      for (let n = 0; n < (s.count ?? 1); n++) {
        // A link nothing prevented would take Chrome off the page (happy-dom
        // follows none): the driver's own listener, added after every
        // listener of the page, stops it and logs that the host would have
        // followed it.
        let followed = null;
        const stop = (event) => {
          if (event.defaultPrevented) return;
          const link = event.composedPath().find((node) => node instanceof HTMLAnchorElement && node.hasAttribute("href"));
          if (link === undefined) return;
          followed = link.getAttribute("href");
          event.preventDefault();
        };
        addEventListener("click", stop);
        const click = new MouseEvent("click", { ...init, button: s.button ?? 0, detail: 1, ...s.modifiers });
        target.dispatchEvent(click);
        removeEventListener("click", stop);
        if (followed !== null) globalThis.__beniHarness.log.push(`(the host follows the link to ${JSON.stringify(followed)})`);
        else if (click.defaultPrevented) globalThis.__beniHarness.log.push("(click's default prevented)");
      }
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

// The numbers of the requests no step answered and nothing aborted.
function pendingRequests() {
  return globalThis.__beniHarness.requests.filter((r) => !r.settled).map((r) => r.n);
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
  process.stderr.write(
    `driver: ${why}\nusage: node driver.mjs (--dom=<happy-dom.mjs> | --chrome=<ws url>) <entry.mjs> [<steps>]\n` +
      `       node driver.mjs (--dom=<happy-dom.mjs> | --chrome=<ws url>) [--steps=<steps>] --page=<entry.mjs>@<report.json>…\n`,
  );
  process.exit(2);
};

// One page per run, its transcript on stdout and its exit code the run's;
// or, with `--page`, several pages one after another in this one process,
// each in a fresh window, each page's exit code, stdout and stderr written
// as JSON to its report (`{"code":…,"stdout":…,"stderr":…}`) — the same
// three a run of that page alone would give — and the run's exit code 0.
// Several pages in one process skip Node's start and the DOM's load for
// every page after the first.
const options = {};
const positional = [];
const pages = [];
for (const arg of process.argv.slice(2)) {
  const m = arg.match(/^--(dom|chrome|steps)=(.+)$/);
  const p = arg.match(/^--page=(.+)@(.+)$/);
  if (m) options[m[1]] = m[2];
  else if (p) pages.push({ entry: p[1], report: p[2] });
  else if (arg.startsWith("--")) usage(`unknown option ${arg}`);
  else positional.push(arg);
}
if (pages.length === 0 && (positional.length < 1 || positional.length > 2)) usage("expected an entry file and at most one steps file");
if (pages.length !== 0 && positional.length !== 0) usage("--page takes the place of the entry and steps files");
if ((options.dom === undefined) === (options.chrome === undefined)) usage("give exactly one of --dom and --chrome");
if (pages.length === 0) pages.push({ entry: positional[0], report: null });
const stepsPath = pages[0].report === null ? positional[1] : options.steps;

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
    if (line === "timers") return void steps.push({ line: written, where, command: "timers", throws });
    if (line === "back" || line === "forward" || line === "location") {
      steps.push({ line: written, where, command: line, selector: null, throws });
      return;
    }
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
    } else if (command === "timers") {
      usage(`${where}: \`timers\` takes nothing`);
    } else if (command === "listeners") {
      if ((selector !== "window" && selector !== "document") || (argument !== undefined && !/^[a-z]+$/.test(argument))) {
        usage(`${where}: \`listeners\` takes \`window\` or \`document\` and at most an event name`);
      }
      s.name = argument;
    } else if (command === "event") {
      const e = (argument ?? "").match(/^([a-z]+)(?:\s+([1-9][0-9]*))?$/);
      if ((selector !== "window" && selector !== "document") || e === null) {
        usage(`${where}: \`event\` takes \`window\` or \`document\`, an event name and at most a count`);
      }
      s.name = e[1];
      s.count = e[2] === undefined ? 1 : Number(e[2]);
    } else if (command === "click" && argument !== undefined && /^[0-9]+$/.test(argument)) {
      if (!/^[1-9][0-9]*$/.test(argument)) usage(`${where}: \`click\` takes a selector and at most a count`);
      s.count = Number(argument);
    } else if (command === "click" && argument !== undefined) {
      s.modifiers = {};
      for (const w of argument.split(/\s+/)) {
        if (["ctrl", "shift", "alt", "meta"].includes(w)) s.modifiers[`${w}Key`] = true;
        else if (/^button:[0-4]$/.test(w)) s.button = Number(w.slice("button:".length));
        else usage(`${where}: \`click\` takes a count, or \`ctrl\`, \`shift\`, \`alt\`, \`meta\` and \`button:<n>\`, not \`${w}\``);
      }
    } else if (command === "respond" || command === "fail") {
      if (!/^[1-9][0-9]*$/.test(selector)) usage(`${where}: \`${command}\` takes the request's number first`);
      s.n = Number(selector);
      if (command === "fail") {
        if (argument !== undefined) usage(`${where}: \`fail\` takes a request's number only`);
      } else {
        const r = (argument ?? "").match(/^([1-5][0-9][0-9])\s+(.*)$/);
        if (r === null) usage(`${where}: \`respond\` takes a request's number, a status from 100 to 599, then a body or \`chunks\``);
        s.status = Number(r[1]);
        // JSON strings, one after another; `rest` is what follows them.
        const strings = (text) => {
          const found = [];
          let rest = text.trim();
          for (;;) {
            const q = rest.match(/^("(?:[^"\\]|\\.)*")\s*/);
            if (q === null) return { found, rest };
            found.push(JSON.parse(q[1]));
            rest = rest.slice(q[0].length);
          }
        };
        if (/^chunks(\s|$)/.test(r[2])) {
          const { found, rest } = strings(r[2].slice("chunks".length));
          if (rest !== "" || found.length === 0) usage(`${where}: \`respond … chunks\` takes one or more JSON strings`);
          s.chunks = found;
          s.headers = [];
        } else {
          const body = r[2].match(/^("(?:[^"\\]|\\.)*")\s*(.*)$/);
          if (body === null) usage(`${where}: \`respond\` takes the body as a JSON string`);
          s.body = JSON.parse(body[1]);
          s.headers = [];
          let rest = body[2];
          while (rest !== "") {
            const h = rest.match(/^([!#$%&'*+.^_`|~0-9A-Za-z-]+):\s*("(?:[^"\\]|\\.)*")\s*/);
            if (h === null) usage(`${where}: a header of \`respond\` is \`<name>: "<value>"\`, not \`${rest}\``);
            s.headers.push([h[1], JSON.parse(h[2])]);
            rest = rest.slice(h[0].length);
          }
        }
      }
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

// The page the program runs in: an empty document whose address is
// `http://127.0.0.1:<port>/_page.html`, so that it is an `http` page as a
// deployed one is (`Url.fromString` reads no `file:` address) and its path
// is the same on every machine. Chrome loads it, and the program's files,
// from a server the driver starts (`/fs/<absolute path>` serves a file);
// happy-dom only names the address and imports the program from disk.
// Only the port differs between the two, so no fixture shows it.
// Each page's, set before it is made (`runPage`).
let entryFile = "";
let pageUrl = "";
let entryUrl = "";
const blank = "<!DOCTYPE html><html><head></head><body></body></html>";

async function serve() {
  const { createServer } = await import("node:http");
  const types = { ".mjs": "text/javascript", ".js": "text/javascript", ".html": "text/html", ".css": "text/css", ".json": "application/json" };
  const server = createServer((request, response) => {
    const path = decodeURIComponent(new URL(request.url, "http://127.0.0.1").pathname);
    if (path === "/_page.html") {
      response.writeHead(200, { "content-type": "text/html" });
      return void response.end(blank);
    }
    if (!path.startsWith("/fs/")) {
      response.writeHead(404);
      return void response.end();
    }
    const file = path.slice("/fs".length);
    let bytes;
    try {
      bytes = readFileSync(file);
    } catch (error) {
      if (error?.code !== "ENOENT" && error?.code !== "EISDIR") throw error;
      response.writeHead(404);
      return void response.end();
    }
    const dot = file.lastIndexOf(".");
    response.writeHead(200, { "content-type": types[dot === -1 ? "" : file.slice(dot)] ?? "application/octet-stream" });
    response.end(bytes);
  });
  await new Promise((listening) => server.listen(0, "127.0.0.1", listening));
  const origin = `http://127.0.0.1:${server.address().port}`;
  pageUrl = `${origin}/_page.html`;
  entryUrl = `${origin}/fs${entryFile.split("\\").join("/")}`;
  return server;
}

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
  // same, and a browser reports it to the page's `error` listeners: so does
  // this, which is also how the prelude records it. Installed once, for
  // whichever page is the current one.
  if (!happyDomPage.handled) {
    happyDomPage.handled = true;
    process.on("uncaughtException", (error) =>
      globalThis.dispatchEvent(new globalThis.ErrorEvent("error", { error, message: error instanceof Error ? error.message : String(error) })),
    );
    process.on("unhandledRejection", (error) => {
      const record = globalThis.__beniHarness;
      record.errors.push(record.describe(error));
    });
  }
  return {
    run: async (fn, arg) => fn(arg),
    // Nothing the page set going may run once the next page is up: its
    // timers, frames and fetches are cancelled, and what the prelude
    // replaced is Node's again.
    close: async () => {
      await window.happyDOM.abort();
      globalThis.setTimeout = nodeTimers.setTimeout;
      globalThis.clearTimeout = nodeTimers.clearTimeout;
    },
  };
}

// Node's timers, which the prelude replaces with the page's virtual clock.
const nodeTimers = { setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout };

async function chromePage(endpoint) {
  const server = await serve();
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
  const helpers = `const step = ${step}; const settle = ${settle}; const drain = ${drain}; const serialise = ${serialise}; const load = ${load}; const pendingRequests = ${pendingRequests};`;
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
      server.close();
    },
  };
}

// One page: load `entry` into a fresh page, run the steps, and resolve to
// what a run of it alone would give — its exit code, its transcript (stdout)
// and why it failed (stderr).
async function runPage(entry) {
  entryFile = resolve(entry);
  pageUrl = "http://127.0.0.1:8000/_page.html";
  entryUrl = pathToFileURL(entryFile).href;
  const page = options.dom !== undefined ? await happyDomPage(options.dom) : await chromePage(options.chrome);
  const script = [...steps];

  const transcript = [];
  let shown = null;
  let result = null;
  const finish = async (code, why) => {
    await page.close();
    result = {
      code,
      stdout: transcript.length === 0 ? "" : `${transcript.join("\n")}\n`,
      stderr: why === undefined ? "" : `${why}\n`,
    };
  };

  // One phase: act, let the page settle, then record what it logged and
  // what it now shows.
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

  // The program runtime, as the entry file names it: `import { run } from
  // …`, or under `--release`, when `start` comes from the same file,
  // `import{run,start}from…`. A `--release` application is one
  // scope-hoisted file that imports no runtime (backend.md §9): the runtime
  // is inside it, and the file itself exports the runtime's `flush`.
  const runtimeImport = readFileSync(entryFile, "utf8").match(/^import ?\{ ?run ?(?:, ?start ?)?\} ?from ?"([^"]+)";$/m);
  const runtime = runtimeImport === null ? `./${basename(entry)}` : runtimeImport[1];

  // The steps before the first that is not `url` or `store` set the page
  // up: they run before the program loads, each a heading with nothing
  // under it.
  const setup = [];
  while (script.length !== 0 && (script[0].command === "url" || script[0].command === "store") && !script[0].throws) setup.push(script.shift());
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
    for (const s of script) {
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
    if (ok) {
      const pending = await page.run(pendingRequests);
      if (pending.length === 0) await finish(0);
      else await finish(1, `the script ended with ${pending.length === 1 ? "request" : "requests"} ${pending.join(", ")} never answered`);
    }
  }
  return result;
}

const written = (stream, text) => new Promise((done) => (text === "" ? done() : stream.write(text, done)));

if (pages[0].report === null) {
  const r = await runPage(pages[0].entry);
  await written(process.stdout, r.stdout);
  await written(process.stderr, r.stderr);
  process.exit(r.code);
} else {
  for (const p of pages) writeFileSync(p.report, JSON.stringify(await runPage(p.entry)));
  process.exit(0);
}
