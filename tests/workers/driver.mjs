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

import crypto from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
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
// Steps that wait for a server line the mark cannot order: a line an
// object writes from a socket event has no order with a request to the
// Worker, so such a step names the line it waits for (`"until"`). A wait
// that times out is a failure of the run, so no golden can keep it.
let untilTimedOut = false;
const lineWaiters = [];
const waitForLine = (text) =>
  consoleLines.some((line) => line.includes(text))
    ? Promise.resolve(true)
    : new Promise((resolve) => {
        const waiter = { text, resolve: null };
        const timer = setTimeout(() => {
          lineWaiters.splice(lineWaiters.indexOf(waiter), 1);
          resolve(false);
        }, stepLimit);
        waiter.resolve = () => {
          clearTimeout(timer);
          resolve(true);
        };
        lineWaiters.push(waiter);
      });
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
      for (const waiter of lineWaiters.filter((w) => line.includes(w.text))) {
        lineWaiters.splice(lineWaiters.indexOf(waiter), 1);
        waiter.resolve();
      }
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
const readyUrl = await mf.ready;
const base = "http://127.0.0.1";

// A hand-made close frame (`"frame"`: the payload in hex, the code's two
// bytes then the reason's), for what the client library refuses to send —
// a code outside 1000-4999, a reason that is not UTF-8. Masked, as a
// client's frame must be (RFC 6455 §5.3), with a random key. A control
// frame's payload is at most 125 bytes (§5.5), which is also the short
// length form's bound; a longer one, or a payload that is not an even
// count of hex digits, is a script error. The frame is written to the
// `ws` library's private `_socket`, since the library has no way to send
// a frame it would refuse; the library still reads the server's answer.
const rawClose = (ws, name, hex) => {
  if (!/^(?:[0-9a-fA-F]{2})*$/.test(hex)) scriptError(`close frame of socket ${name}: "${hex}" is not an even count of hex digits`);
  const payload = Buffer.from(hex, "hex");
  if (payload.length > 125) scriptError(`close frame of socket ${name}: ${payload.length} bytes, and a control frame holds at most 125`);
  const key = crypto.randomBytes(4);
  const masked = Buffer.from(payload.map((byte, i) => byte ^ key[i % 4]));
  ws._socket.write(Buffer.concat([Buffer.from([0x88, 0x80 | payload.length]), key, masked]));
};

// A step the script wrote wrong: the run cannot mean anything, so the
// driver stops with the usage errors' exit code, the step named.
const scriptError = (what) => {
  process.stderr.write(`workers driver: script error: ${what}\n`);
  process.exit(2);
};

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

