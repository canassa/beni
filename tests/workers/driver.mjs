// The `workers/` corpus kind's driver (docs/design/boundary.md §9.12 (k),
// tests/corpus/README.md, `workers/`): `node driver.mjs [--miniflare=<index.js>]
// <out> <script>`, in the fixture's project directory.
//
// It starts the built Worker, `<out>/_worker.mjs`, under Miniflare — the
// workerd that nixpkgs' `wrangler` carries, found through `BENI_MINIFLARE`
// (`nix develop .#workers`) — with the bindings `wrangler.jsonc` beside
// the script declares, `cf: false` so nothing is fetched from the network,
// on 127.0.0.1, runs the script's steps against it, one JSON object per
// line, and prints a transcript: each step and its answer, with what the
// Worker wrote to its console after each. Nothing is deployed, no account
// is used, and the Worker is disposed at the end. The port never appears
// in the transcript, and neither does anything that depends on it, on the
// clock or on the machine.

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

// `--miniflare=<file>` names Miniflare's entry file; the harness passes it
// from `BENI_MINIFLARE`, since a program it spawns gets an empty
// environment. A hand run may set the variable instead.
const given = process.argv.slice(2);
const miniflareArg = given.find((a) => a.startsWith("--miniflare="));
const [outArg, script] = given.filter((a) => !a.startsWith("--miniflare="));
if (outArg === undefined || script === undefined) {
  process.stderr.write("usage: node driver.mjs [--miniflare=<index.js>] <out> <script.steps>\n");
  process.exit(2);
}
const miniflarePath = miniflareArg !== undefined ? miniflareArg.slice("--miniflare=".length) : process.env.BENI_MINIFLARE;
if (miniflarePath === undefined || miniflarePath === "") {
  process.stderr.write("driver.mjs: BENI_MINIFLARE (or --miniflare=) names Miniflare's entry file; enter `nix develop .#workers`\n");
  process.exit(2);
}
const { Miniflare } = await import(miniflarePath);

// How long one step may take, in milliseconds: a bound a correct fixture
// never reaches, since no fixture waits for real.
const stepLimit = 5000;

const out = path.resolve(outArg);
const say = (line) => process.stdout.write(`${line}\n`);

// ---- The configuration ------------------------------------------------------

// `wrangler.jsonc`, as the author writes it (§9.12 (i)): JSON with `//`
// comments and trailing commas. Miniflare reads no such file, so the
// driver maps the keys it needs.
const stripJsonc = (text) =>
  text
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:"'\\])\/\/.*$/gm, "$1")
    .replace(/,(\s*[}\]])/g, "$1");
const configPath = path.join(process.cwd(), "wrangler.jsonc");
const config = fs.existsSync(configPath) ? JSON.parse(stripJsonc(fs.readFileSync(configPath, "utf8"))) : {};

const sqliteClasses = new Set();
for (const migration of config.migrations ?? []) for (const name of migration.new_sqlite_classes ?? []) sqliteClasses.add(name);
const durableObjects = {};
for (const binding of config.durable_objects?.bindings ?? []) {
  durableObjects[binding.name] = { className: binding.class_name, useSQLite: sqliteClasses.has(binding.class_name) };
}

// ---- The script -------------------------------------------------------------

const steps = [];
for (const raw of fs.readFileSync(script, "utf8").split("\n")) {
  const line = raw.trim();
  if (line.length === 0 || line.startsWith("#")) continue;
  steps.push(JSON.parse(line));
}

// ---- The Worker -------------------------------------------------------------

// What the Worker writes to its console, printed after the step it came
// with, each line `| ` and the stream's name. The host's stack lines are
// left out: they hold a store path. After each step the driver asks the
// Worker's test hook `/__beni/mark/<n>` and waits for its line, so a
// step's lines never land under the next, however loaded the host.
let consoleLines = [];
// The mark each stream waits for: the Worker writes it to both, since one
// stream's mark says nothing about the other's order.
const markWaiters = { out: null, err: null };
const capture = (name, stream) => {
  let rest = "";
  stream.on("data", (chunk) => {
    rest += chunk;
    let nl;
    while ((nl = rest.indexOf("\n")) !== -1) {
      const line = rest.slice(0, nl);
      rest = rest.slice(nl + 1);
      if (/^\s+at /.test(line)) continue;
      const mark = /^beni:mark (\d+)$/.exec(line);
      if (mark !== null) {
        const waiter = markWaiters[name];
        if (waiter !== null && waiter.n === Number(mark[1])) waiter.resolve();
        continue;
      }
      consoleLines.push(`| ${name}: ${line}`);
    }
  });
};
const flushConsole = () => {
  for (const line of consoleLines) say(line);
  consoleLines = [];
};
let marks = 0;
const awaitConsole = async () => {
  marks += 1;
  const n = marks;
  const arrived = Promise.all(
    ["out", "err"].map(
      (name) =>
        new Promise((resolve) => {
          markWaiters[name] = { n, resolve };
        }),
    ),
  );
  await mf.dispatchFetch(`${base}/__beni/mark/${n}`);
  await Promise.race([arrived, new Promise((resolve) => setTimeout(resolve, stepLimit))]);
  markWaiters.out = null;
  markWaiters.err = null;
};

