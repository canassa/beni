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
//
// A script also drives WebSocket clients by name (docs/design/boundary.md
// §9.11 (l)) — `socket`, `answer`, `send`, `ping`, `close`, `receive`,
// `pause`, `resume`, `drop` and `reset` steps — through the small RFC 6455
// client below; tests/corpus/README.md lists them.

import { spawn } from "node:child_process";
import crypto from "node:crypto";
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

// ---- WebSocket clients ------------------------------------------------------

// The driver's own RFC 6455 client (docs/design/boundary.md §9.11 (l)), so a
// script can also send the frames no conforming client sends. Each socket
// has a name; what the server sends it is kept, in order, until a
// `receive` step takes it. A close frame the server sends first is
// answered at once with the same code, as a browser answers one.
const sockets = new Map();
// A fixed mask, so the bytes on the wire are the same on every run.
const clientMask = Buffer.from([0x37, 0xfa, 0x21, 0x3d]);

const clientFrame = ({ fin = true, rsv = 0, opcode, payload, mask = true, length = undefined }) => {
  const n = payload.length;
  const declared = length ?? n;
  const head = declared < 126 ? 2 : declared < 65536 ? 4 : 10;
  const out = Buffer.alloc(head + (mask ? 4 : 0) + n);
  out[0] = (fin ? 0x80 : 0) | (rsv << 4) | opcode;
  out[1] = mask ? 0x80 : 0;
  if (declared < 126) out[1] |= declared;
  else if (declared < 65536) {
    out[1] |= 126;
    out.writeUInt16BE(declared, 2);
  } else {
    out[1] |= 127;
    out.writeBigUInt64BE(BigInt(declared), 2);
  }
  let at = head;
  if (mask) {
    clientMask.copy(out, at);
    at += 4;
  }
  for (let i = 0; i < n; i++) out[at + i] = mask ? payload[i] ^ clientMask[i & 3] : payload[i];
  return out;
};

const closePayload = (code, reason) => {
  if (code === undefined) return Buffer.alloc(0);
  const text = Buffer.from(reason ?? "", "utf8");
  const out = Buffer.alloc(2 + text.length);
  out.writeUInt16BE(code, 0);
  text.copy(out, 2);
  return out;
};

// What arrives on a socket, frame by frame, into its inbox: a text message
// (`"…"`), a pong, a close, or the end of the connection.
const readFrames = (ws) => {
  for (;;) {
    const buf = ws.buffer;
    if (buf.length < 2) return;
    const opcode = buf[0] & 0x0f;
    let length = buf[1] & 0x7f;
    let at = 2;
    if (length === 126) {
      if (buf.length < 4) return;
      length = buf.readUInt16BE(2);
      at = 4;
    } else if (length === 127) {
      if (buf.length < 10) return;
      length = Number(buf.readBigUInt64BE(2));
      at = 10;
    }
    if (buf.length < at + length) return;
    const payload = buf.subarray(at, at + length);
    ws.buffer = buf.subarray(at + length);
    if (opcode === 0x1) ws.inbox.push(JSON.stringify(payload.toString("utf8")));
    else if (opcode === 0x2) ws.inbox.push(`binary ${payload.length} bytes`);
    else if (opcode === 0xa) ws.inbox.push(`pong ${JSON.stringify(payload.toString("utf8"))}`);
    else if (opcode === 0x9) ws.socket.write(clientFrame({ opcode: 0xa, payload }));
    else if (opcode === 0x8) {
      const code = payload.length >= 2 ? payload.readUInt16BE(0) : undefined;
      const reason = payload.length > 2 ? payload.subarray(2).toString("utf8") : "";
      ws.inbox.push(code === undefined ? "close (no code)" : `close ${code} ${JSON.stringify(reason)}`);
      if (!ws.closing && !ws.mute) ws.socket.write(clientFrame({ opcode: 0x8, payload: closePayload(code, reason) }));
      ws.closing = true;
    }
    wake(ws);
  }
};

