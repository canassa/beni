// The page fuzzer (docs/design/browser-direct.md §8.3, amended 2026-10-09):
// random sequences of actions replayed on two builds of one program, the
// two pages compared after every step. A difference is a missed or a wrong
// write in one of them — the stale page nothing else on the page would
// show. An oracle that can pass falsely is worse than none, so what is not
// compared is listed (`ignore`), never what is.
//
// It runs in the page driver's process, as one of its pages
// (`driver.mjs --fuzz=<spec.json>@<report.json>`), so the gates pay for
// Node and the DOM once per fixture, and every page here is made, driven
// and printed by the driver's own code: the prelude, `step`, `settle`,
// `drain`, `serialise`. The spec is a JSON object:
//
//   { "a": "<entry.mjs>", "b": "<entry.mjs>",   two builds' entry files
//     "labelA": "…", "labelB": "…",              how the report names them
//     "types": "<file>" | null,                  `beni dump --stage=writes --msg-types`
//     "values": false,                           both builds take messages as values
//     "script": "<.steps file>" | null,          the fixture's script: its answers
//     "ignore": ["^console\\."],                 log lines the two builds may differ on
//     "crash": "same" | "own",                   whether a crash screen is compared
//     "replay": false,                           replay the first seed on `a` too
//     "seeds": [1, 2], "steps": 15,              the sequences
//     "shrink": true }                           shrink a difference
//
// Each seed is one sequence of `steps` actions, drawn by a generator seeded
// with it, so a seed names its sequence on every machine:
//
//   - **a view event** on a random element of the page — `click`,
//     `dblclick`, `input` of a random text, `key`, `focus`, `blur` — or on
//     the window or the document (`event window resize`, …);
//   - **the host**: `advance` of the page's virtual clock, `respond` to or
//     `fail` a request the page made — with a body of the fixture's own
//     script half the time, so a decoder sees what it expects — and
//     `hash` to a random fragment;
//   - **a message as a value**, when `types` holds the programs' message
//     types and `values` says both builds take them: a value of the type
//     as the checker records it — not of the write-set pass's key tree, so
//     a constructor the analysis mis-filed is still sent. The first
//     messages of a sequence sweep every constructor that can be made, in
//     order; then they are drawn at random. Payloads are small, with ints
//     and strings taken from the page as it stands (so a keyed message
//     names a row that exists), and now and then a list long enough to be
//     a trie. A constructor whose payload must hold a function, a
//     `foreign type`, a `Dict`, a `Set` or an unknown type is not sent, and
//     the report says which and why. A value is in the development
//     representation (backend.md §4); a build takes it through its mount's
//     `$$root` (`browser-tea`) or the dispatcher a `--fuzz` build emits,
//     `globalThis.__beniFuzz.send(program, msg)` (`browser-direct`).
//
// Every action but a message is one of the driver's steps, written as a
// `.steps` script writes it, so a sequence of them is a script the driver
// replays — a red-first fixture.
//
// The pages are compared after the load and after every step: the body as
// the driver prints it; the properties it does not print (an option's
// `selected`, `disabled`, `hidden`, `indeterminate`, `open`, `readOnly`,
// a text control's selection); `document.title`; `location.href` less its origin (Chrome serves the
// two builds from two ports); both
// storages; every line the driver logged (requests, prevented defaults,
// links followed, `console.*`), less the lines `ignore` names; and every
// error the step threw. A step that throws on both pages ends the sequence
// once those agree (the body only when `crash` is `same`: a crash screen
// may be a build's own), and the report says how many steps ran. The
// first difference ends the run with code 1; the report names the seed,
// the step, the action and what differs, after shrinking the sequence to
// fewer actions that differ in the same way. Code 0: every seed agreed, a
// line per seed. Code 2: a fault of the fuzzer, or of a page that does not
// replay itself, on stderr. `Math.random`, `new Date()`, `Date.now` and
// `performance.now` are pinned on every page; with `replay` — whenever a
// verdict may be recorded, or a sweep runs — the first seed is also
// played twice on build `a`, and the two must agree.

import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------------------
// Page code of the fuzzer's own: each is self-contained, as the driver's
// are, because Chrome is sent its text (`inPage`).
// ---------------------------------------------------------------------------

// A page function of this file, for `run`: happy-dom's page calls it, and
// Chrome's evaluates its text, which the driver reads as a function's name.
function inPage(fn) {
  return { name: `(${fn})`, own: fn };
}

