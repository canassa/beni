// The sibling JavaScript of `Http/Server.beni` (docs/design/boundary.md §4,
// §9.10): one export per `foreign` value, under the same name, and nothing
// else.
//
// A handle is `{ server, address, queue, waiter, closing, closed, waiters,
// sockets, upgrades }`: the `http.Server`, the address it bound, the
// requests that arrived whole and wait for the accept loop, the loop's
// `Resume` while it waits, the fibers waiting in `Http.Server.wait`, the
// sockets that a WebSocket upgrade took from Node, and those upgrades
// (docs/design/boundary.md §9.11 (e), (g)). Node's `closeAllConnections`
// does not reach an upgraded socket, so the platform destroys them itself. Each primitive starts one host
// operation, resumes the waiting fiber once, and returns what cancels it.
//
// Every failure Node documents is caught by its code, and nothing else is
// caught (CLAUDE.md rule 9): anything else is thrown again, and Node
// reports it and exits 1 (transparent-effects-proposal.md §16.5).

import { Buffer } from "node:buffer";
import http from "node:http";
import os from "node:os";
import process from "node:process";

// `ListenError`'s constructor for each failure Node documents for
// `server.listen`, by the error's `code`. All nullary, so a constructor
// is its tag, the same string in a release build (boundary.md §4).
const listenErrors = {
  EADDRINUSE: "AddressInUse",
  EACCES: "PermissionDenied",
  EADDRNOTAVAIL: "AddressNotAvailable",
  // The address's family (IPv6, say) is off on this machine.
  EAFNOSUPPORT: "AddressNotAvailable",
  // `getaddrinfo` could not answer the host's name, or not now.
  ENOTFOUND: "HostNotFound",
  EAI_AGAIN: "HostNotFound",
  EAI_FAIL: "HostNotFound",
  EMFILE: "TooManyOpenFiles",
  ENFILE: "TooManyOpenFiles",
};

// A request whose `upgrade` header is `websocket` goes to the `upgrade`
// event, and every other one, with another `upgrade` header too, to
// `request` (Node 24's `shouldUpgradeCallback`).
// `upgrade` is a comma list matched without case (§9.11, amendment item 22).
const tokens = (value) => (typeof value === "string" ? value.split(",").map((t) => t.trim().toLowerCase()) : []);
const asksForWebSocket = (req) => tokens(req.headers.upgrade).includes("websocket");

export const startListen = (address, upgrades, resume) => {
  const server = upgrades ? http.createServer({ shouldUpgradeCallback: asksForWebSocket }) : http.createServer();
  const handle = { server, address: null, queue: [], waiter: null, closing: false, closed: false, waiters: [], sockets: new Set(), upgrades: new Set() };
  // Set once the wait is over, or cancelled: the fiber is answered at most
  // once, and a cancelled one not at all.
  let settled = false;
  const refused = (error) => {
    // An unnamed code is a defect whether or not anyone still waits.
    const code = error instanceof Error ? error.code : undefined;
    if (typeof code !== "string" || !Object.hasOwn(listenErrors, code)) throw error;
    // Cancelled while binding: no one waits for the answer.
    if (settled) return;
    settled = true;
    resume({ $: "Err", a: listenErrors[code] });
  };
  server.once("error", refused);
  server.once("listening", () => {
    server.off("error", refused);
    const bound = server.address();
    handle.address = { host: bound.address, port: bound.port };
    if (settled) {
      // Cancelled while binding: nothing waits, so the server closes now.
      server.close();
      return;
    }
    settled = true;
    server.on("request", (req, res) => receive(handle, req, res));
    if (upgrades) server.on("upgrade", (req, socket, head) => upgrade(handle, req, socket, head));
    server.on("close", () => {
      handle.closed = true;
      deliver(handle);
      const waiters = handle.waiters;
      handle.waiters = [];
      for (const waiter of waiters) waiter(null);
    });
    resume({ $: "Ok", a: handle });
  });
  server.listen({ host: address.host, port: address.port });
  return (unit) => {
    settled = true;
    return unit;
  };
};

// A request as it arrives: its body collected whole, then queued for the
// accept loop. A client that closes the connection before the body is whole
// is `req`'s `error` with `ECONNRESET`, and the request is dropped: there is
// no one to answer.
const receive = (handle, req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("error", (error) => {
    if (error instanceof Error && error.code === "ECONNRESET") return;
    throw error;
  });
  // A connection that fails while the response is written is the socket's
  // error, which Node routes to `clientError` and handles by default, and
  // `res` emits none (measured): no listener is needed on it.
  req.on("end", () => {
    const request = requestFrom(req, new TextDecoder().decode(Buffer.concat(chunks)));
    handle.queue.push({ handle, req, res, request });
    deliver(handle);
  });
};