const wake = (ws) => {
  const waiter = ws.waiter;
  if (waiter === null || ws.inbox.length === 0) return;
  ws.waiter = null;
  waiter();
};

// `{"socket": "a", "path": "/arena", "protocols": ["v1"], "headers": {…}}`:
// a client named `a` asks for a WebSocket. The answer is printed as a
// response is; a `101` is checked for its `sec-websocket-accept`.
const openSocket = (port, step) => {
  const name = step.socket;
  const asked = [
    step.http === undefined ? "" : ` HTTP/${step.http}`,
    step.host === false ? " (no host)" : "",
    step.upgrade === undefined ? "" : ` (upgrade: ${step.upgrade})`,
    step.version === undefined ? "" : ` (version ${step.version})`,
    step.key === undefined ? "" : ` (key ${step.key})`,
    step.protocols === undefined ? "" : ` ${JSON.stringify(step.protocols)}`,
    step.wait === false ? " (not waited for)" : "",
  ].join("");
  say(`> (socket ${name}) ${step.method ?? "GET"} ${step.path}${asked}`);
  // The answer's lines, printed when the step ends — or, for a socket
  // opened with `"wait": false`, by the `answer` step that waits for them.
  const lines = [];
  const opened = opening(port, step, name, (line) => lines.push(line));
  if (step.wait === false) {
    pending.set(name, opened.then(() => lines));
    return Promise.resolve();
  }
  return opened.then(() => {
    for (const line of lines) say(line);
  });
};

// The answers of sockets opened with `"wait": false`, by name.
const pending = new Map();

const answerStep = async (step) => {
  const lines = await pending.get(step.answer);
  pending.delete(step.answer);
  if (lines.length === 0) say(`< (socket ${step.answer}) (no answer: the connection ended)`);
  for (const line of lines) say(line);
};