// Before the program loads. Record every program the page mounts, in the
// order it mounts them: a `browser-tea` mount is the node its runtime sets
// `$$root` on (`Rt.mount`), so an accessor on `Node.prototype` sees each.
// And pin what the driver's prelude leaves to the host: `Math.random` is a
// fixed sequence and `new Date()` reads the virtual clock, so a page
// replays itself. happy-dom's classes are shared by every page of one
// process, so what is installed once reads the current page's record.
function fuzzInstall() {
  globalThis.__beniFuzzMounts = [];
  if (Object.getOwnPropertyDescriptor(Node.prototype, "$$root") === undefined) {
    Object.defineProperty(Node.prototype, "$$root", {
      configurable: true,
      get() {
        return undefined;
      },
      set(value) {
        Object.defineProperty(this, "$$root", { value, writable: true, configurable: true, enumerable: false });
        globalThis.__beniFuzzMounts?.push(this);
      },
    });
  }
  let s = 1;
  Math.random = () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
  if (globalThis.Date.__beniPinned === undefined) {
    const Host = globalThis.Date;
    const Pinned = function (...args) {
      if (!new.target) return new Host(globalThis.__beniHarness.clock.now).toString();
      return args.length === 0 ? new Host(globalThis.__beniHarness.clock.now) : new Host(...args);
    };
    Pinned.prototype = Host.prototype;
    Pinned.now = () => globalThis.__beniHarness.clock.now;
    Pinned.parse = Host.parse;
    Pinned.UTC = Host.UTC;
    Pinned.__beniPinned = true;
    globalThis.Date = Pinned;
  }
  if (globalThis.performance !== undefined) {
    try {
      Object.defineProperty(globalThis.performance, "now", { configurable: true, value: () => globalThis.__beniHarness.clock.now });
    } catch {}
  }
  return null;
}

// How many programs the page mounted, or null when the direct platform's
// dispatcher numbers them itself.
function fuzzMounts() {
  return globalThis.__beniFuzz !== undefined ? null : globalThis.__beniFuzzMounts.length;
}

// Send message `value` to program `program` (mount order): the direct
// platform's fuzz dispatcher, or — on `browser-tea` — the mount's
// `$$root` called through the runtime's guard (`Rt.fuzzInstall`), so a
// throw in `update` stops the page as one from a click does. Null, or why
// not.
// The send runs as an event listener of a node of its own, dispatched
// synchronously: a throw it lets out is reported to the page's `error`
// listeners by the DOM, exactly as one out of a click's listener is, and
// the step that sent it throws as a click step that throws does.
function fuzzSend({ program, value }) {
  let send;
  const direct = globalThis.__beniFuzz;
  if (direct !== undefined) {
    send = () => direct.send(program, value);
  } else {
    const mount = globalThis.__beniFuzzMounts[program];
    if (mount === undefined) return `the page mounted no program ${program}`;
    if (globalThis.__beniFuzzSend === undefined) return "the page has no guarded send: build it with --fuzz";
    send = () => globalThis.__beniFuzzSend(mount, value);
  }
  const carrier = document.createElement("span");
  carrier.addEventListener("beni-fuzz-send", send);
  carrier.dispatchEvent(new Event("beni-fuzz-send"));
  return null;
}

// What the page offers the next action: the elements an event may go to,
// in document order, each with a selector the driver accepts (no spaces: a
// `>` chain of `:nth-child`s from the body); the requests still pending;
// and the ints and strings the page shows, for messages to name. A
// `<template>`'s content is not in the document and is left out.
function fuzzOffer() {
  const targets = [];
  const strings = new Set();
  const ints = new Set();
  const take = (text) => {
    const t = text.trim();
    if (t === "" || t.length > 40 || strings.size >= 40) return;
    strings.add(t);
    for (const m of t.matchAll(/-?\d+/g)) if (ints.size < 40) ints.add(Number(m[0]));
  };
  const walk = (node, path) => {
    let k = 0;
    for (const child of node.childNodes) {
      if (child.nodeType === 3) take(child.data);
      if (child.nodeType !== 1) continue;
      k += 1;
      const html = child.namespaceURI === "http://www.w3.org/1999/xhtml" && /^[a-z][a-z0-9-]*$/.test(child.localName);
      const selector = `${path}>${html ? child.localName : "*"}:nth-child(${k})`;
      const tag = child.localName;
      for (const a of child.attributes) if (a.name === "id" || a.name === "value" || a.name === "href" || a.name.startsWith("data-")) take(a.value);
      targets.push({
        selector,
        text: tag === "textarea" || (tag === "input" && !["checkbox", "radio", "button", "submit", "reset", "file"].includes(child.type)),
        control: ["input", "textarea", "select", "button", "a"].includes(tag) || child.tabIndex >= 0,
      });
      if (tag !== "template") walk(child, selector);
    }
  };
  if (document.body !== null) walk(document.body, "body");
  const pending = globalThis.__beniHarness.requests.filter((r) => !r.settled && !r.aborted).map((r) => r.n);
  return { targets, pending, strings: [...strings], ints: [...ints] };
}

