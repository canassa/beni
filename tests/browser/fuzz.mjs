// The page fuzzer (docs/design/browser-direct.md §8.3, amended 2026-10-09):
// random sequences of actions replayed on two builds of one program, the
// two pages compared after every step. A difference is a missed or a wrong
// write in one of them — the stale page nothing else on the page would
// show.
//
// It runs in the page driver's process, as one of its pages
// (`driver.mjs --fuzz=<spec.json>@<report.json>`), so the gates pay for
// Node and the DOM once per fixture, and every page here is made, driven
// and printed by the driver's own code: the prelude, `step`, `settle`,
// `drain`, `serialise`. The spec is a JSON object:
//
//   { "a": "<entry.mjs>", "b": "<entry.mjs>",      two builds' entry files
//     "labelA": "browser-tea", "labelB": "…",       how the report names them
//     "types": "<msg-types file>" | null,           `beni dump --stage=writes --msg-types`
//     "values": false,                              both builds take messages as values
//     "seeds": [1, 2, 3], "steps": 20,              the sequences
//     "shrink": true }                              shrink a difference
//
// Each seed is one sequence of `steps` actions, drawn by a generator seeded
// with it, so a seed names its sequence on every machine:
//
//   - **a view event** on a random element of the page — `click`,
//     `dblclick`, `input` of a random text, `key`, `focus`, `blur` — or on
//     the window or the document (`event window resize`, …);
//   - **the host**: `advance` of the page's virtual clock, `respond` to or
//     `fail` a request the page made, `hash` to a random fragment;
//   - **a message as a value**, when `types` holds the programs' message
//     types and `values` says both builds take them: a random value of the
//     type as the checker records it — not of the write-set pass's key
//     tree, so a constructor the analysis mis-filed is still sent. `Int`s,
//     `String`s, `Bool`s, records, tuples, lists and constructors, small; a
//     constructor whose payload holds a function, a `foreign type`, a
//     `Dict` or a `Set` is not sent. A value is in the development
//     representation (backend.md §4). A development `browser-tea` build
//     takes it through its mount's `$$root`; a `browser-direct` build
//     through the dispatcher its hidden `--fuzz` flag emits,
//     `globalThis.__beniFuzz.send(program, msg)`.
//
// Every action but a message is one of the driver's steps, written as a
// `.steps` script writes it, so a sequence of them is a script the driver
// replays — a red-first fixture.
//
// The pages are compared after every step: the DOM as the driver prints
// it, every request the page made, and whether the step threw. A step that
// throws on both pages ends the sequence there (a crash screen is a
// build's own). The first difference ends the run with code 1, and the
// report names the seed, the step, the action and the smallest element
// where the two DOMs differ, after shrinking the sequence to fewer actions
// that still differ. Code 0: every seed agreed, a line per seed. Code 2: a
// fault of the fuzzer itself, its stack on stderr.

import { cpSync, readFileSync, rmSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import process from "node:process";

// ---------------------------------------------------------------------------
// Page code of the fuzzer's own: each is self-contained, as the driver's
// are, because Chrome is sent its text (`inPage`).
// ---------------------------------------------------------------------------

// A page function of this file, for `run`: happy-dom's page calls it, and
// Chrome's evaluates its text, which the driver reads as a function's name.
function inPage(fn) {
  return { name: `(${fn})`, own: fn };
}

// Before the program loads: record every program the page mounts, in the
// order it mounts them. A `browser-tea` mount is the node its runtime sets
// `$$root` on (`Rt.mount`), so an accessor on `Node.prototype` sees each.
// happy-dom's classes are shared by every page of one process, so the
// accessor is installed once and reads the current page's list.
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
  return null;
}

// Send message `value` to program `program` (mount order): the direct
// platform's fuzz dispatcher, or the mount's `$$root`. Null, or why not.
function fuzzSend({ program, value }) {
  const direct = globalThis.__beniFuzz;
  if (direct !== undefined) {
    direct.send(program, value);
    return null;
  }
  const mount = globalThis.__beniFuzzMounts[program];
  if (mount === undefined) return `the page mounted no program ${program}`;
  mount.$$root(value);
  return null;
}