const mf = new Miniflare({
  modules: true,
  modulesRoot: out,
  scriptPath: path.join(out, "_worker.mjs"),
  compatibilityDate: config.compatibility_date ?? "2026-05-18",
  compatibilityFlags: config.compatibility_flags ?? [],
  bindings: config.vars ?? {},
  durableObjects,
  cf: false,
  host: "127.0.0.1",
  port: 0,
  handleRuntimeStdio(stdout, stderr) {
    capture("out", stdout);
    capture("err", stderr);
  },
});
await mf.ready;
const base = "http://127.0.0.1";

// ---- The steps --------------------------------------------------------------

const within = (work) =>
  new Promise((resolve) => {
    let done = false;
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      resolve({ late: true });
    }, stepLimit);
    work().then(
      (value) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        resolve({ value });
      },
      (error) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        resolve({ error });
      },
    );
  });

const printRequest = (step, note = "") => {
  say(`> ${step.method ?? "GET"} ${step.path}${note}`);
  for (const [name, value] of Object.entries(step.headers ?? {})) say(`> ${name}: ${value}`);
  if (step.body !== undefined && step.body !== "") {
    say(">");
    for (const line of step.body.split("\n")) say(`> ${line}`);
  }
};

// The answer: the status, the headers sorted by name as the host keeps
// them — without Miniflare's own `mf-` headers and the transport's
// `transfer-encoding`, which are not the Worker's — then the body.
const printResponse = async (res, prefix = "") => {
  say(`${prefix}< ${res.status}`);
  for (const [name, value] of res.headers) {
    if (name.startsWith("mf-") || name === "transfer-encoding") continue;
    say(`${prefix}< ${name}: ${value}`);
  }
  const body = await res.text();
  if (body !== "") {
    say(`${prefix}<`);
    // The host's error page carries its stack lines, which hold a store
    // path: left out, as the console's are.
    for (const line of body.split("\n")) if (!/^\s+at /.test(line)) say(`${prefix}< ${line}`);
  }
};

const printOutcome = async (outcome, prefix = "") => {
  if (outcome.late) say(`${prefix}< (no response in ${stepLimit} ms)`);
  else if (outcome.error) say(`${prefix}< (error ${outcome.error.name}: ${outcome.error.message})`);
  else await printResponse(outcome.value, prefix);
};

const send = (step, signal) =>
  mf.dispatchFetch(`${base}${step.path}`, {
    method: step.method ?? "GET",
    headers: step.headers ?? {},
    body: step.body,
    redirect: "manual",
    signal,
  });

// Requests the script sent and has not taken the answer of, by name.
const detached = new Map();

