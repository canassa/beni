// The `serve/` corpus kind's driver (docs/design/boundary.md §9.10 (h),
// tests/corpus/README.md, `serve/`): `node driver.mjs <entry> <script>`,
// in the program's project directory.
//
// It starts the program as a child with `preload.mjs` imported first,
// learns the address of the first server the program binds from file
// descriptor 3, runs the script's steps against it, one JSON object per
// line, and prints a transcript: each step and its answer, then the
// program's standard output, its standard error and its exit. The port
// never appears in the transcript, and neither does anything that depends
// on it, on the clock or on the machine: the `date` header is left out,
// and standard error is filtered (`filterStderr`).

import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import process from "node:process";

const [entry, script] = process.argv.slice(2);
if (entry === undefined || script === undefined) {
  process.stderr.write("usage: node driver.mjs <entry.mjs> <script.requests>\n");
  process.exit(2);
}

// How long one step may take, and how long the program has to exit after
// the last step, in milliseconds: a bound that a correct fixture never
// reaches, since no fixture sleeps for real.
const stepLimit = 5000;
const exitLimit = 5000;

const preload = path.join(path.dirname(new URL(import.meta.url).pathname), "preload.mjs");
const say = (line) => process.stdout.write(`${line}\n`);

// ---- The script -------------------------------------------------------------

const lines = fs.readFileSync(script, "utf8").split("\n");
const steps = [];
for (const raw of lines) {
  const line = raw.trim();
  if (line.length === 0 || line.startsWith("#")) continue;
  steps.push(JSON.parse(line));
}

// ---- The program ------------------------------------------------------------

// A `{"fault": "listen:EPROTO"}` step, first in the script, reaches the
// preload as `BENI_SERVE_FAULT`: it fails the next `listen` (or
// `request:<code>`, the next request's read) with an error the platform
// does not name, so a fixture can assert the crash (boundary.md §4.1).
const fault = steps.length !== 0 && steps[0].fault !== undefined ? steps.shift().fault : null;
if (fault !== null) say(`(fault: ${fault})`);

const child = spawn(process.execPath, ["--import", preload, entry], {
  cwd: process.cwd(),
  stdio: ["ignore", "pipe", "pipe", "pipe"],
  env: fault === null ? process.env : { ...process.env, BENI_SERVE_FAULT: fault },
});
const captured = { stdout: [], stderr: [] };
child.stdout.on("data", (chunk) => captured.stdout.push(chunk));
child.stderr.on("data", (chunk) => captured.stderr.push(chunk));

// How the program ended: `{ code }` or `{ signal }`, once it has and its
// streams are drained (`close`, not `exit`: a line written just before the
// exit arrives after `exit` fires).
let ended = null;
const exited = new Promise((resolve) => {
  child.on("close", (code, signal) => {
    ended = signal === null ? { code } : { signal };
    resolve(ended);
  });
});

// The first address the program binds, from descriptor 3; null if the
// program ends first.
const bound = new Promise((resolve) => {
  let text = "";
  let found = false;
  child.stdio[3].on("data", (chunk) => {
    text += chunk;
    const nl = text.indexOf("\n");
    if (nl === -1 || found) return;
    found = true;
    resolve(JSON.parse(text.slice(0, nl)));
  });
  exited.then(() => resolve(null));
});

// ---- The steps --------------------------------------------------------------

const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });

const within = (limit, work, late) =>
  new Promise((resolve) => {
    let done = false;
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      late();
      resolve();
    }, limit);
    work().then(() => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve();
    });
  });

const printRequest = (step, note = "") => {
  say(`> ${step.method ?? "GET"} ${step.path}${note}`);
  // A value that is a list is sent as one header line per entry, so it is
  // printed that way too.
  for (const [name, value] of Object.entries(step.headers ?? {})) {
    for (const each of Array.isArray(value) ? value : [value]) say(`> ${name}: ${each}`);
  }
  if (step.body !== undefined && step.body !== "") {
    say(">");
    for (const line of step.body.split("\n")) say(`> ${line}`);
  }
};

const printResponse = (res, body, out = say) => {
  out(`< ${res.statusCode}`);
  for (let i = 0; i < res.rawHeaders.length; i += 2) {
    const name = res.rawHeaders[i].toLowerCase();
    if (name === "date") continue;
    out(`< ${name}: ${res.rawHeaders[i + 1]}`);
  }
  if (body !== "") {
    out("<");
    for (const line of body.split("\n")) out(`< ${line}`);
  }
};