// What the page shows besides the body's markup: the title, the address,
// both storages, and the state of every element the driver's `serialise`
// does not print — each line the element's selector and its properties
// that are not their defaults.
function fuzzState() {
  const area = (s) => {
    const out = {};
    const keys = [];
    for (let i = 0; i < s.length; i++) keys.push(s.key(i));
    for (const k of keys.sort()) out[k] = s.getItem(k);
    return JSON.stringify(out);
  };
  const props = [];
  const walk = (node, path) => {
    let k = 0;
    for (const child of node.children) {
      k += 1;
      const selector = `${path}>${child.localName}:nth-child(${k})`;
      const set = [];
      if (child.localName === "option") set.push(`selected=${child.selected}`);
      for (const p of ["disabled", "hidden", "indeterminate", "open", "readOnly"]) if (child[p] === true) set.push(`${p}=true`);
      if ((child.localName === "input" || child.localName === "textarea") && typeof child.selectionStart === "number") {
        let start = null;
        try {
          start = child.selectionStart;
        } catch {}
        if (start !== null) set.push(`selection=${child.selectionStart}-${child.selectionEnd}`);
      }
      if (set.length !== 0) props.push(`${selector} ${set.join(" ")}`);
      if (child.localName !== "template") walk(child, selector);
    }
  };
  if (document.body !== null) walk(document.body, "body");
  // A storage a page made unreadable is compared by what reading it threw.
  const read = (name) => {
    try {
      return area(globalThis[name]);
    } catch (error) {
      return `unreadable (${error?.name})`;
    }
  };
  return { title: document.title, href: location.href.startsWith(location.origin) ? location.href.slice(location.origin.length) : location.href, storage: `local ${read("localStorage")} session ${read("sessionStorage")}`, props: props.join("\n") };
}

// ---------------------------------------------------------------------------
// The generator: one seed, one stream of numbers.
// ---------------------------------------------------------------------------

// mulberry32: small, fast and the same on every machine.
function random(seed) {
  let s = seed >>> 0;
  const next = () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const int = (n) => Math.floor(next() * n);
  const pick = (list) => list[int(list.length)];
  return { next, int, pick };
}

const texts = ["", "a", "ab", "hello", " ", "x y", "0", "1", "42", "-3", "Ω", "<b>", "&amp;", "😀", "   padded   "];
const ints = [0, 1, -1, 2, 3, 5, 10, 100, -100, 1000];
const floats = [0, 0.5, -1.25, 3.14, 1000, -0.0001, -0];

// What the generator answers for a type it cannot make a value of.
const none = Symbol("none");

// Why no value of type `t` (its parameters `env`, `{t, env}` each) can be
// made, or null when one can: a descriptor code the generator does not
// make, wherever every choice of constructor must hold it.
function unmakeable(t, defs, env, seen = new Set()) {
  if (typeof t === "number") return env[t] === undefined ? "an unknown type" : unmakeable(env[t].t, defs, env[t].env, seen);
  if (typeof t === "string") {
    if (["i", "f", "s", "c", "b", "u"].includes(t)) return null;
    return { F: "a function", x: "a foreign type", "?": "an unknown type" }[t] ?? `a type written \`${t}\``;
  }
  if (!Array.isArray(t)) {
    for (const k of Object.keys(t)) {
      const why = unmakeable(t[k], defs, env, seen);
      if (why !== null) return why;
    }
    return null;
  }
  if (t[0] === "t") {
    for (const e of t.slice(1)) {
      const why = unmakeable(e, defs, env, seen);
      if (why !== null) return why;
    }
    return null;
  }
  // An empty list is a list of anything.
  if (t[0] === "l") return null;
  if (t[0] === "D") return "a Dict";
  if (t[0] === "S") return "a Set";
  if (t[0] === "n") {
    const key = JSON.stringify([t, env.map((e) => e.t)]);
    // A type met again on the way down: one of its other constructors ends it.
    if (seen.has(key)) return null;
    seen.add(key);
    const args = t.slice(2).map((a) => ({ t: a, env }));
    let why = null;
    for (const fields of Object.values(defs[t[1]])) {
      why = fields.map((f) => unmakeable(f, defs, args, seen)).find((w) => w !== null) ?? null;
      if (why === null) break;
    }
    seen.delete(key);
    return why;
  }
  return `a type written \`${t[0]}\``;
}