// WebSocket clients the script opened, by name: Miniflare's client over
// `dispatchFetch` with `upgrade: websocket` (`res.webSocket`). What the
// server sends is kept, in order, until a `receive` step takes it.
const sockets = new Map();
const socketNamed = (name) => {
  const ws = sockets.get(name);
  if (ws === undefined) throw new Error(`no socket named ${name}`);
  return ws;
};
const openSocket = async (step) => {
  const name = step.socket;
  const protocols = step.protocols ?? [];
  say(`> (socket ${name}) GET ${step.path}${protocols.length === 0 ? "" : ` ${JSON.stringify(protocols)}`}`);
  const headers = { upgrade: "websocket", ...(step.headers ?? {}) };
  if (protocols.length !== 0) headers["sec-websocket-protocol"] = protocols.join(", ");
  const outcome = await within(() => mf.dispatchFetch(`${base}${step.path}`, { headers }));
  if (outcome.late || outcome.error || outcome.value.status !== 101) {
    await printOutcome(outcome, `(socket ${name}) `);
    return;
  }
  const res = outcome.value;
  say(`(socket ${name}) < 101`);
  for (const [h, value] of res.headers) {
    if (h.startsWith("mf-") || h === "transfer-encoding") continue;
    // The accept key answers the client's random key: shown as present.
    say(`(socket ${name}) < ${h}: ${h === "sec-websocket-accept" ? "(the key)" : value}`);
  }
  const ws = res.webSocket;
  const entry = { ws, inbox: [], waiter: null, ended: false };
  const arrived = (line) => {
    entry.inbox.push(line);
    if (entry.waiter !== null) entry.waiter();
  };
  ws.addEventListener("message", (e) => arrived(typeof e.data === "string" ? JSON.stringify(e.data) : `binary ${e.data.byteLength} bytes`));
  ws.addEventListener("close", (e) => {
    entry.ended = true;
    arrived(`close ${e.code} ${JSON.stringify(e.reason)}`);
  });
  ws.addEventListener("error", (e) => arrived(`error ${e.message ?? ""}`));
  ws.accept();
  sockets.set(name, entry);
};
// The next thing the socket got, waiting up to the step limit for it.
const receiveOne = (entry) =>
  entry.inbox.length !== 0
    ? Promise.resolve(entry.inbox.shift())
    : new Promise((resolve) => {
        const timer = setTimeout(() => {
          entry.waiter = null;
          resolve(null);
        }, stepLimit);
        entry.waiter = () => {
          clearTimeout(timer);
          entry.waiter = null;
          resolve(entry.inbox.shift());
        };
      });

for (const step of steps) {
  if (step.answer !== undefined) {
    const pending = detached.get(step.answer);
    say(`> (answer ${step.answer})`);
    if (pending === undefined) {
      say(`< (no request named ${step.answer})`);
    } else {
      detached.delete(step.answer);
      await printOutcome(await pending, `(${step.answer}) `);
    }
  } else if (step.detach !== undefined) {
    printRequest(step, ` (detached as ${step.detach})`);
    detached.set(step.detach, within(() => send(step)));
    // Let the request reach the Worker before the next step is sent.
    await new Promise((resolve) => setTimeout(resolve, 20));
  } else if (step.abort !== undefined) {
    // Sent, then given up on after `abort` milliseconds: the Worker sees a
    // client that left, where the host provides `request.signal`.
    printRequest(step, " (aborted)");
    const controller = new AbortController();
    const pending = within(() => send(step, controller.signal));
    await new Promise((resolve) => setTimeout(resolve, step.abort));
    controller.abort();
    const outcome = await pending;
    say(outcome.error ? `< (aborted: ${outcome.error.name})` : outcome.late ? `< (no response in ${stepLimit} ms)` : `< ${outcome.value.status} (answered before the abort)`);
  } else if (step.socket !== undefined) {
    await openSocket(step);
  } else if (step.send !== undefined) {
    say(`> (socket ${step.send}) ${JSON.stringify(step.text)}`);
    socketNamed(step.send).ws.send(step.text);
  } else if (step.close !== undefined) {
    say(`> (socket ${step.close}) close${step.code === undefined ? "" : ` ${step.code} ${JSON.stringify(step.reason ?? "")}`}`);
    if (step.code === undefined) socketNamed(step.close).ws.close();
    else socketNamed(step.close).ws.close(step.code, step.reason ?? "");
  } else if (step.receive !== undefined && step.count !== undefined) {
    const entry = socketNamed(step.receive);
    let messages = 0;
    let bytes = 0;
    while (messages < step.count) {
      const line = await receiveOne(entry);
      if (line === null || !line.startsWith('"')) {
        if (line !== null) entry.inbox.unshift(line);
        break;
      }
      messages += 1;
      bytes += JSON.parse(line).length;
    }
    say(`< (socket ${step.receive}) ${messages} messages, ${bytes} bytes`);
  } else if (step.receive !== undefined) {
    const line = await receiveOne(socketNamed(step.receive));
    say(`< (socket ${step.receive}) ${line === null ? "(nothing arrived)" : line}`);
  } else {
    printRequest(step);
    await printOutcome(await within(() => send(step)));
  }
  // The Worker's console lines arrive on a stream of their own: the mark
  // says every line of this step has landed.
  await awaitConsole();
  flushConsole();
}
for (const [name, pending] of detached) {
  say(`> (answer ${name}, at the end)`);
  await printOutcome(await pending, `(${name}) `);
}
await mf.dispose();
flushConsole();