// WebSocket clients the script opened, by name. The client is the `ws`
// library Miniflare itself carries, connected to the Worker's port, so a
// step can send a binary frame or drop the connection with no close
// frame, which Miniflare's own client cannot. What the server sends is
// kept, in order, until a `receive` step takes it.
const WebSocketClient = createRequire(import.meta.url)(path.join(path.dirname(miniflarePath), "..", "..", "node_modules", "ws"));
const sockets = new Map();
const socketNamed = (name) => {
  const entry = sockets.get(name);
  if (entry === undefined) say(`< (no socket ${name})`);
  return entry;
};
const printHeaders = (name, headers) => {
  for (const [h, value] of Object.entries(headers).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
    if (h.startsWith("mf-") || h === "transfer-encoding" || h === "connection" || h === "date") continue;
    // The accept key answers the client's random key: shown as present.
    say(`(socket ${name}) < ${h}: ${h === "sec-websocket-accept" ? "(the key)" : value}`);
  }
};
const openSocket = (step) =>
  new Promise((resolve) => {
    const name = step.socket;
    const protocols = step.protocols ?? [];
    say(`> (socket ${name}) GET ${step.path}${protocols.length === 0 ? "" : ` ${JSON.stringify(protocols)}`}`);
    const ws = new WebSocketClient(`ws://${readyUrl.host}${step.path}`, protocols, { headers: step.headers ?? {} });
    const entry = { ws, inbox: [], waiter: null };
    const arrived = (line) => {
      entry.inbox.push(line);
      if (entry.waiter !== null) entry.waiter();
    };
    let settled = false;
    const done = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(() => {
      say(`(socket ${name}) < (no answer in ${stepLimit} ms)`);
      ws.terminate();
      done();
    }, stepLimit);
    ws.on("upgrade", (res) => {
      say(`(socket ${name}) < 101`);
      printHeaders(name, res.headers);
      sockets.set(name, entry);
      done();
    });
    ws.on("unexpected-response", (_req, res) => {
      say(`(socket ${name}) < ${res.statusCode}`);
      printHeaders(name, res.headers);
      let body = "";
      res.on("data", (chunk) => {
        body += chunk;
      });
      res.on("end", () => {
        if (body !== "") {
          say(`(socket ${name}) <`);
          for (const line of body.split("\n")) if (!/^\s+at /.test(line)) say(`(socket ${name}) < ${line}`);
        }
        done();
      });
    });
    ws.on("message", (data, isBinary) => arrived(isBinary ? `binary ${data.length} bytes` : JSON.stringify(data.toString())));
    ws.on("close", (code, reason) => arrived(`close ${code} ${JSON.stringify(reason.toString())}`));
    ws.on("error", (e) => {
      arrived(`error ${e.message}`);
      done();
    });
  });
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
  } else if (step.send !== undefined && step.binary !== undefined) {
    say(`> (socket ${step.send}) binary ${step.binary} bytes`);
    socketNamed(step.send)?.ws.send(Buffer.alloc(step.binary, 1));
  } else if (step.send !== undefined) {
    say(`> (socket ${step.send}) ${JSON.stringify(step.text)}`);
    socketNamed(step.send)?.ws.send(step.text);
  } else if (step.drop !== undefined) {
    // The connection ends with no close frame: the server sees 1006. The
    // step waits for the client's own close event; the server's close
    // handler is awaited through the step's `until`.
    say(`> (socket ${step.drop}) (dropped, no close frame)`);
    const entry = socketNamed(step.drop);
    if (entry !== undefined) {
      const closed = new Promise((resolve) => entry.ws.once("close", resolve));
      entry.ws.terminate();
      await Promise.race([closed, new Promise((resolve) => setTimeout(resolve, stepLimit))]);
    }
  } else if (step.close !== undefined) {
    say(
      step.frame !== undefined
        ? `> (socket ${step.close}) close frame ${step.frame}`
        : `> (socket ${step.close}) close${step.code === undefined ? "" : ` ${step.code} ${JSON.stringify(step.reason ?? "")}`}`,
    );
    const entry = socketNamed(step.close);
    if (entry === undefined) {
    } else if (step.frame !== undefined) rawClose(entry.ws, step.close, step.frame);
    else if (step.code === undefined) entry.ws.close();
    else entry.ws.close(step.code, step.reason ?? "");
  } else if (step.receive !== undefined && step.count !== undefined) {
    const entry = socketNamed(step.receive);
    let messages = 0;
    let bytes = 0;
    while (entry !== undefined && messages < step.count) {
      const line = await receiveOne(entry);
      if (line === null || !line.startsWith('"')) {
        if (line !== null) entry.inbox.unshift(line);
        break;
      }
      messages += 1;
      bytes += JSON.parse(line).length;
    }
    if (entry !== undefined) say(`< (socket ${step.receive}) ${messages} messages, ${bytes} bytes`);
  } else if (step.receive !== undefined) {
    const entry = socketNamed(step.receive);
    if (entry !== undefined) {
      const line = await receiveOne(entry);
      say(`< (socket ${step.receive}) ${line === null ? "(nothing arrived)" : line}`);
    }
  } else {
    printRequest(step);
    await printOutcome(await within(() => send(step)));
  }
  // A step that names a server line waits for it first (`"until"`).
  if (step.until !== undefined && !(await waitForLine(step.until))) {
    say(`< (no line ${JSON.stringify(step.until)} in ${stepLimit} ms)`);
    process.stderr.write(`workers driver: no line ${JSON.stringify(step.until)} in ${stepLimit} ms; the run fails\n`);
    untilTimedOut = true;
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
// A step named a server line that never came: the run failed, whatever the
// transcript says. The exit code is set, not forced, so the transcript's
// tail is flushed first.
if (untilTimedOut) process.exitCode = 1;