// Values of the types of `defs`, a message type's definitions (backend.md
// §4, *`Debug.toString` reads the argument's type*: `defs[k]` is a type's
// constructors, a number inside one its parameter), drawn from `rng`, in
// the development representation; ints and strings come from `pool` (what
// the page shows) a third of the time.
function generator(defs, rng, pool) {
  const arity = defs.map((d) => Math.max(0, ...Object.values(d).map((args) => args.length)));
  const value = (t, env, depth) => {
    if (typeof t === "number") return env[t] === undefined ? none : value(env[t].t, env[t].env, depth);
    if (typeof t === "string") {
      switch (t) {
        case "i":
          if (pool.ints.length !== 0 && rng.next() < 0.35) return rng.pick(pool.ints);
          return rng.next() < 0.7 ? rng.pick(ints) : rng.int(2001) - 1000;
        case "f":
          return rng.pick(floats);
        case "s":
          if (pool.strings.length !== 0 && rng.next() < 0.35) return rng.pick(pool.strings);
          return rng.next() < 0.8 ? rng.pick(texts) : rng.int(1e6).toString(36);
        case "c":
          return rng.pick(["a", "Z", "0", " ", "Ω"]);
        case "b":
          return rng.next() < 0.5;
        case "u":
          return null;
        default:
          return none;
      }
    }
    if (!Array.isArray(t)) {
      const out = {};
      for (const name of Object.keys(t).sort()) {
        const v = value(t[name], env, depth + 1);
        if (v === none) return none;
        out[name] = v;
      }
      return out;
    }
    switch (t[0]) {
      case "t": {
        const out = {};
        for (let i = 1; i < t.length; i++) {
          const v = value(t[i], env, depth + 1);
          if (v === none) return none;
          out[String.fromCharCode(96 + i)] = v;
        }
        return out;
      }
      case "l": {
        // Now and then past 32 elements: a list that is a trie
        // (backend.md §4, *Lists are arrays*).
        const n = depth > 3 ? 0 : depth <= 1 && rng.next() < 0.08 ? 33 + rng.int(16) : rng.int(4);
        const out = [];
        for (let i = 0; i < n; i++) {
          const v = value(t[1], env, depth + 1);
          if (v === none) return none;
          out.push(v);
        }
        return out;
      }
      case "n": {
        const k = t[1];
        const args = t.slice(2).map((a) => ({ t: a, env }));
        const ctors = Object.entries(defs[k]);
        const order = ctors.map((_, i) => i);
        for (let i = order.length - 1; i > 0; i--) {
          const j = rng.int(i + 1);
          [order[i], order[j]] = [order[j], order[i]];
        }
        // Deep down, the constructors with the fewest fields first, so a
        // recursive type ends.
        if (depth > 3) order.sort((x, y) => ctors[x][1].length - ctors[y][1].length);
        for (const i of order) {
          const v = constructed(k, ctors[i][0], ctors[i][1], args, depth);
          if (v !== none) return v;
        }
        return none;
      }
      default:
        return none;
    }
  };
  // Constructor `tag` of `defs[k]`: the bare tag for a type whose
  // constructors are all nullary, else `{$, a, b, …}` padded with `null`
  // to the type's widest constructor.
  const constructed = (k, tag, fields, args, depth) => {
    if (arity[k] === 0) return tag;
    const out = { $: tag };
    for (let i = 0; i < arity[k]; i++) {
      const name = String.fromCharCode(97 + i);
      if (i >= fields.length) {
        out[name] = null;
        continue;
      }
      const v = value(fields[i], args, depth + 1);
      if (v === none) return none;
      out[name] = v;
    }
    return out;
  };
  return { value, constructed };
}

// The constructors of a message type `[root, defs]` a value can be made
// of, and those it cannot, with why. A root that is not a `type` is one
// "constructor", named by its type.
function constructors(type) {
  const [root, defs] = type;
  if (!Array.isArray(root) || root[0] !== "n") {
    const why = unmakeable(root, defs, []);
    return why === null ? { sendable: [null], not: [] } : { sendable: [], not: [`the message itself (${why})`] };
  }
  const args = root.slice(2).map((a) => ({ t: a, env: [] }));
  const sendable = [];
  const not = [];
  for (const [tag, fields] of Object.entries(defs[root[1]])) {
    const why = fields.map((f) => unmakeable(f, defs, args)).find((w) => w !== null) ?? null;
    if (why === null) sendable.push(tag);
    else not.push(`${tag} (${why})`);
  }
  return { sendable, not };
}

// A message of `type` whose constructor is `tag` (null: the root is no
// `type`), drawn from `rng` and `pool`; `none` when none was made.
function message(type, tag, rng, pool) {
  const [root, defs] = type;
  const g = generator(defs, rng, pool);
  if (tag === null) return g.value(root, [], 0);
  const args = root.slice(2).map((a) => ({ t: a, env: [] }));
  return g.constructed(root[1], tag, defs[root[1]][tag], args, 0);
}