// The codes of `error` on a socket that mean one client is gone (§9.11,
// amendment item 15): the same list as `WebSocket.js`'s, since the two
// siblings cannot share a file.
const gone = new Set([
  "ECONNRESET",
  "EPIPE",
  "ETIMEDOUT",
  "ENETUNREACH",
  "EHOSTUNREACH",
  "EHOSTDOWN",
  "ENONET",
  "ENOPROTOOPT",
  "ECONNREFUSED",
  "ENOTSUP",
  "EPROTO",
  "EACCES",
  "ECONNABORTED",
  "ENETDOWN",
]);

// One client's connection is gone: an `error` whose `code` is in `gone`,
// or whose number is `ENETRESET` (macOS and the BSDs), which libuv does not
// name, so its `code` is not `ENETRESET` (§9.11, amendment item 15).
const isGone = (error) => error instanceof Error && (gone.has(error.code) || error.errno === -os.constants.errno.ENETRESET);

// A request for a WebSocket (§9.11 (e)): its handshake is checked, then it
// waits for the accept loop with no body. A client that goes away while
// the program decides is the socket's `error` with a code of `gone`,
// which ends nothing else; `WebSocket.js` takes the socket over on accept.
const upgrade = (handle, req, socket, head) => {
  handle.sockets.add(socket);
  socket.on("close", () => handle.sockets.delete(socket));
  const waiting = (error) => {
    if (isGone(error)) return;
    throw error;
  };
  socket.on("error", waiting);
  const fault = handshakeFault(req);
  if (fault !== null) {
    writeRaw(socket, fault.status, fault.headers, Buffer.alloc(0));
    return;
  }
  const incoming = { handle, req, res: null, socket, head, waiting, goAway: null, request: requestFrom(req, "") };
  handle.upgrades.add(incoming);
  socket.on("close", () => handle.upgrades.delete(incoming));
  handle.queue.push(incoming);
  deliver(handle);
};

// RFC 6455 §4.2.1: what the server checks of a client's handshake, and
// the answer to one that fails: 426 for another version, 400 otherwise.
// Node checks only that `connection` holds `upgrade` and that an
// `upgrade` header exists; the method, the HTTP version and `host` are
// checked here (amendment item 22).
const handshakeFault = (req) => {
  const bad = { status: 400, headers: [] };
  if (req.method !== "GET") return bad;
  if (req.httpVersionMajor < 1 || (req.httpVersionMajor === 1 && req.httpVersionMinor < 1)) return bad;
  if (typeof req.headers.host !== "string") return bad;
  if (!tokens(req.headers.connection).includes("upgrade")) return bad;
  const version = req.headers["sec-websocket-version"];
  if (version !== "13") return { status: 426, headers: ["sec-websocket-version", "13"] };
  const key = req.headers["sec-websocket-key"];
  if (typeof key !== "string" || !/^[A-Za-z0-9+/]{21}[AQgw]==$/.test(key.trim())) return bad;
  return null;
};

// An HTTP/1.1 response written on a socket that Node gave up, then the end
// of the connection: a refused or a failed upgrade.
const writeRaw = (socket, status, headers, body) => {
  if (socket.destroyed || !socket.writable) return;
  const lines = [`HTTP/1.1 ${status} ${http.STATUS_CODES[status] ?? ""}`, `date: ${new Date().toUTCString()}`];
  for (let i = 0; i < headers.length; i += 2) lines.push(`${headers[i]}: ${headers[i + 1]}`);
  if (status !== 204 && status !== 304) lines.push(`content-length: ${body.length}`);
  lines.push("connection: close");
  socket.end(Buffer.concat([Buffer.from(`${lines.join("\r\n")}\r\n\r\n`, "latin1"), body]));
  socket.destroySoon();
};

// The request a handler is given, from Node's `IncomingMessage` and its
// body.
const requestFrom = (req, body) => {
  const headers = [];
  for (let i = 0; i < req.rawHeaders.length; i += 2) {
    headers.push({ a: req.rawHeaders[i].toLowerCase(), b: req.rawHeaders[i + 1] });
  }
  return { method: req.method, path: req.url, headers, body };
};

// Hand the accept loop the next request, or null once the server has
// closed, when it waits for one.
const deliver = (handle) => {
  if (handle.waiter === null) return;
  if (handle.queue.length !== 0) {
    const resume = handle.waiter;
    handle.waiter = null;
    resume(handle.queue.shift());
  } else if (handle.closed) {
    const resume = handle.waiter;
    handle.waiter = null;
    resume(null);
  }
};

export const nextRequest = (handle, resume) => {
  handle.waiter = resume;
  deliver(handle);
  return (unit) => {
    // The loop's fiber was cancelled, with the fiber that owns the server:
    // every connection is destroyed and the server closes at once.
    handle.waiter = null;
    handle.closing = true;
    handle.server.closeAllConnections();
    for (const socket of handle.sockets) socket.destroy();
    handle.server.close();
    return unit;
  };
};

export const requestOf = (incoming) => incoming.request;

export const isUpgrade = (incoming) => incoming.res === null;