// The elements an event may go to, in document order, each with a
// selector the driver accepts (no spaces: a `>` chain of `:nth-child`s
// from the body) and what it is. A `<template>`'s content is not in the
// document and is left out.
function fuzzTargets() {
  const out = [];
  const walk = (node, path) => {
    let k = 0;
    for (const child of node.children) {
      k += 1;
      const html = child.namespaceURI === "http://www.w3.org/1999/xhtml" && /^[a-z][a-z0-9-]*$/.test(child.localName);
      const selector = `${path}>${html ? child.localName : "*"}:nth-child(${k})`;
      const tag = child.localName;
      out.push({
        selector,
        text: tag === "textarea" || (tag === "input" && !["checkbox", "radio", "button", "submit", "reset", "file"].includes(child.type)),
        control: ["input", "textarea", "select", "button", "a"].includes(tag) || child.tabIndex >= 0,
      });
      if (tag !== "template") walk(child, selector);
    }
  };
  if (document.body !== null) walk(document.body, "body");
  return out;
}

// How many programs the page mounted, or null when the direct platform's
// dispatcher numbers them itself.
function fuzzMounts() {
  return globalThis.__beniFuzz !== undefined ? null : globalThis.__beniFuzzMounts.length;
}

// The requests the page made that are still pending, by number.
function fuzzPending() {
  return globalThis.__beniHarness.requests.filter((r) => !r.settled && !r.aborted).map((r) => r.n);
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

const texts = ["", "a", "ab", "hello", " ", "x y", "0", "1", "42", "-3", "Ω", "<b>", "&amp;"];
const ints = [0, 1, -1, 2, 3, 5, 10, 100, -100, 1000];
const floats = [0, 0.5, -1.25, 3.14, 1000, -0.0001];

// What the generator answers for a type it cannot make a value of.
const none = Symbol("none");

// Values of the types of `defs`, a message type's definitions (backend.md
// §4, *`Debug.toString` reads the argument's type*: `defs[k]` is a type's
// constructors, a number inside one its parameter), drawn from `rng`, in
// the development representation.
function generator(defs, rng) {
  const arity = defs.map((d) => Math.max(0, ...Object.values(d).map((args) => args.length)));
  // A value of type `t`, its parameters `env` (`{t, env}` each), `depth`
  // containers down; `none` for a function, a `foreign type`, a `Dict`, a
  // `Set` or an unknown, anywhere in it.
  const value = (t, env, depth) => {
    if (typeof t === "number") return env[t] === undefined ? none : value(env[t].t, env[t].env, depth);
    if (typeof t === "string") {
      switch (t) {
        case "i":
          return rng.next() < 0.7 ? rng.pick(ints) : rng.int(2001) - 1000;
        case "f":
          return rng.pick(floats);
        case "s":
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
        const n = depth > 3 ? 0 : rng.int(4);
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

// A message of `type` (`[root, defs]`): a constructor of the root type,
// chosen first, then its payload; `none` when none can be made.
function message(type, rng) {
  const [root, defs] = type;
  const g = generator(defs, rng);
  if (!Array.isArray(root) || root[0] !== "n") return g.value(root, [], 0);
  const ctors = Object.entries(defs[root[1]]);
  const args = root.slice(2).map((a) => ({ t: a, env: [] }));
  const start = rng.int(ctors.length);
  for (let i = 0; i < ctors.length; i++) {
    const [tag, fields] = ctors[(start + i) % ctors.length];
    const v = g.constructed(root[1], tag, fields, args, 0);
    if (v !== none) return v;
  }
  return none;
}

// Value `v` of type `t` as beni writes it, for the report.
function show(t, defs, env, v) {
  if (typeof t === "number") return env[t] === undefined ? JSON.stringify(v) : show(env[t].t, defs, env[t].env, v);
  if (typeof t === "string") {
    if (t === "s" || t === "c") return JSON.stringify(v);
    if (t === "b") return v ? "True" : "False";
    if (t === "u") return "⊤";
    return String(v);
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

// ---------------------------------------------------------------------------
// Actions.
// ---------------------------------------------------------------------------

const keys = ["Enter", "Escape", "a", "ArrowUp", "ArrowDown", "Tab", "Backspace"];
const windowEvents = [["window", "resize"], ["window", "focus"], ["window", "blur"], ["document", "visibilitychange"]];
const fragments = ["#/", "#/active", "#/completed", "#/x", "#"];
const bodies = ['""', '"ok"', '"[]"', '"{}"', '"{\\"a\\":1}"', '"[1,2]"'];

// The next action: a driver step (`{line, s}`) or a message (`{line,
// message}`), for a page whose event targets and pending requests are
// these, and whose programs' message types are `types` (null where unknown,
// or for every program when no message goes as a value).
function nextAction(rng, types, targets, pending) {
  // Each kind of action takes a share of the roll in turn, a kind that
  // cannot happen taking none, and view events take what is left.
  let roll = rng.next();
  const takes = (share) => {
    if (roll < share) return true;
    roll -= share;
    return false;
  };
  const sendable = types.map((type, program) => ({ type, program })).filter(({ type }) => type !== null);
  if (sendable.length !== 0 && takes(0.3)) {
    const { type, program } = rng.pick(sendable);
    const v = message(type, rng);
    if (v !== none) {
      const prefix = types.length > 1 ? `program ${program}: ` : "";
      return { line: `message ${prefix}${show(type[0], type[1], [], v)}`, message: { program, value: v } };
    }
  }
  if (pending.length !== 0 && takes(0.15)) {
    const n = rng.pick(pending);
    if (rng.next() < 0.15) return { line: `fail ${n}`, s: { command: "fail", n } };
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
  if (targets.length === 0) return { line: "advance 16", s: { command: "advance", ms: 16, tasks: false } };
  const kind = rng.next();
  const typed = targets.filter((t) => t.text);
  if (typed.length !== 0 && kind < 0.25) {
    const t = rng.pick(typed);
    const text = rng.pick(texts);
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
}

// ---------------------------------------------------------------------------
// Comparing.
// ---------------------------------------------------------------------------

// How two views of a step differ, or null.
function differs(x, y) {
  if (x === undefined || y === undefined) return x === y ? null : "steps";
  if ((x.threw === null) !== (y.threw === null)) return "threw";
  if (x.threw !== null) return null;
  if (x.fault !== y.fault) return "fault";
  if (x.dom !== y.dom) return "dom";
  if (x.requests.join("\n") !== y.requests.join("\n")) return "requests";
  return null;
}

// The first step at which two runs differ, or -1.
function firstDifference(a, b) {
  const n = Math.max(a.shown.length, b.shown.length);
  for (let i = 0; i < n; i++) if (differs(a.shown[i], b.shown[i]) !== null) return i;
  return -1;
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
    const depth = Math.min(indent(xs[first] ?? ""), indent(ys[first] ?? ""));
    open = first - 1;
    while (open >= 0 && !(indent(xs[open]) < depth && opens(xs[open]))) open--;
  }
  const cut = (lines) => {
    if (open < 0) return lines.join("\n");
    const out = lines.slice(open, end(lines, open) + 1);
    return (out.length > 60 ? [...out.slice(0, 60), `${" ".repeat(indent(lines[open]))}… (${out.length - 60} more lines)`] : out).join("\n");
  };
  return { a: cut(xs), b: cut(ys) };
}

const describe = (view) =>
  view === undefined
    ? "(the sequence had ended)"
    : view.threw !== null
      ? `(threw: ${view.threw})`
      : view.fault !== null
        ? `(the step could not run: ${view.fault})`
        : null;

// ---------------------------------------------------------------------------
// The run.
// ---------------------------------------------------------------------------

// The pages this process has made (`fuzz`'s copies).
let copies = 0;

// Fuzz `spec` with the driver's `host`: `open(entry)`, a fresh page of the
// program (`{run, click, close, url}`), and its page functions. Resolves to
// what a page report holds: `{code, stdout, stderr}`.
export async function fuzz(spec, host) {
  // A copy of each build per page, so every page imports a module graph
  // of its own: Node answers a second import of a file from the first —
  // of a path an earlier run in this process used, too, hence the
  // process-wide count — and a runtime's module state would carry over.
  const scratch = join(process.cwd(), `_fuzz-pages-${process.pid}`);
  const types = spec.types === null || spec.types === undefined
    ? []
    : readFileSync(spec.types, "utf8").split("\n").filter((l) => l.trim() !== "").map((l) => JSON.parse(l).msg);
  const sent = spec.values ? types : types.map(() => null);

  // Run `actions` on a fresh page of `entry`; or, with `rng`, draw `steps`
  // actions as the page goes and run those. What each step showed.
  const play = async (entry, actions, rng = null, steps = actions.length) => {
    const dir = join(scratch, String(copies++));
    cpSync(dirname(resolve(entry)), dir, { recursive: true });
    const p = await host.open(join(dir, basename(entry)));
    const shown = [];
    const taken = [];
    const look = async (fault) => {
      await p.run(host.settle);
      const { log, errors } = await p.run(host.drain);
      const dom = await p.run(host.serialise);
      return { dom, requests: log.filter((l) => l.startsWith("(fetch ")), threw: errors.length !== 0 ? errors[0].split("\n")[0] : null, fault };
    };
    try {
      await p.run(inPage(fuzzInstall));
      await p.run(host.load, { url: p.url, runtime: null });
      shown.push(await look(null));
      // A message goes to a program by its place among the mounts: only
      // when the page mounted as many programs as the dump lists.
      const mounts = rng === null ? null : await p.run(inPage(fuzzMounts));
      const to = mounts === null || mounts === sent.length ? sent : sent.map(() => null);
      for (let i = 0; i < steps && shown[shown.length - 1].threw === null; i++) {
        const action = rng === null ? actions[i] : nextAction(rng, to, await p.run(inPage(fuzzTargets)), await p.run(inPage(fuzzPending)));
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

  // Whether `actions` still differ, and how; null when they agree, or no
  // longer run on the first page (then they are no smaller instance).
  const differOn = async (actions) => {
    const a = await play(spec.a, actions);
    if (a.shown.some((v) => v.fault !== null)) return null;
    const b = await play(spec.b, actions);
    const at = firstDifference(a, b);
    return at === -1 ? null : { a, b, at };
  };

  // Fewer actions that still differ: drop chunks, halving them, for a
  // bounded number of tries (a delta debugging; every try is two pages).
  const shrink = async (actions) => {
    let best = actions;
    let tries = 0;
    for (let chunk = Math.max(1, best.length >> 1); chunk >= 1 && tries < 40; chunk >>= 1) {
      for (let start = 0; start < best.length && tries < 40; ) {
        const candidate = [...best.slice(0, start), ...best.slice(start + chunk)];
        tries++;
        if (candidate.length !== 0 && (await differOn(candidate)) !== null) best = candidate;
        else start += chunk;
      }
    }
    return best;
  };

  const lines = [];
  try {
    for (const seed of spec.seeds) {
      const a = await play(spec.a, [], random(seed), spec.steps);
      const b = await play(spec.b, a.taken);
      const at = firstDifference(a, b);
      if (at === -1) {
        const count = (pred) => a.taken.filter(pred).length;
        const messages = count((x) => x.message !== undefined);
        const host = count((x) => x.s !== undefined && ["advance", "respond", "fail", "hash", "event"].includes(x.s.command));
        const threw = a.shown[a.shown.length - 1].threw !== null ? "; both threw at its end" : "";
        const n = (k, what) => `${k} ${what}${k === 1 ? "" : "s"}`;
        lines.push(`seed ${seed}: ${n(a.taken.length, "step")} agree (${n(a.taken.length - messages - host, "view event")}, ${n(messages, "message")}, ${n(host, "host step")}${threw})`);
        continue;
      }
      // Every action up to the one after which the pages differ.
      let sequence = a.taken.slice(0, at);
      let found = { a, b, at };
      if (spec.shrink && sequence.length > 1) {
        const shrunk = await shrink(sequence);
        const again = shrunk.length < sequence.length ? await differOn(shrunk) : null;
        if (again !== null) {
          sequence = shrunk;
          found = again;
        }
      }
      const out = [`${spec.labelA} and ${spec.labelB} differ: seed ${seed}, step ${at} of ${spec.steps}${at === 0 ? " (the load)" : `, ${a.taken[at - 1].line}`}`];
      if (sequence.length !== at) out.push(`shrunk from ${at} steps to ${sequence.length}:`);
      for (const action of sequence) out.push(`  ${action.line}`);
      if (sequence.length === 0) out.push("  (none: the pages differ once loaded)");
      else if (sequence.some((x) => x.message !== undefined)) out.push("(a `message` line is a value sent to the program; the others are `.steps` lines)");
      const x = found.a.shown[found.at];
      const y = found.b.shown[found.at];
      out.push(found.at === 0 ? "once loaded:" : `after ${sequence[found.at - 1].line}:`);
      const kind = differs(x, y);
      if (kind === "dom") {
        const d = smallestDifference(x.dom, y.dom);
        out.push(`--- ${spec.labelA} ---`, d.a, `--- ${spec.labelB} ---`, d.b);
      } else if (kind === "requests") {
        out.push(`--- ${spec.labelA}'s requests ---`, ...x.requests, `--- ${spec.labelB}'s requests ---`, ...y.requests);
      } else {
        out.push(`--- ${spec.labelA} ---`, describe(x) ?? x.dom, `--- ${spec.labelB} ---`, describe(y) ?? y.dom);
      }
      lines.push(...out);
      return { code: 1, stdout: `${lines.join("\n")}\n`, stderr: "" };
    }
    return { code: 0, stdout: `${lines.join("\n")}\n`, stderr: "" };
  } catch (error) {
    return { code: 2, stdout: lines.length === 0 ? "" : `${lines.join("\n")}\n`, stderr: `fuzz: ${error?.stack ?? error}\n` };
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}