// Value `v` of type `t` as beni writes it, for the report.
function show(t, defs, env, v) {
  if (typeof t === "number") return env[t] === undefined ? JSON.stringify(v) : show(env[t].t, defs, env[t].env, v);
  if (typeof t === "string") {
    if (t === "s" || t === "c") return JSON.stringify(v);
    if (t === "b") return v ? "True" : "False";
    if (t === "u") return "⊤";
    return Object.is(v, -0) ? "-0" : String(v);
  }
  if (!Array.isArray(t)) {
    const fields = Object.keys(t).sort().map((k) => `${k} = ${show(t[k], defs, env, v[k])}`);
    return fields.length === 0 ? "{}" : `{ ${fields.join(", ")} }`;
  }
  if (t[0] === "t") return `( ${t.slice(1).map((e, i) => show(e, defs, env, v[String.fromCharCode(97 + i)])).join(", ")} )`;
  if (t[0] === "l") return v.length === 0 ? "[]" : `[ ${v.map((e) => show(t[1], defs, env, e)).join(", ")} ]`;
  if (t[0] === "n") {
    const args = t.slice(2).map((a) => ({ t: a, env }));
    const tag = typeof v === "string" ? v : v.$;
    const parts = (defs[t[1]][tag] ?? []).map((f, i) => {
      const s = show(f, defs, args, v[String.fromCharCode(97 + i)]);
      return /^[\w"\-.]+$/.test(s) || /^[[{(]/.test(s) ? s : `(${s})`;
    });
    return [tag, ...parts].join(" ");
  }
  return JSON.stringify(v);
}

// The answers a fixture's `.steps` script gives (`respond <n> <status>
// "<body>" [<name>: "<value>"]…`), for the fuzzer's own answers.
function scriptAnswers(text) {
  const out = [];
  for (const raw of text.split("\n")) {
    const m = raw.trim().match(/^respond\s+\d+\s+([1-5]\d\d)\s+("(?:[^"\\]|\\.)*")\s*(.*)$/);
    if (m === null) continue;
    const headers = [];
    for (const h of m[3].matchAll(/([!#$%&'*+.^_`|~0-9A-Za-z-]+):\s*("(?:[^"\\]|\\.)*")/g)) headers.push([h[1], JSON.parse(h[2])]);
    out.push({ status: Number(m[1]), body: JSON.parse(m[2]), headers, written: raw.trim().replace(/^respond\s+\d+\s+/, "") });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Actions.
// ---------------------------------------------------------------------------

const keys = ["Enter", "Escape", "a", "ArrowUp", "ArrowDown", "Tab", "Backspace"];
const windowEvents = [["window", "resize"], ["window", "focus"], ["window", "blur"], ["document", "visibilitychange"]];
const fragments = ["#/", "#/active", "#/completed", "#/x", "#"];
const bodies = ['""', '"ok"', '"[]"', '"{}"', '"{\\"a\\":1}"', '"[1,2]"'];

// A sequence's generator of actions: `rng`, the programs' message types
// (`types`, null for a program sent none), and the fixture's answers.
// While the sweep lasts — every sendable constructor of every program, in
// order — half the actions are messages; then three in ten.
function actions(rng, types, answers) {
  const sweep = [];
  types.forEach((type, program) => {
    if (type !== null) for (const tag of constructors(type).sendable) sweep.push({ program, tag });
  });
  let swept = 0;
  const next = (offer) => {
    // Each kind of action takes a share of the roll in turn, a kind that
    // cannot happen taking none, and view events take what is left.
    let roll = rng.next();
    const takes = (share) => {
      if (roll < share) return true;
      roll -= share;
      return false;
    };
    if (sweep.length !== 0 && takes(swept < sweep.length ? 0.5 : 0.3)) {
      const { program, tag } = swept < sweep.length ? sweep[swept++] : rng.pick(sweep);
      const v = message(types[program], tag, rng, offer);
      if (v !== none) {
        const prefix = types.length > 1 ? `program ${program}: ` : "";
        return { line: `message ${prefix}${show(types[program][0], types[program][1], [], v)}`, message: { program, value: v } };
      }
    }
    if (offer.pending.length !== 0 && takes(0.15)) {
      const n = rng.pick(offer.pending);
      if (rng.next() < 0.15) return { line: `fail ${n}`, s: { command: "fail", n } };
      if (answers.length !== 0 && rng.next() < 0.5) {
        const a = rng.pick(answers);
        return { line: `respond ${n} ${a.written}`, s: { command: "respond", n, status: a.status, body: a.body, headers: a.headers } };
      }
      const status = rng.pick([200, 200, 200, 404, 500]);
      const body = rng.pick(bodies);
      return { line: `respond ${n} ${status} ${body}`, s: { command: "respond", n, status, body: JSON.parse(body), headers: [] } };
    }
    if (takes(0.08)) {
      const ms = rng.pick([1, 16, 100, 250, 500, 1000, 3000]);
      return { line: `advance ${ms}`, s: { command: "advance", ms, tasks: false } };
    }
    if (takes(0.03)) {
      const [selector, name] = rng.pick(windowEvents);
      return { line: `event ${selector} ${name}`, s: { command: "event", selector, name, count: 1 } };
    }
    if (takes(0.02)) {
      const text = rng.pick(fragments);
      return { line: `hash ${JSON.stringify(text)}`, s: { command: "hash", text } };
    }
    const targets = offer.targets;
    if (targets.length === 0) return { line: "advance 16", s: { command: "advance", ms: 16, tasks: false } };
    const kind = rng.next();
    const typed = targets.filter((t) => t.text);
    if (typed.length !== 0 && kind < 0.25) {
      const t = rng.pick(typed);
      const text = rng.next() < 0.3 && offer.strings.length !== 0 ? rng.pick(offer.strings) : rng.pick(texts);
      return { line: `input ${t.selector} ${JSON.stringify(text)}`, s: { command: "input", selector: t.selector, text } };
    }
    if (kind < 0.4) {
      const t = rng.pick(targets);
      const key = rng.pick(keys);
      return { line: `key ${t.selector} ${key}`, s: { command: "key", selector: t.selector, key, code: "", modifiers: {} } };
    }
    const controls = targets.filter((t) => t.control);
    if (controls.length !== 0 && kind < 0.5) {
      const t = rng.pick(controls);
      const command = rng.next() < 0.5 ? "focus" : "blur";
      return { line: `${command} ${t.selector}`, s: { command, selector: t.selector } };
    }
    // Clicks go to controls more often than to the rest.
    const t = controls.length !== 0 && kind < 0.85 ? rng.pick(controls) : rng.pick(targets);
    if (kind > 0.95) return { line: `dblclick ${t.selector}`, s: { command: "dblclick", selector: t.selector } };
    return { line: `click ${t.selector}`, s: { command: "click", selector: t.selector } };
  };
  return next;
}

// ---------------------------------------------------------------------------
// Comparing.
// ---------------------------------------------------------------------------

// The parts of a view, in the order a difference is reported.
const parts = [
  ["threw", "the errors thrown differ"],
  ["fault", "whether the step could run differs"],
  ["log", "what the page logged differs"],
  ["title", "document.title differs"],
  ["href", "location.href differs"],
  ["storage", "the storages differ"],
  ["dom", "the body differs"],
  ["props", "the properties of the body's elements differ"],
];

// Which part of two views of a step differs, or null. When both threw,
// the body is compared only when the crash screens are the same (`crash`).
function differs(x, y, crash) {
  if (x === undefined || y === undefined) return x === y ? null : "steps";
  for (const [part] of parts) {
    if (part === "dom" && x.threw !== "" && crash !== "same") continue;
    if (x[part] !== y[part]) return part;
  }
  return null;
}

// The first step at which two runs differ, and how, or null.
function firstDifference(a, b, crash) {
  const n = Math.max(a.shown.length, b.shown.length);
  for (let i = 0; i < n; i++) {
    const kind = differs(a.shown[i], b.shown[i], crash);
    if (kind !== null) return { at: i, kind };
  }
  return null;
}

// The smallest element of two DOM texts (the driver's `serialise`) that
// holds every line where they differ, from each.
function smallestDifference(x, y) {
  const xs = x.split("\n");
  const ys = y.split("\n");
  let first = 0;
  while (first < xs.length && first < ys.length && xs[first] === ys[first]) first++;
  let lastX = xs.length - 1;
  let lastY = ys.length - 1;
  while (lastX > first && lastY > first && xs[lastX] === ys[lastY]) {
    lastX--;
    lastY--;
  }
  const indent = (l) => l.length - l.trimStart().length;
  const opens = (l) => l !== undefined && /^\s*<[^/!?]/.test(l);
  // The last line of the element whose opening line is `o`.
  const end = (lines, o) => {
    let e = o;
    while (e + 1 < lines.length && indent(lines[e + 1]) > indent(lines[o])) e++;
    if (e + 1 < lines.length && indent(lines[e + 1]) === indent(lines[o]) && lines[e + 1].trimStart().startsWith("</")) e++;
    return e;
  };
  // The element opened on the first differing line, when it holds every
  // difference in both texts; else the nearest element opened above it
  // (where the texts still agree) that holds them.
  let open = -1;
  if (opens(xs[first]) && opens(ys[first]) && indent(xs[first]) === indent(ys[first]) && end(xs, first) >= lastX && end(ys, first) >= lastY) {
    open = first;
  } else {
    // Up from the deeper of the two first differing lines, to the first
    // element that holds every difference of both.
    let depth = Math.max(indent(xs[first] ?? ""), indent(ys[first] ?? ""));
    open = first - 1;
    for (; open >= 0; open--) {
      if (!(indent(xs[open]) < depth && opens(xs[open]))) continue;
      if (end(xs, open) >= lastX && end(ys, open) >= lastY) break;
      depth = indent(xs[open]);
    }
  }
  const cut = (lines) => {
    if (open < 0) return lines.join("\n");
    const out = lines.slice(open, end(lines, open) + 1);
    return (out.length > 60 ? [...out.slice(0, 60), `${" ".repeat(indent(lines[open]))}… (${out.length - 60} more lines)`] : out).join("\n");
  };
  return { a: cut(xs), b: cut(ys) };
}

// ---------------------------------------------------------------------------
// The run.
// ---------------------------------------------------------------------------

// Every page imports a module graph of its own, from a copy of its build:
// Node answers a second import of a file from the first, and a runtime's
// module state would carry over. A copy's path is the build's content and
// the page's number in this process — `zig-out/browser-fuzz-pages/<hash of
// the build>/<n>` — so the same page of the same build is the same path
// in every run, and the driver's compile cache, keyed by path, holds one
// entry per module of it instead of one per run. A copy is made once,
// atomically (two fixtures may share a build), and a build's copies go an
// hour after they were last used, as the cache's entries do.
const pagesRoot = fileURLToPath(new URL("../../zig-out/browser-fuzz-pages", import.meta.url));
const pageAge = 60 * 60 * 1000;
const pagesUsed = new Map();
const buildKeys = new Map();
let pagesPruned = false;

// The wall clock, read from the file system: in this process `Date` is the
// pages' virtual clock (the driver's prelude, `fuzzInstall`).
function touch(file) {
  writeFileSync(file, "");
  return statSync(file).mtimeMs;
}

function pagePath(entry) {
  const build = dirname(resolve(entry));
  if (!pagesPruned) {
    pagesPruned = true;
    mkdirSync(pagesRoot, { recursive: true });
    const now = touch(join(pagesRoot, ".now"));
    for (const name of readdirSync(pagesRoot)) {
      if (name === ".now") continue;
      try {
        if (now - statSync(join(pagesRoot, name, ".used")).mtimeMs > pageAge) rmSync(join(pagesRoot, name), { recursive: true, force: true });
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
        // A copy being made, or one a process left half made: its own
        // process finishes it, and an hour later the next prune finds it.
      }
    }
  }
  let key = buildKeys.get(build);
  if (key === undefined) {
    const hash = createHash("sha256");
    const walk = (dir) => {
      for (const name of readdirSync(dir).sort()) {
        const p = join(dir, name);
        if (statSync(p).isDirectory()) walk(p);
        else hash.update(`${p.slice(build.length)}\0`).update(readFileSync(p)).update("\0");
      }
    };
    walk(build);
    key = hash.digest("hex").slice(0, 32);
    buildKeys.set(build, key);
  }
  const n = pagesUsed.get(key) ?? 0;
  pagesUsed.set(key, n + 1);
  const home = join(pagesRoot, key);
  const dir = join(home, String(n));
  if (!existsSync(dir)) {
    const temp = `${dir}.${process.pid}.tmp`;
    cpSync(build, temp, { recursive: true });
    try {
      renameSync(temp, dir);
    } catch (error) {
      // Another process made the same copy first.
      rmSync(temp, { recursive: true, force: true });
      if (!existsSync(dir)) throw error;
    }
  }
  touch(join(home, ".used"));
  return join(dir, basename(entry));
}

// Fuzz `spec` with the driver's `host`: `open(entry)`, a fresh page of the
// program (`{run, click, close, url}`), and its page functions. Resolves to
// what a page report holds: `{code, stdout, stderr}`.
export async function fuzz(spec, host) {
  const types = spec.types === null || spec.types === undefined
    ? []
    : readFileSync(spec.types, "utf8").split("\n").filter((l) => l.trim() !== "").map((l) => JSON.parse(l).msg);
  const sent = spec.values ? types : types.map(() => null);
  const ignore = (spec.ignore ?? []).map((source) => new RegExp(source));
  const crash = spec.crash ?? "own";
  const answers = spec.script ? scriptAnswers(readFileSync(spec.script, "utf8")) : [];

  // Run `actions` on a fresh page of `entry`; or, with `draw`, draw
  // `steps` actions as the page goes and run those. What each step showed.
  const play = async (entry, given, draw = null, steps = given.length) => {
    const p = await host.open(pagePath(entry));
    const shown = [];
    const taken = [];
    const look = async (fault) => {
      await p.run(host.settle);
      const { log, errors } = await p.run(host.drain);
      // A step that threw ends the sequence, so what the stopping page
      // still does — releases a task later — is its tail, taken here
      // while it lasts, up to a few turns: where it falls between two
      // turns is no difference between the builds.
      for (let turn = 0; errors.length !== 0 && turn < 5; turn++) {
        await p.run(host.settle);
        const more = await p.run(host.drain);
        if (more.log.length === 0 && more.errors.length === 0) break;
        log.push(...more.log);
        errors.push(...more.errors);
      }
      const dom = await p.run(host.serialise);
      const state = await p.run(inPage(fuzzState));
      return {
        ...state,
        dom,
        log: log.filter((l) => !ignore.some((r) => r.test(l))).join("\n"),
        threw: errors.map((e) => e.split("\n")[0]).join("\n"),
        fault: fault ?? "",
      };
    };
    try {
      await p.run(inPage(fuzzInstall));
      await p.run(host.load, { url: p.url, runtime: null });
      shown.push(await look(null));
      if (draw !== null && sent.some((t) => t !== null)) {
        // A message goes to a program by its place among the mounts.
        const mounts = await p.run(inPage(fuzzMounts));
        if (mounts !== null && mounts !== sent.length) {
          throw new Error(`${entry} mounted ${mounts} program${mounts === 1 ? "" : "s"}, and the message types list ${sent.length}`);
        }
      }
      for (let i = 0; i < steps && shown[shown.length - 1].threw === ""; i++) {
        const action = draw === null ? given[i] : draw(await p.run(inPage(fuzzOffer)));
        taken.push(action);
        let fault = null;
        if (action.message !== undefined) {
          fault = await p.run(inPage(fuzzSend), action.message);
        } else {
          const why = await p.run(host.step, action.s);
          if (why !== null && typeof why === "object") await p.click(why.x, why.y);
          else fault = why;
        }
        shown.push(await look(fault));
      }
    } finally {
      await p.close();
    }
    return { shown, taken };
  };

  // Whether `actions` still differ in the way `kind` names; null when they
  // agree, differ otherwise, or no longer run on the first page (then they
  // are no smaller instance of the difference).
  const differOn = async (actions, kind) => {
    const a = await play(spec.a, actions);
    if (a.shown.some((v) => v.fault !== "")) return null;
    const b = await play(spec.b, actions);
    const d = firstDifference(a, b, crash);
    return d === null || d.kind !== kind ? null : { a, b, ...d };
  };

  // Fewer actions that still differ in the same way: drop chunks, halving
  // them, for at most `budget` tries (a delta debugging; each try is two
  // pages). Whether the budget ran out.
  const budget = 40;
  const shrink = async (actions, kind) => {
    let best = actions;
    let found = null;
    let tries = 0;
    let done = true;
    for (let chunk = Math.max(1, best.length >> 1); chunk >= 1; chunk >>= 1) {
      for (let start = 0; start < best.length; ) {
        if (tries === budget) {
          done = false;
          break;
        }
        const candidate = [...best.slice(0, start), ...best.slice(start + chunk)];
        tries++;
        const again = candidate.length === 0 ? null : await differOn(candidate, kind);
        if (again !== null) {
          best = candidate;
          found = again;
        } else start += chunk;
      }
      if (!done) break;
    }
    return { best, found, done };
  };

  const plural = (k, what) => `${k} ${what}${k === 1 ? "" : "s"}`;
  const lines = [];
  if (typeof spec.note === "string") lines.push(spec.note);
  types.forEach((type, program) => {
    const name = types.length > 1 ? `program ${program}` : "the program";
    if (type === null) {
      lines.push(`${name}: no message type (the dump has none for it)`);
      return;
    }
    if (!spec.values) return;
    const { sendable, not } = constructors(type);
    lines.push(`${name}: ${plural(sendable.length, "constructor")} sent${not.length === 0 ? "" : `; not sent: ${not.join(", ")}`}`);
  });
  try {
    for (const [index, seed] of spec.seeds.entries()) {
      const a = await play(spec.a, [], actions(random(seed), sent, answers), spec.steps);
      // The first seed again on build `a`, when the run may be recorded
      // (`replay`): a page that does not replay itself would make every
      // verdict below a coin, and a recorded verdict is not run again.
      if (index === 0 && spec.replay) {
        const again = await play(spec.a, a.taken);
        const d = firstDifference(a, again, "same");
        if (d !== null) {
          return {
            code: 2,
            stdout: `${lines.join("\n")}\n`,
            stderr: `fuzz: ${spec.labelA} does not replay itself: seed ${seed}, step ${d.at}, ${parts.find(([p]) => p === d.kind)?.[1] ?? `${d.kind} differ`}\n`,
          };
        }
      }
      const b = await play(spec.b, a.taken);
      const d = firstDifference(a, b, crash);
      if (d === null) {
        const counts = (pred) => a.taken.filter(pred).length;
        const messages = counts((x) => x.message !== undefined);
        const hosted = counts((x) => x.s !== undefined && ["advance", "respond", "fail", "hash", "event"].includes(x.s.command));
        const what = `${plural(a.taken.length - messages - hosted, "view event")}, ${plural(messages, "message")}, ${plural(hosted, "host step")}`;
        const last = a.shown[a.shown.length - 1];
        if (last.threw === "") {
          lines.push(`seed ${seed}: ${plural(a.taken.length, "step")} agree (${what})`);
        } else {
          const where = a.taken.length === 0 ? "at the load" : `at step ${a.taken.length}, ${a.taken[a.taken.length - 1].line}`;
          lines.push(`seed ${seed}: both threw ${where}, so ${a.taken.length} of ${spec.steps} steps ran (${what}): ${last.threw.split("\n")[0]}`);
        }
        continue;
      }
      // Every action up to the one after which the pages differ.
      let sequence = a.taken.slice(0, d.at);
      let found = { a, b, ...d };
      let shrunk = null;
      if (spec.shrink && sequence.length > 1) {
        shrunk = await shrink(sequence, d.kind);
        if (shrunk.found !== null) {
          sequence = shrunk.best;
          found = shrunk.found;
        }
      }
      const out = [`${spec.labelA} and ${spec.labelB} differ: seed ${seed}, step ${d.at} of ${spec.steps}${d.at === 0 ? " (the load)" : `, ${a.taken[d.at - 1].line}`}`];
      if (shrunk !== null) {
        const note = shrunk.done ? "" : ` (shrinking stopped at its budget of ${budget} tries)`;
        out.push(sequence.length === d.at ? `the sequence (no shorter one differs in the same way${note}):` : `shrunk from ${d.at} steps to ${sequence.length}${note}:`);
      }
      for (const action of sequence) out.push(`  ${action.line}`);
      if (sequence.length === 0) out.push("  (none: the pages differ once loaded)");
      else if (sequence.some((x) => x.message !== undefined)) out.push("(a `message` line is a value sent to the program; the others are `.steps` lines)");
      const x = found.a.shown[found.at];
      const y = found.b.shown[found.at];
      out.push(`${found.at === 0 ? "once loaded" : `after ${sequence[found.at - 1].line}`}, ${parts.find(([p]) => p === found.kind)?.[1] ?? "the steps differ"}:`);
      if (found.kind === "dom") {
        const s = smallestDifference(x.dom, y.dom);
        out.push(`--- ${spec.labelA} ---`, s.a, `--- ${spec.labelB} ---`, s.b);
      } else if (found.kind === "steps") {
        out.push(`--- ${spec.labelA} ---`, x === undefined ? "(ended)" : "(went on)", `--- ${spec.labelB} ---`, y === undefined ? "(ended)" : "(went on)");
      } else {
        out.push(`--- ${spec.labelA} ---`, x[found.kind] || "(nothing)", `--- ${spec.labelB} ---`, y[found.kind] || "(nothing)");
      }
      lines.push(...out);
      return { code: 1, stdout: `${lines.join("\n")}\n`, stderr: "" };
    }
    return { code: 0, stdout: `${lines.join("\n")}\n`, stderr: "" };
  } catch (error) {
    return { code: 2, stdout: lines.length === 0 ? "" : `${lines.join("\n")}\n`, stderr: `fuzz: ${error?.stack ?? error}\n` };
  }
}
