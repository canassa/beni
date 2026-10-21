// Loaded before a program `tests/serve/driver.mjs` starts, with `--import`
// (docs/design/boundary.md §9.10 (h)): the driver learns the address each
// server of the program binds, without the program printing it, so a
// fixture listens on port 0 and the port never reaches a transcript.
//
// `net.Server.prototype.listen` is wrapped: on each `listening` event the
// bound address goes to file descriptor 3, the pipe the driver opened, as
// one JSON line. Nothing else of the program is touched.
//
// A fault the script asks for (`BENI_SERVE_FAULT`, from a `{"fault": …}`
// step) makes the host fail in a way the platform does not name, so a
// fixture can assert that the program crashes (`boundary.md` §4.1's
// testable form): `listen:<code>[,<code>…]` makes the next `listen`s emit
// `error` with those codes in turn instead of binding; `request:<code>`
// makes the next request emit `error` with that code on `req` before its
// body ends; `server:<code>` makes the server emit `error` once it listens;
// `socket:<code>` makes a WebSocket emit `error` after its first bytes;
// `socket:errno=<name>` gives that error only the number, as Node gives
// one that libuv does not name (`ENETRESET`).

import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import process from "node:process";
import util from "node:util";

const fault = process.env.BENI_SERVE_FAULT ?? "";
const [faultWhere, faultCodes = ""] = fault.split(":");
// `listen:A,B` fails the next `listen`s in turn; the others take one code.
const listenCodes = faultWhere === "listen" ? faultCodes.split(",") : [];
const faultCode = faultCodes.split(",")[0];

// Shaped as Node shapes a bind failure: the message ends in `host:port`, and
// the properties name both, so the driver's scrubbing of them is exercised.
const hostError = (code, syscall, address, port) => {
  const where = address === undefined ? "" : ` ${address}:${port}`;
  const error = new Error(`${syscall} ${code}: injected by tests/serve/preload.mjs${where}`);
  error.code = code;
  error.syscall = syscall;
  if (address !== undefined) {
    error.address = address;
    error.port = port;
  }
  return error;
};

const listen = net.Server.prototype.listen;
let serverFaulted = false;

net.Server.prototype.listen = function (...args) {
  if (listenCodes.length !== 0) {
    const code = listenCodes.shift();
    // A macrotask, as a real bind failure is: every fiber that can run
    // before the host answers has run, so a fixture can cancel the waiter
    // first.
    const asked = typeof args[0] === "object" && args[0] !== null ? args[0] : {};
    const syscall = code.startsWith("EAI_") || code === "ENOTFOUND" ? "getaddrinfo" : "listen";
    setImmediate(() => this.emit("error", hostError(code, syscall, asked.host ?? "0.0.0.0", 54321)));
    return this;
  }
  this.once("listening", () => {
    const bound = this.address();
    const line = typeof bound === "string" ? { path: bound } : { address: bound.address, port: bound.port };
    fs.writeSync(3, `${JSON.stringify(line)}\n`);
    // The server fails after it listens, as an accept out of descriptors
    // does: the platform has no listener left on it, so Node throws it.
    if (faultWhere === "server" && !serverFaulted) {
      serverFaulted = true;
      setImmediate(() => this.emit("error", hostError(faultCode, "accept")));
    }
  });
  return listen.apply(this, args);
};

if (faultWhere === "request") {
  const emit = http.Server.prototype.emit;
  let requestFaulted = false;
  http.Server.prototype.emit = function (event, ...args) {
    const result = emit.call(this, event, ...args);
    if (event === "request" && !requestFaulted) {
      requestFaulted = true;
      const req = args[0];
      process.nextTick(() => req.emit("error", hostError(faultCode, "read")));
    }
    return result;
  };
}

// `socket:<code>`: the first bytes a client sends on a WebSocket after its
// upgrade are followed by an `error` with that code on the socket, a
// failure of the connection the platform does not name (§9.11 (i)).
// `socket:errno=<name>`: the error carries that errno, and its `code` is
// what Node makes of a number libuv has no name for.
const socketError = (spec) => {
  if (!spec.startsWith("errno=")) return hostError(spec, "read");
  const errno = -os.constants.errno[spec.slice("errno=".length)];
  const error = hostError(util.getSystemErrorName(errno), "read");
  error.errno = errno;
  return error;
};

if (faultWhere === "socket") {
  const emit = http.Server.prototype.emit;
  let socketFaulted = false;
  http.Server.prototype.emit = function (event, ...args) {
    const result = emit.call(this, event, ...args);
    if (event === "upgrade" && !socketFaulted) {
      socketFaulted = true;
      const socket = args[1];
      // As Node fails a socket: `error`, then `close`.
      socket.once("data", () => process.nextTick(() => socket.destroy(socketError(faultCode))));
    }
    return result;
  };
}