// A refused upgrade: the program's response, checked as `write` checks
// one, written on the socket, and the connection ended.
export const refuseUpgrade = (incoming, response) => {
  const fault = invalid(response);
  if (fault !== null) return invalidUpgrade(incoming, `the response is invalid: ${fault}`);
  const headers = [];
  for (const header of listOf(response.headers)) {
    if (header.a.toLowerCase() === "connection") continue;
    headers.push(header.a, header.b);
  }
  const body = response.status === 204 || response.status === 304 ? Buffer.alloc(0) : Buffer.from(response.body, "utf8");
  writeRaw(incoming.socket, response.status, headers, body);
  return null;
};

// An answer to an upgrade that the platform cannot give: 500, and a line on
// standard error, as for an invalid response (§9.10 (d)).
export const invalidUpgrade = (incoming, fault) => {
  const { req, socket } = incoming;
  process.stderr.write(`beni: Http.Server: the answer to the WebSocket request ${req.method} ${req.url} is invalid: ${fault}\n`);
  writeRaw(socket, 500, [], Buffer.alloc(0));
  return null;
};

// A beni `List` as an array: a plain array, or a view of one
// (docs/design/backend.md §4).
const listOf = (list) => (Array.isArray(list) ? list : list.$b.slice(list.$o));

// Why a `Response` cannot be written as it is, or null. The checks are
// Node's own, run before any header is set and before the first byte is
// sent, so a fault leaves nothing behind: the status rule of `writeHead`
// less the interim statuses (a handler answers once, and Node resets the
// connection on a final 100), the two statuses that carry no body,
// `validateHeaderName` and `validateHeaderValue` — caught from those two
// calls alone — and the two headers the transport owns.
const invalid = (response) => {
  const status = response.status;
  if (!Number.isInteger(status) || status < 200 || status > 999) {
    return `status ${status} is not an integer from 200 to 999`;
  }
  if ((status === 204 || status === 205 || status === 304) && response.body !== "") {
    return `status ${status} carries no body, and the body is not empty`;
  }
  const headers = listOf(response.headers);
  for (const header of headers) {
    const name = header.a;
    const value = header.b;
    try {
      http.validateHeaderName(name);
    } catch (error) {
      if (error instanceof TypeError && error.code === "ERR_INVALID_HTTP_TOKEN") return `the header name ${JSON.stringify(name)} is not a token`;
      throw error;
    }
    try {
      http.validateHeaderValue(name, value);
    } catch (error) {
      if (error instanceof TypeError && error.code === "ERR_INVALID_CHAR") return `the header ${JSON.stringify(name)} has a character its value cannot hold`;
      if (error instanceof TypeError && error.code === "ERR_HTTP_INVALID_HEADER_VALUE") return `the header ${JSON.stringify(name)} has no value`;
      throw error;
    }
    const lower = name.toLowerCase();
    if (lower === "content-length" || lower === "transfer-encoding") return `the header ${JSON.stringify(name)} belongs to the platform`;
  }
  return null;
};

export const write = (incoming, response) => {
  const { handle, req, res } = incoming;
  // The client is gone: Node drops the write, and so does the platform.
  if (res.destroyed) return null;
  const fault = invalid(response);
  if (fault !== null) {
    process.stderr.write(`beni: Http.Server: the response to ${req.method} ${req.url} is invalid: ${fault}\n`);
    // After `close`, the 500 ends its connection as every response does.
    res.writeHead(500, handle.closing ? ["content-length", "0", "connection", "close"] : ["content-length", "0"]);
    res.end();
    return null;
  }
  const headers = listOf(response.headers);
  const raw = [];
  for (const header of headers) {
    // After `close`, the connection ends with this response, whatever the
    // program said: Node leaves a busy keep-alive connection open otherwise.
    if (handle.closing && header.a.toLowerCase() === "connection") continue;
    raw.push(header.a, header.b);
  }
  if (handle.closing) raw.push("connection", "close");
  const body = Buffer.from(response.body, "utf8");
  // 204, 205 and 304 carry no body: Node drops one for 204 and 304 and
  // writes it for 205 (measured), so the body is empty here. 204 and 304
  // get no `content-length`; 205 gets `content-length: 0`, since Node
  // would otherwise send a chunked empty body. The headers go as one flat
  // array, so a name given twice is written twice, in order (`setHeader`
  // would keep one value per name).
  if (response.status !== 204 && response.status !== 304) raw.push("content-length", String(body.length));
  res.writeHead(response.status, raw);
  res.end(body);
  return null;
};

export const awaitClosed = (handle, resume) => {
  if (handle.closed) {
    resume(null);
    return (unit) => unit;
  }
  handle.waiters.push(resume);
  return (unit) => {
    const i = handle.waiters.indexOf(resume);
    if (i >= 0) handle.waiters.splice(i, 1);
    return unit;
  };
};

export const beginClose = (handle) => {
  if (handle.closing) return null;
  handle.closing = true;
  handle.server.close();
  handle.server.closeIdleConnections();
  // Each open WebSocket connection is closed with 1001 (§9.11 (g)); one
  // that opens later is closed as it opens.
  for (const incoming of handle.upgrades) if (incoming.goAway !== null) incoming.goAway();
  return null;
};

export const boundAddress = (handle) => handle.address;