const opening = (port, step, name, say) => {
  const key = Buffer.from(`beni-driver-${name}`.padEnd(16, "-").slice(0, 16)).toString("base64");
  return within(
    stepLimit,
    () =>
      new Promise((resolve) => {
        const socket = net.connect(port, "127.0.0.1", () => {
          const head = [
            `${step.method ?? "GET"} ${step.path} HTTP/${step.http ?? "1.1"}`,
            ...(step.host === false ? [] : ["host: 127.0.0.1"]),
            "connection: Upgrade",
            `upgrade: ${step.upgrade ?? "websocket"}`,
            `sec-websocket-version: ${step.version ?? "13"}`,
            `sec-websocket-key: ${step.key ?? key}`,
          ];
          if (step.protocols !== undefined) head.push(`sec-websocket-protocol: ${step.protocols.join(", ")}`);
          for (const [h, value] of Object.entries(step.headers ?? {})) head.push(`${h}: ${value}`);
          head.push("", "");
          socket.write(head.join("\r\n"));
        });
        let text = Buffer.alloc(0);
        const ws = { socket, buffer: Buffer.alloc(0), inbox: [], waiter: null, closing: false, mute: step.mute === true, ended: false };
        // Named at once, so `drop` and `reset` reach a socket whose answer
        // has not come yet.
        sockets.set(name, ws);
        const onData = (chunk) => {
          text = Buffer.concat([text, chunk]);
          const end = text.indexOf("\r\n\r\n");
          if (end === -1) return;
          const lines = text.subarray(0, end).toString("latin1").split("\r\n");
          const status = Number(lines[0].split(" ")[1]);
          say(`< (socket ${name}) ${status}`);
          for (const line of lines.slice(1)) {
            const colon = line.indexOf(":");
            const h = line.slice(0, colon).toLowerCase();
            const value = line.slice(colon + 1).trim();
            if (h === "date") continue;
            if (h === "sec-websocket-accept") {
              const want = crypto.createHash("sha1").update(`${step.key ?? key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
              say(`< (socket ${name}) sec-websocket-accept: ${value === want ? "(the right key)" : value}`);
              continue;
            }
            say(`< (socket ${name}) ${h}: ${value}`);
          }
          socket.off("data", onData);
          const rest = text.subarray(end + 4);
          if (status === 101) {
            sockets.set(name, ws);
            socket.on("data", (chunk) => {
              ws.buffer = Buffer.concat([ws.buffer, chunk]);
              readFrames(ws);
            });
            if (rest.length !== 0) {
              ws.buffer = rest;
              readFrames(ws);
            }
          } else {
            // A refusal ends the connection after its body, which can come in
            // more than one chunk: read to the end.
            let body = rest;
            socket.on("data", (chunk) => {
              body = Buffer.concat([body, chunk]);
            });
            socket.once("close", () => {
              const text = body.toString("utf8");
              if (text !== "") {
                say(`< (socket ${name})`);
                for (const line of text.split("\n")) say(`< (socket ${name}) ${line}`);
              }
              resolve();
            });
            return;
          }
          resolve();
        };
        socket.on("data", onData);
        socket.on("error", () => {});
        socket.on("close", () => {
          ws.ended = true;
          ws.inbox.push("(the connection ended)");
          wake(ws);
          resolve();
        });
      }),
    () => say(`< (socket ${name}) (no answer)`),
  );
};

const socketNamed = (name) => {
  const ws = sockets.get(name);
  if (ws === undefined) throw new Error(`the script has no open socket named ${name}`);
  return ws;
};

// The other steps on a named socket: send a text message, a close or a
// ping, or any frame; take what the server sent next; stop or start
// reading; drop the TCP connection.
const socketStep = async (step) => {
  if (step.send !== undefined) {
    const ws = socketNamed(step.send);
    if (step.frame !== undefined) {
      const f = step.frame;
      const payload = f.hex !== undefined ? Buffer.from(f.hex, "hex") : Buffer.from(f.text ?? "", "utf8");
      say(`> (socket ${step.send}) frame ${JSON.stringify(f)}`);
      ws.socket.write(clientFrame({ fin: f.fin ?? true, rsv: f.rsv ?? 0, opcode: f.opcode, payload, mask: f.mask ?? true, length: f.length }));
    } else if (step.repeat !== undefined) {
      // `"repeat": n, "bytes": b`: n messages of b bytes, each `<i> ` then
      // `x`s, for i from 1, in one write.
      say(`> (socket ${step.send}) ${step.repeat} messages of ${step.bytes} bytes, "<i> xx…"`);
      const frames = [];
      for (let i = 1; i <= step.repeat; i++) frames.push(clientFrame({ opcode: 0x1, payload: Buffer.from(`${i} `.padEnd(step.bytes, "x"), "utf8") }));
      ws.socket.write(Buffer.concat(frames));
    } else {
      say(`> (socket ${step.send}) ${JSON.stringify(step.text)}`);
      ws.socket.write(clientFrame({ opcode: 0x1, payload: Buffer.from(step.text, "utf8") }));
    }
  } else if (step.ping !== undefined) {
    say(`> (socket ${step.ping}) ping ${JSON.stringify(step.text ?? "")}`);
    socketNamed(step.ping).socket.write(clientFrame({ opcode: 0x9, payload: Buffer.from(step.text ?? "", "utf8") }));
  } else if (step.close !== undefined) {
    const ws = socketNamed(step.close);
    say(`> (socket ${step.close}) close${step.code === undefined ? "" : ` ${step.code} ${JSON.stringify(step.reason ?? "")}`}`);
    ws.closing = true;
    ws.socket.write(clientFrame({ opcode: 0x8, payload: closePayload(step.code, step.reason) }));
  } else if (step.receive !== undefined && step.until !== undefined) {
    // `"until": "<text>"`: every message up to the first that is `text`,
    // which is printed; how many came before it is not.
    const ws = socketNamed(step.receive);
    const want = JSON.stringify(step.until);
    let found = false;
    while (!found) {
      if (ws.inbox.length === 0) {
        let late = false;
        await within(
          stepLimit,
          () =>
            new Promise((resolve) => {
              if (ws.inbox.length !== 0) return resolve();
              ws.waiter = resolve;
            }),
          () => {
            ws.waiter = null;
            late = true;
          },
        );
        if (late) break;
      }
      found = ws.inbox.shift() === want;
    }
    say(`< (socket ${step.receive}) ${found ? `… ${want}` : `(no ${want} arrived)`}`);
  } else if (step.receive !== undefined && step.count !== undefined) {
    // `"count": n`: the next `n` text messages, summed up in one line.
    const ws = socketNamed(step.receive);
    let messages = 0;
    let bytes = 0;
    while (messages < step.count) {
      if (ws.inbox.length === 0) {
        let late = false;
        await within(
          stepLimit,
          () =>
            new Promise((resolve) => {
              if (ws.inbox.length !== 0) return resolve();
              ws.waiter = resolve;
            }),
          () => {
            ws.waiter = null;
            late = true;
          },
        );
        if (late) break;
      }
      const next = ws.inbox[0];
      if (!next.startsWith('"')) break;
      ws.inbox.shift();
      messages += 1;
      bytes += Buffer.byteLength(JSON.parse(next), "utf8");
    }
    say(`< (socket ${step.receive}) ${messages} messages, ${bytes} bytes`);
  } else if (step.receive !== undefined) {
    const ws = socketNamed(step.receive);
    await within(
      stepLimit,
      () =>
        new Promise((resolve) => {
          if (ws.inbox.length !== 0) return resolve();
          ws.waiter = resolve;
        }),
      () => {
        ws.waiter = null;
        say(`< (socket ${step.receive}) (nothing arrived)`);
      },
    );
    if (ws.inbox.length !== 0) say(`< (socket ${step.receive}) ${ws.inbox.shift()}`);
  } else if (step.pause !== undefined) {
    say(`> (socket ${step.pause}) (stops reading)`);
    socketNamed(step.pause).socket.pause();
  } else if (step.resume !== undefined) {
    say(`> (socket ${step.resume}) (reads again)`);
    socketNamed(step.resume).socket.resume();
  } else if (step.drop !== undefined) {
    say(`> (socket ${step.drop}) (drops the connection)`);
    socketNamed(step.drop).socket.destroy();
  } else if (step.reset !== undefined) {
    say(`> (socket ${step.reset}) (resets the connection)`);
    socketNamed(step.reset).socket.resetAndDestroy();
  }
};

// ---- Run --------------------------------------------------------------------

const address = await bound;
if (address === null) {
  say("(the program ended before it listened)");
} else {
  for (const step of steps) {
    if (step.socket !== undefined) await openSocket(address.port, step);
    else if (step.answer !== undefined) await answerStep(step);
    else if (step.send !== undefined || step.ping !== undefined || step.close !== undefined || step.receive !== undefined || step.pause !== undefined || step.resume !== undefined || step.drop !== undefined || step.reset !== undefined) await socketStep(step);
    else if (step.raw !== undefined) await rawStep(address.port, step.raw);
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

// `<port>` for the port the program bound, which the system picked; any
// other port as it is.
const boundPort = (port) => (address !== null && Number(port) === address.port ? "<port>" : port);

// Standard error without what varies by machine, by build, by Node's
// version or by the clock: the project's path, Node's report of where a
// throw happened (the location line with its excerpt and caret: the
// build's file and line), stack frames, Node's version line, an IPv4
// address, the port the program bound (`address.port`; any other port is
// kept, so a line that names the wrong one differs), and the time of a
// `logfmt` line with `timestamp` first (`Io.run`'s sink). A throw inside
// Node (an unhandled `error` event) is located in a `node:` module, and
// that line goes the same way.
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
    // its properties; a log line, the time it was written.
    kept.push(
      line
        .replace(/^timestamp=\S+ /, "timestamp=<time> ")
        .replace(/\b\d{1,3}(?:\.\d{1,3}){3}:(\d+)\b/g, (_, port) => `<address>:${boundPort(port)}`)
        .replace(/^(\s+port: )(\d+)/, (_, key, port) => `${key}${boundPort(port)}`)
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