// The outcomes of detached requests, in the order they completed, printed
// after the last step (`--- detached ---`).
const detached = [];
let pendingDetached = 0;

// A request whose answer the script does not wait for: its outcome goes to
// `detached`, as text, when it arrives or when its connection ends.
const detach = (port, step) => {
  printRequest(step, " (detached)");
  pendingDetached += 1;
  const lines = [];
  const done = () => {
    detached.push(lines);
    pendingDetached -= 1;
  };
  const req = http.request(
    { host: "127.0.0.1", port, method: step.method ?? "GET", path: step.path, headers: step.headers ?? {}, agent: new http.Agent({ keepAlive: false }) },
    (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        lines.push(`${step.method ?? "GET"} ${step.path}:`);
        printResponse(res, Buffer.concat(chunks).toString("utf8"), (line) => lines.push(line));
        done();
      });
      res.on("error", (error) => {
        lines.push(`${step.method ?? "GET"} ${step.path}: (error ${error.code ?? error.name})`);
        done();
      });
    },
  );
  req.on("error", (error) => {
    lines.push(`${step.method ?? "GET"} ${step.path}: (error ${error.code ?? error.name})`);
    done();
  });
  req.end(step.body ?? "");
};

// A request the client gives up on as soon as it is sent: the connection is
// destroyed once the request has left, so the server sees a client that is
// gone before it answers.
const abortStep = (port, step) =>
  new Promise((resolve) => {
    printRequest(step, " (aborted)");
    const req = http.request(
      { host: "127.0.0.1", port, method: step.method ?? "GET", path: step.path, headers: step.headers ?? {}, agent: new http.Agent({ keepAlive: false }) },
      () => {},
    );
    req.on("error", () => {});
    req.on("socket", (socket) => {
      socket.on("close", () => resolve());
    });
    req.end(step.body ?? "", () => req.destroy());
  });

// A request whose client leaves after the first chunk of the answer, while
// the rest is still being written: the socket's error is the server's to
// handle. Prints the status the chunk came with.
const cutResponse = (port, step) =>
  new Promise((resolve) => {
    printRequest(step, " (cut after the first chunk)");
    const req = http.request(
      { host: "127.0.0.1", port, method: step.method ?? "GET", path: step.path, headers: step.headers ?? {}, agent: new http.Agent({ keepAlive: false }) },
      (res) => {
        res.once("data", () => {
          say(`< (cut after the first chunk of ${res.statusCode})`);
          req.destroy();
        });
        res.on("error", () => {});
      },
    );
    req.on("error", () => {});
    req.on("close", () => resolve());
    req.end(step.body ?? "");
  });

const request = (port, step) => {
  printRequest(step);
  let req = null;
  return within(
    stepLimit,
    () =>
      new Promise((resolve) => {
        req = http.request(
          { host: "127.0.0.1", port, method: step.method ?? "GET", path: step.path, headers: step.headers ?? {}, agent },
          (res) => {
            const chunks = [];
            res.on("data", (chunk) => chunks.push(chunk));
            res.on("end", () => {
              printResponse(res, Buffer.concat(chunks).toString("utf8"));
              resolve();
            });
            res.on("error", (error) => {
              say(`< (error ${error.code ?? error.name})`);
              resolve();
            });
          },
        );
        req.on("error", (error) => {
          say(`< (error ${error.code ?? error.name})`);
          resolve();
        });
        req.end(step.body ?? "");
      }),
    () => {
      say(`< (no response in ${stepLimit} ms)`);
      req?.destroy();
    },
  );
};

// Bytes on a fresh connection, as they are: what comes back, first line
// only, and whether the server closed.
const rawStep = (port, text) => {
  say(`> (raw ${JSON.stringify(text)})`);
  // `{a*20000}` is that many of the character: a header block over
  // `maxHeaderSize` without a transcript that holds it.
  const bytes = text.replace(/\{(.)\*(\d+)\}/g, (_, ch, n) => ch.repeat(Number(n)));
  let socket = null;
  return within(
    stepLimit,
    () =>
      new Promise((resolve) => {
        let answer = "";
        socket = net.connect(port, "127.0.0.1", () => socket.write(bytes));
        socket.on("data", (chunk) => (answer += chunk));
        socket.on("error", (error) => say(`< (error ${error.code ?? error.name})`));
        socket.on("close", () => {
          if (answer !== "") say(`< ${answer.split("\r\n")[0]}`);
          say("< (closed by the server)");
          resolve();
        });
      }),
    () => {
      say("< (the server kept the connection open)");
      socket?.destroy();
    },
  );
};

// A request whose body stops short of its declared length: the headers,
// `declared` as the content-length, the body given, then the connection
// is reset. (A half-close with FIN leaves Node waiting for the rest until
// its keep-alive timeout; a reset is what a client that crashed sends.)
const cutStep = (port, step) => {
  say(`> (cut) ${step.method ?? "POST"} ${step.path}, content-length ${step.declared}, ${Buffer.byteLength(step.body ?? "")} bytes sent`);
  return within(
    stepLimit,
    () =>
      new Promise((resolve) => {
        const socket = net.connect(port, "127.0.0.1", () => {
          const head = [`${step.method ?? "POST"} ${step.path} HTTP/1.1`, "host: 127.0.0.1"];
          for (const [name, value] of Object.entries(step.headers ?? {})) head.push(`${name}: ${value}`);
          head.push(`content-length: ${step.declared}`, "", "");
          socket.write(head.join("\r\n"));
          socket.write(step.body ?? "", () => socket.destroy());
        });
        socket.on("error", () => {});
        socket.on("close", () => resolve());
      }),
    () => say("< (the cut connection did not close)"),
  );
};

// ---- Run --------------------------------------------------------------------

const address = await bound;
if (address === null) {
  say("(the program ended before it listened)");
} else {
  for (const step of steps) {
    if (step.raw !== undefined) await rawStep(address.port, step.raw);
    else if (step.cut !== undefined) await cutStep(address.port, step.cut);
    else if (step.signal !== undefined) {
      say(`> (signal ${step.signal})`);
      child.kill(step.signal);
    } else if (step.detach === true) detach(address.port, step);
    else if (step.abort === true) await abortStep(address.port, step);
    else if (step.cutResponse === true) await cutResponse(address.port, step);
    else await request(address.port, step);
  }
}
agent.destroy();
// A detached request still open when the program ends is answered by its
// connection's end, which the program's exit brings about.
if (pendingDetached !== 0) {
  await within(exitLimit, () => new Promise((resolve) => {
    const tick = setInterval(() => {
      if (pendingDetached !== 0) return;
      clearInterval(tick);
      resolve();
    }, 10);
  }), () => {});
}
if (detached.length !== 0) {
  say("--- detached ---");
  for (const lines of detached) for (const line of lines) say(line);
}

const end = await Promise.race([exited, new Promise((resolve) => setTimeout(() => resolve(null), exitLimit))]);
if (end === null) {
  child.kill("SIGKILL");
  await exited;
}

// Standard error without what varies by machine, by build or by Node's
// version: the project's path, Node's report of where a throw happened (the
// location line with its excerpt and caret: the build's file and line),
// stack frames, Node's version line, and the port and address a host
// error's properties name. A throw inside Node (an unhandled `error` event)
// is located in a `node:` module, and that line goes the same way.
const filterStderr = (text) => {
  const here = process.cwd();
  const real = fs.realpathSync(here);
  const lines = text
    .split("\n")
    .map((line) => line.replaceAll(`file://${real}`, "<project>").replaceAll(real, "<project>").replaceAll(here, "<project>"));
  const kept = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (/^(<project>\/\S+|node:\S+):\d+$/.test(line)) {
      kept.push("<project>/<file>:<line>");
      i += 2;
      continue;
    }
    if (line.startsWith("    at ")) {
      // The last frame of a report opens the error's properties.
      if (line.endsWith(" {")) kept.push("{");
      continue;
    }
    if (/^Node\.js v\d/.test(line)) continue;
    // A host error names the address and the port, in its message and in
    // its properties.
    kept.push(
      line
        .replace(/\b\d{1,3}(?:\.\d{1,3}){3}:\d+\b/g, "<address>:<port>")
        .replace(/^(\s+port: )\d+/, "$1<port>")
        .replace(/^(\s+address: )'[^']*'/, "$1'<address>'"),
    );
  }
  return kept.join("\n");
};

const section = (title, text) => {
  say(`--- ${title} ---`);
  if (text !== "") process.stdout.write(text.endsWith("\n") ? text : `${text}\n`);
};
section("stdout", Buffer.concat(captured.stdout).toString("utf8"));
section("stderr", filterStderr(Buffer.concat(captured.stderr).toString("utf8")));
if (end === null) say("--- exit killed: still running after the last step ---");
else if (end.signal !== undefined) say(`--- exit signal ${end.signal} ---`);
else say(`--- exit ${end.code} ---`);
